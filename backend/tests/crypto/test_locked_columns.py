"""CRYPTO-AC-09: every 🔒 column of plan §5 uses the expected encrypted type with AAD ``table.column``.

``LOCKED`` is the registry of crypto spec §7.7. Tables owned by modules that do not exist yet (no ``models.py``) are
skipped; as soon as an owner module gets a ``models.py`` its tables must exist and be correctly typed.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

import pytest

import app.modules.auth.models
import app.modules.core.models
import app.modules.day_cycle.models
import app.modules.tasks.models  # noqa: F401
from app.modules.core import Base
from app.modules.crypto import ENCRYPTED_TYPES, EncryptedBytes, EncryptedJSON, EncryptedText

REPO_ROOT = Path(__file__).resolve().parents[3]
MODULES_DIR = REPO_ROOT / "backend" / "app" / "modules"

# table.column -> (expected type, owner module)
LOCKED: dict[str, tuple[type, str]] = {
    "app_settings.report_email": (EncryptedText, "core"),
    "fixed_schedule_block.label": (EncryptedText, "schedule"),
    "calendar_event.title": (EncryptedText, "schedule"),
    "task_template.title": (EncryptedText, "tasks"),
    "task_template.notes": (EncryptedText, "tasks"),
    "task.title": (EncryptedText, "tasks"),
    "task.notes": (EncryptedText, "tasks"),
    "task.status_reason": (EncryptedText, "tasks"),
    "task_status_event.reason": (EncryptedText, "tasks"),
    "feasibility_assessment.draft": (EncryptedJSON, "feasibility"),
    "feasibility_assessment.suggestion": (EncryptedText, "feasibility"),
    "chat_message.content": (EncryptedText, "assistant"),
    "chat_message.proposal": (EncryptedJSON, "assistant"),
    "report.metrics": (EncryptedJSON, "reports"),
    "report.narrative": (EncryptedText, "reports"),
    "report_asset.blob": (EncryptedBytes, "reports"),
    "email_log.recipient": (EncryptedText, "email"),
    "predictor_model.artifact": (EncryptedBytes, "predictor"),  # v2, deferred
}


def _column(qualified: str) -> Any:
    table_name, column_name = qualified.split(".")
    table = Base.metadata.tables.get(table_name)
    return None if table is None else table.columns.get(column_name)


def _owner_has_models(owner: str) -> bool:
    return (MODULES_DIR / owner / "models.py").exists()


def test_every_locked_column_uses_encrypted_type() -> None:
    for qualified, (expected, owner) in LOCKED.items():
        column = _column(qualified)
        if column is None:
            assert not _owner_has_models(owner) or owner == "predictor", (
                f"{qualified}: owner module '{owner}' has models.py but the column/table is missing"
            )
            continue
        assert isinstance(column.type, expected), f"{qualified} must use {expected.__name__}"


def test_no_unregistered_encrypted_columns() -> None:
    found = {
        f"{table.name}.{column.name}"
        for table in Base.metadata.tables.values()
        for column in table.columns
        if isinstance(column.type, ENCRYPTED_TYPES)
    }
    assert found <= set(LOCKED), (
        f"encrypted columns missing from the §7.7 registry: {sorted(found - set(LOCKED))}"
    )


def test_encrypted_columns_aad_matches_location() -> None:
    checked = 0
    for table in Base.metadata.tables.values():
        for column in table.columns:
            if isinstance(column.type, ENCRYPTED_TYPES):
                aad = column.type.aad  # type: ignore[attr-defined]
                assert aad == f"{table.name}.{column.name}", f"wrong AAD on {table.name}.{column.name}"
                checked += 1
    assert checked >= 7  # app_settings(1) + task_template(2) + task(3) + task_status_event(1)


def test_locked_registry_matches_plan() -> None:
    """Best-effort parse of plan §5: every 🔒 row must be in the registry and vice versa."""
    plan = (REPO_ROOT / "plan.md").read_text(encoding="utf-8")
    section = plan.split("## 5. Data Model", 1)[1].split("\n## 6.", 1)[0]
    table_re = re.compile(r"^(?:#+ .*?— |- )?`([a-z_]+)`")
    found: set[str] = set()
    current: str | None = None
    for line in section.splitlines():
        match = table_re.match(line)
        if match and not line.startswith("|"):
            current = match.group(1)
        if "🔒" not in line or current is None:
            continue
        if line.startswith("|"):
            names = re.findall(r"([a-z_]+) 🔒", line.split("|")[1])
        else:  # e.g. "- `email_log`: report_id (...), ..., recipient 🔒"
            names = re.findall(r"([a-z_]+) 🔒", line)
        found |= {f"{current}.{name}" for name in names}
    assert found == set(LOCKED), (
        "plan §5 and the crypto registry disagree - update tests/crypto/test_locked_columns.py and crypto spec §7.7: "
        f"only in plan: {sorted(found - set(LOCKED))}; only in registry: {sorted(set(LOCKED) - found)}"
    )


@pytest.mark.parametrize("qualified", sorted(LOCKED))
def test_registry_entries_are_wellformed(qualified: str) -> None:
    assert re.fullmatch(r"[a-z_]+\.[a-z_]+", qualified)
