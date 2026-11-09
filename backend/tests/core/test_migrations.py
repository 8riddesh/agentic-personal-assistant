"""CORE-AC-11 (M0 part). The model/up-down-up checks arrive with the first migration (M1: ``core: create app_settings``)."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from alembic.config import Config
from alembic.script import ScriptDirectory

from tests.helpers import TEST_DATABASE_URL, requires_db

BACKEND_DIR = Path(__file__).resolve().parents[2]


def _script_dir() -> ScriptDirectory:
    cfg = Config(str(BACKEND_DIR / "alembic.ini"))
    cfg.set_main_option("script_location", str(BACKEND_DIR / "migrations"))
    return ScriptDirectory.from_config(cfg)


def test_single_alembic_head() -> None:
    heads = _script_dir().get_heads()
    # M0 ships no revisions yet (0 heads). From the first migration on there must be exactly one.
    assert len(heads) <= 1, f"multiple Alembic heads: {heads}"


def test_every_migration_implements_downgrade() -> None:
    for rev in _script_dir().walk_revisions():
        assert rev.module.downgrade is not None


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


@requires_db
def test_alembic_upgrade_head_runs_against_postgres() -> None:
    assert TEST_DATABASE_URL
    result = subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "head"],
        cwd=BACKEND_DIR,
        env=_alembic_env(TEST_DATABASE_URL),
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
