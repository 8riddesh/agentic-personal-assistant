"""Tasks DTOs and request bodies (tasks spec §5.2, §5.3)."""

from __future__ import annotations

from datetime import date, datetime, time
from typing import Annotated, Literal, Protocol
from uuid import UUID

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, field_validator, model_validator

KNOWN_CATEGORIES: tuple[str, ...] = ("Work", "Learning", "Health", "Personal", "Chores")

MAX_TITLE_LEN = 200
MAX_NOTES_LEN = 2000
MAX_REASON_LEN = 500
MAX_ESTIMATE_MIN = 720

TaskStatus = Literal["planned", "completed", "postponed", "cancelled", "cant_do", "missed"]
ActualEndSource = Literal["notification_action", "manual", "eod_resolution"]
CreatedVia = Literal["form", "chat", "template"]
CommandSource = Literal["app", "chat", "eod"]


# --------------------------------------------------------------------------- recurrence
class DailyRecurrence(BaseModel):
    freq: Literal["daily"]


class WeeklyRecurrence(BaseModel):
    freq: Literal["weekly"]
    byweekday: list[int]  # unique items in 0..6 (0 = Monday), stored sorted

    @field_validator("byweekday")
    @classmethod
    def _weekdays(cls, value: list[int]) -> list[int]:
        if not value:
            raise ValueError("byweekday needs at least one weekday")
        if len(set(value)) != len(value):
            raise ValueError("byweekday must not contain duplicates")
        if any(not 0 <= d <= 6 for d in value):
            raise ValueError("byweekday items must be within 0..6 (0 = Monday)")
        return sorted(value)


Recurrence = Annotated[DailyRecurrence | WeeklyRecurrence, Field(discriminator="freq")]


# --------------------------------------------------------------------------- shared field rules
def _clean_title(value: str) -> str:
    value = value.strip()
    if not 1 <= len(value) <= MAX_TITLE_LEN:
        raise ValueError(f"title must be 1..{MAX_TITLE_LEN} characters")
    return value


def _clean_notes(value: str | None) -> str | None:
    if value is None:
        return None
    value = value.strip()
    if len(value) > MAX_NOTES_LEN:
        raise ValueError(f"notes must be at most {MAX_NOTES_LEN} characters")
    return value or None


def _clean_estimate(value: int | None) -> int | None:
    if value is not None and not 1 <= value <= MAX_ESTIMATE_MIN:
        raise ValueError(f"estimate_min must be 1..{MAX_ESTIMATE_MIN}")
    return value


# --------------------------------------------------------------------------- drafts / requests
class TaskDraft(BaseModel):
    """Shared with feasibility and assistant (plan §4.1)."""

    title: str
    notes: str | None = None
    category: str = "Personal"  # normalised by the service (§7.6)
    start_at: AwareDatetime | None = None
    estimate_min: int | None = None
    is_recurring: bool  # required: the app always asks
    recurrence: Recurrence | None = None  # required iff is_recurring
    local_date: date | None = None  # needed for anytime tasks; derived when omitted (§7.5)

    @field_validator("title")
    @classmethod
    def _title(cls, value: str) -> str:
        return _clean_title(value)

    @field_validator("notes")
    @classmethod
    def _notes(cls, value: str | None) -> str | None:
        return _clean_notes(value)

    @field_validator("estimate_min")
    @classmethod
    def _estimate(cls, value: int | None) -> int | None:
        return _clean_estimate(value)

    @model_validator(mode="after")
    def _recurrence_matches_flag(self) -> TaskDraft:
        if self.is_recurring != (self.recurrence is not None):
            raise ValueError("recurrence is required if and only if is_recurring is true")
        return self


class CreateTaskRequest(TaskDraft):
    assessment_id: UUID | None = None
    overridden: bool = False
    created_via: Literal["form", "chat"] = "form"
    client_request_id: UUID | None = None


# --------------------------------------------------------------------------- DTOs
class TaskDTO(BaseModel):
    id: UUID
    local_date: date
    template_id: UUID | None
    origin_template_id: UUID | None
    is_recurring: bool  # origin_template_id is not None
    title: str
    notes: str | None
    category: str
    start_at: datetime | None
    estimate_min: int | None
    predicted_end_at: datetime | None
    prediction_method: str | None
    actual_end_at: datetime | None
    actual_end_source: ActualEndSource | None
    status: TaskStatus
    status_reason: str | None
    postponed_to_task_id: UUID | None
    postponed_from_task_id: UUID | None  # reverse link, derived
    feasibility_id: UUID | None
    feasibility_overridden: bool
    created_via: CreatedVia
    check_response: Literal["done", "not_yet"] | None
    check_responded_at: datetime | None
    check_not_yet_at: datetime | None
    check_eta_min: int | None
    created_at: datetime
    updated_at: datetime


class TaskOutcomeDTO(BaseModel):
    """One labelled duration (§7.7)."""

    task_id: UUID
    local_date: date
    template_id: UUID | None  # = origin_template_id
    category: str
    start_at: datetime
    actual_end_at: datetime
    duration_min: float
    estimate_min: int | None
    predicted_end_at: datetime | None
    prediction_method: str | None
    actual_end_source: Literal["notification_action", "manual"]
    weekday: int  # local_date.weekday(), 0 = Monday
    start_minute_local: int  # minutes since local midnight of start_at
    check_not_yet: bool  # check_not_yet_at is not None


class TemplateDTO(BaseModel):
    id: UUID
    title: str
    notes: str | None
    category: str
    start_local: time | None
    recurrence: Recurrence
    default_estimate_min: int | None
    starts_on: date
    active: bool
    created_at: datetime
    updated_at: datetime


class CreateTaskResult(BaseModel):
    task: TaskDTO
    template: TemplateDTO | None
    replayed: bool = False


# --------------------------------------------------------------------------- patches / commands
class TaskPatch(BaseModel):
    """Only fields present in the request are applied; an explicit ``null`` clears notes/start_at/estimate_min."""

    model_config = ConfigDict(extra="forbid")

    title: str | None = None
    notes: str | None = None
    category: str | None = None
    start_at: AwareDatetime | None = None
    estimate_min: int | None = None
    scope: Literal["this", "future"] = "this"

    @field_validator("title")
    @classmethod
    def _title(cls, value: str | None) -> str:
        if value is None:
            raise ValueError("title cannot be null")
        return _clean_title(value)

    @field_validator("category")
    @classmethod
    def _category(cls, value: str | None) -> str:
        if value is None:
            raise ValueError("category cannot be null")
        return value

    @field_validator("notes")
    @classmethod
    def _notes(cls, value: str | None) -> str | None:
        return _clean_notes(value)

    @field_validator("estimate_min")
    @classmethod
    def _estimate(cls, value: int | None) -> int | None:
        return _clean_estimate(value)


class _Command(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Completed(_Command):
    status: Literal["completed"]
    finished_at: AwareDatetime | None = None
    source: CommandSource = "app"


class Postponed(_Command):
    status: Literal["postponed"]
    new_start_at: AwareDatetime | None = None
    new_local_date: date | None = None
    source: CommandSource = "app"


class Cancelled(_Command):
    status: Literal["cancelled"]
    reason: str | None = None
    source: CommandSource = "app"

    @field_validator("reason")
    @classmethod
    def _reason(cls, value: str | None) -> str | None:
        if value is None:
            return None
        value = value.strip()
        if len(value) > MAX_REASON_LEN:
            raise ValueError(f"reason must be at most {MAX_REASON_LEN} characters")
        return value or None


class CantDo(_Command):
    status: Literal["cant_do"]
    reason: str
    source: CommandSource = "app"

    @field_validator("reason")
    @classmethod
    def _reason(cls, value: str) -> str:
        value = value.strip()
        if not 1 <= len(value) <= MAX_REASON_LEN:
            raise ValueError(f"reason must be 1..{MAX_REASON_LEN} characters")
        return value


StatusCommand = Annotated[Completed | Postponed | Cancelled | CantDo, Field(discriminator="status")]


class StatusChangeResult(BaseModel):
    task: TaskDTO
    created_task: TaskDTO | None = None


class CheckDone(_Command):
    response: Literal["done"]
    finished_at: AwareDatetime
    responded_at: AwareDatetime | None = None


class CheckNotYet(_Command):
    response: Literal["not_yet"]
    eta_min: int | None = Field(default=None, ge=5, le=240)
    responded_at: AwareDatetime | None = None


CheckResponse = Annotated[CheckDone | CheckNotYet, Field(discriminator="response")]


class TemplatePatch(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str | None = None
    notes: str | None = None
    category: str | None = None
    start_local: time | None = None
    recurrence: Recurrence | None = None
    default_estimate_min: int | None = None
    active: bool | None = None

    @field_validator("title")
    @classmethod
    def _title(cls, value: str | None) -> str:
        if value is None:
            raise ValueError("title cannot be null")
        return _clean_title(value)

    @field_validator("category", "recurrence", "active")
    @classmethod
    def _not_null(cls, value: object) -> object:
        if value is None:
            raise ValueError("this field cannot be null")
        return value

    @field_validator("notes")
    @classmethod
    def _notes(cls, value: str | None) -> str | None:
        return _clean_notes(value)

    @field_validator("default_estimate_min")
    @classmethod
    def _estimate(cls, value: int | None) -> int | None:
        return _clean_estimate(value)


# --------------------------------------------------------------------------- prediction port (§5.3)
class PredictionRequest(BaseModel):
    title: str
    category: str
    start_at: datetime | None
    estimate_min: int | None
    template_id: UUID | None


class PredictedEnd(BaseModel):
    predicted_end_at: datetime | None
    method: str


class EndTimePredictorPort(Protocol):
    """Defined here, implemented by ``predictor`` and injected by ``app.main`` (dependency inversion, §13 Q1)."""

    async def predict_end(self, req: PredictionRequest) -> PredictedEnd: ...
