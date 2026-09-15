<?php

declare(strict_types=1);

namespace KittMedia\ReadReadSync;

use InvalidArgumentException;
use Throwable;

/**
 * The HTTP surface: route, authenticate, respond.
 *
 * Small enough to be one class on purpose. The service has three endpoints and no user model, and
 * a framework would be more code than the thing it framed.
 */
final class Application
{
    public const VERSION = '1.0.0';

    /** Largest request body accepted, in bytes. */
    public const MAX_BODY_BYTES = 1048576;

    private readonly TokenStore $tokens;
    private readonly RecordStore $records;

    public function __construct(private readonly Database $database)
    {
        $this->tokens = new TokenStore($database);
        $this->records = new RecordStore($database);
    }

    /**
     * @param array<string, mixed> $server
     */
    public function handle(string $method, string $path, array $server, string $body): Response
    {
        try {
            return $this->route($method, $path, $server, $body);
        } catch (InvalidArgumentException $exception) {
            return Response::json(400, ['error' => 'bad_request', 'message' => $exception->getMessage()]);
        } catch (Throwable $exception) {
            // The message is deliberately generic: an exception here may quote SQL or file paths,
            // and this endpoint is reachable from the internet. The detail goes to the log.
            error_log('[readread-sync] ' . $exception->getMessage());
            return Response::json(500, ['error' => 'server_error', 'message' => 'Internal error']);
        }
    }

    /**
     * @param array<string, mixed> $server
     */
    private function route(string $method, string $path, array $server, string $body): Response
    {
        // Health is unauthenticated on purpose, so setup can be checked before a token exists and
        // an uptime monitor needs no credential. It reveals nothing but a version string.
        if ($method === 'GET' && $path === '/api/v1/health') {
            return Response::json(200, [
                'ok' => true,
                'service' => 'readread-sync',
                'version' => self::VERSION,
                'schemaVersion' => (int) $this->database->meta('schema_version', '0'),
            ]);
        }

        if (!$this->isAuthorized($server)) {
            return Response::json(401, ['error' => 'unauthorized', 'message' => 'A valid bearer token is required'])
                ->withHeader('WWW-Authenticate', 'Bearer');
        }

        return match (true) {
            $method === 'GET' && $path === '/api/v1/changes' => $this->pull($server),
            $method === 'POST' && $path === '/api/v1/changes' => $this->push($body),
            $path === '/api/v1/changes' => Response::json(
                405,
                ['error' => 'method_not_allowed', 'message' => 'Use GET to pull or POST to push']
            )->withHeader('Allow', 'GET, POST'),
            default => Response::json(404, ['error' => 'not_found', 'message' => 'No such endpoint']),
        };
    }

    /**
     * @param array<string, mixed> $server
     */
    private function pull(array $server): Response
    {
        $query = [];
        parse_str((string) ($server['QUERY_STRING'] ?? ''), $query);

        $since = filter_var($query['since'] ?? '0', FILTER_VALIDATE_INT);
        if ($since === false || $since < 0) {
            throw new InvalidArgumentException('`since` must be a non-negative integer');
        }

        $limit = filter_var($query['limit'] ?? RecordStore::DEFAULT_LIMIT, FILTER_VALIDATE_INT);
        if ($limit === false || $limit < 1) {
            throw new InvalidArgumentException('`limit` must be a positive integer');
        }

        return Response::json(200, $this->records->changes($since, $limit));
    }

    private function push(string $body): Response
    {
        if ($body === '') {
            throw new InvalidArgumentException('Request body is empty');
        }
        if (strlen($body) > self::MAX_BODY_BYTES) {
            return Response::json(413, [
                'error' => 'payload_too_large',
                'message' => 'Body exceeds ' . self::MAX_BODY_BYTES . ' bytes',
            ]);
        }

        $decoded = json_decode($body, true);
        if (!\is_array($decoded)) {
            throw new InvalidArgumentException('Body must be a JSON object');
        }

        $records = $decoded['records'] ?? null;
        if (!\is_array($records)) {
            throw new InvalidArgumentException('Body must contain a `records` array');
        }
        if ($records === []) {
            // An empty push is a no-op, not an error: the client's outbox may drain to nothing
            // between deciding to sync and sending.
            return Response::json(200, ['applied' => [], 'maxRevision' => $this->records->currentRevision()]);
        }

        return Response::json(200, $this->records->push(array_values($records)));
    }

    /**
     * @param array<string, mixed> $server
     */
    private function isAuthorized(array $server): bool
    {
        return $this->tokens->verify(self::bearerToken($server));
    }

    /**
     * Extracts the bearer token from the request.
     *
     * Several keys are checked because the header does not arrive consistently: PHP-FPM exposes it
     * as `HTTP_AUTHORIZATION`, some Apache configurations strip it entirely unless it is passed
     * through as `REDIRECT_HTTP_AUTHORIZATION`, and the `.htaccess` in this directory sets both.
     *
     * @param array<string, mixed> $server
     */
    public static function bearerToken(array $server): string
    {
        foreach (['HTTP_AUTHORIZATION', 'REDIRECT_HTTP_AUTHORIZATION', 'HTTP_X_AUTHORIZATION'] as $key) {
            $header = $server[$key] ?? null;
            if (!\is_string($header) || $header === '') {
                continue;
            }
            if (preg_match('/^Bearer\s+(.+)$/i', trim($header), $matches) === 1) {
                return trim($matches[1]);
            }
        }
        return '';
    }
}
