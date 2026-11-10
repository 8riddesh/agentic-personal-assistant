"""AuthService: login and owner seeding (auth spec §7.1, §7.2)."""

from __future__ import annotations

import secrets
from datetime import UTC, datetime

from fastapi import Depends
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.concurrency import run_in_threadpool

from app.modules.auth.repository import UserAccountRepository
from app.modules.auth.schemas import JwtClaims, TokenDTO
from app.modules.auth.security import PasswordHasher, encode_jwt
from app.modules.core import (
    AuthenticationError,
    Clock,
    DomainValidationError,
    SessionDep,
    Settings,
    get_clock,
    get_logger,
    get_settings,
)

logger = get_logger("app.auth")

_dummy_hash: str | None = None


def _get_dummy_hash(hasher: PasswordHasher) -> str:
    """argon2id hash of a random secret, computed once, so unknown-email logins still pay one full verification."""
    global _dummy_hash
    if _dummy_hash is None:
        _dummy_hash = hasher.hash(secrets.token_urlsafe(32))
    return _dummy_hash


class AuthService:
    def __init__(
        self, session: AsyncSession, settings: Settings, clock: Clock, hasher: PasswordHasher | None = None
    ) -> None:
        self._repo = UserAccountRepository(session)
        self._settings = settings
        self._clock = clock
        self._hasher = hasher or PasswordHasher()

    async def ensure_owner(self, email: str, password_hash: str) -> bool:
        """Seed the single account. Existing rows are left unchanged (plan §6.1). True if inserted."""
        if not self._hasher.is_supported_hash(password_hash):
            raise DomainValidationError("OWNER_PASSWORD_HASH is not an argon2id hash")
        email_n = email.strip().lower()
        existing = await self._repo.any_user()
        if existing is None:
            inserted = await self._repo.insert(email_n, password_hash)
            if inserted is not None:
                logger.info("owner_seeded")
                return True
            existing = await self._repo.any_user()
        if existing is not None and existing.email != email_n:
            logger.warning("owner_email_mismatch")
        return False

    async def login(self, email: str, password: str) -> TokenDTO:
        email_n = email.strip().lower()
        user = await self._repo.get_by_email(email_n)
        target_hash = user.password_hash if user else _get_dummy_hash(self._hasher)
        ok, new_hash = await run_in_threadpool(self._hasher.verify_and_update, password, target_hash)
        if user is None or not ok:
            logger.info("login_failed")
            raise AuthenticationError("Email or password is incorrect.", code="invalid_credentials")
        if new_hash:
            user.password_hash = new_hash
        now = self._clock.now_utc()
        user.last_login_at = now
        iat = int(now.timestamp())
        exp = iat + self._settings.jwt_ttl_days * 86400
        token = encode_jwt(
            JwtClaims(sub=user.id, ver=user.token_version, iat=iat, exp=exp),
            self._settings.jwt_secret.get_secret_value(),
        )
        logger.info("login_succeeded")
        return TokenDTO(access_token=token, expires_at=datetime.fromtimestamp(exp, UTC))


def get_auth_service(
    session: SessionDep, settings: Settings = Depends(get_settings), clock: Clock = Depends(get_clock)
) -> AuthService:
    return AuthService(session, settings, clock)
