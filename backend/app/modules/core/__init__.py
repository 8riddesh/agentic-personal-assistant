"""Public interface of ``core`` (spec §5). Other modules import from this package root only.

M0 exports: config, db, clock, errors, logging, health DTOs. ``AppSettingsService`` and its DTOs arrive with M1.
"""

from app.modules.core.clock import Clock, FakeClock, SystemClock, get_clock
from app.modules.core.config import Settings, get_settings
from app.modules.core.db import (
    NAMING_CONVENTION,
    Base,
    SessionDep,
    SessionFactory,
    TimestampMixin,
    UUIDPkMixin,
    build_engine,
    build_session_factory,
    db_ping,
    get_session,
    session_scope,
)
from app.modules.core.errors import (
    AppError,
    AuthenticationError,
    ConflictError,
    DomainValidationError,
    NotFoundError,
    UpstreamError,
    install_error_handlers,
)
from app.modules.core.logs import RequestContextMiddleware, configure_logging, get_logger
from app.modules.core.schemas import FieldError, HealthDTO, ProblemDetails

__all__ = [
    "NAMING_CONVENTION",
    "AppError",
    "AuthenticationError",
    "Base",
    "Clock",
    "ConflictError",
    "DomainValidationError",
    "FakeClock",
    "FieldError",
    "HealthDTO",
    "NotFoundError",
    "ProblemDetails",
    "RequestContextMiddleware",
    "SessionDep",
    "SessionFactory",
    "Settings",
    "SystemClock",
    "TimestampMixin",
    "UUIDPkMixin",
    "UpstreamError",
    "build_engine",
    "build_session_factory",
    "configure_logging",
    "db_ping",
    "get_clock",
    "get_logger",
    "get_session",
    "get_settings",
    "install_error_handlers",
    "session_scope",
]
