"""Pure pack/unpack functions for the binary and text envelopes (crypto spec §7.2-7.4).

Binary: ``key_id (1 byte) || nonce (12) || ciphertext || tag (16)``.
Text:   ``v{key_id}:{base64url(nonce || ciphertext || tag)}`` (padding omitted on write, tolerated on read).
"""

from __future__ import annotations

import base64
import binascii
import re
from typing import NamedTuple

from app.modules.crypto.errors import MalformedEnvelopeError

NONCE_BYTES = 12
TAG_BYTES = 16
MIN_BINARY_LEN = 1 + NONCE_BYTES + TAG_BYTES  # 29
MIN_TEXT_PAYLOAD_LEN = NONCE_BYTES + TAG_BYTES  # 28

TEXT_ENVELOPE_RE = re.compile(r"^v([1-9][0-9]{0,2}):([A-Za-z0-9_-]+)$")


class Parts(NamedTuple):
    key_id: int
    nonce: bytes
    ct_tag: bytes


def pack_binary(key_id: int, nonce: bytes, ct_tag: bytes) -> bytes:
    return bytes([key_id]) + nonce + ct_tag


def unpack_binary(envelope: bytes) -> Parts:
    if len(envelope) < MIN_BINARY_LEN:
        raise MalformedEnvelopeError("binary envelope is too short")
    return Parts(envelope[0], envelope[1 : 1 + NONCE_BYTES], envelope[1 + NONCE_BYTES :])


def pack_text(key_id: int, nonce: bytes, ct_tag: bytes) -> str:
    payload = base64.urlsafe_b64encode(nonce + ct_tag).rstrip(b"=").decode("ascii")
    return f"v{key_id}:{payload}"


def unpack_text(envelope: str) -> Parts:
    match = TEXT_ENVELOPE_RE.match(envelope.rstrip("="))
    if match is None:
        raise MalformedEnvelopeError("text envelope does not match v{id}:{base64url}")
    key_id = int(match.group(1))
    payload = match.group(2)
    try:
        raw = base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4))
    except (binascii.Error, ValueError):
        raise MalformedEnvelopeError("text envelope payload is not valid base64url") from None
    if len(raw) < MIN_TEXT_PAYLOAD_LEN:
        raise MalformedEnvelopeError("text envelope payload is too short")
    return Parts(key_id, raw[:NONCE_BYTES], raw[NONCE_BYTES:])
