"""FastAPI wiring for day_cycle: service provider, background scheduler, ``ensure_current_day`` (spec §7.6)."""

from __future__ import annotations

from datetime import date, datetime
from zoneinfo import ZoneInfo

from fastapi import BackgroundTasks, Depends, Request

from app.modules.core import AppSettingsService, Clock, SessionDep, get_app_settings_service, get_clock
from app.modules.day_cycle.pipeline import PipelineDeps, run_pipelines
from app.modules.day_cycle.service import DayService
from app.modules.tasks import TaskService, get_task_service

DAY_ENSURE_MEMO_S = 60  # fast-path memo window for ensure_current_day

type DayMemo = tuple[ZoneInfo, date, datetime]  # (timezone, local today, when it was checked)


class BackgroundPipelineScheduler:
    """``PipelineScheduler`` backed by FastAPI ``BackgroundTasks``: runs after the response (and its commit)."""

    def __init__(self, background_tasks: BackgroundTasks, deps: PipelineDeps) -> None:
        self._background_tasks = background_tasks
        self._deps = deps

    def schedule(self, dates: list[date]) -> None:
        self._background_tasks.add_task(run_pipelines, list(dates), self._deps)


def get_pipeline_deps(request: Request) -> PipelineDeps:
    deps: PipelineDeps = request.app.state.pipeline_deps  # built by the lifespan in app.main
    return deps


def get_day_service(
    background_tasks: BackgroundTasks,
    session: SessionDep,
    clock: Clock = Depends(get_clock),
    app_settings: AppSettingsService = Depends(get_app_settings_service),
    tasks: TaskService = Depends(get_task_service),
    deps: PipelineDeps = Depends(get_pipeline_deps),
) -> DayService:
    return DayService(
        session,
        app_settings,
        clock,
        tasks,
        BackgroundPipelineScheduler(background_tasks, deps),
        reports_enabled=deps.reports.enabled,
    )


def remember_checked(request: Request, service: DayService, clock: Clock) -> None:
    """Refresh the process-local memo after any full ``current()``-style sync."""
    sync = service.last_sync
    if sync is not None:
        request.app.state.day_memo = (sync.tz, sync.today, clock.now_utc())


async def ensure_current_day(
    request: Request,
    service: DayService = Depends(get_day_service),
    clock: Clock = Depends(get_clock),
) -> None:
    """Lazy midnight close for every day-scoped router (tasks, feasibility, assistant).

    Fast path: a process-local memo ``(tz, today, checked_at)``; while the local date is unchanged and the memo is
    fresh, no DB work is done here. ``get_day_service`` itself is cheap (it only builds objects)."""
    memo: DayMemo | None = getattr(request.app.state, "day_memo", None)
    now = clock.now_utc()
    if memo is not None:
        tz, today, checked_at = memo
        if clock.today_local(tz) == today and (now - checked_at).total_seconds() < DAY_ENSURE_MEMO_S:
            return
    await service.current()
    remember_checked(request, service, clock)
