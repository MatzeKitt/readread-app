<?php

declare(strict_types=1);

namespace KittMedia\ReadReadSync;

/**
 * Autoloading and configuration.
 *
 * A hand-written autoloader rather than Composer. The service has no dependencies, and requiring
 * `composer install` on a shared PHP host — the deployment target here, alongside FreshRSS — adds
 * a step and a `vendor/` directory for no benefit.
 */

spl_autoload_register(static function (string $class): void {
    $prefix = __NAMESPACE__ . '\\';
    if (!str_starts_with($class, $prefix)) {
        return;
    }
    $relative = substr($class, strlen($prefix));
    $file = __DIR__ . '/' . str_replace('\\', '/', $relative) . '.php';
    if (is_file($file)) {
        require $file;
    }
});

/**
 * Reads `server/.env`, once.
 *
 * Deliberately tiny, and deliberately not a dependency. The file exists so the database path can
 * be configured in one place that both the web request and the CLI can see, instead of having to
 * be repeated as a `fastcgi_param` in the nginx config *and* an `export` in every cron line — two
 * copies of one fact, which is how a pruning job ends up quietly operating on a different database
 * from the service.
 *
 * Format is one `KEY=VALUE` per line. `#` starts a comment only at the beginning of a line: an
 * unquoted value runs to the end of the line, because these values are filesystem paths and
 * silently truncating one at a `#` would be far worse than not supporting trailing comments.
 * Surrounding single or double quotes are stripped, so a path with trailing spaces can be written
 * unambiguously.
 *
 * @return array<string, string>
 */
function envFile(): array
{
    static $values = null;
    if ($values !== null) {
        return $values;
    }

    $values = [];
    $path = \dirname(__DIR__) . '/.env';
    if (!is_file($path) || !is_readable($path)) {
        return $values;
    }

    $lines = file($path, FILE_IGNORE_NEW_LINES) ?: [];
    foreach ($lines as $line) {
        $line = ltrim($line);
        if ($line === '' || str_starts_with($line, '#')) {
            continue;
        }
        // `export KEY=value` is accepted so the same file can be sourced by a shell.
        if (str_starts_with($line, 'export ')) {
            $line = ltrim(substr($line, 7));
        }
        $split = strpos($line, '=');
        if ($split === false) {
            continue;
        }

        $key = rtrim(substr($line, 0, $split));
        $value = trim(substr($line, $split + 1));
        if (strlen($value) >= 2) {
            $first = $value[0];
            if (($first === '"' || $first === "'") && str_ends_with($value, $first)) {
                $value = substr($value, 1, -1);
            }
        }
        if ($key !== '') {
            $values[$key] = $value;
        }
    }

    return $values;
}

/**
 * A configuration value, from the process environment or `.env`.
 *
 * The real environment wins. That ordering is what keeps a one-off override working —
 * `READREAD_SYNC_DB=/tmp/throwaway.sqlite ./bin/readread-sync migrate` is how the smoke suite runs
 * against a scratch database, and it would be surprising for a file on disk to overrule something
 * stated explicitly on the command line.
 */
function env(string $name): ?string
{
    $value = getenv($name);
    if (\is_string($value) && $value !== '') {
        return $value;
    }

    $value = envFile()[$name] ?? null;
    return ($value === null || $value === '') ? null : $value;
}

/**
 * Resolves the database path.
 *
 * Defaults to `server/data/sync.sqlite`, which the shipped `.htaccess` denies over HTTP. Set
 * `READREAD_SYNC_DB` in `server/.env` to put it outside the document root, which is better still.
 */
function databasePath(): string
{
    return env('READREAD_SYNC_DB') ?? \dirname(__DIR__) . '/data/sync.sqlite';
}

function database(): Database
{
    static $database = null;
    if ($database === null) {
        $database = new Database(databasePath());
    }
    return $database;
}
