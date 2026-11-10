"""``day_session`` ORM (day_cycle spec §4). Holds no personal text, so no encrypted columns."""

from __future__ import annotations

import enum
from datetime import date, datetime
from uuid import UUID

from sqlalchemy import Boolean, CheckConstraint, Date, Index, SmallInteger, String, Uuid, text
from sqlalchemy.orm import Mapped, mapped_column

from app.modules.core import Base, TimestampMixin, UTCDateTime, UUIDPkMixin, enum_type
from app.modules.day_cycle.schemas import CloseMode


class DayStateEnum(enum.StrEnum):
    OPEN = "open"
    CLOSING = "closing"
    CLOSED = "closed"


class DaySession(UUIDPkMixin, TimestampMixin, Base):
    __tablename__ = "day_session"
    __table_args__ = (
        CheckConstraint(
            "state = 'open' OR (closed_at IS NOT NULL AND close_mode IS NOT NULL)",
            name="closed_has_close_info",
        ),
        Index(
            "ix_day_session_state",
            "state",
            postgresql_where=text("state <> 'closed'"),
            sqlite_where=text("state <> 'closed'"),
        ),
        Index(
            "ix_day_session_weekly_pending",
            "local_date",
            postgresql_where=text("weekly_due AND weekly_report_id IS NULL"),
            sqlite_where=text("weekly_due AND weekly_report_id IS NULL"),
        ),
    )

    local_date: Mapped[date] = mapped_column(Date, nullable=False, unique=True)
    opened_at: Mapped[datetime] = mapped_column(UTCDateTime(), nullable=False)
    closed_at: Mapped[datetime | None] = mapped_column(UTCDateTime(), nullable=True)
    close_mode: Mapped[CloseMode | None] = mapped_column(
        enum_type(CloseMode, "day_session_close_mode"), nullable=True
    )
    state: Mapped[DayStateEnum] = mapped_column(
        enum_type(DayStateEnum, "day_session_state"),
        nullable=False,
        default=DayStateEnum.OPEN,
        server_default=DayStateEnum.OPEN.value,
    )
    # No FK in M1: the M4 reports migration adds fk_day_session_*_report.
    daily_report_id: Mapped[UUID | None] = mapped_column(Uuid(as_uuid=True), nullable=True)
    weekly_report_id: Mapped[UUID | None] = mapped_column(Uuid(as_uuid=True), nullable=True)
    auto_created: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default=text("false")
    )
    missed_marked_at: Mapped[datetime | None] = mapped_column(UTCDateTime(), nullable=True)
    predictor_done_at: Mapped[datetime | None] = mapped_column(UTCDateTime(), nullable=True)
    weekly_due: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default=text("false")
    )
    close_started_at: Mapped[datetime | None] = mapped_column(UTCDateTime(), nullable=True)
    close_attempts: Mapped[int] = mapped_column(
        SmallInteger, nullable=False, default=0, server_default=text("0")
    )
    last_error: Mapped[str | None] = mapped_column(String(200), nullable=True)
