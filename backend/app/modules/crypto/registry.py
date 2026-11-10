"""Process-wide cipher registry (crypto spec §7.6).

The TypeDecorators call :func:`get_cipher` on every bind/result, so they carry no key material.
"""

from __future__ import annotations

from app.modules.crypto.cipher import FieldCipher
from app.modules.crypto.errors import CipherNotConfiguredError

_cipher: FieldCipher | None = None


def configure_cipher(cipher: FieldCipher) -> None:
    """Set once in the app lifespan before any DB access; re-configuring replaces it (tests)."""
    global _cipher
    _cipher = cipher


def get_cipher() -> FieldCipher:
    if _cipher is None:
        raise CipherNotConfiguredError("configure_cipher() has not been called")
    return _cipher


def reset_cipher() -> None:
    """Tests only."""
    global _cipher
    _cipher = None
