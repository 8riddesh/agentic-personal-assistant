from __future__ import annotations

from datetime import UTC, date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest

from app.modules.core import FakeClock, SystemClock


def test_fake_clock_rejects_naive() -> None:
    with pytest.raises(ValueError):
        FakeClock(datetime(2026, 11, 8, 9, 0))
    clock = FakeClock(datetime(2026, 11, 8, 9, 0, tzinfo=UTC))
    with pytest.raises(ValueError):
        clock.set(datetime(2026, 11, 8, 10, 0))


def test_fake_clock_stores_utc() -> None:
    clock = FakeClock(datetime(2026, 11, 8, 12, 0, tzinfo=timezone(timedelta(hours=3))))
    assert clock.now_utc() == datetime(2026, 11, 8, 9, 0, tzinfo=UTC)
    assert clock.now_utc().utcoffset() == timedelta(0)


def test_fake_clock_advance_and_negative_delta() -> None:
    clock = FakeClock(datetime(2026, 11, 8, 9, 0, tzinfo=UTC))
    clock.advance(timedelta(hours=2))
    assert clock.now_utc().hour == 11
    clock.advance(timedelta(hours=-3))
    assert clock.now_utc().hour == 8


def test_today_local_crosses_midnight_in_tz() -> None:
    """CORE-AC-08: 22:30Z is already the next day in Bucharest (UTC+2 in November)."""
    clock = FakeClock(datetime(2026, 11, 8, 22, 30, tzinfo=UTC))
    assert clock.today_local(ZoneInfo("Europe/Bucharest")) == date(2026, 11, 9)
    assert clock.today_local(ZoneInfo("UTC")) == date(2026, 11, 8)


def test_system_clock_is_tz_aware_utc() -> None:
    now = SystemClock().now_utc()
    assert now.tzinfo is not None
    assert now.utcoffset() == timedelta(0)
    assert isinstance(SystemClock().today_local(ZoneInfo("UTC")), date)
