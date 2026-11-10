"""Crypto error hierarchy (crypto spec §5). Messages never carry plaintext, ciphertext or key material."""

from __future__ import annotations


class CryptoError(Exception):
    """Base class. Mapped to HTTP 500 ``data_integrity`` by core."""


class KeyConfigError(CryptoError):
    """Bad ``ENCRYPTION_KEYS`` / ``ENCRYPTION_ACTIVE_KEY_ID`` (raised at startup)."""


class CipherNotConfiguredError(CryptoError):
    """A database read/write happened before ``configure_cipher``."""


class MalformedEnvelopeError(CryptoError):
    """The stored value cannot be parsed as an envelope."""


class UnknownKeyIdError(CryptoError):
    """The envelope names a key that is not in the key ring."""

    def __init__(self, key_id: int) -> None:
        super().__init__(f"envelope uses unknown key id {key_id}")
        self.key_id = key_id


class DecryptionError(CryptoError):
    """GCM authentication failed: tampering, wrong AAD (value moved between columns) or wrong key."""


class InvalidAadError(CryptoError):
    """The AAD is not of the form ``table.column``."""


class EncryptedColumnComparisonError(CryptoError):
    """An encrypted column was used in a SQL comparison (plan §5: never filtered/sorted in SQL)."""
