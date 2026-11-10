"""Close pipeline (day_cycle spec §7.5): predictor hook -> daily report -> weekly report, then ``closed``.

Runs in the background with its own DB session (the request session is gone by then). Every step is idempotent
through a checkpoint column, so a process killed at any point resumes correctly on the next request.

``predictor`` and ``reports`` arrive in M3/M4; until then ``NullPredictorHook`` / ``NullReportGenerator`` make those
steps no-ops. ``app.main`` swaps in real adapters when the modules exist.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import date, timedelta
from typing import Literal, Protocol
from uuid import UUID

from sqlalchemy import text

from app.modules.core import AppSettingsService, Clock, SessionFactory, get_logger, session_scope
from app.modules.day_cycle.models import DaySession, DayStateEnum
from app.modules.day_cycle.repository import DaySessionRepository
from app.modules.tasks import EndTimePredictorPort, TaskService

logger = get_logger("app.day_cycle.pipeline")

DAY_CLOSE_MAX_ATTEMPTS = 3
DAY_PIPELINE_LOCK_CLASS = 0x5DA1  # int4 class of the per-date advisory lock

ReportKind = Literal["daily", "weekly"]

# Dates whose pipeline is running in this process (spec §7.5.1). Module-level on purpose: one process, one set.
_running: set[date] = set()


def running_dates() -> frozenset[date]:
    return frozenset(_running)


class PredictorHook(Protocol):
    async def on_day_closed(self, local_date: date) -> None: ...


class ReportGenerator(Protocol):
    """Implemented by ``reports`` in M4 (creating its own session per call). Returns the report id."""

    enabled: bool

    async def generate(self, kind: ReportKind, period_start: date) -> UUID: ...


class NullPredictorHook:
    async def on_day_closed(self, local_date: date) -> None:  # v1 statistics predictor has nothing to retrain
        return None


class NullReportGenerator:
    """Used until the ``reports`` module exists: nothing is generated and no report is expected."""

    enabled = False

    async def generate(self, kind: ReportKind, period_start: date) -> UUID:  # pragma: no cover - never called
        raise RuntimeError("reports module is not installed")


@dataclass
class PipelineDeps:
    session_factory: SessionFactory
    clock: Clock
    predictor_hook: PredictorHook
    reports: ReportGenerator
    task_predictor: EndTimePredictorPort | None = None


class PipelineScheduler(Protocol):
    def schedule(self, dates: list[date]) -> None: ...


def monday_of(d: date) -> date:
    return d - timedelta(days=d.weekday())


def is_pending(row: DaySession, *, reports_enabled: bool) -> bool:
    """Work remains for this session (staleness is judged separately by the service)."""
    if row.state == DayStateEnum.CLOSING:
        return True
    # a closed day still owed its weekly report; bounded by the same attempt counter so failures don't loop forever
    return (
        reports_enabled
        and row.weekly_due
        and row.weekly_report_id is None
        and row.close_attempts < DAY_CLOSE_MAX_ATTEMPTS
    )


@asynccontextmanager
async def _date_lock(deps: PipelineDeps, d: date) -> AsyncIterator[bool]:
    """Session-level advisory lock on a dedicated connection (Postgres only), held for the whole run so it survives
    the pipeline's intermediate commits. Yields ``False`` when another worker owns the date."""
    engine = deps.session_factory.kw["bind"]
    if engine.dialect.name != "postgresql":
        yield True
        return
    params = {"c": DAY_PIPELINE_LOCK_CLASS, "k": d.toordinal()}
    async with engine.connect() as conn:
        acquired = bool(
            (await conn.execute(text("SELECT pg_try_advisory_lock(:c, :k)"), params)).scalar_one()
        )
        try:
            yield acquired
        finally:
            if acquired:
                await conn.execute(text("SELECT pg_advisory_unlock(:c, :k)"), params)
            await conn.rollback()


async def run_pipelines(dates: list[date], deps: PipelineDeps) -> None:
    """Process dates sequentially in ascending order (one chart render at a time on 512 MB)."""
    for d in sorted(set(dates)):
        try:
            await ClosePipeline(deps).run(d)
        except Exception as exc:  # one broken date must not stop the others; resumed after the stale timeout
            logger.error(
                "close pipeline crashed",
                extra={"error_type": type(exc).__name__, "local_date": d.isoformat()},
            )


class ClosePipeline:
    def __init__(self, deps: PipelineDeps) -> None:
        self._deps = deps

    async def run(self, local_date: date) -> None:
        if local_date in _running:
            return
        _running.add(local_date)
        try:
            async with _date_lock(self._deps, local_date) as acquired:
                if acquired:
                    await self._run_locked(local_date)
        finally:
            _running.discard(local_date)

    async def _load(self, repo: DaySessionRepository, local_date: date) -> DaySession | None:
        return await repo.get_by_date(local_date, for_update=True)

    async def _run_locked(self, local_date: date) -> None:
        deps = self._deps
        reports_enabled = deps.reports.enabled

        async with session_scope(deps.session_factory) as session:
            repo = DaySessionRepository(session)
            row = await self._load(repo, local_date)
            if row is None or not is_pending(row, reports_enabled=reports_enabled):
                return
            if row.state == DayStateEnum.CLOSING and row.close_attempts >= DAY_CLOSE_MAX_ATTEMPTS:
                row.state = DayStateEnum.CLOSED  # e.g. crashed on every attempt: stop retrying
                return
            row.close_attempts += 1
            row.close_started_at = deps.clock.now_utc()

        try:
            await self._steps(local_date, reports_enabled)
        except Exception as exc:
            logger.error("close pipeline step failed", extra={"error_type": type(exc).__name__})
            await self._record_failure(local_date, exc)

    async def _steps(self, local_date: date, reports_enabled: bool) -> None:
        deps = self._deps
        # missed -> predictor: only meaningful while the day is still closing
        async with session_scope(deps.session_factory) as session:
            repo = DaySessionRepository(session)
            row = await self._load(repo, local_date)
            assert row is not None
            closing = row.state == DayStateEnum.CLOSING
            if closing and row.missed_marked_at is None:
                tasks = TaskService(session, AppSettingsService(session), deps.clock, deps.task_predictor)
                await tasks.mark_unresolved_missed(local_date)
                row.missed_marked_at = deps.clock.now_utc()
            predictor_pending = closing and row.predictor_done_at is None

        if predictor_pending:
            error: str | None = None
            try:
                await deps.predictor_hook.on_day_closed(local_date)
            except Exception as exc:  # predictor problems never block reports (P10)
                error = type(exc).__name__
                logger.error("predictor hook failed", extra={"error_type": error})
            async with session_scope(deps.session_factory) as session:
                row = await self._load(DaySessionRepository(session), local_date)
                assert row is not None
                row.predictor_done_at = deps.clock.now_utc()
                if error:
                    row.last_error = f"predictor:{error}"[:200]

        # daily report (committed immediately so a crash after it never regenerates it)
        async with session_scope(deps.session_factory) as session:
            row = await self._load(DaySessionRepository(session), local_date)
            assert row is not None
            need_daily = reports_enabled and row.state == DayStateEnum.CLOSING and row.daily_report_id is None
        if need_daily:
            report_id = await deps.reports.generate("daily", local_date)
            async with session_scope(deps.session_factory) as session:
                row = await self._load(DaySessionRepository(session), local_date)
                assert row is not None
                row.daily_report_id = report_id

        # weekly report (Mon-Sun, produced from the session that carries weekly_due)
        async with session_scope(deps.session_factory) as session:
            row = await self._load(DaySessionRepository(session), local_date)
            assert row is not None
            need_weekly = reports_enabled and row.weekly_due and row.weekly_report_id is None
        if need_weekly:
            weekly_id = await deps.reports.generate("weekly", monday_of(local_date))
            async with session_scope(deps.session_factory) as session:
                row = await self._load(DaySessionRepository(session), local_date)
                assert row is not None
                row.weekly_report_id = weekly_id

        async with session_scope(deps.session_factory) as session:
            row = await self._load(DaySessionRepository(session), local_date)
            assert row is not None
            if row.state == DayStateEnum.CLOSING:
                row.state = DayStateEnum.CLOSED

    async def _record_failure(self, local_date: date, exc: Exception) -> None:
        """Keep ``closing`` for a later resume; after the last allowed attempt force ``closed`` (reports can be
        regenerated through ``POST /reports/generate``). ``last_error`` holds the exception class only (P11)."""
        async with session_scope(self._deps.session_factory) as session:
            row = await self._load(DaySessionRepository(session), local_date)
            if row is None:
                return
            row.last_error = type(exc).__name__[:200]
            if row.state == DayStateEnum.CLOSING and row.close_attempts >= DAY_CLOSE_MAX_ATTEMPTS:
                row.state = DayStateEnum.CLOSED
