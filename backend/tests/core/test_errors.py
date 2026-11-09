from __future__ import annotations

import httpx
import pytest
from fastapi import FastAPI
from pydantic import BaseModel

from app.modules.core import (
    AppError,
    AuthenticationError,
    ConflictError,
    DomainValidationError,
    NotFoundError,
    UpstreamError,
)
from tests.helpers import ClientFactory

PERSONAL_TEXT = "SENTINEL-personal-text"


class Body(BaseModel):
    count: int


@pytest.fixture
def probe_app(app: FastAPI) -> FastAPI:
    """The real app plus a few throw-away routes that raise on demand."""

    def raiser(exc: Exception):  # type: ignore[no-untyped-def]
        async def endpoint() -> None:
            raise exc

        return endpoint

    errors: dict[str, Exception] = {
        "not_found": NotFoundError("Task was not found."),
        "conflict": ConflictError("Already closed.", code="day_closed"),
        "validation": DomainValidationError("Bad offsets."),
        "upstream": UpstreamError("Provider down."),
        "upstream_retryable": UpstreamError("Provider busy.", retryable=True),
        "auth": AuthenticationError("Bad token.", code="invalid_token"),
        "boom": RuntimeError(PERSONAL_TEXT),
    }
    for name, exc in errors.items():
        app.add_api_route(f"/_probe/{name}", raiser(exc))

    async def with_body(body: Body) -> None:
        return None

    app.add_api_route("/_probe/body", with_body, methods=["POST"])
    return app


@pytest.mark.parametrize(
    ("name", "status", "code", "problem_type"),
    [
        ("not_found", 404, "not_found", "/problems/not-found"),
        ("conflict", 409, "day_closed", "/problems/conflict"),
        ("validation", 422, "validation_failed", "/problems/validation-failed"),
        ("upstream", 502, "upstream_unavailable", "/problems/upstream-unavailable"),
        ("upstream_retryable", 503, "upstream_unavailable", "/problems/upstream-unavailable"),
        ("auth", 401, "invalid_token", "/problems/unauthorized"),
    ],
)
async def test_problem_json_for_each_app_error(
    probe_app: FastAPI,
    make_client: ClientFactory,
    name: str,
    status: int,
    code: str,
    problem_type: str,
) -> None:
    """CORE-AC-06"""
    async with make_client(probe_app) as client:
        response = await client.get(f"/_probe/{name}")
    assert response.status_code == status
    assert response.headers["content-type"].startswith("application/problem+json")
    body = response.json()
    assert body["status"] == status
    assert body["code"] == code
    assert body["type"] == problem_type
    assert body["instance"] == f"/_probe/{name}"
    assert body["request_id"] == response.headers["x-request-id"]


async def test_authentication_error_sets_www_authenticate(
    probe_app: FastAPI, make_client: ClientFactory
) -> None:
    async with make_client(probe_app) as client:
        response = await client.get("/_probe/auth")
    assert response.headers["www-authenticate"] == "Bearer"


def test_app_error_defaults_and_extras() -> None:
    err = NotFoundError()
    assert err.code == "not_found"
    assert err.detail is None
    assert isinstance(err, AppError)
    assert ConflictError(code="x", foo=1).extra == {"foo": 1}


async def test_validation_error_drops_input(probe_app: FastAPI, make_client: ClientFactory) -> None:
    """CORE-AC-05: 422 problem with `errors[].loc`, without echoing what the client sent."""
    async with make_client(probe_app) as client:
        response = await client.post("/_probe/body", json={"count": PERSONAL_TEXT})
    assert response.status_code == 422
    body = response.json()
    assert body["code"] == "validation_failed"
    assert body["errors"][0]["loc"] == ["body", "count"]
    assert set(body["errors"][0]) == {"loc", "msg", "type"}
    assert PERSONAL_TEXT not in response.text


async def test_unhandled_error_500_generic(probe_app: FastAPI, make_client: ClientFactory) -> None:
    async with make_client(probe_app) as client:
        response = await client.get("/_probe/boom", headers={"X-Request-ID": "req-500"})
    assert response.status_code == 500
    assert response.headers["content-type"].startswith("application/problem+json")
    body = response.json()
    assert body["code"] == "internal_error"
    assert body["request_id"] == "req-500"
    assert response.headers["x-request-id"] == "req-500"
    assert PERSONAL_TEXT not in response.text
    assert "Traceback" not in response.text


async def test_unknown_route_and_wrong_method_are_problems(client: httpx.AsyncClient) -> None:
    missing = await client.get("/nope")
    assert missing.status_code == 404
    assert missing.headers["content-type"].startswith("application/problem+json")
    assert missing.json()["code"] == "http_404"

    wrong_method = await client.post("/health")
    assert wrong_method.status_code == 405
    assert wrong_method.json()["code"] == "http_405"
    assert "GET" in wrong_method.headers["allow"]


async def test_request_id_echoed_or_generated(client: httpx.AsyncClient) -> None:
    echoed = await client.get("/health", headers={"X-Request-ID": "abc-123"})
    assert echoed.headers["x-request-id"] == "abc-123"

    replaced = await client.get("/health", headers={"X-Request-ID": "not valid!!"})
    assert replaced.headers["x-request-id"] != "not valid!!"
    assert len(replaced.headers["x-request-id"]) == 32

    too_long = await client.get("/health", headers={"X-Request-ID": "a" * 65})
    assert len(too_long.headers["x-request-id"]) == 32

    generated = await client.get("/health")
    assert len(generated.headers["x-request-id"]) == 32
