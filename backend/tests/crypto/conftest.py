"""Crypto fixtures (crypto spec §11)."""

from __future__ import annotations

import base64
from collections.abc import Iterator

import pytest

from app.modules.crypto import FieldCipher, KeyRing, configure_cipher, reset_cipher

KEY1 = b"\x01" * 32
KEY2 = b"\x02" * 32


def b64(key: bytes) -> str:
    return base64.b64encode(key).decode()


@pytest.fixture
def test_keyring() -> KeyRing:
    return KeyRing(keys={1: KEY1, 2: KEY2}, active_key_id=1)


@pytest.fixture
def cipher(test_keyring: KeyRing) -> Iterator[FieldCipher]:
    c = FieldCipher(test_keyring)
    configure_cipher(c)
    yield c
    reset_cipher()


@pytest.fixture
def fixed_nonce_cipher(test_keyring: KeyRing) -> FieldCipher:
    return FieldCipher(test_keyring, nonce_source=lambda n: b"\x00" * n)
