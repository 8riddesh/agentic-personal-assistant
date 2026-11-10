"""``POST /auth/login`` (public). Mounted under /api/v1 by ``app.main``."""

from __future__ import annotations

from fastapi import APIRouter, Depends

from app.modules.auth.schemas import LoginRequest, TokenDTO
from app.modules.auth.service import AuthService, get_auth_service
from app.modules.core import (
    AppSettingsPatch,
    AppSettingsService,
    DomainValidationError,
    get_app_settings_service,
    get_logger,
)

router = APIRouter(prefix="/auth", tags=["auth"])
logger = get_logger("app.auth")


@router.post("/login", response_model=TokenDTO, summary="Email + password -> JWT (public)")
async def login(
    body: LoginRequest,
    auth: AuthService = Depends(get_auth_service),
    app_settings: AppSettingsService = Depends(get_app_settings_service),
) -> TokenDTO:
    token = await auth.login(str(body.email), body.password)
    if body.timezone:
        await _bootstrap_timezone(app_settings, body.timezone)
    return token


async def _bootstrap_timezone(app_settings: AppSettingsService, timezone: str) -> None:
    """Device timezone on first login only; an invalid one is ignored and never fails the login (auth spec §7.2.8)."""
    if (await app_settings.get()).timezone_confirmed:
        return
    try:
        await app_settings.update(AppSettingsPatch(timezone=timezone))
    except (DomainValidationError, ValueError):
        logger.warning("login_timezone_ignored")
