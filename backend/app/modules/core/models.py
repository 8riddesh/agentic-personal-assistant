"""``app_settings`` ORM (core spec §4.1). Private to core."""

from __future__ import annotations

from sqlalchemy import ARRAY, JSON, Boolean, CheckConstraint, Integer, SmallInteger, String, text
from sqlalchemy.orm import Mapped, mapped_column

from app.modules.core.db import Base, TimestampMixin, UUIDPkMixin
from app.modules.crypto import EncryptedText

# int[] on Postgres; JSON on SQLite so the test-suite can run without Postgres.
_INT_ARRAY = ARRAY(Integer()).with_variant(JSON(), "sqlite")


class AppSettings(UUIDPkMixin, TimestampMixin, Base):
    __tablename__ = "app_settings"
    __table_args__ = (
        CheckConstraint("singleton", name="singleton"),
        CheckConstraint("week_start BETWEEN 1 AND 7", name="week_start_range"),
        CheckConstraint(
            "cardinality(reminder_offsets_min) BETWEEN 1 AND 2", name="reminder_offsets_size"
        ).ddl_if(dialect="postgresql"),
    )

    singleton: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default=text("true"), unique=True
    )
    timezone: Mapped[str] = mapped_column(String, nullable=False, default="UTC", server_default="UTC")
    timezone_confirmed: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default=text("false")
    )
    reminder_offsets_min: Mapped[list[int]] = mapped_column(
        _INT_ARRAY, nullable=False, default=lambda: [60, 30], server_default=text("'{60,30}'")
    )
    report_email: Mapped[str | None] = mapped_column(
        EncryptedText(aad="app_settings.report_email"), nullable=True
    )
    week_start: Mapped[int] = mapped_column(SmallInteger, nullable=False, default=1, server_default=text("1"))
