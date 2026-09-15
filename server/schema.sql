-- ReadRead sync service schema.
--
-- The server is a dumb, revision-numbered blob store. It never interprets a record's payload,
-- which is what lets the app add fields without a server change, and what keeps merge policy in
-- the client where the domain knowledge lives.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- One row per synced record.
CREATE TABLE IF NOT EXISTS records (
    collection  TEXT    NOT NULL,
    record_id   TEXT    NOT NULL,

    -- Server-assigned, strictly increasing. A client pulls `revision > since`, so a record that
    -- changes moves to a higher revision and is therefore re-delivered to everyone.
    revision    INTEGER NOT NULL,

    -- Tombstone. Deletions must be delivered, not just absent, or a record deleted on one device
    -- would be resurrected by the next device that still has it.
    deleted     INTEGER NOT NULL DEFAULT 0,

    -- Server clock, milliseconds. Diagnostics and tombstone pruning only; never used for merge
    -- resolution, which is the client's job.
    updated_at  INTEGER NOT NULL,

    -- Opaque JSON. Empty for a tombstone.
    payload     TEXT    NOT NULL DEFAULT '',

    PRIMARY KEY (collection, record_id)
);

-- The pull query is `WHERE revision > ? ORDER BY revision`, so this index is what keeps a sync
-- cheap no matter how many records exist.
CREATE INDEX IF NOT EXISTS records_by_revision ON records (revision);

-- Small key/value store. Holds `revision_counter` and `schema_version`.
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- API tokens, stored as SHA-256 hashes.
--
-- Hashed rather than plaintext so a leaked database backup does not hand over live credentials.
-- Multiple tokens are supported so a device can be revoked without re-pairing the others.
CREATE TABLE IF NOT EXISTS tokens (
    token_hash   TEXT PRIMARY KEY,
    label        TEXT NOT NULL DEFAULT '',
    created_at   INTEGER NOT NULL,
    last_used_at INTEGER
);

INSERT OR IGNORE INTO meta (key, value) VALUES ('revision_counter', '0');
INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', '1');
