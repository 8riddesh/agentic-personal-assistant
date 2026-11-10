"""AppSettingsService (core spec §7.4)."""

from __future__ import annotations

from zoneinfo import ZoneInfo

from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.core.db import SessionDep
from app.modules.core.errors import DomainValidationError
from app.modules.core.models import AppSettings
from app.modules.core.repository import AppSettingsRepository
from app.modules.core.schemas import AppSettingsDTO, AppSettingsPatch, validate_offsets, validate_timezone


class AppSettingsService:
    def __init__(self, session: AsyncSession) -> None:
        self._repo = AppSettingsRepository(session)
        self._tz: ZoneInfo | None = None

    @staticmethod
    def _dto(row: AppSettings) -> AppSettingsDTO:
        return AppSettingsDTO(
            timezone=row.timezone,
            timezone_confirmed=row.timezone_confirmed,
            reminder_offsets_min=sorted(row.reminder_offsets_min, reverse=True),
            report_email=row.report_email,
            week_start=row.week_start,
            updated_at=row.updated_at,
        )

    async def get(self) -> AppSettingsDTO:
        return self._dto(await self._repo.get_or_create())

    async def update(self, patch: AppSettingsPatch) -> AppSettingsDTO:
        row = await self._repo.get_or_create()
        fields = patch.model_dump(exclude_unset=True)
        try:  # re-validate: the service is also called directly (e.g. login), not only through the API model
            if "timezone" in fields:
                if fields["timezone"] is None:
                    raise ValueError("timezone cannot be null")
                row.timezone = validate_timezone(fields["timezone"])
                row.timezone_confirmed = True
                self._tz = None
            if "reminder_offsets_min" in fields:
                if fields["reminder_offsets_min"] is None:
                    raise ValueError("reminder_offsets_min cannot be null")
                row.reminder_offsets_min = validate_offsets(fields["reminder_offsets_min"])
            if "report_email" in fields:
                row.report_email = None if fields["report_email"] is None else str(fields["report_email"])
            if "week_start" in fields:
                if fields["week_start"] is None or not 1 <= fields["week_start"] <= 7:
                    raise ValueError("week_start must be 1..7")
                row.week_start = fields["week_start"]
        except ValueError as exc:
            raise DomainValidationError(str(exc)) from None
        await self._repo.flush()
        return self._dto(row)

    async def tz(self) -> ZoneInfo:
        if self._tz is None:
            self._tz = ZoneInfo((await self.get()).timezone)
        return self._tz


def get_app_settings_service(session: SessionDep) -> AppSettingsService:
    return AppSettingsService(session)
