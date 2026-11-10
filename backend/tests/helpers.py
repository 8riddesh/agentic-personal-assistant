"""Test helpers shared across modules (kept out of conftest so they can be imported normally)."""

from __future__ import annotations

import os
from collections.abc import Callable
from typing import Any

import httpx
import pytest
from fastapi import FastAPI

from app.modules.core import Settings

TEST_DATABASE_URL = os.environ.get("TEST_DATABASE_URL")
TEST_OWNER_EMAIL = "owner@example.com"
TEST_OWNER_PASSWORD = "test-password-123"
# argon2id hash of TEST_OWNER_PASSWORD (generated once so the suite does not pay for hashing on every app start)
TEST_OWNER_HASH = (
    "$argon2id$v=19$m=65536,t=3,p=4$WUJA3d9Ywl9Zs1uKcvPYYg$nlbAyEP+p0ZrCsUKqh/BYmMsuIOuEtbbf/vi+CJBNJc"
)
TEST_ENCRYPTION_KEYS = "1:" + "A" * 43 + "="
# Nothing listens on port 1: connections are refused immediately.
CLOSED_PORT_URL = "postgresql+asyncpg://user:pw@127.0.0.1:1/db"

type ClientFactory = Callable[[FastAPI], httpx.AsyncClient]

requires_db = pytest.mark.skipif(not TEST_DATABASE_URL, reason="TEST_DATABASE_URL is not set")


def make_settings(**overrides: Any) -> Settings:
    values: dict[str, Any] = {
        "env": "test",
        "database_url": TEST_DATABASE_URL or CLOSED_PORT_URL,
        "database_ssl": "disable",
        "owner_email": TEST_OWNER_EMAIL,
        "owner_password_hash": TEST_OWNER_HASH,
        "jwt_secret": "x" * 40,
        "encryption_keys": TEST_ENCRYPTION_KEYS,
        "encryption_active_key_id": 1,
        "render_git_commit": "3f2c1ab9999",
    }
    values.update(overrides)
    return Settings(_env_file=None, **values)
