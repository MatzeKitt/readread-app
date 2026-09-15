#!/usr/bin/env bash
#
# End-to-end checks against a real PHP server and a real SQLite database.
#
# Curl against a live server rather than unit tests: the things most likely to break here are the
# HTTP surface itself — header handling, status codes, the revision cursor semantics — and none of
# those are exercised by calling PHP classes directly.

set -uo pipefail

PORT="${PORT:-8788}"
BASE="http://127.0.0.1:${PORT}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="$(mktemp -t readread-sync-test-XXXXXX).sqlite"

PASS=0
FAIL=0

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31m✗\033[0m %s\n     %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

check() { # description expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}

cleanup() {
  # `disown` first so bash does not print a "Terminated" job notice over the test summary.
  if [ -n "${SERVER_PID:-}" ]; then
    disown "$SERVER_PID" 2>/dev/null
    kill "$SERVER_PID" 2>/dev/null
  fi
  rm -f "$DB" "$DB-wal" "$DB-shm"
}
trap cleanup EXIT

echo "readread-sync smoke tests (db: $DB)"

TOKEN="$(READREAD_SYNC_DB="$DB" "$ROOT/bin/readread-sync" token:create --label=smoke | sed -n '3p' | tr -d ' ')"
[ -n "$TOKEN" ] || { echo "could not mint a token"; exit 1; }

READREAD_SYNC_DB="$DB" php -S "127.0.0.1:${PORT}" -t "$ROOT/public" "$ROOT/public/index.php" >/dev/null 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
  curl -fsS "$BASE/api/v1/health" >/dev/null 2>&1 && break
  sleep 0.1
done

AUTH=(-H "Authorization: Bearer $TOKEN")
JSON=(-H 'Content-Type: application/json')

status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
body()   { curl -s "$@"; }
field()  { python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d$1))"; }

echo
echo "Authentication"
check "health needs no token"            "200" "$(status "$BASE/api/v1/health")"
check "pull without a token is rejected" "401" "$(status "$BASE/api/v1/changes")"
check "a wrong token is rejected"        "401" "$(status -H 'Authorization: Bearer nope' "$BASE/api/v1/changes")"
check "a valid token is accepted"        "200" "$(status "${AUTH[@]}" "$BASE/api/v1/changes")"
check "a malformed header is rejected"   "401" "$(status -H "Authorization: $TOKEN" "$BASE/api/v1/changes")"

echo
echo "Revisions"
R1="$(body "${AUTH[@]}" "${JSON[@]}" -X POST "$BASE/api/v1/changes" \
  -d '{"records":[{"collection":"position","id":"all|mac","payload":"{\"gen\":0}"}]}')"
check "first push gets revision 1" "1" "$(echo "$R1" | field "['applied'][0]['revision']")"

R2="$(body "${AUTH[@]}" "${JSON[@]}" -X POST "$BASE/api/v1/changes" \
  -d '{"records":[{"collection":"position","id":"all|phone","payload":"{\"gen\":0}"},{"collection":"filter","id":"f1","payload":"{\"p\":\"ad\"}"}]}')"
check "revisions increase monotonically" "[2, 3]" "$(echo "$R2" | field "['applied']" | python3 -c "import json,sys; print([r['revision'] for r in json.load(sys.stdin)])")"

# Re-writing a record must move it to a *new* revision, or clients that already saw it would never
# be told it changed.
R3="$(body "${AUTH[@]}" "${JSON[@]}" -X POST "$BASE/api/v1/changes" \
  -d '{"records":[{"collection":"position","id":"all|mac","payload":"{\"gen\":1}"}]}')"
check "an update gets a fresh revision" "4" "$(echo "$R3" | field "['applied'][0]['revision']")"
check "an update does not add a row"    "3" "$(body "${AUTH[@]}" "$BASE/api/v1/changes?since=0" | field "['records']" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")"

echo
echo "Pulling"
ALL="$(body "${AUTH[@]}" "$BASE/api/v1/changes?since=0")"
check "since=0 returns everything"  "3" "$(echo "$ALL" | field "['records']" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")"
check "records arrive oldest-first" "True" "$(echo "$ALL" | field "['records']" | python3 -c "
import json,sys
r=[x['revision'] for x in json.load(sys.stdin)]
print(r == sorted(r))")"
check "maxRevision is the highest delivered" "4" "$(echo "$ALL" | field "['maxRevision']")"
check "since filters out what was seen"      "1" "$(body "${AUTH[@]}" "$BASE/api/v1/changes?since=3" | field "['records']" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")"
check "a caught-up client gets nothing"      "0" "$(body "${AUTH[@]}" "$BASE/api/v1/changes?since=4" | field "['records']" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")"
check "payloads round-trip verbatim" '"{\"p\":\"ad\"}"' "$(body "${AUTH[@]}" "$BASE/api/v1/changes?since=2" | field "['records'][0]['payload']")"

echo
echo "Paging"
# A page must report its own highest revision, not the global maximum, or the client would skip
# every remaining page.
PAGE="$(body "${AUTH[@]}" "$BASE/api/v1/changes?since=0&limit=2")"
check "a page is limited"                  "2"    "$(echo "$PAGE" | field "['records']" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")"
check "hasMore is set when truncated"      "true" "$(echo "$PAGE" | field "['hasMore']")"
check "the cursor is the page's own max"   "3"    "$(echo "$PAGE" | field "['maxRevision']")"
check "hasMore is clear on the last page"  "false" "$(body "${AUTH[@]}" "$BASE/api/v1/changes?since=3&limit=2" | field "['hasMore']")"

echo
echo "Tombstones"
body "${AUTH[@]}" "${JSON[@]}" -X POST "$BASE/api/v1/changes" \
  -d '{"records":[{"collection":"filter","id":"f1","deleted":true}]}' >/dev/null
TOMB="$(body "${AUTH[@]}" "$BASE/api/v1/changes?since=4")"
check "a deletion is delivered as a tombstone" "true" "$(echo "$TOMB" | field "['records'][0]['deleted']")"
check "a tombstone pushed without one has no payload" '""' "$(echo "$TOMB" | field "['records'][0]['payload']")"

# Account ids are minted per device, so an account tombstone naming only an id says nothing to a
# device holding the same account under a different one. Its payload — kind, server, username, and
# never a credential — is what lets that device recognise its own copy, so it has to survive the
# round trip rather than being blanked the way it used to be.
body "${AUTH[@]}" "${JSON[@]}" -X POST "$BASE/api/v1/changes" \
  -d '{"records":[{"collection":"account","id":"a1","deleted":true,"payload":"{\"username\":\"matze\"}"}]}' >/dev/null
check "a tombstone keeps the payload it was pushed with" '"{\"username\":\"matze\"}"' \
  "$(body "${AUTH[@]}" "$BASE/api/v1/changes?since=5" | field "['records'][0]['payload']")"
check "a tombstone's payload must still be JSON" "400" \
  "$(status "${AUTH[@]}" "${JSON[@]}" -X POST "$BASE/api/v1/changes" -d '{"records":[{"collection":"account","id":"a2","deleted":true,"payload":"not json"}]}')"

echo
echo "Validation"
check "an unknown collection is rejected" "400" "$(status "${AUTH[@]}" "${JSON[@]}" -X POST "$BASE/api/v1/changes" -d '{"records":[{"collection":"nope","id":"x","payload":"{}"}]}')"
check "an empty id is rejected"           "400" "$(status "${AUTH[@]}" "${JSON[@]}" -X POST "$BASE/api/v1/changes" -d '{"records":[{"collection":"filter","id":"","payload":"{}"}]}')"
check "a non-JSON payload is rejected"    "400" "$(status "${AUTH[@]}" "${JSON[@]}" -X POST "$BASE/api/v1/changes" -d '{"records":[{"collection":"filter","id":"x","payload":"not json"}]}')"
check "a missing records array is rejected" "400" "$(status "${AUTH[@]}" "${JSON[@]}" -X POST "$BASE/api/v1/changes" -d '{}')"
check "malformed JSON is rejected"        "400" "$(status "${AUTH[@]}" "${JSON[@]}" -X POST "$BASE/api/v1/changes" -d '{"records":')"
check "a negative since is rejected"      "400" "$(status "${AUTH[@]}" "$BASE/api/v1/changes?since=-1")"
check "an empty push is a no-op"          "200" "$(status "${AUTH[@]}" "${JSON[@]}" -X POST "$BASE/api/v1/changes" -d '{"records":[]}')"
check "an unknown endpoint is 404"        "404" "$(status "${AUTH[@]}" "$BASE/api/v1/nope")"
check "a wrong method is 405"             "405" "$(status "${AUTH[@]}" -X DELETE "$BASE/api/v1/changes")"

echo
echo "Caps"
# A rejected batch must be rejected whole: a partially applied push would leave the client
# believing records were stored that were not.
BEFORE="$(body "${AUTH[@]}" "$BASE/api/v1/changes?since=0" | field "['maxRevision']")"
python3 -c "
import json
print(json.dumps({'records': [
    {'collection': 'filter', 'id': f'bulk-{i}', 'payload': '{}'} for i in range(501)
]}))" > /tmp/readread-too-many.json
check "over 500 records is rejected" "400" "$(status "${AUTH[@]}" "${JSON[@]}" -X POST "$BASE/api/v1/changes" --data-binary @/tmp/readread-too-many.json)"
check "the rejected batch stored nothing" "$BEFORE" "$(body "${AUTH[@]}" "$BASE/api/v1/changes?since=0" | field "['maxRevision']")"

python3 -c "
import json
print(json.dumps({'records': [
    {'collection': 'filter', 'id': 'huge', 'payload': json.dumps({'x': 'a' * 300000})}
]}))" > /tmp/readread-too-big.json
check "an oversized payload is rejected" "400" "$(status "${AUTH[@]}" "${JSON[@]}" -X POST "$BASE/api/v1/changes" --data-binary @/tmp/readread-too-big.json)"
rm -f /tmp/readread-too-many.json /tmp/readread-too-big.json

echo
echo "Revocation"
FP="$(READREAD_SYNC_DB="$DB" "$ROOT/bin/readread-sync" token:list | awk 'NR==2 {print $1}')"
READREAD_SYNC_DB="$DB" "$ROOT/bin/readread-sync" token:revoke --fingerprint="$FP" >/dev/null
check "a revoked token stops working" "401" "$(status "${AUTH[@]}" "$BASE/api/v1/changes")"

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
