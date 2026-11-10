"""CORE-AC-03/04/05/13: ``/api/v1/settings`` (app_settings single row + AppSettingsService)."""

from __future__ import annotations

from typing import Any

import httpx
import pytest
from fastapi import FastAPI
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.core import AppSettingsPatch, AppSettingsService, DomainValidationError
from app.modules.crypto import TEXT_ENVELOPE_RE
from tests.crypto.helpers import assert_no_plaintext

URL = "/api/v1/settings"


async def test_app_settings_get_creates_default_row(authed_client: httpx.AsyncClient) -> None:
    """CORE-AC-03."""
    response = await authed_client.get(URL)
    assert response.status_code == 200
    body = response.json()
    assert body["timezone"] == "UTC"
    assert body["timezone_confirmed"] is False
    assert body["reminder_offsets_min"] == [60, 30]
    assert body["report_email"] is None
    assert body["week_start"] == 1


async def test_patch_partial_update(authed_client: httpx.AsyncClient) -> None:
    response = await authed_client.patch(URL, json={"report_email": "me@example.com"})
    assert response.status_code == 200
    body = response.json()
    assert body["report_email"] == "me@example.com"
    assert (body["timezone"], body["reminder_offsets_min"], body["week_start"]) == ("UTC", [60, 30], 1)
    assert body["timezone_confirmed"] is False


async def test_patch_empty_body_is_noop(authed_client: httpx.AsyncClient) -> None:
    before = (await authed_client.get(URL)).json()
    response = await authed_client.patch(URL, json={})
    assert response.status_code == 200
    assert response.json() == before


async def test_patch_timezone_sets_confirmed(authed_client: httpx.AsyncClient) -> None:
    response = await authed_client.patch(URL, json={"timezone": "Europe/Bucharest"})
    assert response.status_code == 200
    assert response.json()["timezone"] == "Europe/Bucharest"
    assert response.json()["timezone_confirmed"] is True


@pytest.mark.parametrize(
    ("payload", "field"),
    [
        ({"timezone": "Mars/Olympus"}, "timezone"),
        ({"timezone": "localtime"}, "timezone"),
        ({"timezone": None}, "timezone"),
        ({"reminder_offsets_min": []}, "reminder_offsets_min"),
        ({"reminder_offsets_min": [60, 30, 15]}, "reminder_offsets_min"),
        ({"reminder_offsets_min": [30, 30]}, "reminder_offsets_min"),
        ({"reminder_offsets_min": [4]}, "reminder_offsets_min"),
        ({"reminder_offsets_min": [241]}, "reminder_offsets_min"),
        ({"week_start": 0}, "week_start"),
        ({"week_start": 8}, "week_start"),
        ({"report_email": "not-an-email"}, "report_email"),
    ],
)
async def test_patch_invalid_values_422(
    authed_client: httpx.AsyncClient, payload: dict[str, Any], field: str
) -> None:
    """CORE-AC-05: 422 problem with errors[].loc and no echoed input."""
    response = await authed_client.patch(URL, json=payload)
    assert response.status_code == 422
    assert response.headers["content-type"].startswith("application/problem+json")
    body = response.json()
    assert body["code"] == "validation_failed"
    assert ["body", field] in [e["loc"] for e in body["errors"]]
    assert "input" not in str(body["errors"])


async def test_patch_unknown_field_422(authed_client: httpx.AsyncClient) -> None:
    response = await authed_client.patch(URL, json={"colour": "blue"})
    assert response.status_code == 422


async def test_patch_offsets_stored_sorted_descending(authed_client: httpx.AsyncClient) -> None:
    response = await authed_client.patch(URL, json={"reminder_offsets_min": [15, 45]})
    assert response.status_code == 200
    assert response.json()["reminder_offsets_min"] == [45, 15]


async def test_report_email_clear_with_null(authed_client: httpx.AsyncClient) -> None:
    await authed_client.patch(URL, json={"report_email": "me@example.com"})
    response = await authed_client.patch(URL, json={"report_email": None})
    assert response.status_code == 200
    assert response.json()["report_email"] is None


async def test_report_email_encrypted_at_rest(authed_client: httpx.AsyncClient, app: FastAPI) -> None:
    """CORE-AC-04: the raw DB value is a ``v<id>:`` envelope, never the address."""
    await authed_client.patch(URL, json={"report_email": "secret.person@example.com"})
    async with app.state.session_factory() as session:
        await assert_no_plaintext(session, "app_settings", "report_email", "secret.person@example.com")
        raw = (await session.execute(text("SELECT report_email FROM app_settings"))).scalar_one()
    assert TEXT_ENVELOPE_RE.match(raw)
    assert raw.startswith("v1:")


async def test_settings_requires_auth(client: httpx.AsyncClient) -> None:
    """CORE-AC-13."""
    for method in ("get", "patch"):
        response = await getattr(client, method)(URL)
        assert response.status_code == 401
        assert response.headers["www-authenticate"] == "Bearer"
        assert response.json()["code"] == "not_authenticated"


async def test_service_tz_and_row_recreated_when_missing(db_session: AsyncSession) -> None:
    service = AppSettingsService(db_session)
    assert str(await service.tz()) == "UTC"  # row absent -> recreated with defaults
    await service.update(AppSettingsPatch(timezone="Europe/Berlin"))
    assert str(await service.tz()) == "Europe/Berlin"  # memo reset by the write
    fresh = AppSettingsService(db_session)
    assert (await fresh.get()).timezone_confirmed is True


async def test_service_update_validates_when_called_directly(db_session: AsyncSession) -> None:
    service = AppSettingsService(db_session)
    patch = AppSettingsPatch.model_construct(timezone=None)  # bypass the API model's validators
    patch.__pydantic_fields_set__.add("timezone")
    with pytest.raises(DomainValidationError):
        await service.update(patch)
