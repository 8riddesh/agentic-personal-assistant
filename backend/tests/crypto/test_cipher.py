"""CRYPTO-AC-01..07: roundtrips, envelope formats, tamper detection, rotation-readiness."""

from __future__ import annotations

import pytest

from app.modules.crypto import (
    TEXT_ENVELOPE_RE,
    CipherNotConfiguredError,
    DecryptionError,
    FieldCipher,
    InvalidAadError,
    KeyRing,
    MalformedEnvelopeError,
    UnknownKeyIdError,
    get_cipher,
    reset_cipher,
)
from tests.crypto.conftest import KEY1, KEY2

AAD = "task.title"


def test_roundtrip_bytes(cipher: FieldCipher) -> None:
    assert cipher.decrypt(cipher.encrypt(b"\x00\xffdata", AAD), AAD) == b"\x00\xffdata"


def test_roundtrip_text_unicode(cipher: FieldCipher) -> None:
    text = "Café ☕ — 日本語 🚀"
    assert cipher.decrypt_text(cipher.encrypt_text(text, AAD), AAD) == text


def test_roundtrip_empty_string(cipher: FieldCipher) -> None:
    env = cipher.encrypt_text("", AAD)
    assert env != ""
    assert cipher.decrypt_text(env, AAD) == ""


def test_binary_envelope_layout(cipher: FieldCipher) -> None:
    env = cipher.encrypt(b"hello", AAD)
    assert env[0] == 1
    assert len(env) == 29 + len(b"hello")


def test_text_envelope_matches_regex(cipher: FieldCipher) -> None:
    env = cipher.encrypt_text("hello", AAD)
    assert TEXT_ENVELOPE_RE.match(env)
    assert env.startswith("v1:")
    assert "=" not in env


def test_known_answer_vector(fixed_nonce_cipher: FieldCipher) -> None:
    first = fixed_nonce_cipher.encrypt_text("known answer", AAD)
    assert first == fixed_nonce_cipher.encrypt_text("known answer", AAD)  # deterministic with fixed nonce
    assert first.startswith("v1:AAAAAAAAAAAAAAAA")  # 12 zero bytes -> 16 base64 'A's
    assert fixed_nonce_cipher.decrypt_text(first, AAD) == "known answer"


def test_nonce_unique_per_encryption(cipher: FieldCipher) -> None:
    assert cipher.encrypt_text("same", AAD) != cipher.encrypt_text("same", AAD)


def test_wrong_aad_raises_decryption_error(cipher: FieldCipher) -> None:
    env = cipher.encrypt_text("secret", "task.title")
    with pytest.raises(DecryptionError):
        cipher.decrypt_text(env, "task.notes")


def test_bit_flip_raises_decryption_error(cipher: FieldCipher) -> None:
    env = cipher.encrypt(b"abc", AAD)
    for i in range(len(env)):
        flipped = bytearray(env)
        flipped[i] ^= 0x01
        with pytest.raises((DecryptionError, MalformedEnvelopeError, UnknownKeyIdError)):
            cipher.decrypt(bytes(flipped), AAD)


def test_truncated_raises_malformed(cipher: FieldCipher) -> None:
    with pytest.raises(MalformedEnvelopeError):
        cipher.decrypt(b"\x01" * 10, AAD)
    with pytest.raises(MalformedEnvelopeError):
        cipher.decrypt_text("v1:abcd", AAD)
    with pytest.raises(MalformedEnvelopeError):
        cipher.decrypt_text("not-an-envelope", AAD)


def test_unknown_key_id_raises(cipher: FieldCipher) -> None:
    env = bytearray(cipher.encrypt(b"x", AAD))
    env[0] = 7
    with pytest.raises(UnknownKeyIdError) as info:
        cipher.decrypt(bytes(env), AAD)
    assert info.value.key_id == 7


@pytest.mark.parametrize("aad", ["", "title", "Task.title", "task.", "task.title.extra", "task title"])
def test_invalid_aad_format_rejected(cipher: FieldCipher, aad: str) -> None:
    with pytest.raises(InvalidAadError):
        cipher.encrypt_text("x", aad)
    with pytest.raises(InvalidAadError):
        cipher.decrypt_text("v1:" + "A" * 40, aad)


def test_decrypt_with_non_active_key() -> None:
    old = FieldCipher(KeyRing(keys={1: KEY1}, active_key_id=1))
    env = old.encrypt_text("legacy", AAD)
    rotated = FieldCipher(KeyRing(keys={1: KEY1, 2: KEY2}, active_key_id=2))
    assert rotated.decrypt_text(env, AAD) == "legacy"
    new_env = rotated.encrypt_text("fresh", AAD)
    assert new_env.startswith("v2:")
    assert rotated.key_id_of(new_env) == 2
    assert rotated.key_id_of(rotated.encrypt(b"x", AAD)) == 2


def test_from_config_roundtrip() -> None:
    c = FieldCipher.from_config("1:" + "A" * 43 + "=", 1)
    assert c.active_key_id == 1
    assert c.decrypt_text(c.encrypt_text("ok", AAD), AAD) == "ok"


def test_get_cipher_unconfigured_raises() -> None:
    reset_cipher()
    with pytest.raises(CipherNotConfiguredError):
        get_cipher()
