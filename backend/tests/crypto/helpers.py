"""Shared helper for every module's raw-row "no plaintext at rest" tests (crypto spec §11)."""

from __future__ import annotations

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.crypto import TEXT_ENVELOPE_RE


async def assert_no_plaintext(session: AsyncSession, table: str, column: str, sentinel: str) -> None:
    """Read ``table.column`` as raw SQL text and assert the sentinel is absent and values are envelopes."""
    rows = (await session.execute(text(f"SELECT {column} FROM {table}"))).all()
    assert rows, f"{table} has no rows"
    for (raw,) in rows:
        if raw is None:
            continue
        if isinstance(raw, bytes | memoryview):
            blob = bytes(raw)
            assert sentinel.encode() not in blob
            assert sentinel.encode().hex() not in blob.hex()
        else:
            assert sentinel not in raw
            assert TEXT_ENVELOPE_RE.match(raw), f"{table}.{column} is not an envelope"
