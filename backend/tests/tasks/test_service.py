"""TaskService integration tests (tasks spec §11 "Integration", TASKS-AC-01..17) on the test database."""

from __future__ import annotations

from datetime import date, time, timedelta
from uuid import uuid4

import pytest
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.core import ConflictError, DomainValidationError, FakeClock, NotFoundError
from app.modules.tasks import TaskDTO, TaskService
from app.modules.tasks.models import ActualEndSourceEnum, Task, TaskStatusEnum, TaskStatusEvent
from app.modules.tasks.repository import StatusEventRepository
from app.modules.tasks.schemas import (
    Cancelled,
    CantDo,
    CheckDone,
    CheckNotYet,
    Completed,
    Postponed,
    TaskPatch,
    TemplatePatch,
)
from tests.crypto.helpers import assert_no_plaintext
from tests.tasks.conftest import DAILY, TODAY, WEEKLY_MWF, FakePredictor, at, draft

TOMORROW = TODAY + timedelta(days=1)


async def _events(session: AsyncSession, task_id: object) -> list[tuple[str | None, str, str]]:
    rows = await StatusEventRepository(session).for_task(task_id)  # type: ignore[arg-type]
    return [
        ((e.from_status.value if e.from_status else None), e.to_status.value, e.source.value) for e in rows
    ]


# ------------------------------------------------------------------ create
async def test_create_one_time_anytime_task(tasks: TaskService, db_session: AsyncSession) -> None:
    result = await tasks.create(draft(title="  Read paper  ", notes="  ch. 3  "))
    task = result.task
    assert (task.title, task.notes, task.category) == ("Read paper", "ch. 3", "Health")
    assert (task.local_date, task.start_at, task.status) == (TODAY, None, "planned")
    assert task.is_recurring is False and result.template is None and result.replayed is False
    assert await _events(db_session, task.id) == [(None, "planned", "app")]


async def test_create_prediction_stored(tasks: TaskService, fake_predictor: FakePredictor) -> None:
    """TASKS-AC-01: stored with local_date, status planned, creation event and the predictor's end time."""
    task = (await tasks.create(draft(start_at="2026-11-08T18:00:00+01:00", estimate_min=60))).task
    assert task.local_date == TODAY
    assert task.start_at == at("18:00")
    assert task.predicted_end_at == at("19:10")
    assert task.prediction_method == "category_p60"
    assert fake_predictor.requests[0].estimate_min == 60 and fake_predictor.requests[0].category == "Health"


async def test_create_survives_predictor_failure(tasks: TaskService, fake_predictor: FakePredictor) -> None:
    """TASKS-AC-16."""
    fake_predictor.fail = True
    task = (await tasks.create(draft(start_at=at("18:00")))).task
    assert task.status == "planned"
    assert (task.predicted_end_at, task.prediction_method) == (None, None)


async def test_create_without_predictor_leaves_prediction_empty(
    db_session: AsyncSession, fake_clock: FakeClock, tz_berlin: None
) -> None:
    from app.modules.core import AppSettingsService

    service = TaskService(db_session, AppSettingsService(db_session), fake_clock)
    task = (await service.create(draft(start_at=at("18:00")))).task
    assert task.predicted_end_at is None


def test_create_requires_is_recurring() -> None:
    """TASKS-AC-02 (model level; the API test checks the 422)."""
    from pydantic import ValidationError

    from app.modules.tasks.schemas import CreateTaskRequest

    with pytest.raises(ValidationError):
        CreateTaskRequest.model_validate({"title": "x"})
    with pytest.raises(ValidationError):
        draft(is_recurring=True)  # recurrence missing
    with pytest.raises(ValidationError):
        draft(is_recurring=False, recurrence={"freq": "daily"})


async def test_create_rejects_start_not_on_local_date(tasks: TaskService) -> None:
    """TASKS-AC-04."""
    with pytest.raises(DomainValidationError) as info:
        await tasks.create(draft(start_at=at("18:00", TOMORROW), local_date=TODAY))
    assert info.value.code == "task.start_not_on_local_date"


@pytest.mark.parametrize("offset_days", [-1, 366])
async def test_create_rejects_dates_out_of_range(tasks: TaskService, offset_days: int) -> None:
    with pytest.raises(DomainValidationError) as info:
        await tasks.create(draft(local_date=TODAY + timedelta(days=offset_days)))
    assert info.value.code == "task.date_out_of_range"


async def test_create_derives_local_date_from_start_in_timezone(tasks: TaskService) -> None:
    # 23:30Z on Nov 8 is already Nov 9 in Berlin
    task = (await tasks.create(draft(start_at="2026-11-08T23:30:00+00:00"))).task
    assert task.local_date == TOMORROW


async def test_create_accepts_started_task_in_the_past(tasks: TaskService) -> None:
    assert (await tasks.create(draft(start_at=at("06:00")))).task.status == "planned"


async def test_create_links_assessment_and_override(tasks: TaskService) -> None:
    """TASKS-AC-05."""
    assessment = uuid4()
    task = (await tasks.create(draft(assessment_id=assessment, overridden=True))).task
    assert (task.feasibility_id, task.feasibility_overridden) == (assessment, True)


async def test_create_override_without_assessment_422(tasks: TaskService) -> None:
    with pytest.raises(DomainValidationError) as info:
        await tasks.create(draft(overridden=True))
    assert info.value.code == "task.override_requires_assessment"


async def test_create_idempotent_client_request_id(tasks: TaskService, db_session: AsyncSession) -> None:
    """TASKS-AC-17."""
    request_id = uuid4()
    first = await tasks.create(draft(client_request_id=request_id))
    second = await tasks.create(draft(client_request_id=request_id))
    assert (first.replayed, second.replayed) == (False, True)
    assert first.task.id == second.task.id
    assert (await db_session.execute(select(func.count()).select_from(Task))).scalar_one() == 1


async def test_create_invalid_category_422(tasks: TaskService) -> None:
    with pytest.raises(DomainValidationError) as info:
        await tasks.create(draft(category="bad;category"))
    assert info.value.code == "task.invalid_category"


async def test_create_recurring_creates_template_and_links(tasks: TaskService) -> None:
    result = await tasks.create(
        draft(
            start_at=at("18:00"),
            estimate_min=60,
            is_recurring=True,
            recurrence=WEEKLY_MWF.model_dump(),
            category="health",
        )
    )
    task, template = result.task, result.template
    assert template is not None
    assert (template.start_local, template.starts_on, template.active) == (time(18, 0), TODAY, True)
    assert template.default_estimate_min == 60 and template.recurrence.freq == "weekly"
    assert (task.template_id, task.origin_template_id, task.is_recurring) == (template.id, template.id, True)
    # even though today (Sunday) does not match Mon/Wed/Fri it is the series' first instance
    assert task.local_date == TODAY


# ------------------------------------------------------------------ status lifecycle
async def test_complete_manual_sets_actual_end(tasks: TaskService, db_session: AsyncSession) -> None:
    task = (await tasks.create(draft(start_at=at("09:00")))).task
    result = await tasks.change_status(task.id, Completed(status="completed", finished_at=at("09:45")))
    done = result.task
    assert done.status == "completed" and done.actual_end_at == at("09:45")
    assert done.actual_end_source == "manual" and result.created_task is None
    assert await _events(db_session, task.id) == [(None, "planned", "app"), ("planned", "completed", "app")]


async def test_complete_eod_source(tasks: TaskService) -> None:
    task = (await tasks.create(draft(start_at=at("09:00")))).task
    done = (await tasks.change_status(task.id, Completed(status="completed", source="eod"))).task
    assert done.actual_end_source == "eod_resolution"
    assert done.actual_end_at == at("10:00")  # default: now


async def test_complete_anytime_task_defaults_to_now(tasks: TaskService) -> None:
    task = (await tasks.create(draft())).task
    done = (await tasks.change_status(task.id, Completed(status="completed"))).task
    assert done.status == "completed" and done.actual_end_at == at("10:00")


@pytest.mark.parametrize(
    ("finished", "code"),
    [
        ("08:30", "task.finished_before_start"),  # start is 09:00 local
        ("09:00", "task.finished_before_start"),  # equal to start
        ("10:05", "task.finished_in_future"),  # now is 10:00 local (+2 min skew allowed)
    ],
)
async def test_finished_at_validation_422(tasks: TaskService, finished: str, code: str) -> None:
    task = (await tasks.create(draft(start_at=at("09:00")))).task
    with pytest.raises(DomainValidationError) as info:
        await tasks.change_status(task.id, Completed(status="completed", finished_at=at(finished)))
    assert info.value.code == code


async def test_finished_before_the_tasks_day_422(tasks: TaskService) -> None:
    task = (await tasks.create(draft())).task  # anytime: finished_at must not precede local midnight
    with pytest.raises(DomainValidationError) as info:
        await tasks.change_status(
            task.id, Completed(status="completed", finished_at=at("23:59", TODAY - timedelta(days=1)))
        )
    assert info.value.code == "task.finished_before_day"


async def test_postpone_creates_linked_copy(tasks: TaskService, db_session: AsyncSession) -> None:
    """TASKS-AC-06."""
    original = (await tasks.create(draft(start_at=at("18:00"), estimate_min=45, notes="n"))).task
    result = await tasks.change_status(
        original.id, Postponed(status="postponed", new_start_at=at("09:00", TOMORROW), source="eod")
    )
    moved, copy = result.task, result.created_task
    assert copy is not None
    assert moved.status == "postponed" and moved.postponed_to_task_id == copy.id
    assert (copy.status, copy.local_date, copy.start_at) == ("planned", TOMORROW, at("09:00", TOMORROW))
    assert (copy.title, copy.notes, copy.category, copy.estimate_min) == ("Gym", "n", "Health", 45)
    assert copy.template_id is None and copy.feasibility_id is None
    assert (await tasks.get(copy.id)).postponed_from_task_id == original.id
    assert await _events(db_session, original.id) == [
        (None, "planned", "app"),
        ("planned", "postponed", "eod"),
    ]
    assert await _events(db_session, copy.id) == [(None, "planned", "eod")]


async def test_postpone_recurring_occurrence_no_unique_clash(tasks: TaskService) -> None:
    """TASKS-AC-07: the copy carries origin_template_id but template_id NULL, so it coexists with that day's own
    occurrence."""
    first = (
        await tasks.create(draft(start_at=at("18:00"), is_recurring=True, recurrence=DAILY.model_dump()))
    ).task
    assert await tasks.materialize_templates(TOMORROW) == 1
    result = await tasks.change_status(
        first.id, Postponed(status="postponed", new_start_at=at("20:00", TOMORROW))
    )
    assert result.created_task is not None
    day = await tasks.day_plan(TOMORROW)
    assert len(day) == 2
    assert {t.template_id is None for t in day} == {True, False}
    assert all(t.origin_template_id == first.origin_template_id for t in day)


async def test_postpone_anytime_to_date(tasks: TaskService) -> None:
    task = (await tasks.create(draft(start_at=at("18:00")))).task
    result = await tasks.change_status(task.id, Postponed(status="postponed", new_local_date=TOMORROW))
    assert result.created_task is not None
    assert (result.created_task.local_date, result.created_task.start_at) == (TOMORROW, None)


@pytest.mark.parametrize(
    ("command", "code"),
    [
        (Postponed(status="postponed"), "task.postpone_target_missing"),
        (
            Postponed(status="postponed", new_start_at=at("09:00", TOMORROW), new_local_date=TODAY),
            "task.postpone_date_mismatch",
        ),
        (
            Postponed(status="postponed", new_start_at=at("09:30")),
            "task.postpone_in_past",
        ),  # now is 10:00 local
        (
            Postponed(status="postponed", new_start_at=at("18:00")),
            "task.postpone_noop",
        ),  # same as the current start
        (Postponed(status="postponed", new_local_date=TODAY - timedelta(days=1)), "task.date_out_of_range"),
    ],
)
async def test_postpone_validation(tasks: TaskService, command: Postponed, code: str) -> None:
    task = (await tasks.create(draft(start_at=at("18:00")))).task
    with pytest.raises(DomainValidationError) as info:
        await tasks.change_status(task.id, command)
    assert info.value.code == code


async def test_cant_do_requires_reason_and_encrypts_it(tasks: TaskService, db_session: AsyncSession) -> None:
    """TASKS-AC-08."""
    from pydantic import ValidationError

    with pytest.raises(ValidationError):
        CantDo(status="cant_do", reason="   ")
    task = (await tasks.create(draft())).task
    done = (await tasks.change_status(task.id, CantDo(status="cant_do", reason="SECRET-REASON-123"))).task
    assert (done.status, done.status_reason) == ("cant_do", "SECRET-REASON-123")
    await db_session.flush()
    await assert_no_plaintext(db_session, "task", "status_reason", "SECRET-REASON-123")
    await assert_no_plaintext(db_session, "task_status_event", "reason", "SECRET-REASON-123")


async def test_cancel_with_and_without_reason(tasks: TaskService) -> None:
    a = (await tasks.create(draft(title="a"))).task
    b = (await tasks.create(draft(title="b"))).task
    assert (await tasks.change_status(a.id, Cancelled(status="cancelled"))).task.status_reason is None
    assert (
        await tasks.change_status(b.id, Cancelled(status="cancelled", reason="  no time "))
    ).task.status_reason == "no time"


async def test_terminal_transition_409(tasks: TaskService) -> None:
    """TASKS-AC-12."""
    task = (await tasks.create(draft(start_at=at("09:00")))).task
    await tasks.change_status(task.id, Completed(status="completed", finished_at=at("09:30")))
    with pytest.raises(ConflictError) as info:
        await tasks.change_status(task.id, Cancelled(status="cancelled"))
    assert info.value.code == "task.invalid_transition"
    with pytest.raises(ConflictError):  # same-status requests are conflicts too
        await tasks.change_status(task.id, Completed(status="completed"))


async def test_missed_to_completed_allowed(tasks: TaskService) -> None:
    task = (await tasks.create(draft(start_at=at("09:00")))).task
    assert await tasks.mark_unresolved_missed(TODAY) == 1
    done = (await tasks.change_status(task.id, Completed(status="completed", finished_at=at("09:30")))).task
    assert done.status == "completed"


async def test_missed_to_cancelled_not_allowed(tasks: TaskService) -> None:
    task = (await tasks.create(draft())).task
    await tasks.mark_unresolved_missed(TODAY)
    with pytest.raises(ConflictError):
        await tasks.change_status(task.id, Cancelled(status="cancelled"))


async def test_unknown_task_404(tasks: TaskService) -> None:
    with pytest.raises(NotFoundError):
        await tasks.get(uuid4())
    with pytest.raises(NotFoundError):
        await tasks.change_status(uuid4(), Cancelled(status="cancelled"))


# ------------------------------------------------------------------ completion check
async def test_check_done_completes_with_notification_source(
    tasks: TaskService, db_session: AsyncSession
) -> None:
    """TASKS-AC-09."""
    task = (await tasks.create(draft(start_at=at("09:00")))).task
    done = await tasks.check_response(task.id, CheckDone(response="done", finished_at=at("09:50")))
    assert done.status == "completed" and done.actual_end_at == at("09:50")
    assert done.actual_end_source == "notification_action"
    assert (done.check_response, done.check_responded_at) == ("done", at("10:00"))
    assert (await _events(db_session, task.id))[-1] == ("planned", "completed", "notification")


async def test_check_done_replay_idempotent(tasks: TaskService, db_session: AsyncSession) -> None:
    task = (await tasks.create(draft(start_at=at("09:00")))).task
    first = await tasks.check_response(task.id, CheckDone(response="done", finished_at=at("09:50")))
    replay = await tasks.check_response(task.id, CheckDone(response="done", finished_at=at("09:55")))
    assert replay.actual_end_at == first.actual_end_at == at("09:50")  # unchanged
    assert len(await _events(db_session, task.id)) == 2


async def test_check_done_on_task_completed_elsewhere_only_records_answer(tasks: TaskService) -> None:
    task = (await tasks.create(draft(start_at=at("09:00")))).task
    await tasks.change_status(task.id, Completed(status="completed", finished_at=at("09:30")))
    result = await tasks.check_response(task.id, CheckDone(response="done", finished_at=at("09:50")))
    assert result.check_response == "done"
    assert (result.actual_end_at, result.actual_end_source) == (at("09:30"), "manual")  # untouched


async def test_check_done_after_midnight_replay_for_missed_task(tasks: TaskService) -> None:
    task = (await tasks.create(draft(start_at=at("09:00")))).task
    await tasks.mark_unresolved_missed(TODAY)
    done = await tasks.check_response(task.id, CheckDone(response="done", finished_at=at("09:40")))
    assert (done.status, done.actual_end_source) == ("completed", "notification_action")


async def test_check_done_on_cancelled_409(tasks: TaskService) -> None:
    task = (await tasks.create(draft(start_at=at("09:00")))).task
    await tasks.change_status(task.id, Cancelled(status="cancelled"))
    with pytest.raises(ConflictError) as info:
        await tasks.check_response(task.id, CheckDone(response="done", finished_at=at("09:40")))
    assert info.value.code == "task.invalid_transition"


async def test_check_not_yet_then_done(tasks: TaskService) -> None:
    """TASKS-AC-10: check_not_yet_at stays set when the task is later completed."""
    task = (await tasks.create(draft(start_at=at("09:00")))).task
    waiting = await tasks.check_response(task.id, CheckNotYet(response="not_yet", eta_min=30))
    assert (waiting.status, waiting.check_response, waiting.check_eta_min) == ("planned", "not_yet", 30)
    assert waiting.check_not_yet_at == at("10:00")
    replay = await tasks.check_response(task.id, CheckNotYet(response="not_yet", eta_min=30))
    assert replay.check_not_yet_at == waiting.check_not_yet_at
    done = await tasks.check_response(task.id, CheckDone(response="done", finished_at=at("10:00")))
    assert done.status == "completed" and done.check_not_yet_at == waiting.check_not_yet_at


async def test_check_not_yet_changed_eta_keeps_first_not_yet_time(
    tasks: TaskService, fake_clock: FakeClock
) -> None:
    task = (await tasks.create(draft(start_at=at("09:00")))).task
    first = await tasks.check_response(task.id, CheckNotYet(response="not_yet", eta_min=15))
    fake_clock.advance(timedelta(minutes=20))
    second = await tasks.check_response(task.id, CheckNotYet(response="not_yet", eta_min=30))
    assert second.check_eta_min == 30 and second.check_not_yet_at == first.check_not_yet_at
    assert second.check_responded_at > first.check_responded_at  # type: ignore[operator]


async def test_check_not_yet_on_non_planned_409(tasks: TaskService) -> None:
    task = (await tasks.create(draft(start_at=at("09:00")))).task
    await tasks.change_status(task.id, Cancelled(status="cancelled"))
    with pytest.raises(ConflictError):
        await tasks.check_response(task.id, CheckNotYet(response="not_yet"))


async def test_check_on_anytime_task_409(tasks: TaskService) -> None:
    task = (await tasks.create(draft())).task
    with pytest.raises(ConflictError) as info:
        await tasks.check_response(task.id, CheckNotYet(response="not_yet"))
    assert info.value.code == "task.no_check"


# ------------------------------------------------------------------ edit
async def test_patch_this_scope_leaves_template(tasks: TaskService) -> None:
    """TASKS-AC-13 (scope this)."""
    created = await tasks.create(
        draft(start_at=at("18:00"), is_recurring=True, recurrence=DAILY.model_dump())
    )
    assert created.template is not None
    updated = await tasks.update(created.task.id, TaskPatch(title="Gym (heavy)", estimate_min=90))
    assert (updated.title, updated.estimate_min) == ("Gym (heavy)", 90)
    template = await tasks.get_template(created.template.id)
    assert (template.title, template.default_estimate_min) == ("Gym", None)


async def test_patch_future_scope_updates_template(tasks: TaskService) -> None:
    """TASKS-AC-13 (scope future)."""
    created = await tasks.create(
        draft(start_at=at("18:00"), is_recurring=True, recurrence=DAILY.model_dump())
    )
    assert created.template is not None
    await tasks.update(
        created.task.id,
        TaskPatch(
            title="Run",
            notes="park",
            category="personal",
            estimate_min=30,
            start_at=at("19:30"),
            scope="future",
        ),
    )
    template = await tasks.get_template(created.template.id)
    assert (template.title, template.notes, template.category) == ("Run", "park", "Personal")
    assert (template.default_estimate_min, template.start_local) == (30, time(19, 30))
    assert (await tasks.get(created.task.id)).title == "Run"
    # a later occurrence picks the template values up
    await tasks.materialize_templates(TOMORROW)
    tomorrow = (await tasks.day_plan(TOMORROW))[0]
    assert (tomorrow.title, tomorrow.start_at) == ("Run", at("19:30", TOMORROW))


async def test_patch_future_scope_on_one_time_task_422(tasks: TaskService) -> None:
    task = (await tasks.create(draft())).task
    with pytest.raises(DomainValidationError) as info:
        await tasks.update(task.id, TaskPatch(title="x", scope="future"))
    assert info.value.code == "task.not_recurring"


async def test_patch_start_off_date_422(tasks: TaskService) -> None:
    task = (await tasks.create(draft(start_at=at("18:00")))).task
    with pytest.raises(DomainValidationError) as info:
        await tasks.update(task.id, TaskPatch(start_at=at("09:00", TOMORROW)))
    assert info.value.code == "task.start_not_on_local_date"


async def test_patch_start_resets_check_and_repredicts(
    tasks: TaskService, fake_predictor: FakePredictor
) -> None:
    task = (await tasks.create(draft(start_at=at("18:00")))).task
    await tasks.check_response(task.id, CheckNotYet(response="not_yet", eta_min=15))
    calls = len(fake_predictor.requests)
    moved = await tasks.update(task.id, TaskPatch(start_at=at("20:00")))
    assert (moved.check_response, moved.check_responded_at, moved.check_eta_min, moved.check_not_yet_at) == (
        None,
    ) * 4
    assert moved.predicted_end_at == at("21:10")
    assert len(fake_predictor.requests) == calls + 1


async def test_patch_null_clears_optional_fields(tasks: TaskService) -> None:
    task = (await tasks.create(draft(start_at=at("18:00"), notes="n", estimate_min=30))).task
    cleared = await tasks.update(
        task.id, TaskPatch.model_validate({"notes": None, "start_at": None, "estimate_min": None})
    )
    assert (cleared.notes, cleared.start_at, cleared.estimate_min) == (None, None, None)


async def test_patch_only_notes_after_completion(tasks: TaskService) -> None:
    task = (await tasks.create(draft(start_at=at("09:00")))).task
    await tasks.change_status(task.id, Completed(status="completed", finished_at=at("09:30")))
    assert (await tasks.update(task.id, TaskPatch(notes="felt great"))).notes == "felt great"
    with pytest.raises(ConflictError) as info:
        await tasks.update(task.id, TaskPatch(title="renamed"))
    assert info.value.code == "task.not_editable"


async def test_patch_without_relevant_change_does_not_repredict(
    tasks: TaskService, fake_predictor: FakePredictor
) -> None:
    task = (await tasks.create(draft(start_at=at("18:00"), category="Work"))).task
    calls = len(fake_predictor.requests)
    await tasks.update(task.id, TaskPatch(title="Renamed", category="work"))
    assert len(fake_predictor.requests) == calls


# ------------------------------------------------------------------ recurrence / materialization
async def test_materialize_weekly_only_on_matching_days(tasks: TaskService) -> None:
    """TASKS-AC-03: created on Sunday for [Mon, Wed, Fri]; Tue has none, Wed has one, re-running adds none."""
    await tasks.create(draft(start_at=at("18:00"), is_recurring=True, recurrence=WEEKLY_MWF.model_dump()))
    assert await tasks.materialize_templates(date(2026, 11, 10)) == 0  # Tuesday
    assert await tasks.materialize_templates(date(2026, 11, 11)) == 1  # Wednesday
    assert await tasks.materialize_templates(date(2026, 11, 11)) == 0  # idempotent
    wed = await tasks.day_plan(date(2026, 11, 11))
    assert len(wed) == 1
    assert (wed[0].created_via, wed[0].start_at, wed[0].is_recurring) == (
        "template",
        at("18:00", date(2026, 11, 11)),
        True,
    )


async def test_materialize_idempotent_and_records_system_event(
    tasks: TaskService, db_session: AsyncSession
) -> None:
    await tasks.create(draft(is_recurring=True, recurrence=DAILY.model_dump()))
    assert await tasks.materialize_templates(TOMORROW) == 1
    assert await tasks.materialize_templates(TOMORROW) == 0
    occurrence = (await tasks.day_plan(TOMORROW))[0]
    assert occurrence.start_at is None  # anytime template -> anytime occurrence
    assert await _events(db_session, occurrence.id) == [(None, "planned", "system")]


async def test_materialize_respects_starts_on_and_active(tasks: TaskService) -> None:
    """TASKS-AC-15 (second half)."""
    created = await tasks.create(draft(is_recurring=True, recurrence=DAILY.model_dump()))
    assert created.template is not None
    assert await tasks.materialize_templates(TODAY - timedelta(days=1)) == 0  # before starts_on
    assert await tasks.materialize_templates(TOMORROW) == 1
    await tasks.update_template(created.template.id, TemplatePatch(active=False))
    assert await tasks.materialize_templates(TOMORROW + timedelta(days=1)) == 0
    await tasks.update_template(created.template.id, TemplatePatch(active=True))
    assert await tasks.materialize_templates(TOMORROW + timedelta(days=1)) == 1  # re-enabled, no back-fill


async def test_materialize_does_not_recreate_cancelled_occurrence(tasks: TaskService) -> None:
    created = await tasks.create(draft(is_recurring=True, recurrence=DAILY.model_dump()))
    await tasks.materialize_templates(TOMORROW)
    occurrence = (await tasks.day_plan(TOMORROW))[0]
    await tasks.change_status(occurrence.id, Cancelled(status="cancelled"))
    assert created.template is not None
    assert await tasks.materialize_templates(TOMORROW) == 0
    assert [t.status for t in await tasks.day_plan(TOMORROW)] == ["cancelled"]


async def test_materialize_dst_gap_start(tasks: TaskService) -> None:
    created = await tasks.create(draft(is_recurring=True, recurrence=DAILY.model_dump()))
    assert created.template is not None
    await tasks.update_template(created.template.id, TemplatePatch(start_local=time(2, 30)))
    spring = date(2027, 3, 28)  # Berlin springs forward 02:00 -> 03:00
    assert await tasks.materialize_templates(spring) == 1
    start = (await tasks.day_plan(spring))[0].start_at
    assert start is not None
    assert (start.hour, start.minute) == (1, 30)  # 03:30 CEST == 01:30Z


async def test_deactivate_template_cancel_planned(tasks: TaskService) -> None:
    """TASKS-AC-15."""
    created = await tasks.create(
        draft(start_at=at("18:00"), is_recurring=True, recurrence=DAILY.model_dump())
    )
    assert created.template is not None
    await tasks.materialize_templates(TOMORROW)
    await tasks.deactivate_template(created.template.id, cancel_planned=True)
    assert [t.status for t in await tasks.day_plan(TODAY)] == ["cancelled"]
    assert [t.status for t in await tasks.day_plan(TOMORROW)] == ["cancelled"]
    assert (await tasks.get_template(created.template.id)).active is False  # soft delete: row stays
    assert await tasks.materialize_templates(TOMORROW + timedelta(days=1)) == 0
    await tasks.deactivate_template(created.template.id, cancel_planned=True)  # repeated call is a no-op
    with pytest.raises(NotFoundError):
        await tasks.deactivate_template(uuid4(), cancel_planned=False)


async def test_deactivate_without_cancel_keeps_planned_tasks(tasks: TaskService) -> None:
    created = await tasks.create(draft(is_recurring=True, recurrence=DAILY.model_dump()))
    assert created.template is not None
    await tasks.deactivate_template(created.template.id, cancel_planned=False)
    assert [t.status for t in await tasks.day_plan(TODAY)] == ["planned"]


async def test_template_listing_and_patch(tasks: TaskService) -> None:
    created = await tasks.create(draft(is_recurring=True, recurrence=DAILY.model_dump()))
    assert created.template is not None
    assert len(await tasks.list_templates(None)) == 1
    assert len(await tasks.list_templates(False)) == 0
    patched = await tasks.update_template(
        created.template.id, TemplatePatch(recurrence=WEEKLY_MWF, title="New", notes=None)
    )
    assert patched.recurrence.freq == "weekly" and patched.title == "New"
    with pytest.raises(NotFoundError):
        await tasks.get_template(uuid4())


# ------------------------------------------------------------------ unresolved / missed
async def test_mark_unresolved_missed_idempotent_with_events(
    tasks: TaskService, db_session: AsyncSession
) -> None:
    """TASKS-AC-11."""
    open_a = (await tasks.create(draft(title="a"))).task
    open_b = (await tasks.create(draft(title="b", start_at=at("18:00")))).task
    done = (await tasks.create(draft(title="c", start_at=at("09:00")))).task
    await tasks.change_status(done.id, Completed(status="completed", finished_at=at("09:30")))
    assert {t.id for t in await tasks.unresolved(TODAY)} == {open_a.id, open_b.id}
    assert await tasks.mark_unresolved_missed(TODAY) == 2
    assert await tasks.mark_unresolved_missed(TODAY) == 0
    assert (await tasks.get(open_a.id)).status == "missed" and (
        await tasks.get(done.id)
    ).status == "completed"
    assert (await _events(db_session, open_a.id))[-1] == ("planned", "missed", "system")
    assert await tasks.unresolved(TODAY) == []


# ------------------------------------------------------------------ history (§7.7)
async def _complete(
    tasks: TaskService, *, start: str = "08:00", end: str = "09:00", source: str = "app", **kw: object
) -> TaskDTO:
    task = (await tasks.create(draft(start_at=at(start), **kw))).task
    cmd = Completed.model_validate({"status": "completed", "finished_at": at(end), "source": source})
    return (await tasks.change_status(task.id, cmd)).task


async def test_history_labelling_rules(tasks: TaskService) -> None:
    """TASKS-AC-14."""
    good = await _complete(tasks, title="good", start="08:00", end="09:00")
    await _complete(tasks, title="eod", source="eod")  # excluded: eod_resolution
    short = (await tasks.create(draft(title="short", start_at=at("08:00")))).task
    await tasks.change_status(
        short.id, Completed(status="completed", finished_at=at("08:00") + timedelta(seconds=30))
    )  # excluded: duration < 1 minute
    anytime = (await tasks.create(draft(title="anytime"))).task
    await tasks.change_status(anytime.id, Completed(status="completed"))  # no start_at -> excluded
    cancelled = (await tasks.create(draft(title="cancelled", start_at=at("08:30")))).task
    await tasks.change_status(cancelled.id, Cancelled(status="cancelled"))  # not completed -> excluded
    outcomes = await tasks.history()
    assert [o.task_id for o in outcomes] == [good.id]
    outcome = outcomes[0]
    assert outcome.duration_min == 60.0 and outcome.actual_end_source == "manual"
    assert (outcome.weekday, outcome.start_minute_local, outcome.check_not_yet) == (6, 8 * 60, False)


async def test_history_includes_notification_actions_and_not_yet_flag(tasks: TaskService) -> None:
    task = (await tasks.create(draft(start_at=at("08:00")))).task
    await tasks.check_response(task.id, CheckNotYet(response="not_yet"))
    await tasks.check_response(task.id, CheckDone(response="done", finished_at=at("09:20")))
    (outcome,) = await tasks.history()
    assert (outcome.actual_end_source, outcome.check_not_yet, outcome.duration_min) == (
        "notification_action",
        True,
        80.0,
    )


async def test_history_filters(tasks: TaskService) -> None:
    run = await tasks.create(
        draft(
            title="Run",
            category="health",
            start_at=at("07:00"),
            is_recurring=True,
            recurrence=DAILY.model_dump(),
        )
    )
    assert run.template is not None
    await tasks.change_status(run.task.id, Completed(status="completed", finished_at=at("07:50")))
    work = (await tasks.create(draft(title="Write", category="work", start_at=at("08:00")))).task
    await tasks.change_status(work.id, Completed(status="completed", finished_at=at("09:00")))
    assert {o.category for o in await tasks.history()} == {"Health", "Work"}
    assert [o.task_id for o in await tasks.history(category="WORK")] == [work.id]
    assert [o.task_id for o in await tasks.history(template_id=run.template.id)] == [run.task.id]
    assert await tasks.history(since=TOMORROW) == []
    assert len(await tasks.history(since=TODAY)) == 2


async def test_history_template_includes_postponed_copies(tasks: TaskService) -> None:
    created = await tasks.create(
        draft(start_at=at("18:00"), is_recurring=True, recurrence=DAILY.model_dump())
    )
    assert created.template is not None
    moved = await tasks.change_status(
        created.task.id, Postponed(status="postponed", new_start_at=at("08:00", TOMORROW))
    )
    assert moved.created_task is not None
    # Pretend tomorrow has arrived and the copy was finished (the service only accepts "now"-ish finish times).
    row = await tasks._tasks.get(moved.created_task.id)
    assert row is not None
    row.status = TaskStatusEnum.COMPLETED
    row.actual_end_at = at("09:00", TOMORROW)
    row.actual_end_source = ActualEndSourceEnum.MANUAL
    await tasks._tasks.flush()
    outcomes = await tasks.history(template_id=created.template.id)
    assert [o.task_id for o in outcomes] == [moved.created_task.id]
    assert outcomes[0].template_id == created.template.id  # reported as the series (origin) id


# ------------------------------------------------------------------ ordering / ranges
async def test_day_plan_orders_by_start_then_creation_with_anytime_last(tasks: TaskService) -> None:
    anytime = (await tasks.create(draft(title="anytime"))).task
    late = (await tasks.create(draft(title="late", start_at=at("20:00")))).task
    early = (await tasks.create(draft(title="early", start_at=at("08:00")))).task
    assert [t.id for t in await tasks.day_plan(TODAY)] == [early.id, late.id, anytime.id]


async def test_tasks_in_range_inclusive(tasks: TaskService) -> None:
    today_task = (await tasks.create(draft(title="t"))).task
    tomorrow_task = (await tasks.create(draft(title="m", local_date=TOMORROW))).task
    later = (await tasks.create(draft(title="l", local_date=TOMORROW + timedelta(days=3)))).task
    ids = [t.id for t in await tasks.tasks_in_range(TODAY, TOMORROW)]
    assert ids == [today_task.id, tomorrow_task.id]
    assert later.id not in ids


# ------------------------------------------------------------------ encryption / audit
async def test_encrypted_columns_raw_rows_have_no_plaintext(
    tasks: TaskService, db_session: AsyncSession
) -> None:
    sentinel = "PLAINTEXT-SENTINEL-4f1c"
    created = await tasks.create(
        draft(
            title=f"title {sentinel}",
            notes=f"notes {sentinel}",
            is_recurring=True,
            recurrence=DAILY.model_dump(),
        )
    )
    await tasks.change_status(created.task.id, Cancelled(status="cancelled", reason=f"why {sentinel}"))
    await db_session.flush()
    for table, column in (
        ("task", "title"),
        ("task", "notes"),
        ("task", "status_reason"),
        ("task_template", "title"),
        ("task_template", "notes"),
        ("task_status_event", "reason"),
    ):
        await assert_no_plaintext(db_session, table, column, sentinel)
    assert (await tasks.get(created.task.id)).title == f"title {sentinel}"


async def test_status_events_append_only(tasks: TaskService, db_session: AsyncSession) -> None:
    for forbidden in ("update", "delete", "remove", "set"):
        assert not hasattr(StatusEventRepository, forbidden)
    task = (await tasks.create(draft(start_at=at("09:00")))).task
    await tasks.change_status(task.id, Completed(status="completed", finished_at=at("09:30")))
    assert (await db_session.execute(select(func.count()).select_from(TaskStatusEvent))).scalar_one() == 2
