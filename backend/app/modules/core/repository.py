"""``app_settings`` persistence (private to core)."""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.core.logs import get_logger
from app.modules.core.models import AppSettings

logger = get_logger("app.core.settings")


class AppSettingsRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get_or_create(self) -> AppSettings:
        """Defensive get-or-create: the migration inserts the row; if it vanished it is recreated with defaults.

        Race-free thanks to the ``singleton`` unique constraint: on ``IntegrityError`` re-select."""
        row = (await self._session.execute(select(AppSettings))).scalar_one_or_none()
        if row is not None:
            return row
        logger.warning("app_settings row missing; recreating with defaults")
        try:
            async with self._session.begin_nested():
                row = AppSettings()
                self._session.add(row)
                await self._session.flush()
            return row
        except IntegrityError:
            return (await self._session.execute(select(AppSettings))).scalar_one()

    async def flush(self) -> None:
        await self._session.flush()
