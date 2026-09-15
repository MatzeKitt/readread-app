<?php

declare(strict_types=1);

namespace KittMedia\ReadReadSync;

/**
 * An HTTP response, kept as a value so the request handler can be tested without output buffering.
 */
final class Response
{
    /** @param array<string, string> $headers */
    private function __construct(
        public readonly int $status,
        public readonly string $body,
        public readonly array $headers,
    ) {
    }

    /**
     * @param array<string, mixed> $payload
     */
    public static function json(int $status, array $payload): self
    {
        $encoded = json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        return new self(
            $status,
            $encoded === false ? '{"error":"encoding_failed"}' : $encoded,
            ['Content-Type' => 'application/json; charset=utf-8'],
        );
    }

    public function withHeader(string $name, string $value): self
    {
        return new self($this->status, $this->body, [...$this->headers, $name => $value]);
    }

    /**
     * Writes the response to the SAPI.
     */
    public function send(): void
    {
        http_response_code($this->status);
        foreach ($this->headers as $name => $value) {
            header($name . ': ' . $value);
        }
        // Nothing here is cacheable: a cached pull would hand a client a stale cursor and silently
        // stop it seeing changes.
        header('Cache-Control: no-store');
        header('X-Content-Type-Options: nosniff');
        echo $this->body;
    }
}
