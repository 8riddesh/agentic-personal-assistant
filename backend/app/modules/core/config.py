"""Typed configuration (core spec §7.1, §8).

`Settings` is instantiated only by :func:`get_settings` (cached) - never at import time - so CLIs and tools can import
this package without any environment variables being set.
"""

from __future__ import annotations

import functools
from pathlib import Path
from typing import Literal, Self
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from pydantic import EmailStr, Field, SecretStr, ValidationError, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

type DatabaseSsl = Literal["disable", "require", "verify-full"]

# libpq / asyncpg sslmode values -> our DATABASE_SSL values
_SSLMODE_MAP: dict[str, DatabaseSsl] = {
    "disable": "disable",
    "false": "disable",
    "allow": "require",
    "prefer": "require",
    "require": "require",
    "true": "require",
    "verify-ca": "verify-full",
    "verify-full": "verify-full",
}
_SSL_QUERY_KEYS = frozenset({"sslmode", "ssl"})


def normalise_database_url(url: str) -> tuple[str, DatabaseSsl | None]:
    """Return ``(asyncpg url without ssl query params, ssl hint taken from those params)``."""
    for prefix in ("postgres://", "postgresql://"):
        if url.startswith(prefix):
            url = "postgresql+asyncpg://" + url[len(prefix) :]
            break
    if not url.startswith("postgresql+asyncpg://"):
        raise ValueError(
            "database_url must be a PostgreSQL URL (postgresql://, postgres:// or postgresql+asyncpg://)"
        )

    parts = urlsplit(url)
    hint: DatabaseSsl | None = None
    kept: list[tuple[str, str]] = []
    for key, value in parse_qsl(parts.query, keep_blank_values=True):
        if key in _SSL_QUERY_KEYS:
            hint = _SSLMODE_MAP.get(value.lower(), hint)
        else:
            kept.append((key, value))
    return urlunsplit(parts._replace(query=urlencode(kept))), hint


class Settings(BaseSettings):
    """Every env var of plan §12.1 (+ the additions marked in core spec §8). Secrets are ``SecretStr``."""

    model_config = SettingsConfigDict(
        env_file=".env",  # only present on a dev machine; ignored when absent
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
        env_ignore_empty=True,  # a blank value in the Render dashboard means "not set"
    )

    # --- runtime
    env: Literal["dev", "test", "prod"] = "dev"
    log_level: str = "INFO"
    render_git_commit: str = "dev"  # provided by Render; first 7 chars are the reported version

    # --- database (Supabase session pooler)
    database_url: SecretStr
    database_ssl: DatabaseSsl = "require"
    database_ssl_root_cert: Path | None = None
    db_pool_size: int = Field(default=3, ge=1, le=10)
    db_max_overflow: int = Field(default=2, ge=0, le=10)

    # --- owner account / auth
    owner_email: EmailStr
    owner_password_hash: SecretStr
    jwt_secret: SecretStr
    jwt_ttl_days: int = Field(default=30, ge=1, le=365)

    # --- encryption
    encryption_keys: SecretStr
    encryption_active_key_id: int = Field(ge=1, le=255)

    # --- AI (all optional: P10 graceful degradation)
    openrouter_api_key: SecretStr | None = None
    jev_model: str = "typesafe/jev-1.14"
    jev_daily_call_cap: int = 500
    groq_api_key: SecretStr | None = None
    groq_model: str | None = None
    groq_fast_model: str | None = None
    groq_daily_call_cap: int = 1000
    openrouter_text_fallback_model: str | None = None
    feasibility_weights: dict[str, float] | None = None

    # --- email (optional: email returns `not_configured`)
    email_provider: Literal["brevo", "smtp"] = "brevo"
    brevo_api_key: SecretStr | None = None
    brevo_base_url: str = "https://api.brevo.com"
    email_from: EmailStr | None = None
    email_from_name: str = "Daily Assistant"
    email_inline_mode: Literal["attachment", "cid"] = "attachment"
    email_max_total_bytes: int = 8_388_608
    smtp_host: str | None = None
    smtp_port: int = 587
    smtp_user: str | None = None
    smtp_password: SecretStr | None = None

    @field_validator("jwt_secret")
    @classmethod
    def _jwt_secret_long_enough(cls, value: SecretStr) -> SecretStr:
        if len(value.get_secret_value()) < 32:
            raise ValueError("must be at least 32 characters")
        return value

    @field_validator("log_level")
    @classmethod
    def _log_level_valid(cls, value: str) -> str:
        level = value.upper()
        if level not in {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}:
            raise ValueError("must be one of DEBUG, INFO, WARNING, ERROR, CRITICAL")
        return level

    @model_validator(mode="after")
    def _normalise_database(self) -> Self:
        url, ssl_hint = normalise_database_url(self.database_url.get_secret_value())
        self.database_url = SecretStr(url)
        if ssl_hint is not None and "database_ssl" not in self.model_fields_set:
            self.database_ssl = ssl_hint
        if self.env == "prod" and self.database_ssl == "disable":
            raise ValueError("database_ssl=disable is not allowed when env=prod")
        return self

    @property
    def version(self) -> str:
        return self.render_git_commit[:7]


class SettingsError(SystemExit):
    """Raised at startup for an invalid configuration. The message names fields, never their values."""


def describe_validation_error(exc: ValidationError) -> str:
    """Field names + generic messages only. pydantic's default rendering includes the offending *input*."""
    lines = []
    for err in exc.errors(include_input=False, include_url=False, include_context=False):
        field = ".".join(str(part) for part in err["loc"]).upper() or "SETTINGS"
        lines.append(f"  - {field}: {err['msg']}")
    return "Invalid configuration:\n" + "\n".join(lines)


@functools.lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Cached settings; also the FastAPI dependency (override via ``app.dependency_overrides``)."""
    try:
        return Settings()  # required fields come from the environment
    except ValidationError as exc:
        raise SettingsError(describe_validation_error(exc)) from None
