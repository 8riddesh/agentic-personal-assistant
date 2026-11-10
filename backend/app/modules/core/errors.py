"""Domain errors -> RFC 7807 ``application/problem+json`` (core spec §7.5).

Problem bodies never include request input values, stack traces or SQL. ``detail`` texts are written by developers
and must not interpolate user-provided text.
"""

from __future__ import annotations

from http import HTTPStatus
from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.modules.core.logs import get_logger, get_request_id
from app.modules.core.schemas import FieldError, ProblemDetails
from app.modules.crypto import CryptoError

logger = get_logger("app.errors")

PROBLEM_JSON = "application/problem+json"


class AppError(Exception):
    status: int = 500
    default_code: str = "internal_error"
    title: str = "Internal error"
    problem_type: str = "/problems/internal"

    def __init__(self, detail: str | None = None, *, code: str | None = None, **extra: Any) -> None:
        super().__init__(detail or self.title)
        self.detail = detail
        self.code = code or self.default_code
        self.extra: dict[str, Any] = extra
        self.headers: dict[str, str] = {}


class NotFoundError(AppError):
    status = 404
    default_code = "not_found"
    title = "Not found"
    problem_type = "/problems/not-found"


class ConflictError(AppError):
    status = 409
    default_code = "conflict"
    title = "Conflict"
    problem_type = "/problems/conflict"


class DomainValidationError(AppError):
    status = 422
    default_code = "validation_failed"
    title = "Validation failed"
    problem_type = "/problems/validation-failed"


class UpstreamError(AppError):
    """502 by default; 503 when the failure is retryable."""

    status = 502
    default_code = "upstream_unavailable"
    title = "Upstream unavailable"
    problem_type = "/problems/upstream-unavailable"

    def __init__(
        self, detail: str | None = None, *, code: str | None = None, retryable: bool = False, **extra: Any
    ) -> None:
        super().__init__(detail, code=code, **extra)
        self.retryable = retryable
        self.status = 503 if retryable else 502


class AuthenticationError(AppError):
    status = 401
    default_code = "not_authenticated"
    title = "Authentication required"
    problem_type = "/problems/unauthorized"

    def __init__(self, detail: str | None = None, *, code: str | None = None, **extra: Any) -> None:
        super().__init__(detail, code=code, **extra)
        self.headers["WWW-Authenticate"] = "Bearer"


def problem_response(
    request: Request,
    *,
    status: int,
    title: str,
    problem_type: str,
    code: str,
    detail: str | None = None,
    errors: list[FieldError] | None = None,
    headers: dict[str, str] | None = None,
    extra: dict[str, Any] | None = None,
) -> JSONResponse:
    request_id = get_request_id(request)
    body = ProblemDetails(
        type=problem_type,
        title=title,
        status=status,
        detail=detail,
        instance=request.url.path,
        code=code,
        request_id=request_id,
        errors=errors,
        **(extra or {}),
    )
    response_headers = dict(headers or {})
    if request_id:  # also set here: unhandled-error responses are rendered outside RequestContextMiddleware
        response_headers.setdefault("X-Request-ID", request_id)
    return JSONResponse(
        status_code=status,
        content=body.model_dump(mode="json", exclude_none=True),
        media_type=PROBLEM_JSON,
        headers=response_headers,
    )


async def _handle_app_error(request: Request, exc: Exception) -> JSONResponse:
    assert isinstance(exc, AppError)
    return problem_response(
        request,
        status=exc.status,
        title=exc.title,
        problem_type=exc.problem_type,
        code=exc.code,
        detail=exc.detail,
        headers=exc.headers,
        extra=exc.extra,
    )


async def _handle_request_validation(request: Request, exc: Exception) -> JSONResponse:
    assert isinstance(exc, RequestValidationError)
    # pydantic's `input` and `ctx` echo what the user sent (personal text): keep only loc / msg / type.
    errors = [
        FieldError(
            loc=[p if isinstance(p, int) else str(p) for p in e["loc"]],
            msg=str(e["msg"]),
            type=str(e["type"]),
        )
        for e in exc.errors()
    ]
    return problem_response(
        request,
        status=422,
        title="Validation failed",
        problem_type="/problems/validation-failed",
        code="validation_failed",
        detail="Request body is invalid.",
        errors=errors,
    )


async def _handle_http_exception(request: Request, exc: Exception) -> JSONResponse:
    assert isinstance(exc, StarletteHTTPException)
    try:
        title = HTTPStatus(exc.status_code).phrase
    except ValueError:
        title = "HTTP error"
    return problem_response(
        request,
        status=exc.status_code,
        title=title,
        problem_type=f"/problems/http-{exc.status_code}",
        code=f"http_{exc.status_code}",
        headers=dict(exc.headers or {}),
    )


async def _handle_crypto_error(request: Request, exc: Exception) -> JSONResponse:
    assert isinstance(exc, CryptoError)
    # Never log values; the class name (e.g. DecryptionError) is enough to diagnose.
    logger.error("data integrity error", extra={"error_type": type(exc).__name__})
    return problem_response(
        request,
        status=500,
        title="Internal error",
        problem_type="/problems/internal",
        code="data_integrity",
        detail="Stored data could not be read.",
    )


async def _handle_unexpected(request: Request, exc: Exception) -> JSONResponse:
    # Logged with traceback (no locals); the response stays generic.
    logger.error("unhandled exception", exc_info=exc, extra={"error_type": type(exc).__name__})
    return problem_response(
        request,
        status=500,
        title="Internal error",
        problem_type="/problems/internal",
        code="internal_error",
        detail="An unexpected error occurred.",
    )


def install_error_handlers(app: FastAPI) -> None:
    app.add_exception_handler(AppError, _handle_app_error)
    app.add_exception_handler(RequestValidationError, _handle_request_validation)
    app.add_exception_handler(StarletteHTTPException, _handle_http_exception)
    app.add_exception_handler(CryptoError, _handle_crypto_error)
    app.add_exception_handler(Exception, _handle_unexpected)
