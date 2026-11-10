"""``day_session`` persistence (private to day_cycle)."""

from __future__ import annotations

from datetime import date

from sqlalchemy import or_, select, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.day_cycle.models import DaySession, DayStateEnum

DAY_CYCLE_LOCK_KEY = 0x5DA1C1C1  # bigint constant for pg_advisory_xact_lock


class DaySessionRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def lock_transitions(self) -> None:
        """Serialise all catch-up/close transitions for this transaction (Postgres only: SQLite has one writer)."""
        bind = self._session.get_bind()
        if bind.dialect.name == "postgresql":
            await self._session.execute(text("SELECT pg_advisory_xact_lock(:k)"), {"k": DAY_CYCLE_LOCK_KEY})

    async def get_by_date(self, local_date: date, *, for_update: bool = False) -> DaySession | None:
        stmt = select(DaySession).where(DaySession.local_date == local_date)
        if for_update:
            stmt = stmt.with_for_update()
        return (await self._session.execute(stmt)).scalar_one_or_none()

    async def list_from(self, first: date, last: date) -> list[DaySession]:
        stmt = select(DaySession).where(DaySession.local_date >= first, DaySession.local_date <= last)
        return list((await self._session.execute(stmt.order_by(DaySession.local_date.asc()))).scalars())

    async def list_unclosed_before(self, before: date) -> list[DaySession]:
        stmt = select(DaySession).where(
            DaySession.local_date < before, DaySession.state != DayStateEnum.CLOSED
        )
        return list((await self._session.execute(stmt.order_by(DaySession.local_date.asc()))).scalars())

    async def list_pending_candidates(self) -> list[DaySession]:
        """Not-closed sessions plus closed ones still owed a weekly report; the service filters further."""
        stmt = select(DaySession).where(
            or_(
                DaySession.state != DayStateEnum.CLOSED,
                (DaySession.weekly_due.is_(True)) & (DaySession.weekly_report_id.is_(None)),
            )
        )
        return list((await self._session.execute(stmt.order_by(DaySession.local_date.asc()))).scalars())

    async def insert_if_absent(self, row: DaySession) -> bool:
        """Insert in a savepoint; ``False`` if the date already has a session (``ON CONFLICT DO NOTHING`` semantics)."""
        try:
            async with self._session.begin_nested():
                self._session.add(row)
                await self._session.flush()
        except IntegrityError:
            return False
        return True

    async def flush(self) -> None:
        await self._session.flush()
