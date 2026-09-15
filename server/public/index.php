<?php

declare(strict_types=1);

use KittMedia\ReadReadSync\Application;

require __DIR__ . '/../src/bootstrap.php';

$database = KittMedia\ReadReadSync\database();

// Idempotent, and cheap enough to run per request on SQLite. It means a fresh deployment works
// without a separate migration step, which is one less thing to get wrong on a shared host.
$database->migrate();

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$path = parse_url((string) ($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH) ?: '/';

// Strip the directory the app is mounted in, so it works at a domain root and equally at
// `https://host/readread-sync/` next to FreshRSS.
$scriptName = (string) ($_SERVER['SCRIPT_NAME'] ?? '');
$base = rtrim(str_replace('\\', '/', \dirname($scriptName)), '/');
if ($base !== '' && $base !== '.' && str_starts_with($path, $base)) {
    $path = substr($path, strlen($base));
}
$path = '/' . ltrim($path, '/');

// Read at most one byte more than the cap, so an oversized body is rejected rather than buffered.
$body = (string) file_get_contents('php://input', false, null, 0, Application::MAX_BODY_BYTES + 1);

(new Application($database))->handle($method, $path, $_SERVER, $body)->send();
