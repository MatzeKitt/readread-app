<?php

declare(strict_types=1);

namespace KittMedia\ReadReadSync;

use InvalidArgumentException;
use PDO;

/**
 * Reads and writes synced records.
 *
 * Payloads are opaque. The store validates shape and size but never looks inside, so the app can
 * add fields to a record without touching the server, and no domain logic lives in two places.
 */
final class RecordStore
{
    /** Largest page a pull will return, however large a `limit` is asked for. */
    public const MAX_LIMIT = 500;

    public const DEFAULT_LIMIT = 500;

    /** Largest number of records one push may carry. */
    public const MAX_PUSH_RECORDS = 500;

    /** Largest payload for a single record, in bytes. */
    public const MAX_PAYLOAD_BYTES = 262144;

    /** Collections the client is known to use. Anything else is rejected as a client bug. */
    public const COLLECTIONS = ['position', 'readLater', 'filter', 'account'];

    public function __construct(private readonly Database $database)
    {
    }

    /**
     * Returns records with a revision greater than $since, oldest change first.
     *
     * Ascending order matters: the client advances its cursor to the highest revision it has
     * applied, so a page delivered out of order would let it skip everything below the maximum.
     *
     * @return array{records: list<array<string, mixed>>, maxRevision: int, hasMore: bool}
     */
    public function changes(int $since, int $limit): array
    {
        $limit = max(1, min($limit, self::MAX_LIMIT));

        $statement = $this->database->pdo()->prepare(
            'SELECT collection, record_id, revision, deleted, updated_at, payload
               FROM records
              WHERE revision > :since
              ORDER BY revision ASC
              LIMIT :limit'
        );
        $statement->bindValue('since', $since, PDO::PARAM_INT);
        // One extra row, purely to detect whether another page exists without a second COUNT query.
        $statement->bindValue('limit', $limit + 1, PDO::PARAM_INT);
        $statement->execute();
        $rows = $statement->fetchAll();

        $hasMore = \count($rows) > $limit;
        if ($hasMore) {
            array_pop($rows);
        }

        $records = array_map(static fn (array $row): array => [
            'collection' => (string) $row['collection'],
            'id' => (string) $row['record_id'],
            'revision' => (int) $row['revision'],
            'deleted' => (bool) $row['deleted'],
            'updatedAt' => (int) $row['updated_at'],
            'payload' => (string) $row['payload'],
        ], $rows);

        // The cursor the client should store. When a page is returned it is that page's highest
        // revision — *not* the global maximum, or paging would skip the remaining pages.
        $maxRevision = $records === []
            ? $this->currentRevision()
            : (int) $records[array_key_last($records)]['revision'];

        return ['records' => $records, 'maxRevision' => $maxRevision, 'hasMore' => $hasMore];
    }

    /**
     * Applies a batch of writes, assigning each a new revision.
     *
     * The whole batch is one transaction: a partially applied push would leave the client believing
     * records were stored that were not.
     *
     * @param list<array<string, mixed>> $records
     * @return array{applied: list<array{collection: string, id: string, revision: int}>, maxRevision: int}
     */
    public function push(array $records): array
    {
        if (\count($records) > self::MAX_PUSH_RECORDS) {
            throw new InvalidArgumentException(
                'Too many records in one push; the maximum is ' . self::MAX_PUSH_RECORDS
            );
        }

        $validated = array_map([$this, 'validate'], $records);

        return $this->database->transaction(function (PDO $pdo) use ($validated): array {
            $counter = (int) $this->fetchCounter($pdo);
            $now = (int) (microtime(true) * 1000);
            $applied = [];

            $upsert = $pdo->prepare(
                'INSERT INTO records (collection, record_id, revision, deleted, updated_at, payload)
                      VALUES (:collection, :record_id, :revision, :deleted, :updated_at, :payload)
                 ON CONFLICT (collection, record_id) DO UPDATE SET
                      revision   = excluded.revision,
                      deleted    = excluded.deleted,
                      updated_at = excluded.updated_at,
                      payload    = excluded.payload'
            );

            foreach ($validated as $record) {
                ++$counter;
                $upsert->execute([
                    'collection' => $record['collection'],
                    'record_id' => $record['id'],
                    'revision' => $counter,
                    'deleted' => $record['deleted'] ? 1 : 0,
                    'updated_at' => $now,
                    // A tombstone keeps whatever payload it was pushed with, which is usually
                    // nothing. Accounts are the exception and the reason this no longer blanks it:
                    // the client mints an account id per device, so a tombstone naming only an id
                    // means nothing on a device that holds the same account under a different one.
                    // Its deletions therefore carry the account's kind, server and username — the
                    // same fields the live record already syncs, and still never a credential — so
                    // the receiving device can recognise its own copy and remove that.
                    'payload' => $record['payload'],
                ]);
                $applied[] = [
                    'collection' => $record['collection'],
                    'id' => $record['id'],
                    'revision' => $counter,
                ];
            }

            $this->storeCounter($pdo, $counter);

            return ['applied' => $applied, 'maxRevision' => $counter];
        });
    }

    public function currentRevision(): int
    {
        return (int) $this->database->meta('revision_counter', '0');
    }

    /**
     * Drops tombstones older than $days.
     *
     * Tombstones cannot be deleted immediately — a device that has not synced since the deletion
     * needs to learn about it. After the retention window, a device that far behind has to resync
     * from scratch anyway.
     */
    public function pruneTombstones(int $days = 90): int
    {
        $cutoff = (int) ((microtime(true) - $days * 86400) * 1000);
        $statement = $this->database->pdo()->prepare(
            'DELETE FROM records WHERE deleted = 1 AND updated_at < :cutoff'
        );
        $statement->execute(['cutoff' => $cutoff]);
        return $statement->rowCount();
    }

    /**
     * @return array{collection: string, id: string, deleted: bool, payload: string}
     */
    private function validate(mixed $record): array
    {
        if (!\is_array($record)) {
            throw new InvalidArgumentException('Each record must be an object');
        }

        $collection = $record['collection'] ?? null;
        $id = $record['id'] ?? null;

        if (!\is_string($collection) || !\in_array($collection, self::COLLECTIONS, true)) {
            throw new InvalidArgumentException(
                'Unknown collection; expected one of ' . implode(', ', self::COLLECTIONS)
            );
        }
        if (!\is_string($id) || $id === '' || strlen($id) > 512) {
            throw new InvalidArgumentException('Record id must be a non-empty string of at most 512 characters');
        }

        $deleted = (bool) ($record['deleted'] ?? false);
        $payload = $record['payload'] ?? '';

        if (!\is_string($payload)) {
            throw new InvalidArgumentException('Payload must be a JSON string');
        }
        if (strlen($payload) > self::MAX_PAYLOAD_BYTES) {
            throw new InvalidArgumentException('Payload exceeds ' . self::MAX_PAYLOAD_BYTES . ' bytes');
        }
        // The payload stays opaque, but it must at least *be* JSON. Storing a malformed payload
        // would turn one bad push into a record every client fails to decode forever. Checked for
        // tombstones too, now that they may carry one — an unchecked path is exactly where a
        // malformed payload would get in.
        if ($payload !== '' && json_decode($payload) === null && json_last_error() !== JSON_ERROR_NONE) {
            throw new InvalidArgumentException('Payload is not valid JSON');
        }

        return ['collection' => $collection, 'id' => $id, 'deleted' => $deleted, 'payload' => $payload];
    }

    private function fetchCounter(PDO $pdo): string
    {
        $statement = $pdo->prepare("SELECT value FROM meta WHERE key = 'revision_counter'");
        $statement->execute();
        $value = $statement->fetchColumn();
        return $value === false ? '0' : (string) $value;
    }

    private function storeCounter(PDO $pdo, int $counter): void
    {
        $statement = $pdo->prepare(
            "INSERT INTO meta (key, value) VALUES ('revision_counter', :value)
             ON CONFLICT (key) DO UPDATE SET value = excluded.value"
        );
        $statement->execute(['value' => (string) $counter]);
    }
}
