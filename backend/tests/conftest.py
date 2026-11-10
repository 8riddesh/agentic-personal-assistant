"""Shared fixtures (core spec §11). Tests never touch the network.

Database: when ``TEST_DATABASE_URL`` is set (CI Postgres service container) the schema comes from ``alembic upgrade
head`` and every test starts from truncated tables. Otherwise a throw-away SQLite file with ``create_all`` is used,
so the whole suite also runs on a machine without Postgres (advisory locks and Postgres-only constraints are the
only things that then go untested).
"""

from __future__ import annotations

import logging
import os
import subprocess
import sys
from collections.abc import AsyncIterator, Callable, Iterator
from datetime import UTC, datetime
from pathlib import Path
from uuid import UUID

import httpx
import pytest
from fastapi import FastAPI
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, create_async_engine

import app.modules.auth.models as auth_models
import app.modules.core.models as core_models
import app.modules.day_cycle.models as day_models
import app.modules.tasks.models as task_models
from app.main import create_app
from app.modules.auth.schemas import JwtClaims
from app.modules.auth.security import encode_jwt
from app.modules.core import (
    Base,
    FakeClock,
    Settings,
    build_engine,
    build_session_factory,
)
from app.modules.crypto import FieldCipher, configure_cipher, reset_cipher
from tests.helpers import TEST_DATABASE_URL, TEST_ENCRYPTION_KEYS, make_settings

BACKEND_DIR = Path(__file__).resolve().parents[1]
_MODEL_MODULES = (core_models, auth_models, task_models, day_models)  # imported so Base.metadata is complete
_TABLES = ("task_status_event", "task", "task_template", "day_session", "app_settings", "user_account")


@pytest.fixture(autouse=True)
def _restore_logging() -> Iterator[None]:
    """configure_logging() replaces root handlers (bound to a test's captured stdout): undo after each test."""
    root = logging.getLogger()
    handlers, level = root.handlers[:], root.level
    yield
    root.handlers[:] = handlers
    root.setLevel(level)


@pytest.fixture(autouse=True)
def cipher() -> Iterator[FieldCipher]:
    """The process-wide cipher, configured like the app lifespan does (same fixed, obviously-fake test key)."""
    c = FieldCipher.from_config(TEST_ENCRYPTION_KEYS, 1)
    configure_cipher(c)
    yield c
    reset_cipher()


@pytest.fixture
def settings() -> Settings:
    return make_settings()


@pytest.fixture
def fake_clock() -> FakeClock:
    return FakeClock(datetime(2026, 11, 8, 9, 0, tzinfo=UTC))


@pytest.fixture(scope="session")
def migrated_db() -> None:
    """Postgres only: ``alembic upgrade head`` once per session (also exercises the real migrations)."""
    if not TEST_DATABASE_URL:
        return
    env = {
        **os.environ,
        "ENV": "test",
        "DATABASE_URL": TEST_DATABASE_URL,
        "DATABASE_SSL": "disable",
        "OWNER_EMAIL": "owner@example.com",
        "OWNER_PASSWORD_HASH": "x",
        "JWT_SECRET": "x" * 40,
        "ENCRYPTION_KEYS": TEST_ENCRYPTION_KEYS,
        "ENCRYPTION_ACTIVE_KEY_ID": "1",
    }
    result = subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "head"],
        cwd=BACKEND_DIR,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr


@pytest.fixture
async def db_engine(tmp_path: Path, migrated_db: None) -> AsyncIterator[AsyncEngine]:
    assert _MODEL_MODULES
    if TEST_DATABASE_URL:
        engine = build_engine(make_settings())
        async with engine.begin() as conn:
            await conn.execute(text(f"TRUNCATE {', '.join(_TABLES)} RESTART IDENTITY CASCADE"))
    else:
        engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
    yield engine
    await engine.dispose()


@pytest.fixture
async def db_session(db_engine: AsyncEngine) -> AsyncIterator[AsyncSession]:
    """A session for service-level tests; services flush, the test decides whether to commit."""
    async with build_session_factory(db_engine)() as session:
        yield session
        await session.rollback()


@pytest.fixture
async def app(settings: Settings, fake_clock: FakeClock, db_engine: AsyncEngine) -> AsyncIterator[FastAPI]:
    application = create_app(settings)
    application.state.clock = fake_clock
    application.state.engine_factory = lambda _settings: db_engine
    # httpx's ASGITransport does not run the lifespan: do it explicitly (builds session factory, seeds the owner).
    async with application.router.lifespan_context(application):
        yield application


@pytest.fixture
def make_client() -> Callable[[FastAPI], httpx.AsyncClient]:
    def _make(application: FastAPI) -> httpx.AsyncClient:
        # raise_app_exceptions=False: unhandled errors must come back as the 500 problem response.
        transport = httpx.ASGITransport(app=application, raise_app_exceptions=False)
        return httpx.AsyncClient(transport=transport, base_url="http://test")

    return _make


@pytest.fixture
async def client(
    app: FastAPI, make_client: Callable[[FastAPI], httpx.AsyncClient]
) -> AsyncIterator[httpx.AsyncClient]:
    async with make_client(app) as c:
        yield c


@pytest.fixture
async def owner_id(app: FastAPI) -> UUID:
    """Id of the seeded owner account."""
    async with app.state.session_factory() as session:
        user_id = (await session.execute(select(auth_models.UserAccount.id))).scalar_one()
    assert isinstance(user_id, UUID)
    return user_id


@pytest.fixture
def make_token(app: FastAPI, owner_id: UUID, fake_clock: FakeClock, settings: Settings) -> Callable[..., str]:
    def _make(**overrides: object) -> str:
        now = int(fake_clock.now_utc().timestamp())
        claims: dict[str, object] = {"sub": owner_id, "ver": 1, "iat": now, "exp": now + 30 * 86400}
        claims.update(overrides)
        return encode_jwt(JwtClaims.model_validate(claims), settings.jwt_secret.get_secret_value())

    return _make


@pytest.fixture
def auth_headers(make_token: Callable[..., str]) -> dict[str, str]:
    return {"Authorization": f"Bearer {make_token()}"}


@pytest.fixture
async def authed_client(
    app: FastAPI, make_client: Callable[[FastAPI], httpx.AsyncClient], auth_headers: dict[str, str]
) -> AsyncIterator[httpx.AsyncClient]:
    async with make_client(app) as c:
        c.headers.update(auth_headers)
        yield c
