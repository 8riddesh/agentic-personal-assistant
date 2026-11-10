"""CRYPTO-AC-08: malformed key configuration aborts with a message free of key material."""

from __future__ import annotations

import base64

import pytest

from app.modules.crypto import KeyConfigError, parse_keys
from tests.crypto.conftest import KEY1, KEY2, b64


def test_parse_keys_valid_multi() -> None:
    ring = parse_keys(f"1:{b64(KEY1)}, 2:{b64(KEY2)}", 2)
    assert ring.keys == {1: KEY1, 2: KEY2}
    assert ring.active_key_id == 2


def test_parse_keys_accepts_urlsafe_and_missing_padding() -> None:
    raw = bytes(range(32))
    url = base64.urlsafe_b64encode(raw).decode().rstrip("=")
    assert parse_keys(f"1:{url}", 1).keys[1] == raw


@pytest.mark.parametrize("keys", ["", "   ", "1", "x:AAAA", "1:AAAA", f"1:{b64(KEY1)},", "1:!!!notbase64!!!"])
def test_parse_keys_rejects_bad_input(keys: str) -> None:
    with pytest.raises(KeyConfigError):
        parse_keys(keys, 1)


def test_parse_keys_rejects_wrong_length() -> None:
    with pytest.raises(KeyConfigError, match="32 bytes"):
        parse_keys(f"1:{b64(b'short')}", 1)


def test_parse_keys_rejects_duplicate_id() -> None:
    with pytest.raises(KeyConfigError, match="duplicate"):
        parse_keys(f"1:{b64(KEY1)},1:{b64(KEY2)}", 1)


@pytest.mark.parametrize("key_id", [0, 256, -1])
def test_parse_keys_rejects_id_out_of_range(key_id: int) -> None:
    with pytest.raises(KeyConfigError, match="outside"):
        parse_keys(f"{key_id}:{b64(KEY1)}", 1)


def test_parse_keys_active_missing() -> None:
    with pytest.raises(KeyConfigError, match="ACTIVE"):
        parse_keys(f"1:{b64(KEY1)}", 3)


def test_key_config_error_hides_key_material() -> None:
    secret = b64(KEY1)
    for bad in (f"1:{secret}extra", f"1:{secret},1:{secret}", f"300:{secret}"):
        with pytest.raises(KeyConfigError) as info:
            parse_keys(bad, 1)
        assert secret not in str(info.value)


def test_keyring_repr_hides_keys(test_keyring: object) -> None:
    text = repr(test_keyring)
    assert "ids=[1, 2]" in text
    assert "\x01" not in text
