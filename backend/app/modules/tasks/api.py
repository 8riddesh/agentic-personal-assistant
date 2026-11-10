"""Tasks HTTP surface (tasks spec §6). ``app.main`` mounts this router under /api/v1 with ``current_user`` and the
day-cycle ``ensure_current_day`` dependency attached."""

from __future__ import annotations

from datetime import date
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Response, status

from app.modules.tasks.schemas import (
    CheckResponse,
    CreateTaskRequest,
    CreateTaskResult,
    StatusChangeResult,
    StatusCommand,
    TaskDTO,
    TaskPatch,
    TemplateDTO,
    TemplatePatch,
)
from app.modules.tasks.service import TaskService, get_task_service

router = APIRouter(tags=["tasks"])


@router.post(
    "/tasks", response_model=CreateTaskResult, status_code=status.HTTP_201_CREATED, summary="Create a task"
)
async def create_task(
    body: CreateTaskRequest,
    response: Response,
    service: TaskService = Depends(get_task_service),
) -> CreateTaskResult:
    result = await service.create(body)
    if result.replayed:
        response.status_code = status.HTTP_200_OK  # idempotent replay of the same client_request_id
    response.headers["Location"] = f"/api/v1/tasks/{result.task.id}"
    return result


@router.get("/tasks", response_model=list[TaskDTO], summary="Tasks of a day (default: today)")
async def list_tasks(
    date_: date | None = Query(default=None, alias="date"),
    service: TaskService = Depends(get_task_service),
) -> list[TaskDTO]:
    return await service.day_plan(date_ or await service.today())


@router.get("/tasks/{task_id}", response_model=TaskDTO)
async def get_task(task_id: UUID, service: TaskService = Depends(get_task_service)) -> TaskDTO:
    return await service.get(task_id)


@router.patch("/tasks/{task_id}", response_model=TaskDTO, summary="Edit a task (scope this|future)")
async def patch_task(
    task_id: UUID, body: TaskPatch, service: TaskService = Depends(get_task_service)
) -> TaskDTO:
    return await service.update(task_id, body)


@router.post("/tasks/{task_id}/status", response_model=StatusChangeResult, summary="Change a task's status")
async def change_task_status(
    task_id: UUID, body: StatusCommand, service: TaskService = Depends(get_task_service)
) -> StatusChangeResult:
    return await service.change_status(task_id, body)


@router.post("/tasks/{task_id}/check-response", response_model=TaskDTO, summary="Completion-check answer")
async def task_check_response(
    task_id: UUID, body: CheckResponse, service: TaskService = Depends(get_task_service)
) -> TaskDTO:
    return await service.check_response(task_id, body)


@router.get("/templates", response_model=list[TemplateDTO], summary="Recurring templates")
async def list_templates(
    active: bool | None = None, service: TaskService = Depends(get_task_service)
) -> list[TemplateDTO]:
    return await service.list_templates(active)


@router.get("/templates/{template_id}", response_model=TemplateDTO)
async def get_template(template_id: UUID, service: TaskService = Depends(get_task_service)) -> TemplateDTO:
    return await service.get_template(template_id)


@router.patch("/templates/{template_id}", response_model=TemplateDTO)
async def patch_template(
    template_id: UUID, body: TemplatePatch, service: TaskService = Depends(get_task_service)
) -> TemplateDTO:
    return await service.update_template(template_id, body)


@router.delete(
    "/templates/{template_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Deactivate a template (soft delete)",
)
async def delete_template(
    template_id: UUID, cancel_planned: bool = False, service: TaskService = Depends(get_task_service)
) -> Response:
    await service.deactivate_template(template_id, cancel_planned)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
