"""HTTP surface of core: ``GET /health`` (public, root) and ``/settings`` (mounted under /api/v1 behind auth)."""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse

from app.modules.core.clock import Clock, get_clock
from app.modules.core.config import Settings, get_settings
from app.modules.core.db import db_ping
from app.modules.core.schemas import AppSettingsDTO, AppSettingsPatch, HealthDTO
from app.modules.core.service import AppSettingsService, get_app_settings_service

health_router = APIRouter(tags=["health"])
settings_router = APIRouter(prefix="/settings", tags=["settings"])


@health_router.get(
    "/health",
    response_model=HealthDTO,
    responses={503: {"model": HealthDTO, "description": "Database unreachable"}},
    summary="Liveness + DB ping (public)",
)
async def health(
    request: Request,
    settings: Settings = Depends(get_settings),
    clock: Clock = Depends(get_clock),
) -> HealthDTO | JSONResponse:
    db_ok = await db_ping(request.app.state.engine)
    dto = HealthDTO(
        status="ok" if db_ok else "degraded",
        db="ok" if db_ok else "unavailable",
        env=settings.env,
        version=settings.version,
        time=clock.now_utc(),
    )
    if db_ok:
        return dto
    return JSONResponse(status_code=503, content=dto.model_dump(mode="json"))


@settings_router.get("", response_model=AppSettingsDTO, summary="Timezone, reminder offsets, report email")
async def get_settings_endpoint(
    service: AppSettingsService = Depends(get_app_settings_service),
) -> AppSettingsDTO:
    return await service.get()


@settings_router.patch("", response_model=AppSettingsDTO, summary="Partially update settings")
async def patch_settings_endpoint(
    patch: AppSettingsPatch,
    service: AppSettingsService = Depends(get_app_settings_service),
) -> AppSettingsDTO:
    return await service.update(patch)
