"""Public DTOs of core. (AppSettings DTOs arrive with M1.)"""

from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict


class HealthDTO(BaseModel):
    status: Literal["ok", "degraded"]
    db: Literal["ok", "unavailable"]
    env: str
    version: str
    time: datetime


class FieldError(BaseModel):
    loc: list[str | int]
    msg: str
    type: str


class ProblemDetails(BaseModel):
    """RFC 7807 body. ``extra="allow"`` carries ``AppError.extra`` members (developer-written, never user text)."""

    model_config = ConfigDict(extra="allow")

    type: str
    title: str
    status: int
    detail: str | None = None
    instance: str
    code: str
    request_id: str | None = None
    errors: list[FieldError] | None = None
