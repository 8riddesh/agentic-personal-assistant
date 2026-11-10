"""SQLAlchemy TypeDecorators that encrypt on bind and decrypt on result (crypto spec §7.5).

The AAD is passed explicitly (``EncryptedText(aad="task.title")``) because a TypeDecorator cannot see the column it
is bound to; ``tests/crypto`` asserts ``aad == f"{table}.{column}"`` for every encrypted column.
"""

from __future__ import annotations

import json
from typing import Any

from sqlalchemy import LargeBinary, Text
from sqlalchemy.engine import Dialect
from sqlalchemy.sql import operators
from sqlalchemy.types import TypeDecorator

from app.modules.crypto.errors import CryptoError, EncryptedColumnComparisonError
from app.modules.crypto.registry import get_cipher

_ALLOWED_OPERATORS = (operators.is_, operators.is_not)


class _NoCompareMixin:
    """Mixin for ``TypeDecorator.Comparator`` subclasses: only NULL checks are legal on encrypted columns."""

    def operate(self, op: Any, *other: Any, **kwargs: Any) -> Any:
        if op not in _ALLOWED_OPERATORS:
            raise EncryptedColumnComparisonError(
                "encrypted columns cannot be compared, filtered or sorted in SQL"
            )
        return super().operate(op, *other, **kwargs)  # type: ignore[misc]

    def reverse_operate(self, op: Any, other: Any, **kwargs: Any) -> Any:
        raise EncryptedColumnComparisonError(
            "encrypted columns cannot be compared, filtered or sorted in SQL"
        )


class _EncryptedBase[T](TypeDecorator[T]):
    cache_ok = True  # the only constructor state is the immutable `aad` string

    class Comparator(_NoCompareMixin, TypeDecorator.Comparator[Any]):
        pass

    comparator_factory = Comparator

    def __init__(self, aad: str) -> None:
        super().__init__()
        self.aad = aad

    def process_literal_param(self, value: Any, dialect: Dialect) -> str:
        raise CryptoError("plaintext must never be inlined into SQL text")


class EncryptedText(_EncryptedBase[str]):
    impl = Text
    cache_ok = True

    def process_bind_param(self, value: str | None, dialect: Dialect) -> str | None:
        if value is None:
            return None
        if not isinstance(value, str):
            raise TypeError(f"{self.aad}: EncryptedText requires str")
        return get_cipher().encrypt_text(value, self.aad)

    def process_result_value(self, value: str | None, dialect: Dialect) -> str | None:
        if value is None:
            return None
        return get_cipher().decrypt_text(value, self.aad)


class EncryptedJSON(_EncryptedBase[Any]):
    """JSON-native values (dict/list/str/int/float/bool). A Python ``None`` is SQL NULL, not the JSON ``null``."""

    impl = Text
    cache_ok = True

    def process_bind_param(self, value: Any, dialect: Dialect) -> str | None:
        if value is None:
            return None
        canonical = json.dumps(
            value, ensure_ascii=False, separators=(",", ":"), sort_keys=True, allow_nan=False
        )
        return get_cipher().encrypt_text(canonical, self.aad)

    def process_result_value(self, value: str | None, dialect: Dialect) -> Any:
        if value is None:
            return None
        return json.loads(get_cipher().decrypt_text(value, self.aad))


class EncryptedBytes(_EncryptedBase[bytes]):
    impl = LargeBinary
    cache_ok = True

    def process_bind_param(
        self, value: bytes | bytearray | memoryview | None, dialect: Dialect
    ) -> bytes | None:
        if value is None:
            return None
        if not isinstance(value, bytes | bytearray | memoryview):
            raise TypeError(f"{self.aad}: EncryptedBytes requires bytes")
        return get_cipher().encrypt(bytes(value), self.aad)

    def process_result_value(self, value: bytes | memoryview | None, dialect: Dialect) -> bytes | None:
        if value is None:
            return None
        return get_cipher().decrypt(bytes(value), self.aad)


ENCRYPTED_TYPES: tuple[type, ...] = (EncryptedText, EncryptedJSON, EncryptedBytes)
