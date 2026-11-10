"""day_cycle: create day_session

No FKs on daily_report_id / weekly_report_id: the M4 reports migration adds them.

Revision ID: d4f6b8ca0004
Revises: c3e5a7b90003
Create Date: 2026-11-09 10:30:00
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "d4f6b8ca0004"
down_revision: str | None = "c3e5a7b90003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "day_session",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("local_date", sa.Date(), nullable=False),
        sa.Column("opened_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("closed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "close_mode",
            sa.Enum(
                "user",
                "auto_midnight",
                name="ck_day_session_day_session_close_mode",
                native_enum=False,
                create_constraint=True,
                length=32,
            ),
            nullable=True,
        ),
        sa.Column(
            "state",
            sa.Enum(
                "open",
                "closing",
                "closed",
                name="ck_day_session_day_session_state",
                native_enum=False,
                create_constraint=True,
                length=32,
            ),
            server_default="open",
            nullable=False,
        ),
        sa.Column("daily_report_id", sa.Uuid(), nullable=True),
        sa.Column("weekly_report_id", sa.Uuid(), nullable=True),
        sa.Column("auto_created", sa.Boolean(), server_default=sa.text("false"), nullable=False),
        sa.Column("missed_marked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("predictor_done_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("weekly_due", sa.Boolean(), server_default=sa.text("false"), nullable=False),
        sa.Column("close_started_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("close_attempts", sa.SmallInteger(), server_default=sa.text("0"), nullable=False),
        sa.Column("last_error", sa.String(length=200), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("id", name="pk_day_session"),
        sa.UniqueConstraint("local_date", name="uq_day_session_local_date"),
        sa.CheckConstraint(
            "state = 'open' OR (closed_at IS NOT NULL AND close_mode IS NOT NULL)",
            name="ck_day_session_closed_has_close_info",
        ),
    )
    op.create_index(
        "ix_day_session_state", "day_session", ["state"], postgresql_where=sa.text("state <> 'closed'")
    )
    op.create_index(
        "ix_day_session_weekly_pending",
        "day_session",
        ["local_date"],
        postgresql_where=sa.text("weekly_due AND weekly_report_id IS NULL"),
    )


def downgrade() -> None:
    op.drop_index("ix_day_session_weekly_pending", table_name="day_session")
    op.drop_index("ix_day_session_state", table_name="day_session")
    op.drop_table("day_session")
