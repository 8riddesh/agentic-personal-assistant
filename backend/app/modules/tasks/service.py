"""TaskService: tasks, recurring templates and the status lifecycle (tasks spec §5.1, §7).

Every method flushes but never commits: the request-scoped session (core) commits, so ``day_cycle`` can mark tasks
``missed`` inside its own transaction. All time comes from the injected ``Clock``.
"""

from __future__ import annotations

import asyncio
import re
from datetime import UTC, date, datetime, time, timedelta
from typing import Any
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import Depends
from pydantic import TypeAdapter
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.core import (
    AppSettingsService,
    Clock,
    ConflictError,
    DomainValidationError,
    NotFoundError,
    SessionDep,
    get_app_settings_service,
    get_clock,
    get_logger,
)
from app.modules.tasks.models import (
    ActualEndSourceEnum,
    CheckResponseEnum,
    CreatedViaEnum,
    EventSourceEnum,
    Task,
    TaskStatusEnum,
    TaskTemplate,
)
from app.modules.tasks.repository import StatusEventRepository, TaskRepository, TemplateRepository
from app.modules.tasks.schemas import (
    KNOWN_CATEGORIES,
    Cancelled,
    CantDo,
    CheckDone,
    CheckNotYet,
    CheckResponse,
    Completed,
    CreateTaskRequest,
    CreateTaskResult,
    DailyRecurrence,
    EndTimePredictorPort,
    Postponed,
    PredictionRequest,
    Recurrence,
    StatusChangeResult,
    StatusCommand,
    TaskDTO,
    TaskOutcomeDTO,
    TaskPatch,
    TemplateDTO,
    TemplatePatch,
    WeeklyRecurrence,
)
from app.modules.tasks.state_machine import assert_transition

logger = get_logger("app.tasks")

MAX_FUTURE_DAYS = 365  # TASKS_MAX_FUTURE_DAYS
FINISH_SKEW_S = 120  # TASKS_FINISH_SKEW_S
PREDICT_TIMEOUT_S = 2.0  # predictor port budget (§9)
CHECK_FOLLOWS_MIN_DURATION_MIN = 1
MAX_DURATION_MIN = 1440

_CATEGORY_RE = re.compile(r"^[\w][\w &/+-]*$")
_RECURRENCE_ADAPTER: TypeAdapter[DailyRecurrence | WeeklyRecurrence] = TypeAdapter(Recurrence)


# --------------------------------------------------------------------------- pure helpers
def matches(recurrence: DailyRecurrence | WeeklyRecurrence, d: date) -> bool:
    """``daily`` always matches; ``weekly`` uses Python weekday numbering (0 = Monday)."""
    if isinstance(recurrence, DailyRecurrence):
        return True
    return d.weekday() in recurrence.byweekday


def normalize_category(raw: str) -> str:
    """Strip, collapse whitespace, 1..32 chars; known categories get their canonical spelling (§7.6)."""
    value = " ".join(raw.split())
    if not 1 <= len(value) <= 32 or not _CATEGORY_RE.match(value):
        raise DomainValidationError("category is invalid", code="task.invalid_category")
    for known in KNOWN_CATEGORIES:
        if value.casefold() == known.casefold():
            return known
    return value


def local_to_utc(d: date, t: time, tz: ZoneInfo) -> datetime:
    """Local wall time -> UTC. A non-existent time (spring-forward gap) shifts forward by the gap (02:30 -> 03:30);
    an ambiguous time (fall-back) takes the first occurrence (``fold=0``)."""
    return datetime.combine(d, t, tzinfo=tz).astimezone(UTC)


def resolve_local_date(explicit: date | None, start_at: datetime | None, tz: ZoneInfo, today: date) -> date:
    """§7.5: given -> used; else ``start_at`` local date; else today. Both given must agree."""
    if start_at is not None:
        start_date = start_at.astimezone(tz).date()
        if explicit is not None and explicit != start_date:
            raise DomainValidationError(
                "start_at is not on local_date in the configured timezone",
                code="task.start_not_on_local_date",
            )
        return start_date
    return explicit or today


def parse_recurrence(raw: dict[str, Any]) -> DailyRecurrence | WeeklyRecurrence:
    return _RECURRENCE_ADAPTER.validate_python(raw)


def _enum_value(member: Any) -> Any:
    return None if member is None else member.value


def task_to_dto(task: Task, postponed_from: UUID | None = None) -> TaskDTO:
    return TaskDTO(
        id=task.id,
        local_date=task.local_date,
        template_id=task.template_id,
        origin_template_id=task.origin_template_id,
        is_recurring=task.origin_template_id is not None,
        title=task.title,
        notes=task.notes,
        category=task.category,
        start_at=task.start_at,
        estimate_min=task.estimate_min,
        predicted_end_at=task.predicted_end_at,
        prediction_method=task.prediction_method,
        actual_end_at=task.actual_end_at,
        actual_end_source=_enum_value(task.actual_end_source),
        status=task.status.value,
        status_reason=task.status_reason,
        postponed_to_task_id=task.postponed_to_task_id,
        postponed_from_task_id=postponed_from,
        feasibility_id=task.feasibility_id,
        feasibility_overridden=task.feasibility_overridden,
        created_via=task.created_via.value,
        check_response=_enum_value(task.check_response),
        check_responded_at=task.check_responded_at,
        check_not_yet_at=task.check_not_yet_at,
        check_eta_min=task.check_eta_min,
        created_at=task.created_at,
        updated_at=task.updated_at,
    )


def template_to_dto(template: TaskTemplate) -> TemplateDTO:
    return TemplateDTO(
        id=template.id,
        title=template.title,
        notes=template.notes,
        category=template.category,
        start_local=template.start_local,
        recurrence=parse_recurrence(template.recurrence),
        default_estimate_min=template.default_estimate_min,
        starts_on=template.starts_on,
        active=template.active,
        created_at=template.created_at,
        updated_at=template.updated_at,
    )


class TaskService:
    def __init__(
        self,
        session: AsyncSession,
        settings: AppSettingsService,
        clock: Clock,
        predictor: EndTimePredictorPort | None = None,
    ) -> None:
        self._settings = settings
        self._clock = clock
        self._predictor = predictor
        self._tasks = TaskRepository(session)
        self._templates = TemplateRepository(session)
        self._events = StatusEventRepository(session)
        self._session = session

    # ------------------------------------------------------------------ small internals
    async def _dtos(self, tasks: list[Task]) -> list[TaskDTO]:
        origins = await self._tasks.postponed_from_map(t.id for t in tasks)
        return [task_to_dto(t, origins.get(t.id)) for t in tasks]

    async def _dto(self, task: Task) -> TaskDTO:
        return (await self._dtos([task]))[0]

    async def _get_task(self, task_id: UUID) -> Task:
        task = await self._tasks.get(task_id)
        if task is None:
            raise NotFoundError("Task not found.")
        return task

    async def _get_template(self, template_id: UUID) -> TaskTemplate:
        template = await self._templates.get(template_id)
        if template is None:
            raise NotFoundError("Template not found.")
        return template

    async def _record(
        self,
        task: Task,
        to_status: TaskStatusEnum,
        source: EventSourceEnum,
        *,
        from_status: TaskStatusEnum | None,
        reason: str | None = None,
    ) -> None:
        await self._events.add(
            task_id=task.id,
            from_status=from_status,
            to_status=to_status,
            at=self._clock.now_utc(),
            source=source,
            reason=reason,
        )

    async def _predict(self, task: Task) -> None:
        """Ask the predictor port for an end time. Failure or timeout never blocks the write (P10)."""
        if self._predictor is None:
            return
        request = PredictionRequest(
            title=task.title,
            category=task.category,
            start_at=task.start_at,
            estimate_min=task.estimate_min,
            template_id=task.origin_template_id,
        )
        try:
            result = await asyncio.wait_for(self._predictor.predict_end(request), timeout=PREDICT_TIMEOUT_S)
        except Exception as exc:
            logger.warning(
                "prediction failed", extra={"task_id": str(task.id), "error_type": type(exc).__name__}
            )
            return
        task.predicted_end_at = result.predicted_end_at
        task.prediction_method = result.method
        await self._tasks.flush()

    def _validate_finished_at(self, task: Task, finished_at: datetime, now: datetime, tz: ZoneInfo) -> None:
        if finished_at > now + timedelta(seconds=FINISH_SKEW_S):
            raise DomainValidationError("finished_at is in the future", code="task.finished_in_future")
        if task.start_at is not None:
            if finished_at <= task.start_at:
                raise DomainValidationError(
                    "finished_at must be after the start", code="task.finished_before_start"
                )
            if finished_at - task.start_at > timedelta(hours=24):
                raise DomainValidationError(
                    "finished_at is more than 24 h after the start", code="task.finished_too_late"
                )
        elif finished_at < local_to_utc(task.local_date, time(0, 0), tz):
            raise DomainValidationError(
                "finished_at is before the task's day", code="task.finished_before_day"
            )

    async def today(self) -> date:
        return self._clock.today_local(await self._settings.tz())

    # ------------------------------------------------------------------ reads (public interface)
    async def day_plan(self, local_date: date) -> list[TaskDTO]:
        return await self._dtos(await self._tasks.list_day(local_date))

    async def tasks_in_range(self, start: date, end: date) -> list[TaskDTO]:
        return await self._dtos(await self._tasks.list_range(start, end))

    async def unresolved(self, local_date: date) -> list[TaskDTO]:
        return await self._dtos(await self._tasks.list_day(local_date, status=TaskStatusEnum.PLANNED))

    async def get(self, task_id: UUID) -> TaskDTO:
        return await self._dto(await self._get_task(task_id))

    async def history(
        self, *, template_id: UUID | None = None, category: str | None = None, since: date | None = None
    ) -> list[TaskOutcomeDTO]:
        """Labelled durations (§7.7): completed, timed, real (non-EOD) end, 1..1440 min."""
        tz = await self._settings.tz()
        wanted = category.casefold() if category else None
        outcomes: list[TaskOutcomeDTO] = []
        for task in await self._tasks.completed_timed(since=since, origin_template_id=template_id):
            assert task.start_at is not None and task.actual_end_at is not None
            assert task.actual_end_source is not None
            if wanted is not None and task.category.casefold() != wanted:
                continue
            duration_min = (task.actual_end_at - task.start_at).total_seconds() / 60
            if not CHECK_FOLLOWS_MIN_DURATION_MIN <= duration_min <= MAX_DURATION_MIN:
                continue
            local_start = task.start_at.astimezone(tz)
            outcomes.append(
                TaskOutcomeDTO(
                    task_id=task.id,
                    local_date=task.local_date,
                    template_id=task.origin_template_id,
                    category=task.category,
                    start_at=task.start_at,
                    actual_end_at=task.actual_end_at,
                    duration_min=duration_min,
                    estimate_min=task.estimate_min,
                    predicted_end_at=task.predicted_end_at,
                    prediction_method=task.prediction_method,
                    actual_end_source=task.actual_end_source.value,
                    weekday=task.local_date.weekday(),
                    start_minute_local=local_start.hour * 60 + local_start.minute,
                    check_not_yet=task.check_not_yet_at is not None,
                )
            )
        return outcomes

    # ------------------------------------------------------------------ create
    async def create(self, req: CreateTaskRequest) -> CreateTaskResult:
        if req.overridden and req.assessment_id is None:
            raise DomainValidationError(
                "overridden=true requires an assessment_id", code="task.override_requires_assessment"
            )
        if req.client_request_id is not None:
            replay = await self._replay(req.client_request_id)
            if replay is not None:
                return replay

        tz = await self._settings.tz()
        today = self._clock.today_local(tz)
        category = normalize_category(req.category)
        local_date = resolve_local_date(req.local_date, req.start_at, tz, today)
        if not today <= local_date <= today + timedelta(days=MAX_FUTURE_DAYS):
            raise DomainValidationError(
                "local_date is outside the allowed range", code="task.date_out_of_range"
            )

        template: TaskTemplate | None = None
        if req.is_recurring:
            assert req.recurrence is not None  # guaranteed by TaskDraft validation
            template = TaskTemplate(
                title=req.title,
                notes=req.notes,
                category=category,
                start_local=req.start_at.astimezone(tz).time().replace(tzinfo=None) if req.start_at else None,
                recurrence=req.recurrence.model_dump(mode="json"),
                default_estimate_min=req.estimate_min,
                starts_on=local_date,
                active=True,
            )
        task = Task(
            local_date=local_date,
            title=req.title,
            notes=req.notes,
            category=category,
            start_at=req.start_at,
            estimate_min=req.estimate_min,
            status=TaskStatusEnum.PLANNED,
            feasibility_id=req.assessment_id,
            feasibility_overridden=req.overridden,
            created_via=CreatedViaEnum(req.created_via),
            client_request_id=req.client_request_id,
        )
        try:
            async with self._session.begin_nested():
                if template is not None:
                    await self._templates.add(template)
                    task.template_id = template.id
                    task.origin_template_id = template.id
                await self._tasks.add(task)
        except IntegrityError:
            if req.client_request_id is not None:  # lost a race with a retry of the same request
                replay = await self._replay(req.client_request_id)
                if replay is not None:
                    return replay
            raise DomainValidationError(
                "The referenced assessment does not exist.", code="task.unknown_assessment"
            ) from None

        await self._record(
            task,
            TaskStatusEnum.PLANNED,
            EventSourceEnum.CHAT if req.created_via == "chat" else EventSourceEnum.APP,
            from_status=None,
        )
        await self._predict(task)
        return CreateTaskResult(
            task=await self._dto(task),
            template=template_to_dto(template) if template else None,
            replayed=False,
        )

    async def _replay(self, client_request_id: UUID) -> CreateTaskResult | None:
        existing = await self._tasks.get_by_client_request_id(client_request_id)
        if existing is None:
            return None
        template = (
            await self._templates.get(existing.origin_template_id) if existing.origin_template_id else None
        )
        return CreateTaskResult(
            task=await self._dto(existing),
            template=template_to_dto(template) if template else None,
            replayed=True,
        )

    # ------------------------------------------------------------------ edit
    async def update(self, task_id: UUID, patch: TaskPatch) -> TaskDTO:
        task = await self._get_task(task_id)
        fields = patch.model_fields_set - {"scope"}
        if task.status != TaskStatusEnum.PLANNED and fields - {"notes"}:
            raise ConflictError(
                "Only notes can be edited once a task is no longer planned.", code="task.not_editable"
            )

        tz = await self._settings.tz()
        template: TaskTemplate | None = None
        if patch.scope == "future":
            if task.origin_template_id is None:
                raise DomainValidationError(
                    "This task is not part of a recurring series.", code="task.not_recurring"
                )
            template = await self._get_template(task.origin_template_id)

        repredict = False
        start_changed = False
        if "title" in fields:
            assert patch.title is not None
            task.title = patch.title
            if template:
                template.title = patch.title
        if "notes" in fields:
            task.notes = patch.notes
            if template:
                template.notes = patch.notes
        if "category" in fields:
            assert patch.category is not None
            category = normalize_category(patch.category)
            repredict = repredict or category != task.category
            task.category = category
            if template:
                template.category = category
        if "estimate_min" in fields:
            repredict = repredict or patch.estimate_min != task.estimate_min
            task.estimate_min = patch.estimate_min
            if template:
                template.default_estimate_min = patch.estimate_min
        if "start_at" in fields:
            if patch.start_at is not None and patch.start_at.astimezone(tz).date() != task.local_date:
                raise DomainValidationError(
                    "start_at must stay on the task's local date; use postpone to move it",
                    code="task.start_not_on_local_date",
                )
            start_changed = patch.start_at != task.start_at
            task.start_at = patch.start_at
            if template:
                template.start_local = (
                    patch.start_at.astimezone(tz).time().replace(tzinfo=None) if patch.start_at else None
                )
        if start_changed:  # a new completion check will be scheduled on the device
            task.check_response = None
            task.check_responded_at = None
            task.check_eta_min = None
            task.check_not_yet_at = None
        await self._tasks.flush()
        if repredict or start_changed:
            await self._predict(task)
        return await self._dto(task)

    # ------------------------------------------------------------------ status lifecycle
    async def change_status(self, task_id: UUID, cmd: StatusCommand) -> StatusChangeResult:
        task = await self._get_task(task_id)
        assert_transition(task.status.value, cmd.status)
        source = EventSourceEnum(cmd.source)
        tz = await self._settings.tz()
        now = self._clock.now_utc()
        previous = task.status

        if isinstance(cmd, Completed):
            finished_at = cmd.finished_at or now
            self._validate_finished_at(task, finished_at, now, tz)
            end_source = (
                ActualEndSourceEnum.EOD_RESOLUTION if cmd.source == "eod" else ActualEndSourceEnum.MANUAL
            )
            self._apply_completed(task, finished_at, end_source)
            await self._tasks.flush()
            await self._record(task, TaskStatusEnum.COMPLETED, source, from_status=previous)
            return StatusChangeResult(task=await self._dto(task))

        if isinstance(cmd, Postponed):
            copy = await self._postpone(task, cmd, tz, now, source, previous)
            return StatusChangeResult(task=await self._dto(task), created_task=await self._dto(copy))

        if isinstance(cmd, Cancelled):
            task.status = TaskStatusEnum.CANCELLED
            task.status_reason = cmd.reason
            await self._tasks.flush()
            await self._record(
                task, TaskStatusEnum.CANCELLED, source, from_status=previous, reason=cmd.reason
            )
            return StatusChangeResult(task=await self._dto(task))

        assert isinstance(cmd, CantDo)
        task.status = TaskStatusEnum.CANT_DO
        task.status_reason = cmd.reason
        await self._tasks.flush()
        await self._record(task, TaskStatusEnum.CANT_DO, source, from_status=previous, reason=cmd.reason)
        return StatusChangeResult(task=await self._dto(task))

    @staticmethod
    def _apply_completed(task: Task, finished_at: datetime, end_source: ActualEndSourceEnum) -> None:
        task.status = TaskStatusEnum.COMPLETED
        task.actual_end_at = finished_at
        task.actual_end_source = end_source

    async def _postpone(
        self,
        task: Task,
        cmd: Postponed,
        tz: ZoneInfo,
        now: datetime,
        source: EventSourceEnum,
        previous: TaskStatusEnum,
    ) -> Task:
        """§7.3: resolve the target, create the linked planned copy, mark the original ``postponed``."""
        today = self._clock.today_local(tz)
        if cmd.new_start_at is None and cmd.new_local_date is None:
            raise DomainValidationError(
                "Provide new_start_at or new_local_date", code="task.postpone_target_missing"
            )
        if cmd.new_start_at is not None:
            target_date = cmd.new_start_at.astimezone(tz).date()
            if cmd.new_local_date is not None and cmd.new_local_date != target_date:
                raise DomainValidationError(
                    "new_local_date does not match new_start_at", code="task.postpone_date_mismatch"
                )
            if cmd.new_start_at <= now:
                raise DomainValidationError(
                    "new_start_at must be in the future", code="task.postpone_in_past"
                )
            new_start: datetime | None = cmd.new_start_at
        else:
            assert cmd.new_local_date is not None
            target_date = cmd.new_local_date
            new_start = None  # anytime copy
        if not today <= target_date <= today + timedelta(days=MAX_FUTURE_DAYS):
            raise DomainValidationError(
                "The new date is outside the allowed range", code="task.date_out_of_range"
            )
        if target_date == task.local_date and new_start == task.start_at:
            raise DomainValidationError("The new time equals the current one", code="task.postpone_noop")

        copy = Task(
            local_date=target_date,
            template_id=None,  # so the series' unique (local_date, template_id) never collides
            origin_template_id=task.origin_template_id,
            title=task.title,
            notes=task.notes,
            category=task.category,
            start_at=new_start,
            estimate_min=task.estimate_min,
            status=TaskStatusEnum.PLANNED,
            feasibility_overridden=False,
            created_via=task.created_via,
        )
        await self._tasks.add(copy)
        task.status = TaskStatusEnum.POSTPONED
        task.postponed_to_task_id = copy.id
        await self._tasks.flush()
        await self._record(task, TaskStatusEnum.POSTPONED, source, from_status=previous)
        await self._record(copy, TaskStatusEnum.PLANNED, source, from_status=None)
        await self._predict(copy)
        return copy

    async def check_response(self, task_id: UUID, cmd: CheckResponse) -> TaskDTO:
        """Completion-check answer from the device (§7.2). The server never schedules anything."""
        task = await self._get_task(task_id)
        if task.start_at is None:
            raise ConflictError("Tasks without a start time have no completion check.", code="task.no_check")
        now = self._clock.now_utc()
        tz = await self._settings.tz()

        if isinstance(cmd, CheckDone):
            responded_at = cmd.responded_at or now
            if task.status in (TaskStatusEnum.PLANNED, TaskStatusEnum.MISSED):
                previous = task.status
                self._validate_finished_at(task, cmd.finished_at, now, tz)
                self._apply_completed(task, cmd.finished_at, ActualEndSourceEnum.NOTIFICATION_ACTION)
                task.check_response = CheckResponseEnum.DONE
                task.check_responded_at = responded_at
                await self._tasks.flush()
                await self._record(
                    task, TaskStatusEnum.COMPLETED, EventSourceEnum.NOTIFICATION, from_status=previous
                )
            elif task.status == TaskStatusEnum.COMPLETED:
                if (
                    task.check_response != CheckResponseEnum.DONE
                ):  # completed via another path: only record the answer
                    task.check_response = CheckResponseEnum.DONE
                    task.check_responded_at = responded_at
                    await self._tasks.flush()
            else:
                raise ConflictError(
                    f"{task.status.value} -> completed is not allowed", code="task.invalid_transition"
                )
            return await self._dto(task)

        assert isinstance(cmd, CheckNotYet)
        if task.status != TaskStatusEnum.PLANNED:
            raise ConflictError(
                f"A {task.status.value} task cannot answer not-yet", code="task.invalid_transition"
            )
        if task.check_response == CheckResponseEnum.NOT_YET and task.check_eta_min == cmd.eta_min:
            return await self._dto(task)  # identical replay
        responded_at = cmd.responded_at or now
        task.check_response = CheckResponseEnum.NOT_YET
        task.check_responded_at = responded_at
        task.check_eta_min = cmd.eta_min
        if task.check_not_yet_at is None:
            task.check_not_yet_at = responded_at
        await self._tasks.flush()
        return await self._dto(task)

    # ------------------------------------------------------------------ day cycle hooks
    async def materialize_templates(self, local_date: date) -> int:
        """Create one occurrence per active template that matches ``local_date``. Idempotent (§7.4)."""
        tz = await self._settings.tz()
        inserted = 0
        for template in await self._templates.active_started_by(local_date):
            if not matches(parse_recurrence(template.recurrence), local_date):
                continue
            if await self._tasks.occurrence_exists(local_date, template.id):
                continue  # whatever its status: cancelled/postponed occurrences are never recreated
            occurrence = Task(
                local_date=local_date,
                template_id=template.id,
                origin_template_id=template.id,
                title=template.title,
                notes=template.notes,
                category=template.category,
                start_at=local_to_utc(local_date, template.start_local, tz) if template.start_local else None,
                estimate_min=template.default_estimate_min,
                status=TaskStatusEnum.PLANNED,
                created_via=CreatedViaEnum.TEMPLATE,
            )
            if not await self._tasks.add_nested(occurrence):
                continue  # a concurrent materialization won
            await self._record(occurrence, TaskStatusEnum.PLANNED, EventSourceEnum.SYSTEM, from_status=None)
            await self._predict(occurrence)
            inserted += 1
        return inserted

    async def mark_unresolved_missed(self, local_date: date) -> int:
        """``planned`` -> ``missed`` for the day, one system event per row. Idempotent (a second call returns 0)."""
        tasks = await self._tasks.list_day(local_date, status=TaskStatusEnum.PLANNED)
        for task in tasks:
            task.status = TaskStatusEnum.MISSED
            await self._tasks.flush()
            await self._record(
                task, TaskStatusEnum.MISSED, EventSourceEnum.SYSTEM, from_status=TaskStatusEnum.PLANNED
            )
        return len(tasks)

    # ------------------------------------------------------------------ templates
    async def list_templates(self, active: bool | None) -> list[TemplateDTO]:
        return [template_to_dto(t) for t in await self._templates.list_all(active)]

    async def get_template(self, template_id: UUID) -> TemplateDTO:
        return template_to_dto(await self._get_template(template_id))

    async def update_template(self, template_id: UUID, patch: TemplatePatch) -> TemplateDTO:
        """Affects only dates that are not materialized yet; existing occurrences are never rewritten (§7.9)."""
        template = await self._get_template(template_id)
        fields = patch.model_fields_set
        if "title" in fields:
            assert patch.title is not None
            template.title = patch.title
        if "notes" in fields:
            template.notes = patch.notes
        if "category" in fields:
            assert patch.category is not None
            template.category = normalize_category(patch.category)
        if "start_local" in fields:
            template.start_local = patch.start_local
        if "recurrence" in fields:
            assert patch.recurrence is not None
            template.recurrence = patch.recurrence.model_dump(mode="json")
        if "default_estimate_min" in fields:
            template.default_estimate_min = patch.default_estimate_min
        if "active" in fields:
            assert patch.active is not None
            template.active = patch.active
        await self._templates.flush()
        return template_to_dto(template)

    async def deactivate_template(self, template_id: UUID, cancel_planned: bool) -> None:
        """Soft delete (rows are never removed: FKs from tasks, P9). Repeating the call is a no-op."""
        template = await self._get_template(template_id)
        template.active = False
        if cancel_planned:
            today = await self.today()
            for task in await self._tasks.planned_from_series(template.id, from_date=today):
                task.status = TaskStatusEnum.CANCELLED
                await self._tasks.flush()
                await self._record(
                    task, TaskStatusEnum.CANCELLED, EventSourceEnum.APP, from_status=TaskStatusEnum.PLANNED
                )
        await self._templates.flush()


def get_end_time_predictor() -> EndTimePredictorPort | None:
    """Overridden by ``app.main`` once ``predictor`` exists (M3); until then predictions stay empty."""
    return None


def get_task_service(
    session: SessionDep,
    clock: Clock = Depends(get_clock),
    settings: AppSettingsService = Depends(get_app_settings_service),
    predictor: EndTimePredictorPort | None = Depends(get_end_time_predictor),
) -> TaskService:
    return TaskService(session, settings, clock, predictor)
