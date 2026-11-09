"""Async Alembic environment (core spec §4.3).

Uses the same URL and SSL connect args as the app. Imports every module's ``models`` (when it has one) so that
``Base.metadata`` is complete; ``migrations/`` is outside the ``app`` package, so the boundary contracts don't apply.
"""

import asyncio
import importlib
import pkgutil
from typing import Any

from alembic import context
from sqlalchemy import pool
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import create_async_engine
from sqlalchemy.types import TypeDecorator

import app.modules as modules_pkg
from app.modules.core.config import get_settings
from app.modules.core.db import Base, build_connect_args

config = context.config


def _import_all_models() -> None:
    for info in pkgutil.iter_modules(modules_pkg.__path__):
        name = f"app.modules.{info.name}.models"
        try:
            importlib.import_module(name)
        except ModuleNotFoundError as exc:
            if exc.name != name:  # a real missing dependency inside models.py must not be swallowed
                raise


_import_all_models()
target_metadata = Base.metadata

_TEXT_TYPES = {"EncryptedText", "EncryptedJSON"}
_BYTES_TYPES = {"EncryptedBytes"}


def render_item(type_: str, obj: Any, autogen_context: Any) -> str | bool:
    """Render crypto TypeDecorators as their storage types so migrations never import `crypto`."""
    if type_ == "type":
        name = type(obj).__name__
        if name in _TEXT_TYPES:
            autogen_context.imports.add("import sqlalchemy as sa")
            return "sa.Text()"
        if name in _BYTES_TYPES:
            autogen_context.imports.add("import sqlalchemy as sa")
            return "sa.LargeBinary()"
    return False


def compare_type(
    context_: Any, inspected_column: Any, metadata_column: Any, inspected_type: Any, metadata_type: Any
) -> bool | None:
    """Compare TypeDecorators on their ``impl`` so autogenerate is clean. ``None`` = use Alembic's default."""
    if isinstance(metadata_type, TypeDecorator):
        return not isinstance(inspected_type, type(metadata_type.impl_instance))
    return None


def _configure(connection: Connection) -> None:
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        compare_type=compare_type,
        render_item=render_item,
    )


def _do_run_migrations(connection: Connection) -> None:
    _configure(connection)
    with context.begin_transaction():
        context.run_migrations()


async def _run_async_migrations() -> None:
    settings = get_settings()
    engine = create_async_engine(
        settings.database_url.get_secret_value(),
        poolclass=pool.NullPool,
        connect_args=build_connect_args(settings),
    )
    async with engine.connect() as connection:
        await connection.run_sync(_do_run_migrations)
    await engine.dispose()


if context.is_offline_mode():
    raise RuntimeError(
        "Offline (--sql) migrations are not supported: the URL and SSL setup live in Settings."
    )

asyncio.run(_run_async_migrations())
