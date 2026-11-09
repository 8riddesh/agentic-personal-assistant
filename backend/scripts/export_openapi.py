"""Write the app's OpenAPI schema to ``backend/openapi.json`` (plan §7, §13).

CI runs this and fails on an uncommitted diff, so the mobile DTO contract can never drift silently.
Usage (from ``backend/``):  ``uv run python scripts/export_openapi.py``
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND_DIR))

from app.main import create_app  # noqa: E402
from app.modules.core import Settings  # noqa: E402


def build_schema() -> dict[str, object]:
    # Dummy values: building the schema needs a valid Settings object but never connects to anything.
    settings = Settings(
        _env_file=None,  # type: ignore[call-arg]
        env="test",
        database_url="postgresql+asyncpg://user:pw@localhost:5432/db",
        owner_email="owner@example.com",
        owner_password_hash="unused",
        jwt_secret="x" * 32,
        encryption_keys="1:unused",
        encryption_active_key_id=1,
    )
    return create_app(settings).openapi()


def main() -> None:
    target = BACKEND_DIR / "openapi.json"
    target.write_text(
        json.dumps(build_schema(), indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n"
    )
    print(f"wrote {target}")


if __name__ == "__main__":
    main()
