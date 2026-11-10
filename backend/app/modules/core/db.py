"""Async SQLAlchemy plumbing for Supabase via the Supavisor *session* pooler (core spec §4.2, §7.2)."""

from __future__ import annotations

import asyncio
import ssl
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from enum import Enum
from typing import Annotated, Any
from uuid import UUID, uuid4

from fastapi import Depends, Request
from sqlalchemy import DateTime, MetaData, Uuid, func, text
from sqlalchemy import Enum as SAEnum
from sqlalchemy.engine import Dialect
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column
from sqlalchemy.types import TypeDecorator

from app.modules.core.config import Settings

NAMING_CONVENTION: dict[str, str] = {
    "ix": "ix_%(table_name)s_%(column_0_N_name)s",
    "uq": "uq_%(table_name)s_%(column_0_N_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}

type SessionFactory = async_sessionmaker[AsyncSession]


class Base(DeclarativeBase):
    metadata = MetaData(naming_convention=NAMING_CONVENTION)


class UUIDPkMixin:
    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True, default=uuid4)


class UTCDateTime(TypeDecorator[datetime]):
    """``timestamptz`` that only accepts tz-aware values and always returns tz-aware UTC.

    Postgres already does this; the decorator also makes SQLite (used by the local test-suite, which drops tz info)
    behave identically, and turns "naive datetime" bugs into immediate errors."""

    impl = DateTime(timezone=True)
    cache_ok = True

    def process_bind_param(self, value: datetime | None, dialect: Dialect) -> datetime | None:
        if value is None:
            return None
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("naive datetime: all datetimes must be timezone-aware")
        return value.astimezone(UTC)

    def process_result_value(self, value: datetime | None, dialect: Dialect) -> datetime | None:
        if value is None:
            return None
        if value.tzinfo is None:
            return value.replace(tzinfo=UTC)
        return value.astimezone(UTC)


class TimestampMixin:
    """All datetimes in Python are tz-aware UTC; naive datetimes are a bug.

    ``eager_defaults`` makes the ORM fetch ``created_at``/``updated_at`` in the same statement (RETURNING) instead of
    leaving them expired, which would trigger a forbidden lazy load in async code."""

    __mapper_args__ = {"eager_defaults": True}  # noqa: RUF012

    created_at: Mapped[datetime] = mapped_column(UTCDateTime(), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        UTCDateTime(), server_default=func.now(), onupdate=func.now()
    )


def enum_type(py_enum: type[Enum], name: str, *, length: int = 32) -> SAEnum:
    """varchar + CHECK enum (core spec §4.2): cheaper migrations than native PG enums.

    ``name`` becomes the CHECK constraint name, so it must be unique per table (e.g. ``task_status``)."""
    return SAEnum(
        py_enum,
        name=name,
        native_enum=False,
        create_constraint=True,
        length=length,
        values_callable=lambda members: [m.value for m in members],
    )


def build_connect_args(settings: Settings) -> dict[str, Any]:
    """asyncpg connect args shared by the app engine and Alembic (``DATABASE_SSL`` semantics: spec §7.2)."""
    args: dict[str, Any] = {
        "timeout": 10,
        "command_timeout": 30,
        "server_settings": {"application_name": "daily-assistant"},
    }
    if settings.database_ssl == "disable":
        args["ssl"] = False
    elif settings.database_ssl == "verify-full":
        cafile = str(settings.database_ssl_root_cert) if settings.database_ssl_root_cert else None
        args["ssl"] = ssl.create_default_context(cafile=cafile)
    else:  # "require": encrypted, certificate not verified (Supabase pooler uses its own CA)
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        args["ssl"] = context
    return args


def build_engine(settings: Settings) -> AsyncEngine:
    # echo is never enabled: it would log bound parameters (personal text).
    return create_async_engine(
        settings.database_url.get_secret_value(),
        pool_size=settings.db_pool_size,
        max_overflow=settings.db_max_overflow,
        pool_timeout=10,
        pool_recycle=1800,
        pool_pre_ping=True,
        echo=False,
        connect_args=build_connect_args(settings),
    )


def build_session_factory(engine: AsyncEngine) -> SessionFactory:
    return async_sessionmaker(engine, expire_on_commit=False, autoflush=False)


async def get_session(request: Request) -> AsyncIterator[AsyncSession]:
    """One transaction per request: commit on success, roll back on any exception. Services never commit."""
    factory: SessionFactory = request.app.state.session_factory
    async with factory() as session:
        try:
            yield session
            await session.commit()
        except BaseException:
            await session.rollback()
            raise


# `scope="function"` ends the dependency (commit) right after the endpoint returns, i.e. *before* the response is
# sent, so a client that reads right after a write always sees it. Modules inject `SessionDep`.
SessionDep = Annotated[AsyncSession, Depends(get_session, scope="function")]


@asynccontextmanager
async def session_scope(factory: SessionFactory) -> AsyncIterator[AsyncSession]:
    """Same semantics as :func:`get_session`, for background work that must not reuse the request session."""
    async with factory() as session:
        try:
            yield session
            await session.commit()
        except BaseException:
            await session.rollback()
            raise


async def db_ping(engine: AsyncEngine, timeout_s: float = 3.0) -> bool:
    """``SELECT 1`` on a pooled connection. Returns a bool and never raises."""

    async def _ping() -> None:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))

    try:
        await asyncio.wait_for(_ping(), timeout=timeout_s)
    except Exception:
        return False
    return True
