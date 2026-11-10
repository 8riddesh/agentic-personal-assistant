"""Tasks persistence (private to the module). Repositories flush but never commit."""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from datetime import date, datetime
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.tasks.models import (
    ActualEndSourceEnum,
    EventSourceEnum,
    Task,
    TaskStatusEnum,
    TaskStatusEvent,
    TaskTemplate,
)

_DAY_ORDER = (Task.start_at.asc().nulls_last(), Task.created_at.asc(), Task.id.asc())


class TaskRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get(self, task_id: UUID) -> Task | None:
        return await self._session.get(Task, task_id)

    async def get_by_client_request_id(self, client_request_id: UUID) -> Task | None:
        stmt = select(Task).where(Task.client_request_id == client_request_id)
        return (await self._session.execute(stmt)).scalar_one_or_none()

    async def add(self, task: Task) -> None:
        self._session.add(task)
        await self._session.flush()

    async def add_nested(self, task: Task) -> bool:
        """Insert inside a savepoint; ``False`` when a unique constraint rejected it (e.g. an existing occurrence)."""
        try:
            async with self._session.begin_nested():
                self._session.add(task)
                await self._session.flush()
        except IntegrityError:
            return False
        return True

    async def flush(self) -> None:
        await self._session.flush()

    async def list_day(self, local_date: date, *, status: TaskStatusEnum | None = None) -> list[Task]:
        stmt = select(Task).where(Task.local_date == local_date)
        if status is not None:
            stmt = stmt.where(Task.status == status)
        return list((await self._session.execute(stmt.order_by(*_DAY_ORDER))).scalars())

    async def list_range(self, start: date, end: date) -> list[Task]:
        stmt = select(Task).where(Task.local_date >= start, Task.local_date <= end)
        return list(
            (await self._session.execute(stmt.order_by(Task.local_date.asc(), *_DAY_ORDER))).scalars()
        )

    async def occurrence_exists(self, local_date: date, template_id: UUID) -> bool:
        stmt = select(Task.id).where(Task.local_date == local_date, Task.template_id == template_id).limit(1)
        return (await self._session.execute(stmt)).first() is not None

    async def postponed_from_map(self, task_ids: Iterable[UUID]) -> dict[UUID, UUID]:
        """``copy_id -> original_id`` for the given (copy) task ids: the reverse of ``postponed_to_task_id``."""
        ids = list(task_ids)
        if not ids:
            return {}
        stmt = select(Task.id, Task.postponed_to_task_id).where(Task.postponed_to_task_id.in_(ids))
        return {
            copy_id: original_id
            for original_id, copy_id in (await self._session.execute(stmt)).all()
            if copy_id
        }

    async def completed_timed(self, *, since: date | None, origin_template_id: UUID | None) -> list[Task]:
        """Candidates for labelled durations (§7.7); remaining rules are applied by the service."""
        stmt = select(Task).where(
            Task.status == TaskStatusEnum.COMPLETED,
            Task.start_at.is_not(None),
            Task.actual_end_at.is_not(None),
            Task.actual_end_source.in_([ActualEndSourceEnum.NOTIFICATION_ACTION, ActualEndSourceEnum.MANUAL]),
        )
        if since is not None:
            stmt = stmt.where(Task.local_date >= since)
        if origin_template_id is not None:
            stmt = stmt.where(Task.origin_template_id == origin_template_id)
        return list((await self._session.execute(stmt.order_by(Task.actual_end_at.asc()))).scalars())

    async def planned_from_series(self, origin_template_id: UUID, *, from_date: date) -> list[Task]:
        stmt = select(Task).where(
            Task.origin_template_id == origin_template_id,
            Task.local_date >= from_date,
            Task.status == TaskStatusEnum.PLANNED,
        )
        return list((await self._session.execute(stmt.order_by(Task.local_date.asc()))).scalars())


class TemplateRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get(self, template_id: UUID) -> TaskTemplate | None:
        return await self._session.get(TaskTemplate, template_id)

    async def add(self, template: TaskTemplate) -> None:
        self._session.add(template)
        await self._session.flush()

    async def list_all(self, active: bool | None) -> list[TaskTemplate]:
        stmt = select(TaskTemplate)
        if active is not None:
            stmt = stmt.where(TaskTemplate.active == active)
        return list((await self._session.execute(stmt.order_by(TaskTemplate.created_at.asc()))).scalars())

    async def active_started_by(self, local_date: date) -> list[TaskTemplate]:
        stmt = select(TaskTemplate).where(TaskTemplate.active.is_(True), TaskTemplate.starts_on <= local_date)
        return list((await self._session.execute(stmt.order_by(TaskTemplate.created_at.asc()))).scalars())

    async def flush(self) -> None:
        await self._session.flush()


class StatusEventRepository:
    """Insert + select only: the audit trail is append-only (no update/delete API on purpose)."""

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def add(
        self,
        *,
        task_id: UUID,
        from_status: TaskStatusEnum | None,
        to_status: TaskStatusEnum,
        at: datetime,
        source: EventSourceEnum,
        reason: str | None = None,
    ) -> TaskStatusEvent:
        event = TaskStatusEvent(
            task_id=task_id, from_status=from_status, to_status=to_status, at=at, source=source, reason=reason
        )
        self._session.add(event)
        await self._session.flush()
        return event

    async def for_task(self, task_id: UUID) -> Sequence[TaskStatusEvent]:
        stmt = (
            select(TaskStatusEvent)
            .where(TaskStatusEvent.task_id == task_id)
            .order_by(TaskStatusEvent.at.asc(), TaskStatusEvent.created_at.asc())
        )
        return (await self._session.execute(stmt)).scalars().all()
