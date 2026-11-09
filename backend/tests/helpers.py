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
# Nothing listens on port 1: connections are refused immediately.
CLOSED_PORT_URL = "postgresql+asyncpg://user:pw@127.0.0.1:1/db"

type ClientFactory = Callable[[FastAPI], httpx.AsyncClient]

requires_db = pytest.mark.skipif(not TEST_DATABASE_URL, reason="TEST_DATABASE_URL is not set")


def make_settings(**overrides: Any) -> Settings:
    values: dict[str, Any] = {
        "env": "test",
        "database_url": TEST_DATABASE_URL or CLOSED_PORT_URL,
        "database_ssl": "disable",
        "owner_email": "owner@example.com",
        "owner_password_hash": "not-a-real-hash",
        "jwt_secret": "x" * 40,
        "encryption_keys": "1:" + "A" * 43 + "=",
        "encryption_active_key_id": 1,
        "render_git_commit": "3f2c1ab9999",
    }
    values.update(overrides)
    return Settings(_env_file=None, **values)
