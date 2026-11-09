"""Clock abstraction (plan §4.1, core spec §7.3). All modules obtain time only through a `Clock`."""

from __future__ import annotations

from datetime import UTC, date, datetime, timedelta
from typing import Protocol
from zoneinfo import ZoneInfo

from fastapi import Request


class Clock(Protocol):
    def now_utc(self) -> datetime: ...

    def today_local(self, tz: ZoneInfo) -> date: ...


class SystemClock:
    def now_utc(self) -> datetime:
        return datetime.now(UTC)

    def today_local(self, tz: ZoneInfo) -> date:
        return self.now_utc().astimezone(tz).date()


class FakeClock:
    """Test clock. Rejects naive datetimes; ``advance`` accepts negative deltas."""

    def __init__(self, start: datetime) -> None:
        self._now = self._to_utc(start)

    @staticmethod
    def _to_utc(value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("FakeClock requires a timezone-aware datetime")
        return value.astimezone(UTC)

    def now_utc(self) -> datetime:
        return self._now

    def today_local(self, tz: ZoneInfo) -> date:
        return self._now.astimezone(tz).date()

    def set(self, at: datetime) -> None:
        self._now = self._to_utc(at)

    def advance(self, delta: timedelta) -> None:
        self._now = self._now + delta


def get_clock(request: Request) -> Clock:
    clock: Clock = request.app.state.clock
    return clock
