"""HTTP-level day_cycle tests: endpoints, 202/200 semantics and the ``ensure_current_day`` dependency.

The app runs with the M1 null predictor/report ports, so a closing day finishes in the background task that
httpx's ASGI transport awaits before returning.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
import pytest
from fastapi import FastAPI
from sqlalchemy import select

from app.modules.core import FakeClock
from app.modules.day_cycle import DayService
from app.modules.day_cycle.models import DaySession

DAYS = "/api/v1/days"
TASKS = "/api/v1/tasks"


async def _sessions(app: FastAPI) -> dict[str, DaySession]:
    async with app.state.session_factory() as session:
        rows = (await session.execute(select(DaySession))).scalars().all()
    return {r.local_date.isoformat(): r for r in rows}


async def test_routes_require_auth(client: httpx.AsyncClient) -> None:
    for method, url in (
        ("get", f"{DAYS}/current"),
        ("get", f"{DAYS}/current/unresolved"),
        ("post", f"{DAYS}/current/close"),
        ("get", f"{DAYS}/2026-11-08"),
    ):
        assert (await getattr(client, method)(url)).status_code == 401


async def test_current_day_shape(authed_client: httpx.AsyncClient) -> None:
    """DAY-AC-01 (HTTP)."""
    response = await authed_client.get(f"{DAYS}/current")
    assert response.status_code == 200
    day = response.json()
    assert (day["local_date"], day["state"], day["is_today"]) == ("2026-11-08", "open", True)
    assert day["closed_at"] is None and day["close_mode"] is None
    assert day["daily_report_id"] is None and day["weekly_due"] is False and day["auto_created"] is False
    assert day["summary"] == {
        "total": 0,
        "by_status": {
            "planned": 0,
            "completed": 0,
            "postponed": 0,
            "cancelled": 0,
            "cant_do": 0,
            "missed": 0,
        },
    }


async def test_close_flow_202_then_closed_then_200(authed_client: httpx.AsyncClient, app: FastAPI) -> None:
    """DAY-AC-04 / DAY-AC-09 over HTTP (Sunday: the weekly report is expected)."""
    await authed_client.post(TASKS, json={"title": "a", "is_recurring": False})
    await authed_client.post(
        TASKS, json={"title": "b", "is_recurring": False, "start_at": "2026-11-08T18:00:00Z"}
    )
    unresolved = await authed_client.get(f"{DAYS}/current/unresolved")
    assert unresolved.status_code == 200
    assert unresolved.json()["local_date"] == "2026-11-08" and len(unresolved.json()["tasks"]) == 2

    closing = await authed_client.post(f"{DAYS}/current/close")
    assert closing.status_code == 202
    assert closing.json() == {
        "local_date": "2026-11-08",
        "state": "closing",
        "close_mode": "user",
        "missed_count": 2,
        "daily_report_id": None,
        "weekly_report_id": None,
        "weekly_expected": True,
        "already_closed": False,
    }
    polled = await authed_client.get(f"{DAYS}/2026-11-08")  # the app polls until the pipeline is done
    assert polled.status_code == 200
    assert polled.json()["state"] == "closed" and polled.json()["summary"]["by_status"]["missed"] == 2

    replay = await authed_client.post(f"{DAYS}/current/close")
    assert replay.status_code == 200
    assert (replay.json()["already_closed"], replay.json()["missed_count"], replay.json()["state"]) == (
        True,
        0,
        "closed",
    )
    assert (await authed_client.get(f"{DAYS}/current/unresolved")).json()["tasks"] == []
    assert (await _sessions(app))["2026-11-08"].close_attempts == 1


async def test_get_unknown_day_404_and_bad_date_422(authed_client: httpx.AsyncClient) -> None:
    missing = await authed_client.get(f"{DAYS}/2026-01-01")
    assert (missing.status_code, missing.json()["code"]) == (404, "day.not_found")
    assert (await authed_client.get(f"{DAYS}/not-a-date")).status_code == 422
    assert (
        await authed_client.get(f"{DAYS}/current")
    ).status_code == 200  # "current" is not parsed as a date


async def test_ensure_dependency_triggers_autoclose_on_tasks_route(
    authed_client: httpx.AsyncClient, app: FastAPI, fake_clock: FakeClock
) -> None:
    """DAY-AC-02 via the tasks router (no /days call involved)."""
    created = await authed_client.post(TASKS, json={"title": "forgotten", "is_recurring": False})
    task_id = created.json()["task"]["id"]
    fake_clock.set(datetime(2026, 11, 9, 0, 5, tzinfo=UTC))  # just after midnight (UTC timezone in this app)
    today = await authed_client.get(TASKS)  # any day-scoped request
    assert today.status_code == 200 and today.json() == []  # the new day is empty
    sessions = await _sessions(app)
    assert set(sessions) == {"2026-11-08", "2026-11-09"}
    old = sessions["2026-11-08"]
    assert (old.state.value, old.close_mode.value if old.close_mode else None) == ("closed", "auto_midnight")
    assert old.closed_at == datetime(2026, 11, 8, 23, 59, 59, tzinfo=UTC)
    assert (await authed_client.get(f"{TASKS}/{task_id}")).json()["status"] == "missed"
    assert sessions["2026-11-09"].state.value == "open"


async def test_ensure_dependency_memo_skips_repeat_syncs(
    authed_client: httpx.AsyncClient, fake_clock: FakeClock, monkeypatch: pytest.MonkeyPatch
) -> None:
    calls: list[int] = []
    original = DayService.current

    async def counting(self: DayService) -> Any:
        calls.append(1)
        return await original(self)

    monkeypatch.setattr(DayService, "current", counting)
    for _ in range(3):
        assert (await authed_client.get(TASKS)).status_code == 200
    assert len(calls) == 1  # first call syncs, the next two hit the fast path
    fake_clock.advance(timedelta(seconds=61))
    await authed_client.get(TASKS)
    assert len(calls) == 2  # memo expired
    fake_clock.advance(timedelta(hours=16))  # past local midnight: the date changed, so no fast path either
    await authed_client.get(TASKS)
    assert len(calls) == 3
