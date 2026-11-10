"""Task status transition table as data (tasks spec §7.1). Pure and unit-tested over all 6x6 pairs.

Terminal: completed, postponed, cancelled, cant_do. ``missed`` is semi-terminal: the user may still record what
really happened (completed / postponed). ``planned -> missed`` is reserved for the system (``mark_unresolved_missed``).
"""

from __future__ import annotations

from app.modules.core import ConflictError

STATUSES: tuple[str, ...] = ("planned", "completed", "postponed", "cancelled", "cant_do", "missed")

# Transitions a user command may request.
USER_TRANSITIONS: frozenset[tuple[str, str]] = frozenset(
    {
        ("planned", "completed"),
        ("planned", "postponed"),
        ("planned", "cancelled"),
        ("planned", "cant_do"),
        ("missed", "completed"),
        ("missed", "postponed"),
    }
)
# Transitions only the system may perform.
SYSTEM_TRANSITIONS: frozenset[tuple[str, str]] = frozenset({("planned", "missed")})


def is_allowed(from_status: str, to_status: str, *, system: bool = False) -> bool:
    pair = (from_status, to_status)
    return pair in USER_TRANSITIONS or (system and pair in SYSTEM_TRANSITIONS)


def assert_transition(from_status: str, to_status: str, *, system: bool = False) -> None:
    if not is_allowed(from_status, to_status, system=system):
        raise ConflictError(f"{from_status} -> {to_status} is not allowed", code="task.invalid_transition")
