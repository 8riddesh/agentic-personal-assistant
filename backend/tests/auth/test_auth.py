"""AUTH-AC-01..10: owner seeding, login, JWT dependency, hash CLI."""

from __future__ import annotations

import logging
import os
import subprocess
import sys
from collections.abc import Callable
from datetime import timedelta
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock
from uuid import UUID, uuid4

import httpx
import jwt
import pytest
from fastapi import FastAPI
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.auth import AuthService
from app.modules.auth.models import UserAccount
from app.modules.auth.security import PasswordHasher
from app.modules.core import AuthenticationError, DomainValidationError, FakeClock, Settings
from tests.helpers import TEST_OWNER_EMAIL, TEST_OWNER_HASH, TEST_OWNER_PASSWORD

BACKEND_DIR = Path(__file__).resolve().parents[2]
LOGIN = "/api/v1/auth/login"
PROTECTED = "/api/v1/settings"


def _good() -> dict[str, str]:
    return {"email": TEST_OWNER_EMAIL, "password": TEST_OWNER_PASSWORD}


@pytest.fixture
def auth_service(db_session: AsyncSession, settings: Settings, fake_clock: FakeClock) -> AuthService:
    return AuthService(db_session, settings, fake_clock)


# ------------------------------------------------------------------ seeding
async def test_ensure_owner_inserts_when_empty(auth_service: AuthService, db_session: AsyncSession) -> None:
    """AUTH-AC-01."""
    assert await auth_service.ensure_owner("  Owner@Example.COM ", TEST_OWNER_HASH) is True
    rows = (await db_session.execute(select(UserAccount))).scalars().all()
    assert [r.email for r in rows] == ["owner@example.com"]
    assert rows[0].token_version == 1


async def test_ensure_owner_leaves_existing_row_unchanged(
    auth_service: AuthService, db_session: AsyncSession
) -> None:
    """AUTH-AC-02."""
    await auth_service.ensure_owner("owner@example.com", TEST_OWNER_HASH)
    other_hash = PasswordHasher().hash("another-password")
    assert await auth_service.ensure_owner("someone.else@example.com", other_hash) is False
    row = (await db_session.execute(select(UserAccount))).scalar_one()
    assert (row.email, row.password_hash) == ("owner@example.com", TEST_OWNER_HASH)


async def test_ensure_owner_email_mismatch_logs_warning_without_values(
    auth_service: AuthService, caplog: pytest.LogCaptureFixture
) -> None:
    await auth_service.ensure_owner("owner@example.com", TEST_OWNER_HASH)
    with caplog.at_level(logging.WARNING):
        await auth_service.ensure_owner("different@example.com", TEST_OWNER_HASH)
    messages = " ".join(r.getMessage() for r in caplog.records)
    assert "owner_email_mismatch" in messages
    assert "different@example.com" not in messages
    assert "owner@example.com" not in messages


async def test_ensure_owner_rejects_non_argon2id_hash(auth_service: AuthService) -> None:
    with pytest.raises(DomainValidationError, match="argon2id"):
        await auth_service.ensure_owner("owner@example.com", "plain-text-password")


# ------------------------------------------------------------------ login
async def test_login_success_returns_token_and_expiry(
    client: httpx.AsyncClient, fake_clock: FakeClock, settings: Settings
) -> None:
    """AUTH-AC-03 (+ test_jwt_claims_exact_set)."""
    response = await client.post(LOGIN, json=_good())
    assert response.status_code == 200
    body = response.json()
    assert body["token_type"] == "bearer"
    expected_exp = int(fake_clock.now_utc().timestamp()) + 30 * 86400
    assert body["expires_at"] == (fake_clock.now_utc() + timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ")
    secret = settings.jwt_secret.get_secret_value()
    assert jwt.get_unverified_header(body["access_token"])["alg"] == "HS256"
    claims: dict[str, Any] = jwt.decode(
        body["access_token"], secret, algorithms=["HS256"], options={"verify_iat": False, "verify_exp": False}
    )
    assert set(claims) == {"sub", "ver", "iat", "exp"}
    assert claims["exp"] == expected_exp
    assert claims["ver"] == 1


async def test_login_normalises_email_case(client: httpx.AsyncClient) -> None:
    response = await client.post(LOGIN, json={"email": "OWNER@Example.com", "password": TEST_OWNER_PASSWORD})
    assert response.status_code == 200


async def test_login_updates_last_login_at(
    client: httpx.AsyncClient, app: FastAPI, fake_clock: FakeClock
) -> None:
    await client.post(LOGIN, json=_good())
    async with app.state.session_factory() as session:
        last = (await session.execute(select(UserAccount.last_login_at))).scalar_one()
    assert last == fake_clock.now_utc()


async def test_login_wrong_password_and_unknown_email_identical_401(client: httpx.AsyncClient) -> None:
    """AUTH-AC-04 (bodies identical except request_id)."""
    wrong = await client.post(LOGIN, json={**_good(), "password": "wrong-password"})
    unknown = await client.post(LOGIN, json={"email": "nobody@example.com", "password": "whatever"})
    assert wrong.status_code == unknown.status_code == 401
    assert wrong.headers["www-authenticate"] == "Bearer"

    def strip(r: httpx.Response) -> dict[str, Any]:
        return {k: v for k, v in r.json().items() if k != "request_id"}

    assert strip(wrong) == strip(unknown)
    assert wrong.json()["code"] == "invalid_credentials"
    assert wrong.json()["detail"] == "Email or password is incorrect."


async def test_login_unknown_email_runs_dummy_verify(
    db_session: AsyncSession, settings: Settings, fake_clock: FakeClock
) -> None:
    """One argon2 verification runs for an unknown email (timing equalisation)."""
    spy = MagicMock(wraps=PasswordHasher())
    service = AuthService(db_session, settings, fake_clock, spy)
    with pytest.raises(AuthenticationError):
        await service.login("nobody@example.com", "whatever")
    assert spy.verify_and_update.call_count == 1


async def test_login_rehashes_when_params_outdated(
    db_session: AsyncSession, auth_service: AuthService, settings: Settings, fake_clock: FakeClock
) -> None:
    await auth_service.ensure_owner("owner@example.com", TEST_OWNER_HASH)
    hasher = MagicMock()
    hasher.verify_and_update.return_value = (True, "$argon2id$upgraded")
    hasher.is_supported_hash.return_value = True
    service = AuthService(db_session, settings, fake_clock, hasher)
    await service.login("owner@example.com", "pw")
    row = (await db_session.execute(select(UserAccount))).scalar_one()
    assert row.password_hash == "$argon2id$upgraded"


async def test_login_sets_timezone_when_unconfirmed(
    authed_client: httpx.AsyncClient, client: httpx.AsyncClient
) -> None:
    """AUTH-AC-08."""
    await client.post(LOGIN, json={**_good(), "timezone": "Europe/Bucharest"})
    settings_body = (await authed_client.get(PROTECTED)).json()
    assert settings_body["timezone"] == "Europe/Bucharest"
    assert settings_body["timezone_confirmed"] is True


async def test_login_does_not_override_confirmed_timezone(
    authed_client: httpx.AsyncClient, client: httpx.AsyncClient
) -> None:
    await client.post(LOGIN, json={**_good(), "timezone": "Europe/Bucharest"})
    await client.post(LOGIN, json={**_good(), "timezone": "America/New_York"})
    assert (await authed_client.get(PROTECTED)).json()["timezone"] == "Europe/Bucharest"


async def test_login_ignores_invalid_timezone(
    authed_client: httpx.AsyncClient, client: httpx.AsyncClient
) -> None:
    response = await client.post(LOGIN, json={**_good(), "timezone": "Mars/Olympus"})
    assert response.status_code == 200
    body = (await authed_client.get(PROTECTED)).json()
    assert (body["timezone"], body["timezone_confirmed"]) == ("UTC", False)


async def test_login_validation_422_never_echoes_input(client: httpx.AsyncClient) -> None:
    response = await client.post(LOGIN, json={"email": "not-an-email", "password": "hunter2-secret"})
    assert response.status_code == 422
    assert "hunter2-secret" not in response.text and "not-an-email" not in response.text
    long_password = await client.post(LOGIN, json={**_good(), "password": "x" * 1025})
    assert long_password.status_code == 422


# ------------------------------------------------------------------ current_user
async def test_current_user_missing_header_401(client: httpx.AsyncClient) -> None:
    response = await client.get(PROTECTED)
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"
    assert response.json()["code"] == "not_authenticated"
    wrong_scheme = await client.get(PROTECTED, headers={"Authorization": "Basic abc"})
    assert wrong_scheme.json()["code"] == "not_authenticated"


async def test_current_user_valid_token_ok(client: httpx.AsyncClient, auth_headers: dict[str, str]) -> None:
    assert (await client.get(PROTECTED, headers=auth_headers)).status_code == 200


async def test_current_user_bad_signature_401(
    client: httpx.AsyncClient, make_token: Callable[..., str]
) -> None:
    token = make_token()
    tampered = token[:-4] + ("AAAA" if not token.endswith("AAAA") else "BBBB")
    response = await client.get(PROTECTED, headers={"Authorization": f"Bearer {tampered}"})
    assert response.status_code == 401
    assert response.json()["code"] == "invalid_token"


async def test_current_user_alg_none_rejected(
    client: httpx.AsyncClient, owner_id: UUID, fake_clock: FakeClock
) -> None:
    now = int(fake_clock.now_utc().timestamp())
    token = jwt.encode(
        {"sub": str(owner_id), "ver": 1, "iat": now, "exp": now + 1000},
        key=None,  # type: ignore[arg-type]
        algorithm="none",
    )
    response = await client.get(PROTECTED, headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 401
    assert response.json()["code"] == "invalid_token"


async def test_current_user_missing_claim_and_garbage_401(
    client: httpx.AsyncClient, settings: Settings, owner_id: UUID
) -> None:
    secret = settings.jwt_secret.get_secret_value()
    no_ver = jwt.encode({"sub": str(owner_id), "iat": 1, "exp": 9999999999}, secret, algorithm="HS256")
    for token in (no_ver, "not.a.jwt", "x"):
        response = await client.get(PROTECTED, headers={"Authorization": f"Bearer {token}"})
        assert response.status_code == 401, token
        assert response.json()["code"] == "invalid_token"


async def test_current_user_expired_401(
    client: httpx.AsyncClient, auth_headers: dict[str, str], fake_clock: FakeClock
) -> None:
    """AUTH-AC-06."""
    fake_clock.advance(timedelta(days=30, seconds=1))
    response = await client.get(PROTECTED, headers=auth_headers)
    assert response.status_code == 401
    assert response.json()["code"] == "token_expired"


async def test_current_user_version_bump_revokes(
    client: httpx.AsyncClient, auth_headers: dict[str, str], app: FastAPI
) -> None:
    """AUTH-AC-07."""
    assert (await client.get(PROTECTED, headers=auth_headers)).status_code == 200
    async with app.state.session_factory() as session:
        await session.execute(text("UPDATE user_account SET token_version = token_version + 1"))
        await session.commit()
    response = await client.get(PROTECTED, headers=auth_headers)
    assert response.status_code == 401
    assert response.json()["code"] == "invalid_token"


async def test_current_user_unknown_sub_401(
    client: httpx.AsyncClient, make_token: Callable[..., str]
) -> None:
    response = await client.get(PROTECTED, headers={"Authorization": f"Bearer {make_token(sub=uuid4())}"})
    assert response.status_code == 401
    assert response.json()["code"] == "invalid_token"


async def test_health_and_login_are_public(client: httpx.AsyncClient) -> None:
    assert (await client.get("/health")).status_code in (200, 503)  # reachable without a token either way
    assert (await client.post(LOGIN, json=_good())).status_code == 200


# ------------------------------------------------------------------ logging / CLI
async def test_password_never_logged(client: httpx.AsyncClient, caplog: pytest.LogCaptureFixture) -> None:
    with caplog.at_level(logging.DEBUG):
        ok = await client.post(LOGIN, json=_good())
        await client.post(LOGIN, json={**_good(), "password": "wrong-password-xyz"})
    # the app's own loggers only: aiosqlite (a test-only driver) logs bound SQL parameters at DEBUG
    records = [r for r in caplog.records if r.name.startswith("app")]
    assert records
    blob = " ".join(
        f"{r.getMessage()} {sorted(r.__dict__.keys())} {[str(v) for v in r.__dict__.values()]}"
        for r in records
    )
    for secret in (TEST_OWNER_PASSWORD, "wrong-password-xyz", ok.json()["access_token"], TEST_OWNER_EMAIL):
        assert secret not in blob


def _run_cli(*args: str, stdin: str = "") -> subprocess.CompletedProcess[str]:
    env = {
        k: v for k, v in os.environ.items() if k.upper() not in {"DATABASE_URL", "JWT_SECRET", "OWNER_EMAIL"}
    }
    return subprocess.run(
        [sys.executable, "-m", "app.modules.auth.hash_password", *args],
        cwd=BACKEND_DIR,
        input=stdin,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def test_hash_password_cli_stdin_outputs_argon2id() -> None:
    """AUTH-AC-09: runs with no app env vars; the hash is accepted by ``ensure_owner``."""
    result = _run_cli("--stdin", stdin="a-long-enough-password\n")
    assert result.returncode == 0, result.stderr
    out = result.stdout.strip()
    assert out.startswith("$argon2id$")
    assert PasswordHasher().is_supported_hash(out)
    assert PasswordHasher().verify_and_update("a-long-enough-password", out)[0] is True
    assert "a-long-enough-password" not in result.stderr + result.stdout
    assert "single quotes" in result.stderr


def test_hash_password_cli_short_exit_2() -> None:
    result = _run_cli("--stdin", stdin="short\n")
    assert result.returncode == 2
    assert result.stdout == ""


def test_hash_password_cli_mismatch_exit_1(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    from app.modules.auth import hash_password

    answers = iter(["first-password-1", "second-password-2"])
    monkeypatch.setattr("getpass.getpass", lambda prompt="": next(answers))
    assert hash_password.main([]) == 1
    assert capsys.readouterr().out == ""
