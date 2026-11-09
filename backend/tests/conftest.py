"""Shared fixtures (core spec §11). Tests never touch the network; DB tests need ``TEST_DATABASE_URL``."""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator, Callable, Iterator
from datetime import UTC, datetime

import httpx
import pytest
from fastapi import FastAPI

from app.main import create_app
from app.modules.core import FakeClock, Settings
from tests.helpers import make_settings


@pytest.fixture(autouse=True)
def _restore_logging() -> Iterator[None]:
    """configure_logging() replaces root handlers (bound to a test's captured stdout): undo after each test."""
    root = logging.getLogger()
    handlers, level = root.handlers[:], root.level
    yield
    root.handlers[:] = handlers
    root.setLevel(level)


@pytest.fixture
def settings() -> Settings:
    return make_settings()


@pytest.fixture
def fake_clock() -> FakeClock:
    return FakeClock(datetime(2026, 11, 8, 9, 0, tzinfo=UTC))


@pytest.fixture
async def app(settings: Settings, fake_clock: FakeClock) -> AsyncIterator[FastAPI]:
    application = create_app(settings)
    application.state.clock = fake_clock
    # httpx's ASGITransport does not run the lifespan: do it explicitly (builds engine / session factory).
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
