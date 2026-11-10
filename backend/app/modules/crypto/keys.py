"""Key ring parsing (crypto spec §7.1)."""

from __future__ import annotations

import base64
import binascii
from collections.abc import Mapping
from dataclasses import dataclass

from app.modules.crypto.errors import KeyConfigError

KEY_BYTES = 32
MIN_KEY_ID = 1
MAX_KEY_ID = 255


@dataclass(frozen=True)
class KeyRing:
    keys: Mapping[int, bytes]  # key_id -> 32 bytes
    active_key_id: int

    def __repr__(self) -> str:  # never show key bytes
        return f"KeyRing(ids={sorted(self.keys)}, active={self.active_key_id})"


def _decode_key(raw: str, key_id: int) -> bytes:
    text = raw.strip()
    padded = text + "=" * (-len(text) % 4)
    try:
        # urlsafe decoder accepts '-'/'_' only; map the standard alphabet first so both forms work.
        data = base64.urlsafe_b64decode(padded.replace("+", "-").replace("/", "_"))
    except (binascii.Error, ValueError):
        raise KeyConfigError(f"key {key_id}: not valid base64") from None
    if len(data) != KEY_BYTES:
        raise KeyConfigError(f"key {key_id}: must decode to exactly {KEY_BYTES} bytes")
    return data


def parse_keys(keys: str, active_key_id: int) -> KeyRing:
    """Parse ``"1:<base64>[,2:<base64>...]"``. Errors name the problem and the key id, never key bytes."""
    if not keys or not keys.strip():
        raise KeyConfigError("ENCRYPTION_KEYS is empty")
    parsed: dict[int, bytes] = {}
    for item in keys.split(","):
        entry = item.strip()
        if not entry:
            raise KeyConfigError("ENCRYPTION_KEYS contains an empty item")
        id_part, sep, key_part = entry.partition(":")
        if not sep:
            raise KeyConfigError("ENCRYPTION_KEYS item is missing ':' between id and key")
        try:
            key_id = int(id_part.strip())
        except ValueError:
            raise KeyConfigError("ENCRYPTION_KEYS item has a non-integer key id") from None
        if not MIN_KEY_ID <= key_id <= MAX_KEY_ID:
            raise KeyConfigError(f"key id {key_id} is outside {MIN_KEY_ID}..{MAX_KEY_ID}")
        if key_id in parsed:
            raise KeyConfigError(f"duplicate key id {key_id}")
        parsed[key_id] = _decode_key(key_part, key_id)
    if active_key_id not in parsed:
        raise KeyConfigError(f"ENCRYPTION_ACTIVE_KEY_ID {active_key_id} is not in ENCRYPTION_KEYS")
    return KeyRing(keys=parsed, active_key_id=active_key_id)
