"""CRYPTO-AC-10..12: TypeDecorators, raw rows contain no plaintext, comparisons are refused.

Uses a throw-away SQLite file (the decorators are dialect-agnostic), so no Postgres is required.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from pathlib import Path
from uuid import uuid4

import pytest
from sqlalchemy import Column, Integer, MetaData, Table, select, text
from sqlalchemy.dialects import postgresql
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from app.modules.crypto import (
    TEXT_ENVELOPE_RE,
    CryptoError,
    EncryptedBytes,
    EncryptedColumnComparisonError,
    EncryptedJSON,
    EncryptedText,
    FieldCipher,
)

probe_meta = MetaData()
probe = Table(
    "crypto_probe",
    probe_meta,
    Column("id", Integer, primary_key=True),
    Column("t", EncryptedText(aad="crypto_probe.t")),
    Column("j", EncryptedJSON(aad="crypto_probe.j")),
    Column("b", EncryptedBytes(aad="crypto_probe.b")),
)


@pytest.fixture
async def engine(tmp_path: Path, cipher: FieldCipher) -> AsyncIterator[AsyncEngine]:
    eng = create_async_engine(f"sqlite+aiosqlite:///{tmp_path / 'probe.db'}")
    async with eng.begin() as conn:
        await conn.run_sync(probe_meta.create_all)
    yield eng
    await eng.dispose()


async def test_raw_rows_contain_no_plaintext(engine: AsyncEngine, cipher: FieldCipher) -> None:
    sentinel = f"PLAINTEXT-SENTINEL-{uuid4()}"
    async with engine.begin() as conn:
        await conn.execute(
            probe.insert().values(id=1, t=sentinel, j={"inner": sentinel, "n": 3}, b=sentinel.encode())
        )
    async with engine.connect() as conn:
        raw_t, raw_j, raw_b = (await conn.execute(text("SELECT t, j, b FROM crypto_probe"))).one()
        assert sentinel not in raw_t and sentinel not in raw_j
        assert TEXT_ENVELOPE_RE.match(raw_t) and TEXT_ENVELOPE_RE.match(raw_j)
        assert sentinel.encode() not in bytes(raw_b)
        assert bytes(raw_b)[0] == cipher.active_key_id
        got_t, got_j, got_b = (await conn.execute(select(probe.c.t, probe.c.j, probe.c.b))).one()
    assert got_t == sentinel
    assert got_j == {"inner": sentinel, "n": 3}
    assert got_b == sentinel.encode()


async def test_type_decorators_none_passthrough(engine: AsyncEngine) -> None:
    async with engine.begin() as conn:
        await conn.execute(probe.insert().values(id=1, t=None, j=None, b=None))
        raw = (await conn.execute(text("SELECT t, j, b FROM crypto_probe"))).one()
        assert tuple(raw) == (None, None, None)
        row = (await conn.execute(select(probe.c.t, probe.c.j, probe.c.b))).one()
    assert tuple(row) == (None, None, None)


async def test_encrypted_json_canonical_roundtrip(engine: AsyncEngine) -> None:
    value = {"b": [1, 2.5, "ü"], "a": {"x": None, "y": True}}
    async with engine.begin() as conn:
        await conn.execute(probe.insert().values(id=1, j=value))
        got = (await conn.execute(select(probe.c.j))).scalar_one()
    assert got == value


async def test_encrypted_text_rejects_non_str(engine: AsyncEngine) -> None:
    async with engine.begin() as conn:
        with pytest.raises(Exception, match="requires str") as info:
            await conn.execute(probe.insert().values(id=1, t=123))
    assert "123" not in str(info.value).replace("crypto_probe", "")  # message names the AAD only


def test_literal_param_raises() -> None:
    stmt = select(probe).where(probe.c.t.is_(None))
    pg = postgresql.dialect()  # type: ignore[no-untyped-call]
    stmt.compile(dialect=pg, compile_kwargs={"literal_binds": True})  # NULL check is fine
    with pytest.raises(CryptoError):
        EncryptedText(aad="crypto_probe.t").process_literal_param("x", pg)


def test_comparison_on_encrypted_column_raises() -> None:
    with pytest.raises(EncryptedColumnComparisonError):
        probe.c.t == "x"  # noqa: B015
    with pytest.raises(EncryptedColumnComparisonError):
        probe.c.t.like("%x%")
    with pytest.raises(EncryptedColumnComparisonError):
        probe.c.t.in_(["x"])
    with pytest.raises(EncryptedColumnComparisonError):
        probe.c.b == b"x"  # noqa: B015
    with pytest.raises(EncryptedColumnComparisonError):
        probe.c.t.desc()


def test_null_checks_remain_legal() -> None:
    assert probe.c.t.is_(None) is not None
    assert probe.c.t.is_not(None) is not None
