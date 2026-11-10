"""day_cycle fixtures (spec §11): real TaskService, recording scheduler, fake predictor hook and report generator."""

from __future__ import annotations

from collections.abc import Callable
from datetime import UTC, date, datetime
from uuid import UUID, uuid4

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession

from app.modules.core import AppSettingsPatch, AppSettingsService, FakeClock, build_session_factory
from app.modules.day_cycle import DayService, PipelineDeps, run_pipelines
from app.modules.day_cycle.models import DaySession
from app.modules.tasks import TaskDTO, TaskService
from app.modules.tasks.schemas import CreateTaskRequest

WED = datetime(2026, 11, 11, 9, 0, tzinfo=UTC)  # a Wednesday: 10:00 in Berlin


class CallLog:
    """One shared, ordered log so tests can assert the pipeline order (predictor -> daily -> weekly)."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, date]] = []

    def of(self, name: str) -> list[date]:
        return [d for n, d in self.calls if n == name]


class FakeHook:
    def __init__(self, log: CallLog, *, fail: bool = False) -> None:
        self._log = log
        self.fail = fail

    async def on_day_closed(self, local_date: date) -> None:
        self._log.calls.append(("predictor", local_date))
        if self.fail:
            raise RuntimeError("retrain failed")


class FakeReports:
    enabled = True

    def __init__(self, log: CallLog) -> None:
        self._log = log
        self.fail_always = False
        self.fail_next = 0  # fail this many upcoming calls, then succeed
        self.ids: dict[tuple[str, date], UUID] = {}

    async def generate(self, kind: str, period_start: date) -> UUID:
        self._log.calls.append((kind, period_start))
        if self.fail_always or self.fail_next > 0:
            self.fail_next = max(0, self.fail_next - 1)
            raise RuntimeError("report generation failed")
        return self.ids.setdefault((kind, period_start), uuid4())


class RecordingScheduler:
    def __init__(self) -> None:
        self.batches: list[list[date]] = []

    def schedule(self, dates: list[date]) -> None:
        self.batches.append(list(dates))

    def take(self) -> list[date]:
        dates = sorted({d for batch in self.batches for d in batch})
        self.batches.clear()
        return dates


@pytest.fixture
def call_log() -> CallLog:
    return CallLog()


@pytest.fixture
def hook(call_log: CallLog) -> FakeHook:
    return FakeHook(call_log)


@pytest.fixture
def reports(call_log: CallLog) -> FakeReports:
    return FakeReports(call_log)


@pytest.fixture
def scheduler() -> RecordingScheduler:
    return RecordingScheduler()


@pytest.fixture
def wed_clock(fake_clock: FakeClock) -> FakeClock:
    fake_clock.set(WED)
    return fake_clock


@pytest.fixture
async def tz_berlin(db_session: AsyncSession) -> None:
    await AppSettingsService(db_session).update(AppSettingsPatch(timezone="Europe/Berlin"))


@pytest.fixture
async def tasks(db_session: AsyncSession, wed_clock: FakeClock, tz_berlin: None) -> TaskService:
    return TaskService(db_session, AppSettingsService(db_session), wed_clock)


@pytest.fixture
async def days(
    db_session: AsyncSession,
    wed_clock: FakeClock,
    tasks: TaskService,
    scheduler: RecordingScheduler,
    reports: FakeReports,
) -> DayService:
    return DayService(
        db_session,
        AppSettingsService(db_session),
        wed_clock,
        tasks,
        scheduler,
        reports_enabled=reports.enabled,
    )


@pytest.fixture
def deps(db_engine: AsyncEngine, wed_clock: FakeClock, hook: FakeHook, reports: FakeReports) -> PipelineDeps:
    return PipelineDeps(
        session_factory=build_session_factory(db_engine),
        clock=wed_clock,
        predictor_hook=hook,
        reports=reports,
    )


@pytest.fixture
def drain(
    db_session: AsyncSession, scheduler: RecordingScheduler, deps: PipelineDeps
) -> Callable[[], object]:
    """Commit the test session, run every scheduled pipeline (as BackgroundTasks would), refresh the session."""

    async def _drain() -> list[date]:
        await db_session.commit()
        dates = scheduler.take()
        await run_pipelines(dates, deps)
        db_session.expire_all()
        return dates

    return _drain


async def make_task(tasks: TaskService, **overrides: object) -> TaskDTO:
    values: dict[str, object] = {"title": "Task", "category": "work", "is_recurring": False}
    values.update(overrides)
    return (await tasks.create(CreateTaskRequest.model_validate(values))).task


async def sessions_by_date(session: AsyncSession) -> dict[date, DaySession]:
    session.expire_all()
    rows = (await session.execute(select(DaySession))).scalars().all()
    return {r.local_date: r for r in rows}
