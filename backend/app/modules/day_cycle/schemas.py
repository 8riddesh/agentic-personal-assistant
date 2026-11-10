"""day_cycle DTOs (spec §5)."""

from __future__ import annotations

import enum
from datetime import date, datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field

from app.modules.tasks import TaskDTO, TaskStatus

DayState = Literal["open", "closing", "closed"]
ALL_STATUSES: tuple[TaskStatus, ...] = ("planned", "completed", "postponed", "cancelled", "cant_do", "missed")


class CloseMode(enum.StrEnum):
    USER = "user"
    AUTO_MIDNIGHT = "auto_midnight"


class DaySummary(BaseModel):
    total: int
    by_status: dict[TaskStatus, int]  # all six keys present, zeros included

    @classmethod
    def from_tasks(cls, tasks: list[TaskDTO]) -> DaySummary:
        counts: dict[TaskStatus, int] = dict.fromkeys(ALL_STATUSES, 0)
        for task in tasks:
            counts[task.status] += 1
        return cls(total=len(tasks), by_status=counts)


class DayDTO(BaseModel):
    id: UUID
    local_date: date
    state: DayState
    is_today: bool
    opened_at: datetime
    closed_at: datetime | None
    close_mode: CloseMode | None
    daily_report_id: UUID | None
    weekly_report_id: UUID | None
    weekly_due: bool
    auto_created: bool
    summary: DaySummary


class CloseResultDTO(BaseModel):
    local_date: date
    state: DayState
    close_mode: CloseMode
    missed_count: int  # tasks marked missed by THIS call (0 on replay)
    daily_report_id: UUID | None  # null while state == closing (spec §13 Q1)
    weekly_report_id: UUID | None
    weekly_expected: bool  # = weekly_due
    already_closed: bool


class UnresolvedDTO(BaseModel):
    local_date: date
    tasks: list[TaskDTO] = Field(default_factory=list)
