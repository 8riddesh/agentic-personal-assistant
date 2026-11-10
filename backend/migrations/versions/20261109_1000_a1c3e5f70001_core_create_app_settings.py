"""core: create app_settings

Revision ID: a1c3e5f70001
Revises:
Create Date: 2026-11-09 10:00:00
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "a1c3e5f70001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "app_settings",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("singleton", sa.Boolean(), server_default=sa.text("true"), nullable=False),
        sa.Column("timezone", sa.String(), server_default="UTC", nullable=False),
        sa.Column("timezone_confirmed", sa.Boolean(), server_default=sa.text("false"), nullable=False),
        sa.Column(
            "reminder_offsets_min",
            postgresql.ARRAY(sa.Integer()),
            server_default=sa.text("'{60,30}'"),
            nullable=False,
        ),
        sa.Column("report_email", sa.Text(), nullable=True),  # encrypted (EncryptedText, aad app_settings.report_email)
        sa.Column("week_start", sa.SmallInteger(), server_default=sa.text("1"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("id", name="pk_app_settings"),
        sa.UniqueConstraint("singleton", name="uq_app_settings_singleton"),
        sa.CheckConstraint("singleton", name="ck_app_settings_singleton"),
        sa.CheckConstraint("week_start BETWEEN 1 AND 7", name="ck_app_settings_week_start_range"),
        sa.CheckConstraint(
            "cardinality(reminder_offsets_min) BETWEEN 1 AND 2", name="ck_app_settings_reminder_offsets_size"
        ),
    )
    # Data migration: the single default row (no personal text; report_email stays NULL until set in the app).
    op.execute(
        "INSERT INTO app_settings (id, singleton, timezone, timezone_confirmed, reminder_offsets_min, week_start) "
        "VALUES (gen_random_uuid(), true, 'UTC', false, '{60,30}', 1)"
    )


def downgrade() -> None:
    op.drop_table("app_settings")
