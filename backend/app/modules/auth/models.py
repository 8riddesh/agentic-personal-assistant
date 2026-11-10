"""``user_account`` ORM (auth spec §4). Exactly one row; no encrypted columns."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import Boolean, CheckConstraint, Integer, String, text
from sqlalchemy.orm import Mapped, mapped_column

from app.modules.core import Base, TimestampMixin, UTCDateTime, UUIDPkMixin


class UserAccount(UUIDPkMixin, TimestampMixin, Base):
    __tablename__ = "user_account"
    __table_args__ = (
        CheckConstraint("singleton", name="singleton"),
        CheckConstraint("token_version >= 1", name="token_version_positive"),
    )

    singleton: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default=text("true"), unique=True
    )
    email: Mapped[str] = mapped_column(String, nullable=False, unique=True)
    password_hash: Mapped[str] = mapped_column(String, nullable=False)
    token_version: Mapped[int] = mapped_column(Integer, nullable=False, default=1, server_default=text("1"))
    last_login_at: Mapped[datetime | None] = mapped_column(UTCDateTime(), nullable=True)
