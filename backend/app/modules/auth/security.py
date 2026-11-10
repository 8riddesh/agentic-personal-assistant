"""Password hashing and JWT helpers (auth spec §5, §7.3). Pure functions, no I/O."""

from __future__ import annotations

import jwt
from pwdlib import PasswordHash
from pwdlib.hashers.argon2 import Argon2Hasher
from pydantic import ValidationError

from app.modules.auth.schemas import JwtClaims
from app.modules.core import AuthenticationError

ALGORITHM = "HS256"
_REQUIRED_CLAIMS = ["sub", "ver", "iat", "exp"]


class PasswordHasher:
    """Thin wrapper over ``pwdlib.PasswordHash`` (argon2id with the library's default parameters)."""

    def __init__(self) -> None:
        self._hasher = PasswordHash((Argon2Hasher(),))

    def hash(self, password: str) -> str:
        return self._hasher.hash(password)

    def verify_and_update(self, password: str, hash_: str) -> tuple[bool, str | None]:
        return self._hasher.verify_and_update(password, hash_)

    def is_supported_hash(self, hash_: str) -> bool:
        return hash_.startswith("$argon2id$")


def encode_jwt(claims: JwtClaims, secret: str) -> str:
    return jwt.encode(claims.model_dump(mode="json"), secret, algorithm=ALGORITHM)


def decode_jwt(token: str, secret: str) -> JwtClaims:
    """Verify signature and structure. ``exp`` is *not* checked here: the dependency compares it with the injected
    ``Clock`` so tests are deterministic. ``algorithms`` is pinned, which rejects ``none`` and RS*."""
    try:
        payload = jwt.decode(
            token,
            secret,
            algorithms=[ALGORITHM],
            options={
                "require": _REQUIRED_CLAIMS,
                "verify_exp": False,
                "verify_iat": False,
                "verify_nbf": False,
            },
        )
        return JwtClaims.model_validate(payload)
    except (jwt.InvalidTokenError, ValidationError):
        raise AuthenticationError("The access token is invalid.", code="invalid_token") from None
