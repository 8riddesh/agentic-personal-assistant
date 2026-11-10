"""Task fixtures (tasks spec §11): service on the test DB, Berlin timezone, fake predictors."""

from __future__ import annotations

from datetime import date, datetime, timedelta
from typing import Any

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.core import AppSettingsPatch, AppSettingsService, FakeClock
from app.modules.tasks import PredictedEnd, PredictionRequest, TaskService
from app.modules.tasks.schemas import CreateTaskRequest, DailyRecurrence, WeeklyRecurrence

TODAY = date(2026, 11, 8)  # Sunday; FakeClock starts at 2026-11-08T09:00Z = 10:00 in Europe/Berlin (CET)


class FakePredictor:
    """Records every request; returns start + 70 min (method ``category_p60``) or raises on demand."""

    def __init__(self, *, fail: bool = False) -> None:
        self.requests: list[PredictionRequest] = []
        self.fail = fail

    async def predict_end(self, req: PredictionRequest) -> PredictedEnd:
        self.requests.append(req)
        if self.fail:
            raise RuntimeError("predictor down")
        end = req.start_at + timedelta(minutes=70) if req.start_at else None
        return PredictedEnd(predicted_end_at=end, method="category_p60")


@pytest.fixture
async def tz_berlin(db_session: AsyncSession) -> None:
    await AppSettingsService(db_session).update(AppSettingsPatch(timezone="Europe/Berlin"))


@pytest.fixture
def fake_predictor() -> FakePredictor:
    return FakePredictor()


@pytest.fixture
async def tasks(
    db_session: AsyncSession, fake_clock: FakeClock, tz_berlin: None, fake_predictor: FakePredictor
) -> TaskService:
    return TaskService(db_session, AppSettingsService(db_session), fake_clock, fake_predictor)


def draft(**overrides: Any) -> CreateTaskRequest:
    """A one-time task today; override any field. ``start_at`` accepts ISO strings."""
    values: dict[str, Any] = {"title": "Gym", "category": "health", "is_recurring": False}
    values.update(overrides)
    return CreateTaskRequest.model_validate(values)


def at(hhmm: str, day: date = TODAY, offset: str = "+01:00") -> datetime:
    """Local wall-clock time on ``day`` in Berlin winter time as an aware datetime."""
    return datetime.fromisoformat(f"{day.isoformat()}T{hhmm}:00{offset}")


WEEKLY_MWF = WeeklyRecurrence(freq="weekly", byweekday=[0, 2, 4])
DAILY = DailyRecurrence(freq="daily")
