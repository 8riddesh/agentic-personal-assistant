"""Auth DTOs (auth spec §5)."""

from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, EmailStr, Field


class LoginRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    email: EmailStr
    password: str = Field(min_length=1, max_length=1024)
    timezone: str | None = Field(default=None, max_length=64)  # device IANA tz (core spec Q2)


class TokenDTO(BaseModel):
    access_token: str
    token_type: Literal["bearer"] = "bearer"
    expires_at: datetime  # UTC


class UserDTO(BaseModel):
    id: UUID
    email: EmailStr


class JwtClaims(BaseModel):
    """Exactly these four claims, nothing else (no email)."""

    sub: UUID
    ver: int
    iat: int
    exp: int  # NumericDate seconds
