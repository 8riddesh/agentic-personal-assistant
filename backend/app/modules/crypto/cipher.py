"""AES-256-GCM field cipher (crypto spec §5, §7.2-7.4)."""

from __future__ import annotations

import os
import re
from collections.abc import Callable

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from app.modules.crypto.envelope import (
    NONCE_BYTES,
    Parts,
    pack_binary,
    pack_text,
    unpack_binary,
    unpack_text,
)
from app.modules.crypto.errors import DecryptionError, InvalidAadError, UnknownKeyIdError
from app.modules.crypto.keys import KeyRing, parse_keys

_AAD_RE = re.compile(r"^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$")


def _check_aad(aad: str) -> bytes:
    if not _AAD_RE.match(aad):
        raise InvalidAadError("aad must look like 'table.column'")
    return aad.encode("utf-8")


class FieldCipher:
    """Encrypts with the active key; decrypts with any key in the ring (rotation-ready)."""

    def __init__(self, keyring: KeyRing, *, nonce_source: Callable[[int], bytes] = os.urandom) -> None:
        self._keyring = keyring
        self._nonce_source = nonce_source
        self._aesgcm = {key_id: AESGCM(key) for key_id, key in keyring.keys.items()}

    @classmethod
    def from_config(cls, keys: str, active_key_id: int) -> FieldCipher:
        return cls(parse_keys(keys, active_key_id))

    @property
    def active_key_id(self) -> int:
        return self._keyring.active_key_id

    # ------------------------------------------------------------------ encrypt
    def _seal(self, plaintext: bytes, aad: str) -> tuple[bytes, bytes]:
        aad_bytes = _check_aad(aad)
        nonce = self._nonce_source(NONCE_BYTES)
        return nonce, self._aesgcm[self.active_key_id].encrypt(nonce, plaintext, aad_bytes)

    def encrypt(self, plaintext: bytes, aad: str) -> bytes:
        """Binary envelope."""
        nonce, ct_tag = self._seal(plaintext, aad)
        return pack_binary(self.active_key_id, nonce, ct_tag)

    def encrypt_text(self, plaintext: str, aad: str) -> str:
        """Text envelope ``v{key_id}:{base64url}`` of the UTF-8 bytes."""
        nonce, ct_tag = self._seal(plaintext.encode("utf-8"), aad)
        return pack_text(self.active_key_id, nonce, ct_tag)

    # ------------------------------------------------------------------ decrypt
    def _open(self, parts: Parts, aad_bytes: bytes) -> bytes:
        aesgcm = self._aesgcm.get(parts.key_id)
        if aesgcm is None:
            raise UnknownKeyIdError(parts.key_id)
        try:
            return aesgcm.decrypt(parts.nonce, parts.ct_tag, aad_bytes)
        except InvalidTag:
            raise DecryptionError("authentication failed (tampering, wrong column or wrong key)") from None

    def decrypt(self, envelope: bytes, aad: str) -> bytes:
        aad_bytes = _check_aad(aad)
        return self._open(unpack_binary(envelope), aad_bytes)

    def decrypt_text(self, envelope: str, aad: str) -> str:
        aad_bytes = _check_aad(aad)
        plaintext = self._open(unpack_text(envelope), aad_bytes)
        try:
            return plaintext.decode("utf-8")
        except UnicodeDecodeError:
            raise DecryptionError("decrypted value is not valid UTF-8") from None

    def key_id_of(self, envelope: bytes | str) -> int:
        if isinstance(envelope, str):
            return unpack_text(envelope).key_id
        return unpack_binary(envelope).key_id
