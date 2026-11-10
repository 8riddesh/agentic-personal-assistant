"""Record real API responses for the mobile contract test (``mobile/test/fixtures/backend_responses.json``).

Runs a short scenario against the actual FastAPI app (in-process, throw-away SQLite, fixed clock) and stores every
response body. The Flutter test ``backend_contract_test.dart`` parses them with the Dart DTOs, so a backend change
that breaks the app shows up as a failing mobile test instead of a runtime crash.

Usage (from ``backend/``):  ``uv run python scripts/export_mobile_fixtures.py``
"""

from __future__ import annotations

import asyncio
import json
import sys
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

BACKEND_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND_DIR))

import httpx  # noqa: E402
from sqlalchemy.ext.asyncio import create_async_engine  # noqa: E402

import app.modules.auth.models  # noqa: E402, F401
import app.modules.core.models  # noqa: E402, F401
import app.modules.day_cycle.models  # noqa: E402, F401
import app.modules.tasks.models  # noqa: E402, F401
from app.main import create_app  # noqa: E402
from app.modules.core import Base, FakeClock, Settings  # noqa: E402

TARGET = BACKEND_DIR.parent / "mobile" / "test" / "fixtures" / "backend_responses.json"
PASSWORD = "contract-test-password"


def _settings(password_hash: str) -> Settings:
    return Settings(
        _env_file=None,  # type: ignore[call-arg]
        env="test",
        database_url="postgresql+asyncpg://user:pw@localhost:5432/db",
        owner_email="owner@example.com",
        owner_password_hash=password_hash,
        jwt_secret="x" * 40,
        encryption_keys="1:" + "A" * 43 + "=",
        encryption_active_key_id=1,
    )


async def record() -> dict[str, Any]:
    from app.modules.auth.security import PasswordHasher

    out: dict[str, Any] = {}
    with tempfile.TemporaryDirectory() as tmp:
        engine = create_async_engine(f"sqlite+aiosqlite:///{Path(tmp) / 'fixtures.db'}")
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        application = create_app(_settings(PasswordHasher().hash(PASSWORD)))
        clock = FakeClock(datetime(2026, 11, 9, 8, 0, tzinfo=UTC))  # Monday 08:00Z
        application.state.clock = clock
        application.state.engine_factory = lambda _s: engine
        async with application.router.lifespan_context(application):
            transport = httpx.ASGITransport(app=application, raise_app_exceptions=False)
            async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:

                async def call(name: str, method: str, url: str, **kwargs: Any) -> Any:
                    response = await client.request(method, url, **kwargs)
                    body = response.json() if response.content else None
                    out[name] = {"status": response.status_code, "body": body}
                    return body

                login = await call(
                    "login", "POST", "/api/v1/auth/login",
                    json={"email": "owner@example.com", "password": PASSWORD, "timezone": "Europe/Bucharest"},
                )
                client.headers["Authorization"] = f"Bearer {login['access_token']}"
                out["login"]["body"]["access_token"] = "<redacted>"  # never store a token, even a throw-away one

                await call("settings", "GET", "/api/v1/settings")
                await call("login_wrong_password", "POST", "/api/v1/auth/login",
                           json={"email": "owner@example.com", "password": "nope"})

                day = await call("day_current", "GET", "/api/v1/days/current")
                timed = await call(
                    "create_timed_task", "POST", "/api/v1/tasks",
                    json={"title": "Write report", "category": "work", "is_recurring": False,
                          "local_date": day["local_date"], "start_at": "2026-11-09T07:00:00Z",
                          "estimate_min": 60, "client_request_id": "11111111-1111-4111-8111-111111111111"},
                )
                await call("create_replay", "POST", "/api/v1/tasks",
                           json={"title": "Write report", "category": "work", "is_recurring": False,
                                 "client_request_id": "11111111-1111-4111-8111-111111111111"})
                await call("create_recurring_task", "POST", "/api/v1/tasks",
                           json={"title": "Gym", "category": "health", "is_recurring": True,
                                 "recurrence": {"freq": "weekly", "byweekday": [0, 2, 4]},
                                 "start_at": "2026-11-09T16:00:00Z", "estimate_min": 45})
                anytime = await call("create_anytime_task", "POST", "/api/v1/tasks",
                                     json={"title": "Read", "is_recurring": False})
                cancel_me = await call("create_task_to_cancel", "POST", "/api/v1/tasks",
                                       json={"title": "Call bank", "is_recurring": False})
                cant = await call("create_task_cant_do", "POST", "/api/v1/tasks",
                                  json={"title": "Dentist", "category": "Health", "is_recurring": False})
                late = await call("create_task_to_postpone", "POST", "/api/v1/tasks",
                                  json={"title": "Taxes", "is_recurring": False, "start_at": "2026-11-09T17:00:00Z"})

                await call("tasks_today", "GET", "/api/v1/tasks", params={"date": day["local_date"]})
                await call("status_completed", "POST", f"/api/v1/tasks/{timed['task']['id']}/status",
                           json={"status": "completed", "finished_at": "2026-11-09T07:50:00Z", "source": "app"})
                await call("status_cancelled", "POST", f"/api/v1/tasks/{cancel_me['task']['id']}/status",
                           json={"status": "cancelled", "reason": "not needed", "source": "app"})
                await call("status_cant_do", "POST", f"/api/v1/tasks/{cant['task']['id']}/status",
                           json={"status": "cant_do", "reason": "clinic closed", "source": "app"})
                await call("status_postponed", "POST", f"/api/v1/tasks/{late['task']['id']}/status",
                           json={"status": "postponed", "new_start_at": "2026-11-10T09:00:00Z", "source": "eod"})
                await call("status_invalid_transition", "POST", f"/api/v1/tasks/{timed['task']['id']}/status",
                           json={"status": "cancelled", "source": "app"})
                await call("check_response_not_yet", "POST", f"/api/v1/tasks/{anytime['task']['id']}/check-response",
                           json={"response": "not_yet"})  # anytime task: 409 task.no_check
                await call("validation_error", "POST", "/api/v1/tasks", json={"title": "x"})
                await call("patch_task", "PATCH", f"/api/v1/tasks/{anytime['task']['id']}",
                           json={"title": "Read paper", "estimate_min": 30})
                await call("templates", "GET", "/api/v1/templates")
                await call("unresolved", "GET", "/api/v1/days/current/unresolved")
                await call("close_day", "POST", "/api/v1/days/current/close")
                await call("day_after_close", "GET", f"/api/v1/days/{day['local_date']}")
                await call("close_again", "POST", "/api/v1/days/current/close")

                client.headers.pop("Authorization")
                await call("unauthorized", "GET", "/api/v1/tasks")
        await engine.dispose()
    return out


def main() -> None:
    data = asyncio.run(record())
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    TARGET.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")
    print(f"wrote {TARGET} ({len(data)} responses)")


if __name__ == "__main__":
    main()
