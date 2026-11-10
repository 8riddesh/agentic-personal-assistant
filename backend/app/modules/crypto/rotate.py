"""Key rotation - NOT implemented in v1 (plan §18). Outline of the future tool (crypto spec §7.8):

``uv run python -m app.modules.crypto.rotate [--dry-run] [--batch-size 200]``

1. Precondition: the new key is added to ``ENCRYPTION_KEYS`` and ``ENCRYPTION_ACTIVE_KEY_ID`` switched; the app is
   redeployed (new writes already use the new key).
2. Discover columns from ``Base.metadata`` (every column whose type is in ``ENCRYPTED_TYPES``); the metadata is
   received from ``app.main``'s registry so crypto never imports other modules.
3. Per table: select ``id`` + the raw encrypted columns via a ``Text``/``LargeBinary``-typed Core query (bypassing the
   decorators), batch by primary key; for each value whose ``key_id_of(...)`` is not the active key, decrypt and
   re-encrypt with the same AAD; ``UPDATE`` by id in one transaction per batch; count per table/key id.
4. ``--dry-run`` prints counts per ``(table.column, key_id)`` only.
5. After a run that reports zero non-active envelopes the old key may be removed from ``ENCRYPTION_KEYS``.
"""
