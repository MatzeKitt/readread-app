<?php

declare(strict_types=1);

namespace KittMedia\ReadReadSync;

use PDO;

/**
 * Issues and verifies API tokens.
 */
final class TokenStore
{
    public function __construct(private readonly Database $database)
    {
    }

    /**
     * Mints a token, stores only its hash, and returns the plaintext once.
     *
     * The plaintext is never stored and cannot be recovered — a lost token is replaced, not
     * looked up. 32 random bytes from `random_bytes`, which is the CSPRNG; `rand`/`mt_rand` would
     * be guessable.
     */
    public function create(string $label = ''): string
    {
        $token = rtrim(strtr(base64_encode(random_bytes(32)), '+/', '-_'), '=');

        $statement = $this->database->pdo()->prepare(
            'INSERT INTO tokens (token_hash, label, created_at) VALUES (:hash, :label, :created)'
        );
        $statement->execute([
            'hash' => self::hash($token),
            'label' => $label,
            'created' => self::now(),
        ]);

        return $token;
    }

    /**
     * Verifies a presented token.
     */
    public function verify(string $token): bool
    {
        if ($token === '') {
            return false;
        }

        $hash = self::hash($token);
        $statement = $this->database->pdo()->prepare(
            'SELECT token_hash FROM tokens WHERE token_hash = :hash'
        );
        $statement->execute(['hash' => $hash]);
        $stored = $statement->fetchColumn();

        if ($stored === false) {
            return false;
        }

        // `hash_equals` rather than `===`: comparing hashes is a lookup here, but keeping the
        // comparison constant-time costs nothing and keeps the habit correct.
        if (!hash_equals((string) $stored, $hash)) {
            return false;
        }

        $touch = $this->database->pdo()->prepare(
            'UPDATE tokens SET last_used_at = :now WHERE token_hash = :hash'
        );
        $touch->execute(['now' => self::now(), 'hash' => $hash]);

        return true;
    }

    /**
     * @return list<array{label: string, created_at: int, last_used_at: int|null, token_hash: string}>
     */
    public function all(): array
    {
        $rows = $this->database->pdo()
            ->query('SELECT token_hash, label, created_at, last_used_at FROM tokens ORDER BY created_at')
            ->fetchAll();

        return array_map(static fn (array $row): array => [
            'token_hash' => (string) $row['token_hash'],
            'label' => (string) $row['label'],
            'created_at' => (int) $row['created_at'],
            'last_used_at' => $row['last_used_at'] === null ? null : (int) $row['last_used_at'],
        ], $rows);
    }

    /**
     * Revokes by hash prefix, so a token can be removed using the fingerprint shown by
     * `token:list` without the plaintext ever being needed again.
     */
    public function revokeByHashPrefix(string $prefix): int
    {
        if (strlen($prefix) < 8) {
            return 0;
        }
        $statement = $this->database->pdo()->prepare(
            'DELETE FROM tokens WHERE token_hash LIKE :prefix'
        );
        $statement->execute(['prefix' => $prefix . '%']);
        return $statement->rowCount();
    }

    public static function hash(string $token): string
    {
        return hash('sha256', $token);
    }

    private static function now(): int
    {
        return (int) (microtime(true) * 1000);
    }
}
