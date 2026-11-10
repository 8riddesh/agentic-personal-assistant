"""Pure-rule unit tests (tasks spec §11 "Unit"): recurrence, categories, time zones, state machine."""

from __future__ import annotations

from datetime import UTC, date, datetime, time
from zoneinfo import ZoneInfo

import pytest
from pydantic import ValidationError

from app.modules.core import ConflictError, DomainValidationError
from app.modules.tasks import DailyRecurrence, WeeklyRecurrence, local_to_utc
from app.modules.tasks.service import matches, normalize_category, resolve_local_date
from app.modules.tasks.state_machine import STATUSES, USER_TRANSITIONS, assert_transition, is_allowed

BERLIN = ZoneInfo("Europe/Berlin")


# ------------------------------------------------------------------ recurrence
def test_matches_daily() -> None:
    assert all(matches(DailyRecurrence(freq="daily"), date(2026, 11, 2 + i)) for i in range(7))


def test_matches_weekly_monday_is_zero() -> None:
    rule = WeeklyRecurrence(freq="weekly", byweekday=[0, 2])
    assert matches(rule, date(2026, 11, 9))  # Monday
    assert matches(rule, date(2026, 11, 11))  # Wednesday
    assert not matches(rule, date(2026, 11, 10))  # Tuesday
    assert not matches(rule, date(2026, 11, 8))  # Sunday = 6


@pytest.mark.parametrize("weekdays", [[], [1, 1], [7], [-1], [0, 2, 2]])
def test_recurrence_validation_rejects_empty_or_dup_weekdays(weekdays: list[int]) -> None:
    with pytest.raises(ValidationError):
        WeeklyRecurrence(freq="weekly", byweekday=weekdays)


def test_recurrence_weekdays_stored_sorted() -> None:
    assert WeeklyRecurrence(freq="weekly", byweekday=[4, 0, 2]).byweekday == [0, 2, 4]


# ------------------------------------------------------------------ categories (§7.6)
@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("health", "Health"),
        ("  WORK ", "Work"),
        ("learning", "Learning"),
        ("Side   project", "Side project"),
        ("Café & Bar", "Café & Bar"),
    ],
)
def test_normalize_category_canonicalizes_known(raw: str, expected: str) -> None:
    assert normalize_category(raw) == expected


@pytest.mark.parametrize("raw", ["", "   ", "x" * 33, "-leading", "emoji 😀", "semi;colon"])
def test_normalize_category_rejects_invalid(raw: str) -> None:
    with pytest.raises(DomainValidationError) as info:
        normalize_category(raw)
    assert info.value.code == "task.invalid_category"


# ------------------------------------------------------------------ local time (§7.4)
def test_local_to_utc_regular_day() -> None:
    assert local_to_utc(date(2026, 11, 9), time(18, 0), BERLIN) == datetime(2026, 11, 9, 17, 0, tzinfo=UTC)


def test_local_to_utc_spring_gap_shifts_forward() -> None:
    """2026-03-29 02:30 does not exist in Berlin (02:00 -> 03:00): it shifts forward to 03:30 CEST = 01:30Z."""
    result = local_to_utc(date(2026, 3, 29), time(2, 30), BERLIN)
    assert result == datetime(2026, 3, 29, 1, 30, tzinfo=UTC)
    assert result.astimezone(BERLIN).hour == 3


def test_local_to_utc_fall_back_first_occurrence() -> None:
    """2026-10-25 02:30 happens twice in Berlin: the first (CEST, +02:00) = 00:30Z is used."""
    assert local_to_utc(date(2026, 10, 25), time(2, 30), BERLIN) == datetime(2026, 10, 25, 0, 30, tzinfo=UTC)


def test_local_date_resolution() -> None:
    today = date(2026, 11, 8)
    late = datetime(2026, 11, 8, 23, 30, tzinfo=UTC)  # 00:30 on the 9th in Berlin
    assert resolve_local_date(None, None, BERLIN, today) == today
    assert resolve_local_date(date(2026, 11, 20), None, BERLIN, today) == date(2026, 11, 20)
    assert resolve_local_date(None, late, BERLIN, today) == date(2026, 11, 9)
    assert resolve_local_date(date(2026, 11, 9), late, BERLIN, today) == date(2026, 11, 9)
    with pytest.raises(DomainValidationError) as info:
        resolve_local_date(date(2026, 11, 8), late, BERLIN, today)
    assert info.value.code == "task.start_not_on_local_date"


# ------------------------------------------------------------------ state machine (§7.1)
@pytest.mark.parametrize("from_status", STATUSES)
@pytest.mark.parametrize("to_status", STATUSES)
def test_state_machine_table_all_pairs(from_status: str, to_status: str) -> None:
    expected = (from_status, to_status) in USER_TRANSITIONS
    assert is_allowed(from_status, to_status) is expected
    if expected:
        assert_transition(from_status, to_status)
    else:
        with pytest.raises(ConflictError) as info:
            assert_transition(from_status, to_status)
        assert info.value.code == "task.invalid_transition"


def test_planned_to_missed_is_system_only() -> None:
    assert not is_allowed("planned", "missed")
    assert is_allowed("planned", "missed", system=True)
    assert not is_allowed("completed", "missed", system=True)


def test_terminal_statuses_have_no_exits() -> None:
    for terminal in ("completed", "postponed", "cancelled", "cant_do"):
        assert not any(is_allowed(terminal, to) for to in STATUSES)
