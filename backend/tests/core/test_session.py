"""CORE-AC-12: transaction semantics of ``get_session``.

``get_session`` only needs ``app.state.session_factory``, so these tests use a throw-away SQLite file through
aiosqlite - no Postgres needed - and exercise the real dependency through the real app.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from fastapi import FastAPI
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.modules.core import SessionDep, build_session_factory
from tests.helpers import ClientFactory


@pytest.fixture
async def db_app(app: FastAPI, tmp_path: Path) -> AsyncIterator[FastAPI]:
    engine: AsyncEngine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path / 'session-test.db'}")
    async with engine.begin() as conn:
        await conn.execute(text("CREATE TABLE item (id INTEGER PRIMARY KEY, name TEXT NOT NULL)"))
    factory = build_session_factory(engine)
    app.state.session_factory = factory  # replace the (unused) Postgres factory built by the lifespan

    async def add(name: str, session: SessionDep) -> dict[str, str]:
        await session.execute(text("INSERT INTO item (name) VALUES (:n)"), {"n": name})
        return {"added": name}

    async def add_then_fail(session: SessionDep) -> None:
        await session.execute(text("INSERT INTO item (name) VALUES ('doomed')"))
        raise RuntimeError("handler failed after writing")

    app.add_api_route("/_t/add/{name}", add, methods=["POST"])
    app.add_api_route("/_t/fail", add_then_fail, methods=["POST"])
    yield app
    await engine.dispose()


async def _names(app: FastAPI) -> list[str]:
    async with app.state.session_factory() as session:
        rows = await session.execute(text("SELECT name FROM item ORDER BY id"))
        return [r[0] for r in rows]


async def test_rollback_on_exception(db_app: FastAPI, make_client: ClientFactory) -> None:
    async with make_client(db_app) as client:
        response = await client.post("/_t/fail")
    assert response.status_code == 500
    assert await _names(db_app) == []


async def test_write_committed_before_response(db_app: FastAPI, make_client: ClientFactory) -> None:
    """The row is already visible to a *new* session when the response starts (dependency scope="function")."""
    seen_at_response_start: list[list[str]] = []

    class Probe:
        def __init__(self, inner: ASGIApp) -> None:
            self.inner = inner

        async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
            async def send_probe(message: Message) -> None:
                if message["type"] == "http.response.start" and scope["path"].startswith("/_t/add"):
                    seen_at_response_start.append(await _names(db_app))
                await send(message)

            await self.inner(scope, receive, send_probe)

    import httpx

    transport = httpx.ASGITransport(app=Probe(db_app))
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.post("/_t/add/alpha")
    assert response.status_code == 200
    assert seen_at_response_start == [["alpha"]]
    assert await _names(db_app) == ["alpha"]
