from __future__ import annotations

import time
from collections.abc import Callable
from unittest.mock import AsyncMock

import httpx
import pytest
from fastapi import FastAPI

from app.main import create_app
from tests.helpers import CLOSED_PORT_URL, make_settings, requires_db


async def test_health_response_shape_when_db_ok(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("app.modules.core.api.db_ping", AsyncMock(return_value=True))
    response = await client.get("/health")  # no auth header: public
    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "db": "ok",
        "env": "test",
        "version": "3f2c1ab",
        "time": "2026-11-08T09:00:00Z",
    }


@requires_db
async def test_health_ok(client: httpx.AsyncClient) -> None:
    """CORE-AC-01 against a real Postgres (CI service container)."""
    response = await client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"
    assert response.json()["db"] == "ok"


async def test_health_db_down_returns_503(make_client: Callable[[FastAPI], httpx.AsyncClient]) -> None:
    """CORE-AC-02: engine pointed at a closed port -> 503 `degraded` within 5 s."""
    application = create_app(make_settings(database_url=CLOSED_PORT_URL))
    async with application.router.lifespan_context(application), make_client(application) as client:
        started = time.perf_counter()
        response = await client.get("/health")
        elapsed = time.perf_counter() - started
    assert response.status_code == 503
    body = response.json()
    assert body["status"] == "degraded"
    assert body["db"] == "unavailable"
    assert elapsed < 5


async def test_docs_hidden_in_prod(make_client: Callable[[FastAPI], httpx.AsyncClient]) -> None:
    application = create_app(make_settings(env="prod", database_ssl="require"))
    async with application.router.lifespan_context(application), make_client(application) as client:
        for path in ("/docs", "/openapi.json", "/redoc"):
            assert (await client.get(path)).status_code == 404


async def test_docs_available_outside_prod(client: httpx.AsyncClient) -> None:
    assert (await client.get("/openapi.json")).status_code == 200
