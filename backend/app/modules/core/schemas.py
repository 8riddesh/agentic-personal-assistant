"""Public DTOs of core (spec §5.1)."""

from __future__ import annotations

from datetime import datetime
from typing import Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import BaseModel, ConfigDict, EmailStr, field_validator

MIN_OFFSET_MIN = 5
MAX_OFFSET_MIN = 240


def validate_timezone(value: str) -> str:
    """IANA key loadable by ``ZoneInfo`` (``"localtime"`` is not a portable key and is rejected)."""
    if value.lower() == "localtime" or not value or len(value) > 64:
        raise ValueError("unknown IANA timezone")
    try:
        ZoneInfo(value)
    except (ZoneInfoNotFoundError, ValueError, OSError):
        raise ValueError("unknown IANA timezone") from None
    return value


def validate_offsets(value: list[int]) -> list[int]:
    """1-2 distinct ints in 5..240, stored sorted descending (core spec §6, Q4)."""
    if not 1 <= len(value) <= 2:
        raise ValueError("reminder_offsets_min needs one or two values")
    if len(set(value)) != len(value):
        raise ValueError("reminder offsets must be distinct")
    if any(not MIN_OFFSET_MIN <= v <= MAX_OFFSET_MIN for v in value):
        raise ValueError(f"reminder offsets must be within {MIN_OFFSET_MIN}..{MAX_OFFSET_MIN} minutes")
    return sorted(value, reverse=True)


class AppSettingsDTO(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    timezone: str
    timezone_confirmed: bool
    reminder_offsets_min: list[int]
    report_email: EmailStr | None
    week_start: int
    updated_at: datetime


class AppSettingsPatch(BaseModel):
    """Only fields present in the request are applied (``model_fields_set``); ``report_email: null`` clears it."""

    model_config = ConfigDict(extra="forbid")

    timezone: str | None = None
    reminder_offsets_min: list[int] | None = None
    report_email: EmailStr | None = None
    week_start: int | None = None

    @field_validator("timezone")
    @classmethod
    def _timezone(cls, value: str | None) -> str:
        if value is None:
            raise ValueError("timezone cannot be null")
        return validate_timezone(value)

    @field_validator("reminder_offsets_min")
    @classmethod
    def _offsets(cls, value: list[int] | None) -> list[int]:
        if value is None:
            raise ValueError("reminder_offsets_min cannot be null")
        return validate_offsets(value)

    @field_validator("week_start")
    @classmethod
    def _week_start(cls, value: int | None) -> int:
        if value is None or not 1 <= value <= 7:
            raise ValueError("week_start must be 1..7")
        return value


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
