# readread-sync

The sync service for ReadRead. It carries **reading positions, Read Later entries, filter rules and
the account list** between your devices.

It deliberately does **not** carry credentials. FreshRSS API passwords, Mastodon OAuth tokens and
this service's own bearer token live only in each device's Keychain. A compromised sync host
therefore cannot read your feeds or act as you on Mastodon — the worst it can do is lie about where
you had read up to.

## What it is

About 700 lines of PHP 8.3 over a SQLite file, with no dependencies and no `composer install`. The
server is a **revision-numbered blob store**: it validates that a record is well-formed and small
enough, then stores its payload without ever looking inside. Every merge decision is made by the
app. Two consequences worth knowing:

- Adding a field to a synced record needs **no server change**.
- Reading positions **cannot conflict**, because each device writes only its own row. That is what
  lets the server stay this simple.

## Requirements

- PHP 8.3 or newer with `pdo_sqlite` (`php -m | grep pdo_sqlite`)
- A directory the web server can write to, for the database

## Installing next to FreshRSS

Copy the `server/` directory somewhere your web server can reach, for example
`/var/www/readread-sync`, then point a URL at it.

**Put the database outside the document root** if you can. The bundled `.htaccess` files deny it
over HTTP, but a path the web server cannot serve at all is a stronger guarantee than a rule that
has to keep working. Configure it in `server/.env` — copy `.env.example` and edit:

```sh
cp .env.example .env
```

```ini
READREAD_SYNC_DB=/var/lib/readread-sync/sync.sqlite
```

Both the web service and `bin/readread-sync` read this file, which is the point: the path is
stated once instead of being repeated in the web server config *and* in every cron line, where the
two copies eventually disagree and the pruning job quietly operates on a different database from
the service.

Anything already in the process environment still wins, so a one-off override works as before:

```sh
READREAD_SYNC_DB=/tmp/scratch.sqlite ./bin/readread-sync status
```

Apache with the shipped `.htaccess` needs `AllowOverride All` for the directory, and `mod_rewrite`
and `mod_headers` enabled. The rewrite block also re-exports the `Authorization` header, which
Apache with mod_php otherwise drops — without it every correctly-authenticated request answers 401.

nginx has no `.htaccess`, so the equivalent has to be in the site config:

```nginx
location /readread-sync/ {
    alias /var/www/readread-sync/public/;
    try_files $uri /readread-sync/index.php$is_args$args;

    location ~ \.php$ {
        include        fastcgi_params;
        fastcgi_pass   unix:/run/php/php8.3-fpm.sock;
        fastcgi_param  SCRIPT_FILENAME $request_filename;
    }
}

# The database and the configuration must never be downloadable.
location ~ ^/readread-sync/(data|src|bin|tests)/ { return 404; }
location ~ ^/readread-sync/\.env { return 404; }
```

Serve it over **HTTPS**. The bearer token is sent on every request.

## Setting up

```sh
# Apply the schema (the service also does this on first request, so this is optional).
./bin/readread-sync migrate

# Mint a token per device. Shown once — the server stores only a SHA-256 hash and cannot
# recover the original.
./bin/readread-sync token:create --label="My Mac"
./bin/readread-sync token:create --label="My iPhone"

./bin/readread-sync token:list                            # fingerprints, labels, last use
./bin/readread-sync token:revoke --fingerprint=abc123de    # revoke one device
./bin/readread-sync status                                 # revision and token counts
./bin/readread-sync prune --days=90                        # drop old tombstones
```

A token per device is worth the extra minute: it lets you revoke a lost phone without re-pairing
everything else, and `token:list` shows which devices are actually syncing.

Tombstone pruning is optional but tidy — a monthly cron entry is plenty:

```
0 4 1 * * cd /var/www/readread-sync && ./bin/readread-sync prune
```

## Running locally

```sh
make server-dev     # php -S 127.0.0.1:8787
make server-test    # the smoke suite, against a throwaway database
```

## API

Three endpoints, all under `/api/v1`. Authentication is `Authorization: Bearer <token>` on
everything except health.

### `GET /health`

Unauthenticated on purpose, so you can check the URL before you have a token and so an uptime
monitor needs no credential. It reveals nothing but a version string.

```json
{ "ok": true, "service": "readread-sync", "version": "1.0.0", "schemaVersion": 1 }
```

### `GET /changes?since=<revision>&limit=<n>`

Returns records with a revision **greater than** `since`, oldest change first, at most 500 per page.

```json
{
  "records": [
    { "collection": "position", "id": "all|A1B2", "revision": 41,
      "deleted": false, "updatedAt": 1788000000000, "payload": "{…}" }
  ],
  "maxRevision": 41,
  "hasMore": false
}
```

`maxRevision` is **this page's** highest revision, not the server's global maximum. Store it as
your cursor only after applying the page, and keep paging while `hasMore` is true.

### `POST /changes`

```json
{ "records": [ { "collection": "filter", "id": "…", "deleted": false, "payload": "{…}" } ] }
```

Assigns each record a new revision and returns them:

```json
{ "applied": [ { "collection": "filter", "id": "…", "revision": 42 } ], "maxRevision": 42 }
```

**Do not use this `maxRevision` as your pull cursor.** Another device may hold a lower revision you
have not pulled yet, and adopting this value would skip it permanently. The pull cursor only ever
advances from a pull. The app enforces this and there is a test for it, because the bug it causes
is silent.

Collections are `position`, `readLater`, `filter` and `account`. A deletion is a record with
`deleted: true` — a tombstone, so other devices learn about it rather than re-uploading their copy.

A tombstone is stored with whatever payload it was pushed with, which for everything but an account
is none. Accounts are the exception because the app mints an account id **per device**: a tombstone
naming only an id says nothing to a device holding the same account under a different one, so
account deletions carry the account's kind, server and username — the fields the live record already
syncs, and never a credential — and the receiving device matches on those. A tombstone's payload is
still validated as JSON. Serving an older build simply blanks it, and the app falls back to matching
on the id alone, so the two can be updated in either order.

### Limits and errors

| Limit | Value |
| --- | --- |
| Request body | 1 MB |
| Records per push | 500 |
| Payload per record | 256 KB |
| Records per pull page | 500 |

`400` for a malformed record, `401` for a bad token, `404`/`405` for the wrong endpoint or method,
`413` for an oversized body, `500` for a server fault. A rejected push stores **nothing** — the
batch is one transaction, so a partial apply cannot leave the client believing records landed.

A `400` will fail identically on retry, so the app drops that record from its outbox rather than
letting it block everything queued behind it. A `500` is retried.

## Backups

The whole state is one SQLite file. Copy it while the service is idle, or use
`sqlite3 sync.sqlite ".backup out.sqlite"` to snapshot it safely while running.

Losing it is inconvenient, not fatal: positions and filters are rebuilt as your devices sync again,
and nothing here is the only copy of anything except your Read Later list.
