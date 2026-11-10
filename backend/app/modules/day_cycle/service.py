"""DayService: open today, user-declared End of Day, lazy midnight auto-close (day_cycle spec §5, §7).

The server may be asleep at midnight (plan §8.3), so every transition is applied lazily by the first day-scoped
request after local midnight (``_sync``). Everything here runs in the request transaction; the close *pipeline*
(predictor hook, reports) runs afterwards in the background (``pipeline.py``).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.core import AppSettingsService, Clock, NotFoundError
from app.modules.day_cycle.models import DaySession, DayStateEnum
from app.modules.day_cycle.pipeline import PipelineScheduler, is_pending, running_dates
from app.modules.day_cycle.repository import DaySessionRepository
from app.modules.day_cycle.schemas import CloseMode, CloseResultDTO, DayDTO, DaySummary
from app.modules.tasks import TaskDTO, TaskService, local_to_utc

DAY_CATCHUP_MAX_DAYS = 14  # look-back window for never-opened dates, stragglers, weekly catch-up
DAY_CLOSE_STALE_AFTER_S = 300  # a `closing` session older than this is resumed


@dataclass
class SyncResult:
    tz: ZoneInfo
    today: date
    now: datetime
    today_row: DaySession
    newly_closing: set[date] = field(default_factory=set)


class DayService:
    def __init__(
        self,
        session: AsyncSession,
        settings: AppSettingsService,
        clock: Clock,
        tasks: TaskService,
        scheduler: PipelineScheduler,
        *,
        reports_enabled: bool = False,
    ) -> None:
        self._repo = DaySessionRepository(session)
        self._settings = settings
        self._clock = clock
        self._tasks = tasks
        self._scheduler = scheduler
        self._reports_enabled = reports_enabled
        self.last_sync: SyncResult | None = None

    # ------------------------------------------------------------------ public interface
    async def current(self) -> DayDTO:
        """Auto-close stale day(s), open today, materialize today's recurring tasks (§7.3)."""
        sync = await self._sync_and_schedule()
        return await self._dto(sync.today_row, sync.today)

    async def get(self, local_date: date) -> DayDTO:
        sync = await self._sync_and_schedule()
        row = sync.today_row if local_date == sync.today else await self._repo.get_by_date(local_date)
        if row is None:
            raise NotFoundError("No day session exists for that date.", code="day.not_found")
        return await self._dto(row, sync.today)

    async def unresolved(self) -> list[TaskDTO]:
        """Tasks still ``planned`` today (the EOD resolution sheet); empty once today is closing/closed."""
        sync = await self._sync_and_schedule()
        if sync.today_row.state != DayStateEnum.OPEN:
            return []
        return await self._tasks.unresolved(sync.today)

    async def close(self, mode: CloseMode) -> CloseResultDTO:
        """Close TODAY (§7.4). Closing with unresolved tasks is allowed: they become ``missed``."""
        sync = await self._sync()
        row = sync.today_row
        missed = 0
        if row.state == DayStateEnum.OPEN:
            closed_at = sync.now if mode == CloseMode.USER else self._local_end(sync.today, sync.tz)
            missed = await self._begin_close(row, mode, closed_at, sync.now)
            sync.newly_closing.add(sync.today)
        self._schedule_pending(await self._pending_dates(sync))
        assert row.close_mode is not None  # `closing`/`closed` always carry a close mode (CHECK constraint)
        return CloseResultDTO(
            local_date=row.local_date,
            state=row.state.value,
            close_mode=row.close_mode,
            missed_count=missed,
            daily_report_id=row.daily_report_id,
            weekly_report_id=row.weekly_report_id,
            weekly_expected=row.weekly_due,
            already_closed=row.state == DayStateEnum.CLOSED,
        )

    # ------------------------------------------------------------------ catch-up (§7.3 steps 1-7)
    @staticmethod
    def _local_end(d: date, tz: ZoneInfo) -> datetime:
        return local_to_utc(d, time(23, 59, 59), tz)

    async def _begin_close(self, row: DaySession, mode: CloseMode, closed_at: datetime, now: datetime) -> int:
        """open -> closing in one transaction together with the planned -> missed sweep."""
        missed = await self._tasks.mark_unresolved_missed(row.local_date)
        row.state = DayStateEnum.CLOSING
        row.close_mode = mode
        row.closed_at = closed_at
        row.missed_marked_at = now
        row.weekly_due = row.weekly_due or row.local_date.weekday() == 6
        row.close_started_at = now
        await self._repo.flush()
        return missed

    async def _sync(self) -> SyncResult:
        await self._repo.lock_transitions()
        tz = await self._settings.tz()
        now = self._clock.now_utc()
        today = self._clock.today_local(tz)
        yesterday = today - timedelta(days=1)
        lo = today - timedelta(days=DAY_CATCHUP_MAX_DAYS)

        # sessions in the window (plus one week before it, for the weekly rule) and any older unclosed ones
        rows: dict[date, DaySession] = {}
        for r in [
            *await self._repo.list_unclosed_before(lo),
            *await self._repo.list_from(lo - timedelta(days=7), today),
        ]:
            rows[r.local_date] = r

        # 3. never-opened dates that hold tasks (postponed-to / future tasks) get an auto-created session
        tasks_by_date: dict[date, list[TaskDTO]] = {}
        for task in await self._tasks.tasks_in_range(lo, yesterday):
            tasks_by_date.setdefault(task.local_date, []).append(task)
        for d in sorted(tasks_by_date):
            if d not in rows:
                fresh = DaySession(local_date=d, opened_at=now, state=DayStateEnum.OPEN, auto_created=True)
                if await self._repo.insert_if_absent(fresh):
                    rows[d] = fresh
                else:  # a concurrent request created it
                    existing = await self._repo.get_by_date(d)
                    if existing is not None:
                        rows[d] = existing

        # 4. stale open sessions -> closing (auto_midnight), ascending
        newly: set[date] = set()
        for d in sorted(rows):
            row = rows[d]
            if d < today and row.state == DayStateEnum.OPEN:
                await self._begin_close(row, CloseMode.AUTO_MIDNIGHT, self._local_end(d, tz), now)
                newly.add(d)

        # 5. stragglers: a task added to a day after it was closed is swept to `missed` (reports not regenerated)
        for d, day_tasks in sorted(tasks_by_date.items()):
            known = rows.get(d)
            if known is None or d in newly or known.state == DayStateEnum.OPEN:
                continue
            if any(t.status == "planned" for t in day_tasks):
                await self._tasks.mark_unresolved_missed(d)

        # 6. weekly catch-up: a past week with no weekly report owed gets one owed from its latest session
        for sunday in (lo + timedelta(days=i) for i in range((yesterday - lo).days + 1)):
            if sunday.weekday() != 6:
                continue
            week = [r for r in rows.values() if sunday - timedelta(days=6) <= r.local_date <= sunday]
            if week and not any(r.weekly_due or r.weekly_report_id is not None for r in week):
                max(week, key=lambda r: r.local_date).weekly_due = True

        # 7. today: get-or-create, then materialize recurring tasks while it is open
        today_row = await self._repo.get_by_date(today, for_update=True)
        if today_row is None:
            await self._repo.insert_if_absent(
                DaySession(local_date=today, opened_at=now, state=DayStateEnum.OPEN)
            )
            today_row = await self._repo.get_by_date(today, for_update=True)
        assert today_row is not None
        if today_row.state == DayStateEnum.OPEN:
            await self._tasks.materialize_templates(today)

        await self._repo.flush()
        sync = SyncResult(tz=tz, today=today, now=now, today_row=today_row, newly_closing=newly)
        self.last_sync = sync
        return sync

    # ------------------------------------------------------------------ pipeline scheduling (§7.3 step 9)
    async def _pending_dates(self, sync: SyncResult) -> list[date]:
        stale_before = sync.now - timedelta(seconds=DAY_CLOSE_STALE_AFTER_S)
        running = running_dates()
        pending: list[date] = []
        for row in await self._repo.list_pending_candidates():
            if row.local_date in running:
                continue
            if row.state == DayStateEnum.CLOSING:
                stale = row.close_started_at is None or row.close_started_at < stale_before
                if stale or row.local_date in sync.newly_closing:
                    pending.append(row.local_date)
            elif is_pending(row, reports_enabled=self._reports_enabled):
                pending.append(row.local_date)
        return sorted(pending)

    def _schedule_pending(self, dates: list[date]) -> None:
        if dates:
            self._scheduler.schedule(dates)

    async def _sync_and_schedule(self) -> SyncResult:
        sync = await self._sync()
        self._schedule_pending(await self._pending_dates(sync))
        return sync

    # ------------------------------------------------------------------ DTO
    async def _dto(self, row: DaySession, today: date) -> DayDTO:
        day_tasks = await self._tasks.day_plan(row.local_date)
        return DayDTO(
            id=row.id,
            local_date=row.local_date,
            state=row.state.value,
            is_today=row.local_date == today,
            opened_at=row.opened_at,
            closed_at=row.closed_at,
            close_mode=row.close_mode,
            daily_report_id=row.daily_report_id,
            weekly_report_id=row.weekly_report_id,
            weekly_due=row.weekly_due,
            auto_created=row.auto_created,
            summary=DaySummary.from_tasks(day_tasks),
        )
