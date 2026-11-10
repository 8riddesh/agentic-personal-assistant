"""Public interface of ``crypto`` (spec §2). Leaf module: imports nothing else from the app."""

from app.modules.crypto.cipher import FieldCipher
from app.modules.crypto.envelope import TEXT_ENVELOPE_RE
from app.modules.crypto.errors import (
    CipherNotConfiguredError,
    CryptoError,
    DecryptionError,
    EncryptedColumnComparisonError,
    InvalidAadError,
    KeyConfigError,
    MalformedEnvelopeError,
    UnknownKeyIdError,
)
from app.modules.crypto.keys import KeyRing, parse_keys
from app.modules.crypto.registry import configure_cipher, get_cipher, reset_cipher
from app.modules.crypto.types import ENCRYPTED_TYPES, EncryptedBytes, EncryptedJSON, EncryptedText

__all__ = [
    "ENCRYPTED_TYPES",
    "TEXT_ENVELOPE_RE",
    "CipherNotConfiguredError",
    "CryptoError",
    "DecryptionError",
    "EncryptedBytes",
    "EncryptedColumnComparisonError",
    "EncryptedJSON",
    "EncryptedText",
    "FieldCipher",
    "InvalidAadError",
    "KeyConfigError",
    "KeyRing",
    "MalformedEnvelopeError",
    "UnknownKeyIdError",
    "configure_cipher",
    "get_cipher",
    "parse_keys",
    "reset_cipher",
]
