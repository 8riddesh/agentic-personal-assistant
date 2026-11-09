from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest
from pydantic import ValidationError

from app.modules.core.config import Settings, SettingsError, get_settings
from tests.helpers import make_settings

BACKEND_DIR = Path(__file__).resolve().parents[2]
SETTING_VARS = [name.upper() for name in Settings.model_fields]

MANDATORY: dict[str, Any] = {
    "owner_email": "o@example.com",
    "owner_password_hash": "h",
    "jwt_secret": "x" * 40,
    "encryption_keys": "k",
    "encryption_active_key_id": 1,
}


def _clean_env(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """No inherited config and no stray `.env` in the working directory."""
    for name in SETTING_VARS:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.chdir(tmp_path)
    get_settings.cache_clear()


def test_settings_require_mandatory_vars(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _clean_env(monkeypatch, tmp_path)
    with pytest.raises(ValidationError) as info:
        Settings()
    missing = {str(e["loc"][0]) for e in info.value.errors() if e["type"] == "missing"}
    assert missing == {
        "database_url",
        "owner_email",
        "owner_password_hash",
        "jwt_secret",
        "encryption_keys",
        "encryption_active_key_id",
    }


def test_database_url_scheme_normalised() -> None:
    url = make_settings(database_url="postgresql://u:p@h:5432/db").database_url.get_secret_value()
    assert url == "postgresql+asyncpg://u:p@h:5432/db"
    url = make_settings(database_url="postgres://u:p@h/db").database_url.get_secret_value()
    assert url.startswith("postgresql+asyncpg://")


def test_non_postgres_url_rejected() -> None:
    with pytest.raises(ValidationError):
        make_settings(database_url="mysql://u:p@h/db")


def test_sslmode_param_stripped_other_params_kept() -> None:
    url = make_settings(
        database_url="postgresql://u:p@h/db?sslmode=require&x=1"
    ).database_url.get_secret_value()
    assert "sslmode" not in url
    assert url.endswith("/db?x=1")


def test_sslmode_maps_to_database_ssl_unless_set_explicitly(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _clean_env(monkeypatch, tmp_path)
    url = "postgresql://u:p@h/db?sslmode=verify-full"
    s = Settings(database_url=url, **MANDATORY)
    assert s.database_ssl == "verify-full"
    assert "ssl" not in s.database_url.get_secret_value()
    # an explicit DATABASE_SSL wins over the URL hint
    assert Settings(database_url=url, database_ssl="require", **MANDATORY).database_ssl == "require"


def test_ssl_disable_rejected_in_prod() -> None:
    with pytest.raises(ValidationError):
        make_settings(env="prod", database_ssl="disable")


def test_jwt_secret_min_length() -> None:
    with pytest.raises(ValidationError):
        make_settings(jwt_secret="too-short")


def test_version_is_first_seven_chars_of_commit() -> None:
    assert make_settings(render_git_commit="3f2c1ab9999").version == "3f2c1ab"
    assert make_settings(render_git_commit="dev").version == "dev"


def test_settings_repr_hides_secrets() -> None:
    assert "S3CRET" not in repr(make_settings(jwt_secret="S3CRET-" + "x" * 40))


def test_settings_errors_hide_values(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _clean_env(monkeypatch, tmp_path)
    sentinel = "sentinel-secret-value"
    monkeypatch.setenv("DATABASE_URL", "postgresql://u:p@h/db")
    monkeypatch.setenv("OWNER_EMAIL", "owner@example.com")
    monkeypatch.setenv("OWNER_PASSWORD_HASH", "h")
    monkeypatch.setenv("JWT_SECRET", sentinel)  # too short -> invalid
    monkeypatch.setenv("ENCRYPTION_KEYS", "k")
    monkeypatch.setenv("ENCRYPTION_ACTIVE_KEY_ID", "1")
    with pytest.raises(SettingsError) as info:
        get_settings()
    message = str(info.value)
    assert "JWT_SECRET" in message
    assert sentinel not in message


def test_blank_optional_env_var_means_unset(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _clean_env(monkeypatch, tmp_path)
    monkeypatch.setenv("EMAIL_FROM", "")
    monkeypatch.setenv("BREVO_API_KEY", "")
    s = Settings(database_url="postgresql://u:p@h/db", **MANDATORY)
    assert s.email_from is None
    assert s.brevo_api_key is None


def test_settings_not_instantiated_on_import() -> None:
    env = {k: v for k, v in os.environ.items() if k.upper() not in SETTING_VARS}
    code = (
        "import app.main, app.modules.core.config as c;"
        "assert c.get_settings.cache_info().currsize == 0, 'Settings created at import time'"
    )
    result = subprocess.run(
        [sys.executable, "-c", code], cwd=BACKEND_DIR, env=env, capture_output=True, text=True, check=False
    )
    assert result.returncode == 0, result.stderr
