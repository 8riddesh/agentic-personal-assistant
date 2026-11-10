"""Composition root (core spec §7.7): builds the app and mounts module routers.

Importing this module never needs environment variables and never opens a DB connection: the module-level ``app``
is created lazily on first access (uvicorn's ``app.main:app`` triggers it), and connections open in the lifespan.
"""

from __future__ import annotations

from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager
from datetime import date, datetime
from typing import Any
from zoneinfo import ZoneInfo

from fastapi import Depends, FastAPI
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncEngine

from app.modules.auth import AuthService, current_user
from app.modules.auth.api import router as auth_router
from app.modules.core import (
    Clock,
    RequestContextMiddleware,
    Settings,
    SystemClock,
    build_engine,
    build_session_factory,
    configure_logging,
    get_logger,
    get_settings,
    install_error_handlers,
    session_scope,
)
from app.modules.core.api import health_router, settings_router
from app.modules.crypto import FieldCipher, configure_cipher
from app.modules.day_cycle import NullPredictorHook, NullReportGenerator, PipelineDeps, ensure_current_day
from app.modules.day_cycle.api import router as day_router
from app.modules.tasks.api import router as tasks_router

API_PREFIX = "/api/v1"

type ShutdownHook = Callable[[], Awaitable[None]]
type EngineFactory = Callable[[Settings], AsyncEngine]


class AppStateClock:
    """Delegates to ``app.state.clock`` on every call, so tests can swap the clock after the app was created."""

    def __init__(self, app: FastAPI) -> None:
        self._app = app

    def _clock(self) -> Clock:
        clock: Clock = self._app.state.clock
        return clock

    def now_utc(self) -> datetime:
        return self._clock().now_utc()

    def today_local(self, tz: ZoneInfo) -> date:
        return self._clock().today_local(tz)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings: Settings = app.state.settings
    configure_logging(settings)
    log = get_logger("app.main")

    # Startup order (any failure aborts start): logging -> cipher -> engine/session factory -> pipeline deps -> owner.
    configure_cipher(
        FieldCipher.from_config(
            settings.encryption_keys.get_secret_value(), settings.encryption_active_key_id
        )
    )
    engine_factory: EngineFactory = app.state.engine_factory
    engine = engine_factory(settings)
    app.state.engine = engine
    session_factory = build_session_factory(engine)
    app.state.session_factory = session_factory
    app.state.day_memo = None
    # M1 close pipeline: no predictor / reports modules yet, so those steps are no-ops (M3 / M4 swap these in).
    app.state.pipeline_deps = PipelineDeps(
        session_factory=session_factory,
        clock=AppStateClock(app),
        predictor_hook=NullPredictorHook(),
        reports=NullReportGenerator(),
        task_predictor=None,
    )

    owner_hash = settings.owner_password_hash.get_secret_value()
    try:
        async with session_scope(session_factory) as session:
            await AuthService(session, settings, AppStateClock(app)).ensure_owner(
                str(settings.owner_email), owner_hash
            )
    except (OSError, SQLAlchemyError) as exc:
        # Pure connectivity trouble must not stop the process: /health reports the outage (503) and the next start
        # seeds the account (alembic already needed the DB on container start). Config errors above/below still abort.
        log.error("owner seeding skipped: database unavailable", extra={"error_type": type(exc).__name__})

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
    app.state.engine_factory = build_engine  # tests may inject another engine (e.g. SQLite)
    app.state.shutdown_hooks = []
    app.dependency_overrides[get_settings] = lambda: settings

    app.add_middleware(RequestContextMiddleware)
    install_error_handlers(app)

    # Public routes: /health at the root, /auth/login under the API prefix.
    app.include_router(health_router)
    app.include_router(auth_router, prefix=API_PREFIX)

    # Everything else is guarded here, at mount time, so no module ever imports ``auth`` (core spec §7.7).
    guarded = [Depends(current_user)]
    app.include_router(settings_router, prefix=API_PREFIX, dependencies=guarded)
    app.include_router(day_router, prefix=API_PREFIX, dependencies=guarded)
    # Day-scoped routers also run ``ensure_current_day`` so the lazy midnight auto-close happens on any of them.
    app.include_router(tasks_router, prefix=API_PREFIX, dependencies=[*guarded, Depends(ensure_current_day)])
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
