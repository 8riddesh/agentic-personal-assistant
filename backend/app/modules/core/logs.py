"""Structured JSON logging with request id and no personal text (core spec §7.6).

Rule for every module: log ids, counts, statuses, latencies and enum values - never free text from the user or an AI.
(Named ``logs.py`` rather than ``logging.py`` to avoid confusion with the stdlib.)
"""

from __future__ import annotations

import json
import logging
import re
import sys
import time
from contextvars import ContextVar
from datetime import UTC, datetime
from typing import Any
from uuid import uuid4

from starlette.datastructures import Headers, MutableHeaders
from starlette.requests import Request
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.modules.core.config import Settings

request_id_var: ContextVar[str | None] = ContextVar("request_id", default=None)

_VALID_REQUEST_ID = re.compile(r"[A-Za-z0-9-]{1,64}")
_SENSITIVE_KEYS = re.compile(
    r"password|token|authorization|secret|key|title|notes|content|reason|email|recipient|narrative|label|"
    r"suggestion|draft",
    re.IGNORECASE,
)
_MAX_MESSAGE_CHARS = 1000
_STANDARD_ATTRS = frozenset(logging.makeLogRecord({}).__dict__) | {"message", "asctime", "taskName"}
# httpx logs full request URLs (query strings included) at INFO, so it is silenced along with the DB/access loggers.
_NOISY_LOGGERS = ("sqlalchemy", "sqlalchemy.engine", "asyncpg", "uvicorn.access", "httpx", "httpcore")


def get_logger(name: str) -> logging.Logger:
    return logging.getLogger(name)


def get_request_id(request: Request) -> str | None:
    """Request id of the current request. Reads the ASGI scope, which (unlike the ContextVar) survives the
    outer ServerErrorMiddleware that renders unhandled-exception responses."""
    state = request.scope.get("state") or {}
    rid = state.get("request_id")
    return rid if isinstance(rid, str) else request_id_var.get()


class RedactingFilter(logging.Filter):
    """Drops extras whose keys look sensitive and truncates over-long messages."""

    def filter(self, record: logging.LogRecord) -> bool:
        for key in [k for k in record.__dict__ if k not in _STANDARD_ATTRS]:
            if _SENSITIVE_KEYS.search(key):
                del record.__dict__[key]
        message = record.getMessage()
        if len(message) > _MAX_MESSAGE_CHARS:
            record.msg = message[:_MAX_MESSAGE_CHARS] + "...[truncated]"
            record.args = None
        return True


class JsonFormatter(logging.Formatter):
    def __init__(self, env: str) -> None:
        super().__init__()
        self._env = env

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "ts": datetime.fromtimestamp(record.created, UTC).isoformat(timespec="milliseconds"),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
            "request_id": request_id_var.get(),
            "env": self._env,
        }
        for key, value in record.__dict__.items():
            if key not in _STANDARD_ATTRS and key not in payload:
                payload[key] = value
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)  # traceback only, never locals
        return json.dumps(payload, default=str)


def configure_logging(settings: Settings) -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter(settings.env))
    handler.addFilter(RedactingFilter())

    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(settings.log_level)

    # uvicorn installs its own plain-text handlers: route its loggers through ours instead.
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        lg = logging.getLogger(name)
        lg.handlers.clear()
        lg.propagate = True
    for name in _NOISY_LOGGERS:
        logging.getLogger(name).setLevel(logging.WARNING)


class RequestContextMiddleware:
    """Pure ASGI middleware: request id in/out, one access line per request (never query strings or bodies)."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app
        self._log = get_logger("app.access")

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        incoming = Headers(scope=scope).get("x-request-id")
        request_id = incoming if incoming and _VALID_REQUEST_ID.fullmatch(incoming) else uuid4().hex
        scope.setdefault("state", {})["request_id"] = request_id
        token = request_id_var.set(request_id)
        status = 500
        started = time.perf_counter()

        async def send_with_request_id(message: Message) -> None:
            nonlocal status
            if message["type"] == "http.response.start":
                status = message["status"]
                message.setdefault("headers", [])
                MutableHeaders(scope=message)["X-Request-ID"] = request_id
            await send(message)

        try:
            await self.app(scope, receive, send_with_request_id)
        finally:
            route = scope.get("route")
            self._log.info(
                "request",
                extra={
                    "method": scope.get("method"),
                    "route": getattr(route, "path", "unmatched"),
                    "status": status,
                    "duration_ms": round((time.perf_counter() - started) * 1000, 1),
                },
            )
            request_id_var.reset(token)
