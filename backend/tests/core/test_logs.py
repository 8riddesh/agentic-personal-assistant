from __future__ import annotations

import io
import json
import logging

import pytest
from fastapi import FastAPI

from app.modules.core import FakeClock, Settings
from app.modules.core.logs import JsonFormatter, RedactingFilter
from tests.helpers import ClientFactory

PERSONAL_TEXT = "SENTINEL-personal-text"


def _logger_with_buffer(name: str) -> tuple[logging.Logger, io.StringIO]:
    buffer = io.StringIO()
    handler = logging.StreamHandler(buffer)
    handler.setFormatter(JsonFormatter("test"))
    handler.addFilter(RedactingFilter())
    logger = logging.getLogger(name)
    logger.handlers[:] = [handler]
    logger.propagate = False
    logger.setLevel(logging.INFO)
    return logger, buffer


def test_output_is_json_with_standard_fields() -> None:
    logger, buffer = _logger_with_buffer("test.json")
    logger.info("hello", extra={"task_count": 3})
    record = json.loads(buffer.getvalue())
    assert record["msg"] == "hello"
    assert record["level"] == "INFO"
    assert record["logger"] == "test.json"
    assert record["env"] == "test"
    assert record["task_count"] == 3
    assert {"ts", "request_id"} <= set(record)


@pytest.mark.parametrize(
    "key",
    [
        "title",
        "notes",
        "content",
        "reason",
        "email",
        "recipient",
        "narrative",
        "label",
        "suggestion",
        "draft",
        "password",
        "token",
        "authorization",
        "secret",
        "api_key",
        "Title",
    ],
)
def test_sensitive_extras_are_dropped(key: str) -> None:
    logger, buffer = _logger_with_buffer(f"test.redact.{key}")
    logger.info("saved", extra={key: PERSONAL_TEXT, "task_id": "t-1"})
    assert PERSONAL_TEXT not in buffer.getvalue()
    assert json.loads(buffer.getvalue())["task_id"] == "t-1"


def test_long_messages_are_truncated() -> None:
    logger, buffer = _logger_with_buffer("test.long")
    logger.info("x" * 5000)
    assert len(json.loads(buffer.getvalue())["msg"]) < 1100


def test_exceptions_are_logged_with_traceback_but_no_locals() -> None:
    logger, buffer = _logger_with_buffer("test.exc")
    secret_local = PERSONAL_TEXT  # noqa: F841 - must not appear in the log
    try:
        raise RuntimeError("failed")
    except RuntimeError:
        logger.exception("boom")
    record = json.loads(buffer.getvalue())
    assert "Traceback" in record["exc"]
    assert PERSONAL_TEXT not in buffer.getvalue()


async def test_logs_are_json_and_redacted(
    capsys: pytest.CaptureFixture[str],
    settings: Settings,
    fake_clock: FakeClock,
    make_client: ClientFactory,
) -> None:
    """CORE-AC-07: personal text in query / headers / log extras never reaches a log line."""
    from app.main import create_app

    application: FastAPI = create_app(settings)
    application.state.clock = fake_clock

    async def endpoint() -> dict[str, str]:
        logging.getLogger("app.test").info("handled", extra={"title": PERSONAL_TEXT, "item_count": 2})
        return {"ok": "yes"}

    application.add_api_route("/items/{item_id}", endpoint)

    # configure_logging runs in the lifespan and binds to the *captured* stdout.
    async with application.router.lifespan_context(application), make_client(application) as client:
        await client.get(f"/items/42?q={PERSONAL_TEXT}", headers={"Authorization": f"Bearer {PERSONAL_TEXT}"})

    out = capsys.readouterr().out
    assert PERSONAL_TEXT not in out
    lines = [json.loads(line) for line in out.splitlines() if line.strip()]  # every line is valid JSON
    access = next(line for line in lines if line["msg"] == "request")
    assert access["route"] == "/items/{item_id}"  # path template, not the raw path
    assert access["method"] == "GET"
    assert access["status"] == 200
    assert "duration_ms" in access
    handled = next(line for line in lines if line["msg"] == "handled")
    assert handled["item_count"] == 2
    assert "title" not in handled
    assert handled["request_id"] == access["request_id"]
