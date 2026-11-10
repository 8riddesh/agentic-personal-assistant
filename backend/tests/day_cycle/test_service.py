"""DayService + close pipeline (day_cycle spec §11, DAY-AC-01..11) against the test database."""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from datetime import UTC, date, datetime, time, timedelta
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import pytest
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession

from app.modules.core import (
    AppSettingsPatch,
    AppSettingsService,
    FakeClock,
    NotFoundError,
    build_session_factory,
)
from app.modules.day_cycle import CloseMode, DayService
from app.modules.day_cycle.models import DayStateEnum
from app.modules.day_cycle.pipeline import DAY_CLOSE_MAX_ATTEMPTS, is_pending, monday_of
from app.modules.day_cycle.service import DAY_CLOSE_STALE_AFTER_S
from app.modules.tasks import TaskService, local_to_utc
from app.modules.tasks.schemas import Cancelled, Completed
from tests.day_cycle.conftest import (
    CallLog,
    FakeHook,
    FakeReports,
    RecordingScheduler,
    make_task,
    sessions_by_date,
)
from tests.helpers import TEST_DATABASE_URL, requires_db

WED = date(2026, 11, 11)
THU = date(2026, 11, 12)
FRI = date(2026, 11, 13)
SUN = date(2026, 11, 8)
Drain = Callable[[], Awaitable[list[date]]]

BERLIN = ZoneInfo("Europe/Berlin")


def at_local(day: date, hhmm: str) -> str:
    return f"{day.isoformat()}T{hhmm}:00+01:00"


# ------------------------------------------------------------------ pure helpers
def test_week_monday_of() -> None:
    assert monday_of(date(2026, 11, 8)) == date(2026, 11, 2)  # Sunday -> the Monday six days before
    assert monday_of(date(2026, 11, 9)) == date(2026, 11, 9)
    assert monday_of(date(2026, 11, 11)) == date(2026, 11, 9)


def test_local_end_dst() -> None:
    cet = local_to_utc(date(2026, 10, 25), time(23, 59, 59), BERLIN)  # fall-back day, evening is CET (+1)
    cest = local_to_utc(
        date(2026, 3, 29), time(23, 59, 59), BERLIN
    )  # spring-forward day, evening is CEST (+2)
    assert cet == datetime(2026, 10, 25, 22, 59, 59, tzinfo=UTC)
    assert cest == datetime(2026, 3, 29, 21, 59, 59, tzinfo=UTC)


@pytest.mark.parametrize(
    ("state", "weekly_due", "weekly_id", "attempts", "reports_enabled", "expected"),
    [
        (DayStateEnum.OPEN, False, None, 0, True, False),
        (DayStateEnum.CLOSING, False, None, 0, True, True),
        (
            DayStateEnum.CLOSING,
            False,
            None,
            0,
            False,
            True,
        ),  # closing days always have work (missed/predictor)
        (DayStateEnum.CLOSED, False, None, 0, True, False),
        (DayStateEnum.CLOSED, True, None, 0, True, True),  # weekly report still owed
        (DayStateEnum.CLOSED, True, "id", 0, True, False),  # already produced
        (DayStateEnum.CLOSED, True, None, 0, False, False),  # reports module not installed
        (DayStateEnum.CLOSED, True, None, DAY_CLOSE_MAX_ATTEMPTS, True, False),  # gave up
    ],
)
def test_pending_work_predicate(
    state: DayStateEnum,
    weekly_due: bool,
    weekly_id: str | None,
    attempts: int,
    reports_enabled: bool,
    expected: bool,
) -> None:
    row = SimpleNamespace(
        state=state, weekly_due=weekly_due, weekly_report_id=weekly_id, close_attempts=attempts
    )
    assert is_pending(row, reports_enabled=reports_enabled) is expected  # type: ignore[arg-type]


# ------------------------------------------------------------------ opening a day
async def test_current_opens_today_and_materializes(
    days: DayService, tasks: TaskService, wed_clock: FakeClock
) -> None:
    """DAY-AC-01: a recurring task created yesterday appears in today's freshly opened day."""
    wed_clock.set(datetime(2026, 11, 10, 9, 0, tzinfo=UTC))  # Tuesday
    await make_task(
        tasks, is_recurring=True, recurrence={"freq": "daily"}, start_at=at_local(date(2026, 11, 10), "18:00")
    )
    wed_clock.set(datetime(2026, 11, 11, 9, 0, tzinfo=UTC))
    day = await days.current()
    assert (day.local_date, day.state, day.is_today, day.close_mode) == (WED, "open", True, None)
    assert day.summary.total == 1 and day.summary.by_status["planned"] == 1
    assert set(day.summary.by_status) == {
        "planned",
        "completed",
        "postponed",
        "cancelled",
        "cant_do",
        "missed",
    }
    occurrence = (await tasks.day_plan(WED))[0]
    assert occurrence.created_via == "template" and occurrence.template_id is not None


async def test_current_is_idempotent(
    days: DayService, tasks: TaskService, scheduler: RecordingScheduler
) -> None:
    await make_task(tasks, is_recurring=True, recurrence={"freq": "daily"})
    first = await days.current()
    second = await days.current()
    assert first.id == second.id and first.summary == second.summary
    assert scheduler.batches == []  # nothing to run for an open day


async def test_current_autocloses_yesterday_after_midnight(
    days: DayService,
    tasks: TaskService,
    wed_clock: FakeClock,
    db_session: AsyncSession,
    scheduler: RecordingScheduler,
    reports: FakeReports,
    call_log: CallLog,
    drain: Drain,
) -> None:
    """DAY-AC-02 (+ closed_at = local 23:59:59)."""
    day1 = await days.current()
    task = await make_task(tasks, start_at=at_local(WED, "18:00"))
    wed_clock.set(datetime(2026, 11, 11, 23, 5, tzinfo=UTC))  # 00:05 on Thursday in Berlin
    day2 = await days.current()
    assert (day2.local_date, day2.state) == (THU, "open") and day2.id != day1.id
    rows = await sessions_by_date(db_session)
    wed_row = rows[WED]
    assert (wed_row.state, wed_row.close_mode) == (DayStateEnum.CLOSING, CloseMode.AUTO_MIDNIGHT)
    assert wed_row.closed_at == datetime(2026, 11, 11, 22, 59, 59, tzinfo=UTC)  # 23:59:59 Berlin
    assert (await tasks.get(task.id)).status == "missed"
    assert scheduler.batches == [[WED]]
    await drain()
    rows = await sessions_by_date(db_session)
    assert rows[WED].state == DayStateEnum.CLOSED and rows[WED].daily_report_id == reports.ids[("daily", WED)]
    assert call_log.calls == [("predictor", WED), ("daily", WED)]  # Wednesday: no weekly report


async def test_autoclose_several_missed_days(
    days: DayService,
    tasks: TaskService,
    wed_clock: FakeClock,
    db_session: AsyncSession,
    call_log: CallLog,
    reports: FakeReports,
    drain: Drain,
) -> None:
    """DAY-AC-03: stale open session + never-opened dates that hold tasks are closed in date order."""
    await days.current()  # opens Wednesday
    await make_task(tasks, title="for Thursday", local_date=THU.isoformat())  # a day nobody will open
    wed_clock.set(datetime(2026, 11, 14, 9, 0, tzinfo=UTC))  # Saturday, app unused for 3 days
    await days.current()
    rows = await sessions_by_date(db_session)
    assert set(rows) == {WED, THU, date(2026, 11, 14)}  # Friday had no tasks -> no session
    assert rows[THU].auto_created is True and rows[WED].auto_created is False
    assert {d for d, r in rows.items() if r.state == DayStateEnum.CLOSING} == {WED, THU}
    await drain()
    assert call_log.of("daily") == [WED, THU]  # ascending
    rows = await sessions_by_date(db_session)
    assert rows[WED].state == rows[THU].state == DayStateEnum.CLOSED
    assert rows[THU].daily_report_id == reports.ids[("daily", THU)]


async def test_never_opened_empty_date_gets_no_session(
    days: DayService, wed_clock: FakeClock, db_session: AsyncSession
) -> None:
    await days.current()
    wed_clock.set(datetime(2026, 11, 13, 9, 0, tzinfo=UTC))
    await days.current()
    assert set(await sessions_by_date(db_session)) == {WED, FRI}  # Thu/ nothing in between


async def test_straggler_task_after_close_marked_missed(
    days: DayService, tasks: TaskService, wed_clock: FakeClock, drain: Drain
) -> None:
    await days.current()
    await days.close(CloseMode.USER)
    await drain()
    late = await make_task(
        tasks, title="added after closing"
    )  # today is Wednesday and already closed (spec Q7)
    assert (await tasks.get(late.id)).status == "planned"
    wed_clock.set(datetime(2026, 11, 12, 9, 0, tzinfo=UTC))
    await days.current()
    assert (await tasks.get(late.id)).status == "missed"


# ------------------------------------------------------------------ closing
async def test_close_marks_planned_missed_and_returns_closing(
    days: DayService, tasks: TaskService, scheduler: RecordingScheduler, wed_clock: FakeClock
) -> None:
    """DAY-AC-04 (service half)."""
    await make_task(tasks, title="a")
    await make_task(tasks, title="b", start_at=at_local(WED, "18:00"))
    done = await make_task(tasks, title="c", start_at=at_local(WED, "09:00"))
    await tasks.change_status(done.id, _completed(wed_clock))
    result = await days.close(CloseMode.USER)
    assert (result.state, result.missed_count, result.already_closed) == ("closing", 2, False)
    assert (result.daily_report_id, result.weekly_report_id, result.weekly_expected) == (None, None, False)
    assert result.close_mode == CloseMode.USER and result.local_date == WED
    assert scheduler.batches == [[WED]]
    assert (await days.current()).summary.by_status["missed"] == 2


def _completed(clock: FakeClock) -> Completed:
    return Completed(status="completed", finished_at=clock.now_utc() - timedelta(minutes=30))


async def test_close_twice_returns_already_closed(days: DayService, tasks: TaskService, drain: Drain) -> None:
    """DAY-AC-09."""
    await make_task(tasks)
    first = await days.close(CloseMode.USER)
    await drain()
    second = await days.close(CloseMode.USER)
    assert (first.already_closed, second.already_closed) == (False, True)
    assert (second.state, second.missed_count) == ("closed", 0)


async def test_close_while_closing_returns_same_state_and_no_second_transition(
    days: DayService, scheduler: RecordingScheduler
) -> None:
    first = await days.close(CloseMode.USER)
    scheduler.batches.clear()
    second = await days.close(CloseMode.USER)
    assert (second.state, second.missed_count, second.already_closed) == ("closing", 0, False)
    assert second.close_mode == first.close_mode
    assert scheduler.batches == []  # fresh pipeline attempt is not stale yet


async def test_unresolved_lists_planned_and_is_empty_once_closed(
    days: DayService, tasks: TaskService
) -> None:
    """DAY unresolved helper (spec §7.7)."""
    a = await make_task(tasks, title="a")
    await make_task(tasks, title="b", start_at=at_local(WED, "18:00"))
    assert len(await days.unresolved()) == 2
    await tasks.change_status(a.id, _cancel())
    assert len(await days.unresolved()) == 1
    await days.close(CloseMode.USER)
    assert await days.unresolved() == []


def _cancel() -> Cancelled:
    return Cancelled(status="cancelled")


async def test_get_unknown_date_404(days: DayService) -> None:
    with pytest.raises(NotFoundError) as info:
        await days.get(date(2026, 1, 1))
    assert info.value.code == "day.not_found"


async def test_get_returns_today_and_past_days(days: DayService, wed_clock: FakeClock) -> None:
    today = await days.get(WED)
    assert today.is_today is True
    wed_clock.set(datetime(2026, 11, 12, 9, 0, tzinfo=UTC))
    past = await days.get(WED)
    assert past.is_today is False and past.state == "closing"


async def test_tz_change_west_leaves_future_session(
    days: DayService, wed_clock: FakeClock, db_session: AsyncSession, scheduler: RecordingScheduler
) -> None:
    wed_clock.set(datetime(2026, 11, 11, 23, 30, tzinfo=UTC))  # already Thursday in Berlin
    assert (await days.current()).local_date == THU
    app_settings = AppSettingsService(db_session)  # the next request builds fresh (un-memoised) services
    await app_settings.update(AppSettingsPatch(timezone="America/Los_Angeles"))  # Wednesday there
    next_request = DayService(
        db_session, app_settings, wed_clock, TaskService(db_session, app_settings, wed_clock), scheduler
    )
    today = await next_request.current()
    assert today.local_date == WED
    rows = await sessions_by_date(db_session)
    assert rows[THU].state == DayStateEnum.OPEN  # in the future relative to the new timezone: untouched
    assert rows[THU].closed_at is None


# ------------------------------------------------------------------ pipeline
async def test_pipeline_order_predictor_then_daily_then_weekly(
    days: DayService,
    tasks: TaskService,
    wed_clock: FakeClock,
    db_session: AsyncSession,
    reports: FakeReports,
    call_log: CallLog,
    drain: Drain,
) -> None:
    """DAY-AC-04 / DAY-AC-05: on a Sunday the weekly report (period_start = Monday) follows the daily one."""
    wed_clock.set(datetime(2026, 11, 8, 12, 0, tzinfo=UTC))  # Sunday
    await make_task(tasks)
    result = await days.close(CloseMode.USER)
    assert result.weekly_expected is True
    await drain()
    assert call_log.calls == [("predictor", SUN), ("daily", SUN), ("weekly", date(2026, 11, 2))]
    row = (await sessions_by_date(db_session))[SUN]
    assert row.state == DayStateEnum.CLOSED
    assert (row.daily_report_id, row.weekly_report_id) == (
        reports.ids[("daily", SUN)],
        reports.ids[("weekly", date(2026, 11, 2))],
    )
    again = await days.close(CloseMode.USER)
    assert (again.already_closed, again.weekly_report_id) == (True, row.weekly_report_id)


async def test_pipeline_weekly_only_on_sunday(days: DayService, call_log: CallLog, drain: Drain) -> None:
    await days.close(CloseMode.USER)  # Wednesday
    await drain()
    assert [n for n, _ in call_log.calls] == ["predictor", "daily"]


async def test_pipeline_resume_after_crash_skips_done_steps(
    days: DayService,
    reports: FakeReports,
    call_log: CallLog,
    db_session: AsyncSession,
    scheduler: RecordingScheduler,
    wed_clock: FakeClock,
    drain: Drain,
) -> None:
    """DAY-AC-07: the first attempt dies in the report step; the resumed one re-runs only what is missing."""
    await days.close(CloseMode.USER)
    reports.fail_next = 1
    await drain()
    row = (await sessions_by_date(db_session))[WED]
    assert row.state == DayStateEnum.CLOSING and row.close_attempts == 1
    assert row.predictor_done_at is not None and row.daily_report_id is None
    assert row.last_error == "RuntimeError"

    await days.current()  # request right after the crash: the attempt is not stale yet
    assert scheduler.batches == []
    wed_clock.advance(timedelta(seconds=DAY_CLOSE_STALE_AFTER_S + 1))
    await days.current()  # "after 5 min": resumed
    assert scheduler.batches == [[WED]]
    await drain()
    row = (await sessions_by_date(db_session))[WED]
    assert row.state == DayStateEnum.CLOSED and row.daily_report_id is not None
    assert call_log.of("predictor") == [WED]  # not re-run
    assert call_log.of("daily") == [WED, WED]  # failed once, succeeded once


async def test_pipeline_max_attempts_forces_closed(
    days: DayService, reports: FakeReports, db_session: AsyncSession, wed_clock: FakeClock, drain: Drain
) -> None:
    """DAY-AC-08."""
    reports.fail_always = True
    await days.close(CloseMode.USER)
    for _ in range(DAY_CLOSE_MAX_ATTEMPTS):
        await drain()
        wed_clock.advance(timedelta(seconds=DAY_CLOSE_STALE_AFTER_S + 1))
        await days.current()
    row = (await sessions_by_date(db_session))[WED]
    assert row.state == DayStateEnum.CLOSED
    assert (row.close_attempts, row.last_error) == (DAY_CLOSE_MAX_ATTEMPTS, "RuntimeError")
    assert row.daily_report_id is None  # can be regenerated through POST /reports/generate later


async def test_predictor_failure_does_not_block_reports(
    days: DayService, hook: FakeHook, call_log: CallLog, db_session: AsyncSession, drain: Drain
) -> None:
    """DAY-AC-11."""
    hook.fail = True
    await days.close(CloseMode.USER)
    await drain()
    row = (await sessions_by_date(db_session))[WED]
    assert row.state == DayStateEnum.CLOSED and row.daily_report_id is not None
    assert row.last_error == "predictor:RuntimeError"
    assert [n for n, _ in call_log.calls] == ["predictor", "daily"]


async def test_close_without_reports_module_still_closes(
    db_session: AsyncSession,
    tasks: TaskService,
    wed_clock: FakeClock,
    scheduler: RecordingScheduler,
    db_engine: AsyncEngine,
) -> None:
    """M1: no predictor/reports modules yet -> the null ports make those steps no-ops and the day just closes."""
    from app.modules.day_cycle import NullPredictorHook, NullReportGenerator, PipelineDeps, run_pipelines

    service = DayService(db_session, AppSettingsService(db_session), wed_clock, tasks, scheduler)
    await make_task(tasks)
    await service.close(CloseMode.USER)
    await db_session.commit()
    deps = PipelineDeps(
        build_session_factory(db_engine), wed_clock, NullPredictorHook(), NullReportGenerator()
    )
    await run_pipelines(scheduler.take(), deps)
    db_session.expire_all()
    row = (await sessions_by_date(db_session))[WED]
    assert (row.state, row.daily_report_id, row.weekly_report_id) == (DayStateEnum.CLOSED, None, None)
    await service.current()
    assert scheduler.batches == []  # nothing pending: closed days are not rescheduled forever


async def test_weekly_catchup_for_skipped_sunday(
    days: DayService,
    tasks: TaskService,
    wed_clock: FakeClock,
    call_log: CallLog,
    reports: FakeReports,
    drain: Drain,
) -> None:
    """DAY-AC-10: the Sunday of the week was never opened; the next week's first request owes one weekly report."""
    for day in (2, 3, 4):  # Mon..Wed of the week of 2026-11-02, opened one by one
        wed_clock.set(datetime(2026, 11, day, 9, 0, tzinfo=UTC))
        await make_task(tasks, title=f"d{day}")
        await days.current()
    wed_clock.set(datetime(2026, 11, 9, 9, 0, tzinfo=UTC))  # next Monday
    await days.current()
    await drain()
    assert call_log.of("daily") == [date(2026, 11, 2), date(2026, 11, 3), date(2026, 11, 4)]
    assert call_log.of("weekly") == [date(2026, 11, 2)]  # exactly one, for the Mon-Sun week
    await days.current()
    assert await drain() == []  # produced once: nothing pending any more
    assert call_log.of("weekly") == [date(2026, 11, 2)]
    assert len([k for k in reports.ids if k[0] == "weekly"]) == 1


# ------------------------------------------------------------------ concurrency (Postgres only)
@requires_db
async def test_concurrent_close_single_transition(db_engine: AsyncEngine, wed_clock: FakeClock) -> None:
    """DAY-AC-06: the advisory lock makes two simultaneous closes produce exactly one open->closing transition."""
    assert TEST_DATABASE_URL
    factory = build_session_factory(db_engine)
    async with factory() as seed:
        settings_service = AppSettingsService(seed)
        await settings_service.update(AppSettingsPatch(timezone="Europe/Berlin"))
        await make_task(TaskService(seed, settings_service, wed_clock), title="planned")
        await seed.commit()

    async def one_close() -> tuple[int, list[list[date]]]:
        scheduler = RecordingScheduler()
        async with factory() as session:
            app_settings = AppSettingsService(session)
            service = DayService(
                session,
                app_settings,
                wed_clock,
                TaskService(session, app_settings, wed_clock),
                scheduler,
                reports_enabled=True,
            )
            result = await service.close(CloseMode.USER)
            await session.commit()
            return result.missed_count, scheduler.batches

    first, second = await asyncio.gather(one_close(), one_close())
    assert sorted([first[0], second[0]]) == [0, 1]  # only one of them performed the transition
    assert sum(len(batches) for batches in (first[1], second[1])) == 1  # and only one scheduled the pipeline
    async with factory() as session:
        assert list(await sessions_by_date(session)) == [WED]
