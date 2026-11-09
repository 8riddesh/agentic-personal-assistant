"""Composition root (core spec §7.7): builds the app and mounts module routers.

Importing this module never needs environment variables and never opens a DB connection: the module-level ``app``
is created lazily on first access (uvicorn's ``app.main:app`` triggers it), and connections open in the lifespan.
"""
#testing commit
from __future__ import annotations

from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI

from app.modules.core import (
    RequestContextMiddleware,
    Settings,
    SystemClock,
    build_engine,
    build_session_factory,
    configure_logging,
    get_logger,
    get_settings,
    install_error_handlers,
)
from app.modules.core.api import health_router

API_PREFIX = "/api/v1"

type ShutdownHook = Callable[[], Awaitable[None]]


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings: Settings = app.state.settings
    configure_logging(settings)
    log = get_logger("app.main")

    # Startup order (any failure aborts start). M1 adds, after the clock: crypto.configure_cipher(...) and
    # AuthService.ensure_owner(...) inside session_scope.
    engine = build_engine(settings)
    app.state.engine = engine
    app.state.session_factory = build_session_factory(engine)
    log.info("startup complete", extra={"version": settings.version})
    try:
        yield
    finally:
        hooks: list[ShutdownHook] = app.state.shutdown_hooks
        for hook in reversed(hooks):
            await hook()
        await engine.dispose()
        log.info("shutdown complete")


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    is_prod = settings.env == "prod"

    app = FastAPI(
        title="Daily Assistant",
        docs_url=None if is_prod else "/docs",
        redoc_url=None,
        openapi_url=None if is_prod else "/openapi.json",
        lifespan=lifespan,
    )
    app.state.settings = settings
    app.state.clock = SystemClock()  # tests replace this with FakeClock
    app.state.shutdown_hooks = []
    app.dependency_overrides[get_settings] = lambda: settings

    app.add_middleware(RequestContextMiddleware)
    install_error_handlers(app)

    # Public routes at the root. Routers under API_PREFIX (auth public; everything else guarded with
    # `dependencies=[Depends(current_user)]` applied here, at mount time) are added by their milestones.
    app.include_router(health_router)
    return app


_app: FastAPI | None = None


def __getattr__(name: str) -> Any:
    """Lazy module-level ``app`` (PEP 562)."""
    global _app
    if name == "app":
        if _app is None:
            _app = create_app()
        return _app
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
