# Module spec — `backend/crypto`

> Status: draft v1 · 2026-11-08 · Governed by `constitution.md` (P11, P12) and `plan.md` (§4.1, §5, §6.2, ADR-004).
> Milestone: M1.

## 1. Purpose & scope

Serves **C12** (field-level encryption by the middleware). Every 🔒 column in plan §5 is encrypted with AES-256-GCM
by the FastAPI process before it reaches Postgres and decrypted on read, transparently to repositories.

In scope: key parsing, `FieldCipher`, text and binary envelope formats, the SQLAlchemy TypeDecorators
`EncryptedText`, `EncryptedJSON`, `EncryptedBytes`, the process-wide cipher registry, the CI coverage test for 🔒
columns, the raw-row "no plaintext at rest" test helper, and an outline of a future key-rotation script.

**Out of scope:** TLS (Render/Supabase), password hashing (`auth`), searchable/deterministic encryption (🔒 columns
are never filtered or sorted in SQL), encryption of data sent to AI providers (plaintext over TLS, plan §6.2),
key-rotation tooling implementation (plan §18 — outline only).

## 2. Folder layout

```
app/modules/crypto/
├── spec.md
├── __init__.py     # exports: FieldCipher, KeyRing, parse_keys, EncryptedText, EncryptedJSON, EncryptedBytes,
│                   #   configure_cipher, get_cipher, reset_cipher, ENCRYPTED_TYPES, TEXT_ENVELOPE_RE, errors
├── errors.py       # CryptoError hierarchy
├── keys.py         # KeyRing, parse_keys()
├── envelope.py     # pack/unpack of binary and text envelopes (pure functions)
├── cipher.py       # FieldCipher
├── registry.py     # configure_cipher / get_cipher / reset_cipher (process-wide singleton)
├── types.py        # TypeDecorators
└── rotate.py       # NOT implemented in v1 — module docstring holds the §7.8 outline only
```

No `models.py`, `repository.py`, `api.py` or `schemas.py`: crypto owns no tables and no endpoints.

## 3. Dependencies

- **Internal: none.** crypto is a leaf. `core` depends on crypto (for `app_settings.report_email`), so crypto must not
  import `core` (would be a cycle). Configuration values are passed in by `app.main` (core spec §7.7).
- **Third-party:** `cryptography` (`AESGCM`), `sqlalchemy`.

## 4. Data owned

None. Storage formats it defines for other modules' columns:

| Decorator | SQL impl | Stored value |
|---|---|---|
| `EncryptedText` | `text` | text envelope of UTF-8 bytes |
| `EncryptedJSON` | `text` | text envelope of canonical JSON (UTF-8) |
| `EncryptedBytes` | `bytea` | binary envelope |

Python `None` ↔ SQL `NULL` (not encrypted; nullability is therefore visible at rest — accepted).

## 5. Public interface

```python
# canonical (plan §4.1)
class FieldCipher:
    def encrypt(self, plaintext: bytes, aad: str) -> bytes: ...        # returns BINARY envelope
    def decrypt(self, envelope: bytes, aad: str) -> bytes: ...

# additions
    def __init__(self, keyring: KeyRing, *, nonce_source: Callable[[int], bytes] = os.urandom) -> None: ...
    @classmethod
    def from_config(cls, keys: str, active_key_id: int) -> "FieldCipher": ...
    def encrypt_text(self, plaintext: str, aad: str) -> str: ...       # returns TEXT envelope
    def decrypt_text(self, envelope: str, aad: str) -> str: ...
    def key_id_of(self, envelope: bytes | str) -> int: ...
    @property
    def active_key_id(self) -> int: ...

@dataclass(frozen=True)
class KeyRing:
    keys: Mapping[int, bytes]        # key_id -> 32 bytes
    active_key_id: int
def parse_keys(keys: str, active_key_id: int) -> KeyRing: ...

def configure_cipher(cipher: FieldCipher) -> None: ...
def get_cipher() -> FieldCipher: ...      # raises CipherNotConfiguredError
def reset_cipher() -> None: ...           # tests only

class EncryptedText(TypeDecorator[str]):    impl = Text;        cache_ok = True; def __init__(self, aad: str): ...
class EncryptedJSON(TypeDecorator[Any]):    impl = Text;        cache_ok = True; def __init__(self, aad: str): ...
class EncryptedBytes(TypeDecorator[bytes]): impl = LargeBinary; cache_ok = True; def __init__(self, aad: str): ...
ENCRYPTED_TYPES: tuple[type, ...] = (EncryptedText, EncryptedJSON, EncryptedBytes)
TEXT_ENVELOPE_RE = re.compile(r"^v([1-9][0-9]{0,2}):([A-Za-z0-9_-]+)$")

# errors.py
class CryptoError(Exception): ...                   # never carries plaintext, ciphertext or key material
class KeyConfigError(CryptoError): ...              # bad ENCRYPTION_KEYS / ENCRYPTION_ACTIVE_KEY_ID
class CipherNotConfiguredError(CryptoError): ...
class MalformedEnvelopeError(CryptoError): ...      # cannot parse envelope
class UnknownKeyIdError(CryptoError): key_id: int   # envelope names a key not in the ring
class DecryptionError(CryptoError): ...             # GCM tag check failed: tamper, wrong AAD, wrong key
class InvalidAadError(CryptoError): ...             # aad not "table.column"
class EncryptedColumnComparisonError(CryptoError): ...
```

Column usage (the **AAD mechanism is the explicit `aad` constructor argument**):

```python
title: Mapped[str] = mapped_column(EncryptedText(aad="task.title"), nullable=False)
draft: Mapped[dict] = mapped_column(EncryptedJSON(aad="feasibility_assessment.draft"), nullable=False)
blob: Mapped[bytes] = mapped_column(EncryptedBytes(aad="report_asset.blob"), nullable=False)
```

A TypeDecorator cannot see the column it is bound to at bind time, so the AAD is declared explicitly and its
correctness (`aad == f"{column.table.name}.{column.name}"`) is enforced by `test_encrypted_columns_aad_matches_location`
(§11). Copy-paste mistakes therefore fail CI rather than silently weakening the swap protection.

## 6. HTTP endpoints

None.

## 7. Behaviour & rules

### 7.1 Key parsing (`parse_keys`)
- Input format: `ENCRYPTION_KEYS="1:<base64>[,2:<base64>...]"`; whitespace around items ignored; empty items rejected.
- `key_id`: decimal integer **1..255** (must fit the single key-id byte of the binary envelope).
- Key: standard or URL-safe base64 (padding optional) decoding to **exactly 32 bytes**.
- Errors (`KeyConfigError`, message names the problem and the key id, never key bytes): empty string, missing `:`,
  non-integer or out-of-range id, duplicate id, bad base64, wrong length, `active_key_id` not present.
- Generation hint (documented in README): `python -c "import os,base64;print(base64.b64encode(os.urandom(32)).decode())"`.
- `FieldCipher` builds and caches one `AESGCM(key)` per key id.

### 7.2 Encryption (`encrypt`)
1. Validate `aad` against `^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$` → else `InvalidAadError`.
2. `nonce = nonce_source(12)` (96-bit random, fresh per value).
3. `ct_tag = AESGCM(active_key).encrypt(nonce, plaintext, aad.encode("utf-8"))` (tag = last 16 bytes).
4. Binary envelope: `bytes([active_key_id]) + nonce + ct_tag`. Minimum length 1 + 12 + 16 = 29 bytes.

### 7.3 Text envelope (`encrypt_text`)
`f"v{key_id}:{base64.urlsafe_b64encode(nonce + ct_tag).rstrip(b'=').decode('ascii')}"` with
`plaintext.encode("utf-8")`. Exactly plan §6.2: `v{key_id}:{base64url(nonce ‖ ciphertext ‖ tag)}`; padding is
omitted on write and tolerated on read. The key id lives in the prefix, not in the base64 payload.

### 7.4 Decryption
1. Validate `aad` (as 7.2.1).
2. Parse: binary → `key_id = env[0]`, `nonce = env[1:13]`, `ct_tag = env[13:]`; length < 29 → `MalformedEnvelopeError`.
   Text → must match `TEXT_ENVELOPE_RE` (after stripping optional `=` padding) else `MalformedEnvelopeError`; decoded
   payload < 28 bytes → `MalformedEnvelopeError`.
3. `key_id ∉ keyring` → `UnknownKeyIdError(key_id)`.
4. `AESGCM(key).decrypt(nonce, ct_tag, aad)`; `cryptography.exceptions.InvalidTag` → `DecryptionError`
   (covers bit-flips, truncated tag, wrong AAD i.e. value moved between columns, header key id altered).
5. Text: decode UTF-8 (`UnicodeDecodeError` cannot occur after a valid tag but is mapped to `DecryptionError`).
- Any key in the ring decrypts; only the active key encrypts (rotation-ready, plan §6.2).

### 7.5 TypeDecorators
- `process_bind_param(value, dialect)`:
  - `None` → `None`.
  - `EncryptedText`: requires `str` (else `TypeError`, message names the AAD only) → `get_cipher().encrypt_text(value, aad)`.
    Empty string is encrypted (not stored as `''`).
  - `EncryptedJSON`: `json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True, allow_nan=False)`
    → `encrypt_text`. Values must be JSON-native (dict/list/str/int/float/bool/None); repositories pass
    `model.model_dump(mode="json")`. A Python `None` value is SQL NULL, not the JSON literal `null`.
  - `EncryptedBytes`: requires `bytes`/`bytearray`/`memoryview` → `get_cipher().encrypt(bytes(value), aad)`.
- `process_result_value(value, dialect)`: `None` → `None`; else the inverse (`json.loads` for JSON; `bytes(value)`
  for asyncpg memoryview before decrypting).
- `process_literal_param` raises `CryptoError` — plaintext must never be inlined into SQL text.
- `comparator_factory`: custom `Comparator` whose `operate`/`reverse_operate` raise `EncryptedColumnComparisonError`
  for every operator except `is_` / `is_not` (NULL checks remain legal). Enforces plan §5 "never filtered/sorted".
  (Verify at implementation that overriding `TypeDecorator.Comparator` intercepts `==`, `like`, `in_`; `ORDER BY` on
  an encrypted column cannot be intercepted this way and is caught by code review.)
- Mutation tracking is not provided for `EncryptedJSON`: assign a new object to persist changes.
- `cache_ok = True` is safe: the only constructor state is the immutable `aad` string.
- Alembic renders these as `sa.Text()` / `sa.LargeBinary()` (core spec §4.3).

### 7.6 Registry
`configure_cipher` stores the instance in a module-level variable (set once in lifespan before any DB access;
re-configuring replaces it — used by tests). `get_cipher()` is called on every bind/result so the decorators carry no
key material and stay picklable/cacheable.

### 7.7 Registry of 🔒 columns (from plan §5) — `tests/crypto/locked_columns.py`

| table.column | expected type | owner |
|---|---|---|
| app_settings.report_email | EncryptedText | core |
| fixed_schedule_block.label | EncryptedText | schedule |
| calendar_event.title | EncryptedText | schedule |
| task_template.title, task_template.notes | EncryptedText | tasks |
| task.title, task.notes, task.status_reason | EncryptedText | tasks |
| task_status_event.reason | EncryptedText | tasks |
| feasibility_assessment.draft | EncryptedJSON | feasibility |
| feasibility_assessment.suggestion | EncryptedText | feasibility |
| chat_message.content | EncryptedText | assistant |
| chat_message.proposal | EncryptedJSON | assistant |
| report.metrics | EncryptedJSON | reports |
| report.narrative | EncryptedText | reports |
| report_asset.blob | EncryptedBytes | reports |
| email_log.recipient | EncryptedText | email |
| predictor_model.artifact | EncryptedBytes | predictor (v2, deferred) |

### 7.8 Key rotation (future, plan §18 — outline only)
`uv run python -m app.modules.crypto.rotate [--dry-run] [--batch-size 200]`:
1. Precondition: new key added to `ENCRYPTION_KEYS` and `ENCRYPTION_ACTIVE_KEY_ID` switched; app redeployed (new writes
   already use the new key).
2. Discover columns from `Base.metadata` (all columns whose type is in `ENCRYPTED_TYPES`) — the script lives in crypto
   but receives the metadata from `app.main`'s registry to avoid importing other modules.
3. Per table: select `id` + raw encrypted columns via a `Text`/`LargeBinary`-typed Core query (bypassing decorators),
   batch by PK; for each value whose `key_id_of(...) != active`, decrypt and re-encrypt with the same AAD; `UPDATE` by
   id inside one transaction per batch; count per table/key id.
4. `--dry-run` prints counts per `(table.column, key_id)` only.
5. After a run reporting zero non-active envelopes, the old key may be removed from `ENCRYPTION_KEYS`.

## 8. Configuration

Read by core `Settings` and passed in by `app.main`:

| Var | Format | Example |
|---|---|---|
| `ENCRYPTION_KEYS` | `id:base64,...` (id 1..255, 32-byte keys) | `1:q0Jx...=` |
| `ENCRYPTION_ACTIVE_KEY_ID` | int, must be in `ENCRYPTION_KEYS` | `1` |

Tests use a fixed, obviously-fake key (`1:` + base64 of 32 × `0x01`), never a production key.

## 9. Errors & degradation

| Error | When | API effect (core mapping) |
|---|---|---|
| `KeyConfigError` | startup | process exits, message without key material |
| `CipherNotConfiguredError` | DB I/O before `configure_cipher` | 500 `data_integrity` |
| `UnknownKeyIdError` | key removed while data still uses it | 500 `data_integrity`, ERROR log with table.column + key id |
| `DecryptionError` / `MalformedEnvelopeError` | tamper, wrong AAD, corruption | 500 `data_integrity`, ERROR log with table.column only |

No silent fallback: a value that fails to decrypt is never returned as ciphertext or empty string (P9: data is never
silently discarded or faked).

## 10. Security & privacy notes

- AES-256-GCM, random 96-bit nonce per value; at single-user volume nonce collision probability is negligible.
- AAD binds each ciphertext to its `table.column`; swapping values across columns fails authentication. AAD does not
  bind to the row id, so swapping the same column between two rows is not detected (accepted: attacker would need DB
  write access; noted in Open questions).
- Keys exist only in env vars (P12); never logged; `KeyRing.__repr__` shows ids only.
- Error messages and logs never include plaintext, envelopes or keys.
- Length of ciphertext reveals approximate plaintext length (accepted).

## 11. Testing plan

Fixtures: `test_keyring` (ids 1 and 2, active 1), `cipher` (configured via `configure_cipher`, `reset_cipher` on
teardown), `fixed_nonce_cipher` (`nonce_source=lambda n: b"\x00" * n`) for known-answer tests, `probe_table` (test-only
table `crypto_probe(id uuid, t EncryptedText(aad="crypto_probe.t"), j EncryptedJSON(...), b EncryptedBytes(...))`
created on the test DB via `metadata.create_all` in a test-only MetaData, not a migration).

| Test | Kind |
|---|---|
| `test_parse_keys_valid_multi`, `test_parse_keys_rejects_wrong_length`, `test_parse_keys_rejects_bad_base64`, `test_parse_keys_rejects_duplicate_id`, `test_parse_keys_rejects_id_out_of_range` (0, 256), `test_parse_keys_active_missing`, `test_key_config_error_hides_key_material` | unit |
| `test_roundtrip_bytes`, `test_roundtrip_text_unicode`, `test_roundtrip_empty_string` | unit |
| `test_binary_envelope_layout` (byte 0 = key id, len = 29 + len(pt)), `test_text_envelope_matches_regex`, `test_known_answer_vector` (fixed key + zero nonce → golden envelope) | unit |
| `test_nonce_unique_per_encryption` (same pt twice → different envelopes) | unit |
| `test_wrong_aad_raises_decryption_error`, `test_bit_flip_raises_decryption_error` (every byte position of a short envelope), `test_truncated_raises_malformed`, `test_unknown_key_id_raises`, `test_invalid_aad_format_rejected` | unit |
| `test_decrypt_with_non_active_key` (encrypt with ring active=1, decrypt with ring {1,2} active=2) | unit |
| `test_get_cipher_unconfigured_raises` | unit |
| `test_type_decorators_none_passthrough`, `test_encrypted_json_canonical_roundtrip`, `test_encrypted_text_rejects_non_str`, `test_literal_param_raises`, `test_comparison_on_encrypted_column_raises` | unit |
| `test_every_locked_column_uses_encrypted_type` — import all `app.modules.*.models`; for each §7.7 entry whose table exists in `Base.metadata` assert `isinstance(col.type, expected)`; tables listed as deferred (`predictor_model`) may be absent, any other missing table fails | unit (CI) |
| `test_no_unregistered_encrypted_columns` — every column in metadata with an encrypted type is in the §7.7 registry | unit (CI) |
| `test_encrypted_columns_aad_matches_location` | unit (CI) |
| `test_locked_registry_matches_plan` — best-effort parse of `plan.md` §5 (rows containing 🔒 within the table section headers) and compare to §7.7 registry; failure message tells the developer to update the registry/spec | unit (CI) |
| `test_raw_rows_contain_no_plaintext` — insert into `probe_table` sentinel `"PLAINTEXT-SENTINEL-<uuid4>"` (text, inside JSON, and bytes); read via `text("SELECT t, j, encode(b,'hex') FROM crypto_probe")`; assert sentinel (and its hex) absent, `t`/`j` match `TEXT_ENVELOPE_RE`, `b[0] == active_key_id`; ORM re-read returns originals | integration |
| Shared helper `assert_no_plaintext(session, table, column, sentinel)` in `tests/crypto/helpers.py`, used by every module's own raw-row tests | helper |

Coverage target ≥ 95% for crypto (pure, small).

## 12. Acceptance criteria

| ID | Given / When / Then | Test |
|---|---|---|
| CRYPTO-AC-01 | Given a valid key ring, when a value is encrypted then decrypted with the same AAD, then the original is returned for text, JSON and bytes | `test_roundtrip_*`, `test_encrypted_json_canonical_roundtrip` |
| CRYPTO-AC-02 | Given the same plaintext encrypted twice, then the envelopes differ | `test_nonce_unique_per_encryption` |
| CRYPTO-AC-03 | Given an envelope, when its text form is inspected, then it matches `v{key_id}:{base64url}`; binary starts with the key-id byte | `test_text_envelope_matches_regex`, `test_binary_envelope_layout`, `test_known_answer_vector` |
| CRYPTO-AC-04 | Given a ciphertext from `task.title`, when decrypted with AAD `task.notes`, then `DecryptionError` | `test_wrong_aad_raises_decryption_error` |
| CRYPTO-AC-05 | Given any single flipped byte, when decrypting, then `DecryptionError` or `MalformedEnvelopeError`/`UnknownKeyIdError` — never wrong plaintext | `test_bit_flip_raises_decryption_error` |
| CRYPTO-AC-06 | Given an envelope with key id 7 not in the ring, then `UnknownKeyIdError` | `test_unknown_key_id_raises` |
| CRYPTO-AC-07 | Given keys {1,2} active 2, when reading a key-1 envelope, then it decrypts; new writes use key 2 | `test_decrypt_with_non_active_key` |
| CRYPTO-AC-08 | Given a malformed `ENCRYPTION_KEYS`, when the app starts, then it aborts with a message free of key material | `test_parse_keys_*`, `test_key_config_error_hides_key_material` |
| CRYPTO-AC-09 | Given every 🔒 column of plan §5, when CI runs, then each uses the expected encrypted type with AAD `table.column` | `test_every_locked_column_uses_encrypted_type`, `test_encrypted_columns_aad_matches_location`, `test_locked_registry_matches_plan` |
| CRYPTO-AC-10 | Given a sentinel written through the ORM, when the raw row is read with SQL, then the sentinel is absent and only envelopes are stored | `test_raw_rows_contain_no_plaintext` |
| CRYPTO-AC-11 | Given `None`, when written, then SQL NULL is stored and `None` read back | `test_type_decorators_none_passthrough` |
| CRYPTO-AC-12 | Given a query filtering on an encrypted column, then it raises before reaching the DB | `test_comparison_on_encrypted_column_raises` |

## 13. Open questions

- **Q1 (plan §4.1 vs §6.2):** `FieldCipher.encrypt` returns `bytes`, while text columns need the string envelope
  `v{id}:...`. Resolved by defining `encrypt`/`decrypt` on the **binary** envelope and adding `encrypt_text`/
  `decrypt_text` for the text envelope. Canonical signatures unchanged.
- **Q2 (plan §6.2):** the binary envelope's single key-id byte limits key ids to 1..255 — enforced for both formats.
- **Q3 (plan §4):** crypto's own dependencies are not listed; it is specified as a leaf because `core` (app_settings)
  depends on it.
- **Q4:** AAD is `table.column` only (per plan); adding the row id would also prevent intra-column row swaps but
  complicates inserts (id must be known before bind — it is, since UUIDs are app-generated). Keep as plan for v1?
- **Q5:** `email_log.recipient` is 🔒 but `user_account.email` is plaintext (needed for lookup) — consistent with the
  plan, noted only for awareness.
