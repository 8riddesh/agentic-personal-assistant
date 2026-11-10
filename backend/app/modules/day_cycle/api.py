"""Day-cycle HTTP surface (day_cycle spec §6). Mounted under /api/v1 by ``app.main`` behind ``current_user``."""

from __future__ import annotations

from datetime import date

from fastapi import APIRouter, Depends, Request, Response, status

from app.modules.core import Clock, get_clock
from app.modules.day_cycle.dependencies import get_day_service, remember_checked
from app.modules.day_cycle.schemas import CloseMode, CloseResultDTO, DayDTO, UnresolvedDTO
from app.modules.day_cycle.service import DayService

router = APIRouter(prefix="/days", tags=["days"])


@router.get("/current", response_model=DayDTO, summary="Get or open today's day (auto-closes a stale day)")
async def current_day(
    request: Request, service: DayService = Depends(get_day_service), clock: Clock = Depends(get_clock)
) -> DayDTO:
    dto = await service.current()
    remember_checked(request, service, clock)
    return dto


@router.get("/current/unresolved", response_model=UnresolvedDTO, summary="Tasks still planned (EOD sheet)")
async def unresolved(
    request: Request, service: DayService = Depends(get_day_service), clock: Clock = Depends(get_clock)
) -> UnresolvedDTO:
    tasks = await service.unresolved()
    remember_checked(request, service, clock)
    assert service.last_sync is not None
    return UnresolvedDTO(local_date=service.last_sync.today, tasks=tasks)


@router.post(
    "/current/close",
    response_model=CloseResultDTO,
    status_code=status.HTTP_202_ACCEPTED,
    summary="End of Day: 202 while reports build, 200 if already closed",
)
async def close_day(
    request: Request,
    response: Response,
    service: DayService = Depends(get_day_service),
    clock: Clock = Depends(get_clock),
) -> CloseResultDTO:
    result = await service.close(CloseMode.USER)
    remember_checked(request, service, clock)
    if result.already_closed:
        response.status_code = status.HTTP_200_OK
    return result


@router.get("/{local_date}", response_model=DayDTO, summary="Day summary")
async def get_day(
    local_date: date,
    request: Request,
    service: DayService = Depends(get_day_service),
    clock: Clock = Depends(get_clock),
) -> DayDTO:
    dto = await service.get(local_date)
    remember_checked(request, service, clock)
    return dto
