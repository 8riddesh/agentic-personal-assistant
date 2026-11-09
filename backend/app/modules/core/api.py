"""HTTP surface of core. M0: ``GET /health``. (``/settings`` arrives with M1.)"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse

from app.modules.core.clock import Clock, get_clock
from app.modules.core.config import Settings, get_settings
from app.modules.core.db import db_ping
from app.modules.core.schemas import HealthDTO

health_router = APIRouter(tags=["health"])


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
