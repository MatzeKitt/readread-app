<?php

declare(strict_types=1);

namespace KittMedia\ReadReadSync;

use PDO;
use PDOException;
use RuntimeException;

/**
 * Owns the SQLite connection and schema.
 */
final class Database
{
    private PDO $pdo;

    public function __construct(private readonly string $path)
    {
        $directory = \dirname($path);
        if (!is_dir($directory) && !mkdir($directory, 0o770, true) && !is_dir($directory)) {
            throw new RuntimeException("Cannot create database directory: {$directory}");
        }

        try {
            $this->pdo = new PDO('sqlite:' . $path, null, null, [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                // Emulated prepares would defeat the point of using placeholders at all.
                PDO::ATTR_EMULATE_PREPARES => false,
            ]);
        } catch (PDOException $exception) {
            throw new RuntimeException('Cannot open database: ' . $exception->getMessage(), 0, $exception);
        }

        // WAL lets a pull read while a push writes, which matters as soon as two devices sync at
        // once. The busy timeout turns a momentary lock into a short wait rather than an error.
        $this->pdo->exec('PRAGMA journal_mode = WAL');
        $this->pdo->exec('PRAGMA busy_timeout = 5000');
        $this->pdo->exec('PRAGMA foreign_keys = ON');
    }

    public function pdo(): PDO
    {
        return $this->pdo;
    }

    /**
     * Applies the schema. Idempotent, so it is safe to run on every deploy.
     */
    public function migrate(): void
    {
        $schema = file_get_contents(__DIR__ . '/../schema.sql');
        if ($schema === false) {
            throw new RuntimeException('Cannot read schema.sql');
        }
        $this->pdo->exec($schema);
    }

    /**
     * Runs $work inside an immediate transaction.
     *
     * `BEGIN IMMEDIATE` rather than a deferred transaction: the revision counter is read and then
     * written, and under a deferred transaction two concurrent pushes can both read the same
     * counter before either writes, handing two different records the same revision. A duplicate
     * revision makes `revision > since` skip one of them permanently.
     *
     * @template T
     * @param callable(PDO): T $work
     * @return T
     */
    public function transaction(callable $work): mixed
    {
        $this->pdo->exec('BEGIN IMMEDIATE');
        try {
            $result = $work($this->pdo);
            $this->pdo->exec('COMMIT');
            return $result;
        } catch (\Throwable $exception) {
            $this->pdo->exec('ROLLBACK');
            throw $exception;
        }
    }

    public function meta(string $key, string $default = ''): string
    {
        $statement = $this->pdo->prepare('SELECT value FROM meta WHERE key = :key');
        $statement->execute(['key' => $key]);
        $value = $statement->fetchColumn();
        return $value === false ? $default : (string) $value;
    }
}
