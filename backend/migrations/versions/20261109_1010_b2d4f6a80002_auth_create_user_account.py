"""auth: create user_account

The single owner row is seeded at app startup from OWNER_EMAIL / OWNER_PASSWORD_HASH, never in a migration,
so no credential ever lives in the repository.

Revision ID: b2d4f6a80002
Revises: a1c3e5f70001
Create Date: 2026-11-09 10:10:00
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "b2d4f6a80002"
down_revision: str | None = "a1c3e5f70001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "user_account",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("singleton", sa.Boolean(), server_default=sa.text("true"), nullable=False),
        sa.Column("email", sa.String(), nullable=False),
        sa.Column("password_hash", sa.String(), nullable=False),
        sa.Column("token_version", sa.Integer(), server_default=sa.text("1"), nullable=False),
        sa.Column("last_login_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("id", name="pk_user_account"),
        sa.UniqueConstraint("singleton", name="uq_user_account_singleton"),
        sa.UniqueConstraint("email", name="uq_user_account_email"),
        sa.CheckConstraint("singleton", name="ck_user_account_singleton"),
        sa.CheckConstraint("token_version >= 1", name="ck_user_account_token_version_positive"),
    )


def downgrade() -> None:
    op.drop_table("user_account")
