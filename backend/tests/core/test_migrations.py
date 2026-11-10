"""CORE-AC-11: one Alembic head, up/down/up succeeds, models match migrations.

The offline tests run everywhere; the ``requires_db`` ones need the CI Postgres service container.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest
from alembic.config import Config
from alembic.script import ScriptDirectory
from sqlalchemy.dialects import postgresql
from sqlalchemy.schema import CreateIndex, CreateTable
from sqlalchemy.types import TypeDecorator

import app.modules.auth.models
import app.modules.core.models
import app.modules.day_cycle.models
import app.modules.tasks.models  # noqa: F401
from app.modules.core import Base
from tests.helpers import TEST_DATABASE_URL, requires_db

BACKEND_DIR = Path(__file__).resolve().parents[2]
EXPECTED_ORDER = ["core", "auth", "tasks", "day_cycle"]  # one migration per module change, linear history


def _script_dir() -> ScriptDirectory:
    cfg = Config(str(BACKEND_DIR / "alembic.ini"))
    cfg.set_main_option("script_location", str(BACKEND_DIR / "migrations"))
    return ScriptDirectory.from_config(cfg)


def test_single_alembic_head() -> None:
    heads = _script_dir().get_heads()
    assert len(heads) == 1, f"expected exactly one Alembic head, got: {heads}"


def test_every_migration_implements_downgrade() -> None:
    for rev in _script_dir().walk_revisions():
        assert rev.module.downgrade is not None


def test_history_is_linear_and_in_module_order() -> None:
    revisions = list(_script_dir().walk_revisions())  # newest first
    messages = [r.doc.split(":")[0] for r in reversed(revisions) if r.doc]
    assert messages == EXPECTED_ORDER
    assert all(len(r.nextrev) <= 1 for r in revisions)  # no branches


def test_postgres_ddl_compiles_for_every_table() -> None:
    """Offline signal for the Postgres-only parts (ARRAY, JSONB, partial indexes, ddl_if CHECK constraints)."""
    dialect = postgresql.dialect()  # type: ignore[no-untyped-call]
    ddl: dict[str, str] = {}
    for table in Base.metadata.sorted_tables:
        ddl[table.name] = str(CreateTable(table).compile(dialect=dialect))
        for index in table.indexes:
            ddl[f"{table.name}:{index.name}"] = str(CreateIndex(index).compile(dialect=dialect))
    assert set(Base.metadata.tables) == {
        "app_settings",
        "user_account",
        "task_template",
        "task",
        "task_status_event",
        "day_session",
    }
    assert "cardinality(reminder_offsets_min)" in ddl["app_settings"]  # Postgres-only CHECK is emitted for PG
    assert "INTEGER[]" in ddl["app_settings"]
    assert "JSONB" in ddl["task_template"]
    assert "WHERE template_id IS NOT NULL" in ddl["task:uq_task_local_date_template"]
    assert "WHERE state <> 'closed'" in ddl["day_session:ix_day_session_state"]


def _alembic_env(database_url: str) -> dict[str, str]:
    return {
        **os.environ,
        "ENV": "test",
        "DATABASE_URL": database_url,
        "DATABASE_SSL": "disable",
        "OWNER_EMAIL": "owner@example.com",
        "OWNER_PASSWORD_HASH": "x",
        "JWT_SECRET": "x" * 40,
        "ENCRYPTION_KEYS": "1:" + "A" * 43 + "=",
        "ENCRYPTION_ACTIVE_KEY_ID": "1",
    }


def _alembic(*args: str) -> subprocess.CompletedProcess[str]:
    assert TEST_DATABASE_URL
    return subprocess.run(
        [sys.executable, "-m", "alembic", *args],
        cwd=BACKEND_DIR,
        env=_alembic_env(TEST_DATABASE_URL),
        capture_output=True,
        text=True,
        check=False,
    )


@requires_db
def test_alembic_upgrade_head_runs_against_postgres() -> None:
    result = _alembic("upgrade", "head")
    assert result.returncode == 0, result.stderr


@requires_db
def test_migrations_up_down_up() -> None:
    for step in (("upgrade", "head"), ("downgrade", "base"), ("upgrade", "head")):
        result = _alembic(*step)
        assert result.returncode == 0, f"{step}: {result.stderr}"


@requires_db
async def test_models_match_migrations() -> None:
    """Autogenerate against the migrated database must find no differences."""
    from alembic.autogenerate import compare_metadata
    from alembic.migration import MigrationContext
    from sqlalchemy.ext.asyncio import create_async_engine

    from app.modules.core.db import build_connect_args
    from tests.helpers import make_settings

    assert _alembic("upgrade", "head").returncode == 0

    def compare_type(
        _ctx: Any, _col: Any, _meta_col: Any, inspected_type: Any, metadata_type: Any
    ) -> bool | None:
        if isinstance(metadata_type, TypeDecorator):
            return not isinstance(inspected_type, type(metadata_type.impl_instance))
        return None

    settings = make_settings()
    engine = create_async_engine(
        settings.database_url.get_secret_value(), connect_args=build_connect_args(settings)
    )
    try:
        async with engine.connect() as conn:

            def diff(sync_conn: Any) -> list[Any]:
                context = MigrationContext.configure(sync_conn, opts={"compare_type": compare_type})
                return list(compare_metadata(context, Base.metadata))

            differences = await conn.run_sync(diff)
    finally:
        await engine.dispose()
    assert differences == [], f"models and migrations differ: {differences}"


@pytest.mark.skipif(bool(TEST_DATABASE_URL), reason="documents the local (no Postgres) behaviour")
def test_db_tests_are_skipped_without_postgres() -> None:
    assert not TEST_DATABASE_URL
