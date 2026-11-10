# backend - FastAPI modular monolith

Specs: [`app/modules/*/spec.md`](app/modules). Global rules: [`../plan.md`](../plan.md), [`../constitution.md`](../constitution.md).

## Local development

```powershell
cd backend
uv sync                              # Python 3.12 per .python-version (uv downloads it if missing)
copy .env.example .env               # then fill in DATABASE_URL, JWT_SECRET, ... (never commit .env)

uv run ruff check . ; uv run ruff format --check .
uv run mypy
uv run lint-imports                  # module boundaries (core spec §7.8)
uv run pytest --cov                  # DB tests are skipped unless TEST_DATABASE_URL is set

uv run alembic upgrade head          # apply migrations to DATABASE_URL
uv run uvicorn app.main:app --reload --no-access-log   # http://127.0.0.1:8000/health, /docs (non-prod only)
```

Run the Postgres-backed tests locally with any Postgres 16:
`$env:TEST_DATABASE_URL = "postgresql+asyncpg://postgres:postgres@localhost:5432/daily_assistant_test"`.

`uv run python scripts/export_openapi.py` regenerates `openapi.json`; CI fails if it is not committed.

## First run (M1)

```powershell
uv run python -m app.modules.auth.hash_password   # prompts twice, prints the argon2id hash for OWNER_PASSWORD_HASH
# ENCRYPTION_KEYS: python -c "import os,base64; print('1:'+base64.b64encode(os.urandom(32)).decode())"
```

The owner account is seeded from `OWNER_EMAIL` / `OWNER_PASSWORD_HASH` on first start (an existing row is never
changed). `uv run python scripts/export_mobile_fixtures.py` records real API responses for the Flutter contract test
(`mobile/test/contract/backend_contract_test.dart`); re-run it whenever a response shape changes.

## Layout

`app/main.py` is the composition root; each folder in `app/modules/` is one module with its own `spec.md`. A module
may import another only through its package root (`from app.modules.tasks import TaskService`) - enforced by
import-linter and `tests/core/test_boundaries.py`.
