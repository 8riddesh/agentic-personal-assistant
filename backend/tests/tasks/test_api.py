"""HTTP-level tests for ``/api/v1/tasks`` and ``/templates`` (status codes, bodies, auth, day opening)."""

from __future__ import annotations

from typing import Any
from uuid import uuid4

import httpx
import pytest

TASKS = "/api/v1/tasks"
TEMPLATES = "/api/v1/templates"
# FakeClock = 2026-11-08T09:00Z and the app timezone is UTC in these tests
START = "2026-11-08T18:00:00Z"
PAST_START = "2026-11-08T07:00:00Z"


def body(**overrides: Any) -> dict[str, Any]:
    values: dict[str, Any] = {"title": "Gym", "category": "health", "is_recurring": False}
    values.update(overrides)
    return values


async def test_all_routes_require_auth(client: httpx.AsyncClient) -> None:
    for method, url in (("get", TASKS), ("post", TASKS), ("get", TEMPLATES), ("patch", f"{TASKS}/{uuid4()}")):
        response = await getattr(client, method)(url)
        assert response.status_code == 401, (method, url)
        assert response.json()["code"] == "not_authenticated"


async def test_create_returns_201_with_location_then_200_on_replay(authed_client: httpx.AsyncClient) -> None:
    request_id = str(uuid4())
    first = await authed_client.post(TASKS, json=body(start_at=START, client_request_id=request_id))
    assert first.status_code == 201
    created = first.json()
    assert created["replayed"] is False and created["template"] is None
    assert first.headers["location"] == f"/api/v1/tasks/{created['task']['id']}"
    task = created["task"]
    assert (task["title"], task["category"], task["status"], task["local_date"]) == (
        "Gym",
        "Health",
        "planned",
        "2026-11-08",
    )
    assert task["start_at"].startswith("2026-11-08T18:00:00")
    second = await authed_client.post(TASKS, json=body(start_at=START, client_request_id=request_id))
    assert second.status_code == 200
    assert second.json()["replayed"] is True and second.json()["task"]["id"] == task["id"]


async def test_create_recurring_returns_template(authed_client: httpx.AsyncClient) -> None:
    response = await authed_client.post(
        TASKS,
        json=body(start_at=START, is_recurring=True, recurrence={"freq": "weekly", "byweekday": [4, 0, 2]}),
    )
    assert response.status_code == 201
    template = response.json()["template"]
    assert template["recurrence"] == {"freq": "weekly", "byweekday": [0, 2, 4]}
    assert template["start_local"] == "18:00:00" and template["starts_on"] == "2026-11-08"
    assert response.json()["task"]["is_recurring"] is True


@pytest.mark.parametrize(
    "payload",
    [
        {"title": "x"},  # is_recurring missing (TASKS-AC-02)
        body(is_recurring=True),  # recurrence missing
        body(recurrence={"freq": "daily"}),  # recurrence without is_recurring
        body(title="   "),
        body(title="x" * 201),
        body(estimate_min=0),
        body(estimate_min=721),
        body(start_at="2026-11-08T18:00:00"),  # naive datetime
        body(is_recurring=True, recurrence={"freq": "weekly", "byweekday": []}),
        body(created_via="template"),
    ],
)
async def test_create_validation_422(authed_client: httpx.AsyncClient, payload: dict[str, Any]) -> None:
    response = await authed_client.post(TASKS, json=payload)
    assert response.status_code == 422
    assert response.headers["content-type"].startswith("application/problem+json")
    assert response.json()["code"] == "validation_failed"


async def test_create_domain_errors_carry_codes(authed_client: httpx.AsyncClient) -> None:
    mismatch = await authed_client.post(TASKS, json=body(start_at=START, local_date="2026-11-09"))
    assert (mismatch.status_code, mismatch.json()["code"]) == (422, "task.start_not_on_local_date")
    override = await authed_client.post(TASKS, json=body(overridden=True))
    assert (override.status_code, override.json()["code"]) == (422, "task.override_requires_assessment")
    past = await authed_client.post(TASKS, json=body(local_date="2026-11-01"))
    assert (past.status_code, past.json()["code"]) == (422, "task.date_out_of_range")


async def test_validation_error_does_not_echo_personal_text(authed_client: httpx.AsyncClient) -> None:
    response = await authed_client.post(TASKS, json=body(title="PERSONAL-TEXT-XYZ", estimate_min=-5))
    assert response.status_code == 422
    assert "PERSONAL-TEXT-XYZ" not in response.text


async def test_list_defaults_to_today_and_filters_by_date(authed_client: httpx.AsyncClient) -> None:
    await authed_client.post(TASKS, json=body(title="today"))
    await authed_client.post(TASKS, json=body(title="tomorrow", local_date="2026-11-09"))
    today = await authed_client.get(TASKS)
    assert [t["title"] for t in today.json()] == ["today"]
    tomorrow = await authed_client.get(TASKS, params={"date": "2026-11-09"})
    assert [t["title"] for t in tomorrow.json()] == ["tomorrow"]
    assert (await authed_client.get(TASKS, params={"date": "nonsense"})).status_code == 422


async def test_get_unknown_task_404_problem(authed_client: httpx.AsyncClient) -> None:
    response = await authed_client.get(f"{TASKS}/{uuid4()}")
    assert response.status_code == 404
    assert response.json()["code"] == "not_found"
    assert (await authed_client.get(f"{TASKS}/not-a-uuid")).status_code == 422


async def test_status_flow_over_http(authed_client: httpx.AsyncClient) -> None:
    task = (await authed_client.post(TASKS, json=body(start_at=PAST_START))).json()["task"]
    done = await authed_client.post(
        f"{TASKS}/{task['id']}/status", json={"status": "completed", "finished_at": "2026-11-08T08:00:00Z"}
    )
    assert done.status_code == 200
    assert done.json()["task"]["status"] == "completed" and done.json()["created_task"] is None
    again = await authed_client.post(f"{TASKS}/{task['id']}/status", json={"status": "cancelled"})
    assert (again.status_code, again.json()["code"]) == (409, "task.invalid_transition")


async def test_missed_is_not_settable_via_api(authed_client: httpx.AsyncClient) -> None:
    """TASKS-AC-11 (API half)."""
    task = (await authed_client.post(TASKS, json=body())).json()["task"]
    response = await authed_client.post(f"{TASKS}/{task['id']}/status", json={"status": "missed"})
    assert response.status_code == 422


async def test_cant_do_requires_reason_422(authed_client: httpx.AsyncClient) -> None:
    task = (await authed_client.post(TASKS, json=body())).json()["task"]
    assert (
        await authed_client.post(f"{TASKS}/{task['id']}/status", json={"status": "cant_do"})
    ).status_code == 422
    blank = await authed_client.post(
        f"{TASKS}/{task['id']}/status", json={"status": "cant_do", "reason": " "}
    )
    assert blank.status_code == 422
    ok = await authed_client.post(
        f"{TASKS}/{task['id']}/status", json={"status": "cant_do", "reason": "sick"}
    )
    assert ok.status_code == 200 and ok.json()["task"]["status_reason"] == "sick"


async def test_postpone_over_http_returns_both_tasks(authed_client: httpx.AsyncClient) -> None:
    task = (await authed_client.post(TASKS, json=body(start_at=START))).json()["task"]
    response = await authed_client.post(
        f"{TASKS}/{task['id']}/status",
        json={"status": "postponed", "new_start_at": "2026-11-09T09:00:00Z", "source": "eod"},
    )
    assert response.status_code == 200
    payload = response.json()
    assert payload["task"]["status"] == "postponed"
    assert payload["task"]["postponed_to_task_id"] == payload["created_task"]["id"]
    assert payload["created_task"]["local_date"] == "2026-11-09"


async def test_check_response_over_http(authed_client: httpx.AsyncClient) -> None:
    task = (await authed_client.post(TASKS, json=body(start_at=PAST_START))).json()["task"]
    not_yet = await authed_client.post(
        f"{TASKS}/{task['id']}/check-response", json={"response": "not_yet", "eta_min": 15}
    )
    assert not_yet.status_code == 200 and not_yet.json()["check_response"] == "not_yet"
    done = await authed_client.post(
        f"{TASKS}/{task['id']}/check-response",
        json={"response": "done", "finished_at": "2026-11-08T08:30:00Z"},
    )
    assert done.status_code == 200
    assert (done.json()["status"], done.json()["actual_end_source"]) == ("completed", "notification_action")
    bad_eta = await authed_client.post(
        f"{TASKS}/{task['id']}/check-response", json={"response": "not_yet", "eta_min": 1}
    )
    assert bad_eta.status_code == 422


async def test_check_response_on_anytime_task_409(authed_client: httpx.AsyncClient) -> None:
    task = (await authed_client.post(TASKS, json=body())).json()["task"]
    response = await authed_client.post(f"{TASKS}/{task['id']}/check-response", json={"response": "not_yet"})
    assert (response.status_code, response.json()["code"]) == (409, "task.no_check")


async def test_patch_task_and_not_editable(authed_client: httpx.AsyncClient) -> None:
    task = (await authed_client.post(TASKS, json=body(start_at=START))).json()["task"]
    patched = await authed_client.patch(f"{TASKS}/{task['id']}", json={"title": "Gym v2", "estimate_min": 45})
    assert patched.status_code == 200 and patched.json()["title"] == "Gym v2"
    assert (await authed_client.patch(f"{TASKS}/{task['id']}", json={"colour": "red"})).status_code == 422
    assert (await authed_client.patch(f"{TASKS}/{task['id']}", json={"title": None})).status_code == 422
    await authed_client.post(f"{TASKS}/{task['id']}/status", json={"status": "cancelled"})
    locked = await authed_client.patch(f"{TASKS}/{task['id']}", json={"title": "again"})
    assert (locked.status_code, locked.json()["code"]) == (409, "task.not_editable")


async def test_templates_endpoints(authed_client: httpx.AsyncClient) -> None:
    created = (
        await authed_client.post(TASKS, json=body(is_recurring=True, recurrence={"freq": "daily"}))
    ).json()["template"]
    listing = await authed_client.get(TEMPLATES)
    assert [t["id"] for t in listing.json()] == [created["id"]]
    assert (await authed_client.get(f"{TEMPLATES}/{created['id']}")).json()["active"] is True
    patched = await authed_client.patch(
        f"{TEMPLATES}/{created['id']}",
        json={"recurrence": {"freq": "weekly", "byweekday": [1]}, "title": "T"},
    )
    assert patched.status_code == 200 and patched.json()["recurrence"]["byweekday"] == [1]
    assert (
        await authed_client.patch(f"{TEMPLATES}/{created['id']}", json={"recurrence": None})
    ).status_code == 422
    first = await authed_client.delete(f"{TEMPLATES}/{created['id']}", params={"cancel_planned": "true"})
    second = await authed_client.delete(f"{TEMPLATES}/{created['id']}")
    assert (first.status_code, second.status_code) == (204, 204)
    assert (await authed_client.get(TEMPLATES, params={"active": "true"})).json() == []
    assert len((await authed_client.get(TEMPLATES, params={"active": "false"})).json()) == 1
    assert (await authed_client.delete(f"{TEMPLATES}/{uuid4()}")).status_code == 404
    todays = (await authed_client.get(TASKS)).json()
    assert [t["status"] for t in todays] == ["cancelled"]


async def test_task_routes_open_todays_day_and_materialize_templates(
    authed_client: httpx.AsyncClient, app: Any
) -> None:
    """The day-scoped dependency runs on the tasks router (lazy day open, day_cycle spec §7.6)."""
    from sqlalchemy import select

    from app.modules.day_cycle.models import DaySession

    await authed_client.post(TASKS, json=body(is_recurring=True, recurrence={"freq": "daily"}))
    async with app.state.session_factory() as session:
        sessions = (await session.execute(select(DaySession))).scalars().all()
    assert [(s.local_date.isoformat(), s.state.value) for s in sessions] == [("2026-11-08", "open")]
