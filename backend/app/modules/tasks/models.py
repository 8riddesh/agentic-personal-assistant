"""Tasks ORM (tasks spec §4): ``task_template``, ``task``, ``task_status_event``. Private to the module."""

from __future__ import annotations

import enum
from datetime import date, datetime, time
from typing import Any
from uuid import UUID

from sqlalchemy import (
    JSON,
    Boolean,
    CheckConstraint,
    Date,
    ForeignKey,
    Index,
    Integer,
    SmallInteger,
    String,
    Time,
    Uuid,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.modules.core import Base, TimestampMixin, UTCDateTime, UUIDPkMixin, enum_type
from app.modules.crypto import EncryptedText

# jsonb on Postgres; plain JSON on SQLite so the local test-suite runs without Postgres.
_JSONB = JSONB().with_variant(JSON(), "sqlite")


class TaskStatusEnum(enum.StrEnum):
    PLANNED = "planned"
    COMPLETED = "completed"
    POSTPONED = "postponed"
    CANCELLED = "cancelled"
    CANT_DO = "cant_do"
    MISSED = "missed"


class ActualEndSourceEnum(enum.StrEnum):
    NOTIFICATION_ACTION = "notification_action"
    MANUAL = "manual"
    EOD_RESOLUTION = "eod_resolution"


class CreatedViaEnum(enum.StrEnum):
    FORM = "form"
    CHAT = "chat"
    TEMPLATE = "template"


class CheckResponseEnum(enum.StrEnum):
    DONE = "done"
    NOT_YET = "not_yet"


class EventSourceEnum(enum.StrEnum):
    APP = "app"
    NOTIFICATION = "notification"
    CHAT = "chat"
    EOD = "eod"
    SYSTEM = "system"


class TaskTemplate(UUIDPkMixin, TimestampMixin, Base):
    __tablename__ = "task_template"
    __table_args__ = (
        CheckConstraint(
            "default_estimate_min IS NULL OR default_estimate_min BETWEEN 1 AND 720", name="estimate_range"
        ),
        Index("ix_task_template_active", "active"),
    )

    title: Mapped[str] = mapped_column(EncryptedText(aad="task_template.title"), nullable=False)
    notes: Mapped[str | None] = mapped_column(EncryptedText(aad="task_template.notes"), nullable=True)
    category: Mapped[str] = mapped_column(String(32), nullable=False)
    start_local: Mapped[time | None] = mapped_column(Time, nullable=True)
    recurrence: Mapped[dict[str, Any]] = mapped_column(_JSONB, nullable=False)
    default_estimate_min: Mapped[int | None] = mapped_column(Integer, nullable=True)
    starts_on: Mapped[date] = mapped_column(Date, nullable=False)
    active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True, server_default=text("true"))


class Task(UUIDPkMixin, TimestampMixin, Base):
    __tablename__ = "task"
    __table_args__ = (
        CheckConstraint("estimate_min IS NULL OR estimate_min BETWEEN 1 AND 720", name="estimate_range"),
        CheckConstraint(
            "status <> 'completed' OR (actual_end_at IS NOT NULL AND actual_end_source IS NOT NULL)",
            name="completed_has_end",
        ),
        CheckConstraint(
            "status <> 'postponed' OR postponed_to_task_id IS NOT NULL", name="postponed_has_target"
        ),
        CheckConstraint("status <> 'cant_do' OR status_reason IS NOT NULL", name="cant_do_has_reason"),
        CheckConstraint(
            "feasibility_overridden = false OR feasibility_id IS NOT NULL", name="override_has_assessment"
        ),
        Index(
            "uq_task_local_date_template",
            "local_date",
            "template_id",
            unique=True,
            postgresql_where=text("template_id IS NOT NULL"),
            sqlite_where=text("template_id IS NOT NULL"),
        ),
        Index(
            "uq_task_client_request_id",
            "client_request_id",
            unique=True,
            postgresql_where=text("client_request_id IS NOT NULL"),
            sqlite_where=text("client_request_id IS NOT NULL"),
        ),
        Index("ix_task_local_date", "local_date"),
        Index("ix_task_status_local_date", "status", "local_date"),
        Index(
            "ix_task_origin_template",
            "origin_template_id",
            postgresql_where=text("origin_template_id IS NOT NULL"),
            sqlite_where=text("origin_template_id IS NOT NULL"),
        ),
    )

    local_date: Mapped[date] = mapped_column(Date, nullable=False)
    template_id: Mapped[UUID | None] = mapped_column(
        Uuid(as_uuid=True), ForeignKey("task_template.id", ondelete="RESTRICT"), nullable=True
    )
    origin_template_id: Mapped[UUID | None] = mapped_column(
        Uuid(as_uuid=True), ForeignKey("task_template.id", ondelete="RESTRICT"), nullable=True
    )
    title: Mapped[str] = mapped_column(EncryptedText(aad="task.title"), nullable=False)
    notes: Mapped[str | None] = mapped_column(EncryptedText(aad="task.notes"), nullable=True)
    category: Mapped[str] = mapped_column(String(32), nullable=False)
    start_at: Mapped[datetime | None] = mapped_column(UTCDateTime(), nullable=True)
    estimate_min: Mapped[int | None] = mapped_column(Integer, nullable=True)
    predicted_end_at: Mapped[datetime | None] = mapped_column(UTCDateTime(), nullable=True)
    prediction_method: Mapped[str | None] = mapped_column(String(64), nullable=True)
    actual_end_at: Mapped[datetime | None] = mapped_column(UTCDateTime(), nullable=True)
    actual_end_source: Mapped[ActualEndSourceEnum | None] = mapped_column(
        enum_type(ActualEndSourceEnum, "task_actual_end_source"), nullable=True
    )
    status: Mapped[TaskStatusEnum] = mapped_column(
        enum_type(TaskStatusEnum, "task_status"),
        nullable=False,
        default=TaskStatusEnum.PLANNED,
        server_default=TaskStatusEnum.PLANNED.value,
    )
    status_reason: Mapped[str | None] = mapped_column(EncryptedText(aad="task.status_reason"), nullable=True)
    postponed_to_task_id: Mapped[UUID | None] = mapped_column(
        Uuid(as_uuid=True), ForeignKey("task.id"), nullable=True
    )
    # No FK in M1: the M2 feasibility migration adds ``fk_task_feasibility_id_feasibility_assessment``.
    feasibility_id: Mapped[UUID | None] = mapped_column(Uuid(as_uuid=True), nullable=True)
    feasibility_overridden: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default=text("false")
    )
    created_via: Mapped[CreatedViaEnum] = mapped_column(
        enum_type(CreatedViaEnum, "task_created_via"), nullable=False
    )
    check_response: Mapped[CheckResponseEnum | None] = mapped_column(
        enum_type(CheckResponseEnum, "task_check_response"), nullable=True
    )
    check_responded_at: Mapped[datetime | None] = mapped_column(UTCDateTime(), nullable=True)
    check_not_yet_at: Mapped[datetime | None] = mapped_column(UTCDateTime(), nullable=True)
    check_eta_min: Mapped[int | None] = mapped_column(SmallInteger, nullable=True)
    client_request_id: Mapped[UUID | None] = mapped_column(Uuid(as_uuid=True), nullable=True)


class TaskStatusEvent(UUIDPkMixin, TimestampMixin, Base):
    """Append-only audit trail: the repository exposes insert + select only."""

    __tablename__ = "task_status_event"
    __table_args__ = (Index("ix_task_status_event_task", "task_id", "at"),)

    task_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), ForeignKey("task.id"), nullable=False)
    from_status: Mapped[TaskStatusEnum | None] = mapped_column(
        enum_type(TaskStatusEnum, "task_status_event_from_status"), nullable=True
    )
    to_status: Mapped[TaskStatusEnum] = mapped_column(
        enum_type(TaskStatusEnum, "task_status_event_to_status"), nullable=False
    )
    at: Mapped[datetime] = mapped_column(UTCDateTime(), nullable=False)
    source: Mapped[EventSourceEnum] = mapped_column(
        enum_type(EventSourceEnum, "task_status_event_source"), nullable=False
    )
    reason: Mapped[str | None] = mapped_column(EncryptedText(aad="task_status_event.reason"), nullable=True)
