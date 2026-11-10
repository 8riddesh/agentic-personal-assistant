"""tasks: create task_template, task, task_status_event

No FK on task.feasibility_id: the M2 feasibility migration adds ``fk_task_feasibility_id_feasibility_assessment``.

Revision ID: c3e5a7b90003
Revises: b2d4f6a80002
Create Date: 2026-11-09 10:20:00
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "c3e5a7b90003"
down_revision: str | None = "b2d4f6a80002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

STATUSES = ["planned", "completed", "postponed", "cancelled", "cant_do", "missed"]
END_SOURCES = ["notification_action", "manual", "eod_resolution"]
CREATED_VIA = ["form", "chat", "template"]
CHECK_RESPONSES = ["done", "not_yet"]
EVENT_SOURCES = ["app", "notification", "chat", "eod", "system"]


def _enum(values: list[str], constraint: str) -> sa.Enum:
    """varchar(32) + CHECK, named like core's ``enum_type`` helper under the naming convention."""
    return sa.Enum(*values, name=constraint, native_enum=False, create_constraint=True, length=32)


def _ts(name: str, *, nullable: bool = False, default: bool = False) -> sa.Column:  # type: ignore[type-arg]
    kwargs = {"server_default": sa.func.now()} if default else {}
    return sa.Column(name, sa.DateTime(timezone=True), nullable=nullable, **kwargs)


def upgrade() -> None:
    op.create_table(
        "task_template",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("title", sa.Text(), nullable=False),  # encrypted
        sa.Column("notes", sa.Text(), nullable=True),  # encrypted
        sa.Column("category", sa.String(length=32), nullable=False),
        sa.Column("start_local", sa.Time(), nullable=True),
        sa.Column("recurrence", postgresql.JSONB(), nullable=False),
        sa.Column("default_estimate_min", sa.Integer(), nullable=True),
        sa.Column("starts_on", sa.Date(), nullable=False),
        sa.Column("active", sa.Boolean(), server_default=sa.text("true"), nullable=False),
        _ts("created_at", default=True),
        _ts("updated_at", default=True),
        sa.PrimaryKeyConstraint("id", name="pk_task_template"),
        sa.CheckConstraint(
            "default_estimate_min IS NULL OR default_estimate_min BETWEEN 1 AND 720",
            name="ck_task_template_estimate_range",
        ),
        sa.CheckConstraint("recurrence->>'freq' IN ('daily','weekly')", name="ck_task_template_recurrence_freq"),
    )
    op.create_index("ix_task_template_active", "task_template", ["active"])

    op.create_table(
        "task",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("local_date", sa.Date(), nullable=False),
        sa.Column("template_id", sa.Uuid(), nullable=True),
        sa.Column("origin_template_id", sa.Uuid(), nullable=True),
        sa.Column("title", sa.Text(), nullable=False),  # encrypted
        sa.Column("notes", sa.Text(), nullable=True),  # encrypted
        sa.Column("category", sa.String(length=32), nullable=False),
        _ts("start_at", nullable=True),
        sa.Column("estimate_min", sa.Integer(), nullable=True),
        _ts("predicted_end_at", nullable=True),
        sa.Column("prediction_method", sa.String(length=64), nullable=True),
        _ts("actual_end_at", nullable=True),
        sa.Column("actual_end_source", _enum(END_SOURCES, "ck_task_task_actual_end_source"), nullable=True),
        sa.Column(
            "status", _enum(STATUSES, "ck_task_task_status"), server_default="planned", nullable=False
        ),
        sa.Column("status_reason", sa.Text(), nullable=True),  # encrypted
        sa.Column("postponed_to_task_id", sa.Uuid(), nullable=True),
        sa.Column("feasibility_id", sa.Uuid(), nullable=True),
        sa.Column("feasibility_overridden", sa.Boolean(), server_default=sa.text("false"), nullable=False),
        sa.Column("created_via", _enum(CREATED_VIA, "ck_task_task_created_via"), nullable=False),
        sa.Column("check_response", _enum(CHECK_RESPONSES, "ck_task_task_check_response"), nullable=True),
        _ts("check_responded_at", nullable=True),
        _ts("check_not_yet_at", nullable=True),
        sa.Column("check_eta_min", sa.SmallInteger(), nullable=True),
        sa.Column("client_request_id", sa.Uuid(), nullable=True),
        _ts("created_at", default=True),
        _ts("updated_at", default=True),
        sa.PrimaryKeyConstraint("id", name="pk_task"),
        sa.ForeignKeyConstraint(
            ["template_id"], ["task_template.id"], name="fk_task_template_id_task_template", ondelete="RESTRICT"
        ),
        sa.ForeignKeyConstraint(
            ["origin_template_id"],
            ["task_template.id"],
            name="fk_task_origin_template_id_task_template",
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(["postponed_to_task_id"], ["task.id"], name="fk_task_postponed_to_task_id_task"),
        sa.CheckConstraint("estimate_min IS NULL OR estimate_min BETWEEN 1 AND 720", name="ck_task_estimate_range"),
        sa.CheckConstraint(
            "status <> 'completed' OR (actual_end_at IS NOT NULL AND actual_end_source IS NOT NULL)",
            name="ck_task_completed_has_end",
        ),
        sa.CheckConstraint(
            "status <> 'postponed' OR postponed_to_task_id IS NOT NULL", name="ck_task_postponed_has_target"
        ),
        sa.CheckConstraint("status <> 'cant_do' OR status_reason IS NOT NULL", name="ck_task_cant_do_has_reason"),
        sa.CheckConstraint(
            "feasibility_overridden = false OR feasibility_id IS NOT NULL", name="ck_task_override_has_assessment"
        ),
    )
    op.create_index(
        "uq_task_local_date_template",
        "task",
        ["local_date", "template_id"],
        unique=True,
        postgresql_where=sa.text("template_id IS NOT NULL"),
    )
    op.create_index(
        "uq_task_client_request_id",
        "task",
        ["client_request_id"],
        unique=True,
        postgresql_where=sa.text("client_request_id IS NOT NULL"),
    )
    op.create_index("ix_task_local_date", "task", ["local_date"])
    op.create_index("ix_task_status_local_date", "task", ["status", "local_date"])
    op.create_index(
        "ix_task_origin_template",
        "task",
        ["origin_template_id"],
        postgresql_where=sa.text("origin_template_id IS NOT NULL"),
    )

    op.create_table(
        "task_status_event",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("task_id", sa.Uuid(), nullable=False),
        sa.Column("from_status", _enum(STATUSES, "ck_task_status_event_task_status_event_from_status"), nullable=True),
        sa.Column("to_status", _enum(STATUSES, "ck_task_status_event_task_status_event_to_status"), nullable=False),
        _ts("at"),
        sa.Column("source", _enum(EVENT_SOURCES, "ck_task_status_event_task_status_event_source"), nullable=False),
        sa.Column("reason", sa.Text(), nullable=True),  # encrypted
        _ts("created_at", default=True),
        _ts("updated_at", default=True),
        sa.PrimaryKeyConstraint("id", name="pk_task_status_event"),
        sa.ForeignKeyConstraint(["task_id"], ["task.id"], name="fk_task_status_event_task_id_task"),
    )
    op.create_index("ix_task_status_event_task", "task_status_event", ["task_id", "at"])


def downgrade() -> None:
    op.drop_index("ix_task_status_event_task", table_name="task_status_event")
    op.drop_table("task_status_event")
    for index in (
        "ix_task_origin_template",
        "ix_task_status_local_date",
        "ix_task_local_date",
        "uq_task_client_request_id",
        "uq_task_local_date_template",
    ):
        op.drop_index(index, table_name="task")
    op.drop_table("task")
    op.drop_index("ix_task_template_active", table_name="task_template")
    op.drop_table("task_template")
