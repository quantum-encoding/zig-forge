#!/bin/bash
# End-to-end smoke test: runs the built binary and hits it with curl.
# Complements the in-process integration tests in integration_test.zig
# which cover auth/billing/store logic but skip the HTTP layer.
#
# Usage: ./scripts/smoke_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Pick a random high port to avoid collisions
PORT=$((20000 + RANDOM % 40000))
BOOTSTRAP_KEY="smoketest_$(openssl rand -hex 16)"
BINARY="./zig-out/bin/zig-ai-server"
LOG_FILE=$(mktemp -t zig_ai_smoke.XXXXXX.log)
TEST_DATA_DIR=$(mktemp -d -t zig_ai_smoke_data.XXXXXX)
PASS=0
FAIL=0

# Cleanup on exit
cleanup() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f "$LOG_FILE"
  rm -rf "$TEST_DATA_DIR"
}
trap cleanup EXIT

assert_eq() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✓ $name"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $name: expected '$expected', got '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local name="$1"
  local needle="$2"
  local haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then
    echo "  ✓ $name"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $name: '$needle' not found in response"
    echo "    response: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

# ── Build ───────────────────────────────────────────────────────
echo "→ Building..."
if ! zig build > /dev/null 2>&1; then
  echo "✗ Build failed"
  exit 1
fi
echo "✓ Build OK"

# ── Start server ────────────────────────────────────────────────
echo "→ Starting server on port $PORT (data dir: $TEST_DATA_DIR)..."
ABS_BINARY="$(pwd)/$BINARY"
(cd "$TEST_DATA_DIR" && QAI_BOOTSTRAP_KEY="$BOOTSTRAP_KEY" "$ABS_BINARY" --port "$PORT" > "$LOG_FILE" 2>&1) &
SERVER_PID=$!

# Wait for server to be ready
for i in $(seq 1 20); do
  if curl -sf "http://localhost:$PORT/health" > /dev/null 2>&1; then
    break
  fi
  sleep 0.2
  if [ "$i" = "20" ]; then
    echo "✗ Server failed to start. Logs:"
    cat "$LOG_FILE"
    exit 1
  fi
done
echo "✓ Server ready"

# ── Tests ───────────────────────────────────────────────────────
echo ""
echo "Running smoke tests:"

# Test 1: Health endpoint
status=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/health")
assert_eq "GET /health returns 200" "200" "$status"

# Test 2: Root endpoint
resp=$(curl -s "http://localhost:$PORT/")
assert_contains "GET / returns service info" "zig-ai-server" "$resp"

# Test 3: Unknown endpoint returns 404
status=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/nonexistent")
assert_eq "GET /nonexistent returns 404" "404" "$status"

# Test 4: Missing auth on /qai/v1/chat returns 401
status=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "http://localhost:$PORT/qai/v1/chat" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude","messages":[]}')
assert_eq "POST /qai/v1/chat without auth returns 401" "401" "$status"

# Test 5: Invalid auth returns 403
status=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "http://localhost:$PORT/qai/v1/chat" \
  -H "Authorization: Bearer invalid_key_xyz" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude","messages":[]}')
assert_eq "POST /qai/v1/chat with bad key returns 403" "403" "$status"

# Test 6: Models endpoint with bootstrap key
resp=$(curl -s "http://localhost:$PORT/qai/v1/models" \
  -H "Authorization: Bearer $BOOTSTRAP_KEY")
assert_contains "GET /qai/v1/models returns model list" "claude" "$resp"

# Test 7: Account balance with bootstrap key
resp=$(curl -s "http://localhost:$PORT/qai/v1/account/balance" \
  -H "Authorization: Bearer $BOOTSTRAP_KEY")
assert_contains "GET /qai/v1/account/balance returns balance" "balance_ticks" "$resp"

# Test 8: Invalid JSON on chat returns 400
status=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "http://localhost:$PORT/qai/v1/chat" \
  -H "Authorization: Bearer $BOOTSTRAP_KEY" \
  -H "Content-Type: application/json" \
  -d 'not valid json')
assert_eq "POST /qai/v1/chat with bad JSON returns 400" "400" "$status"

# Test 9: Unknown model returns 400 (unless it routes to vertex which needs GCP)
status=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "http://localhost:$PORT/qai/v1/chat" \
  -H "Authorization: Bearer $BOOTSTRAP_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"totally-fake-model","messages":[{"role":"user","content":"hi"}]}')
# Either 400 (not in registry) or 503 (vertex needed GCP context)
if [ "$status" = "400" ] || [ "$status" = "503" ]; then
  echo "  ✓ POST /qai/v1/chat with unknown model returns 400 or 503 (got $status)"
  PASS=$((PASS + 1))
else
  echo "  ✗ POST /qai/v1/chat with unknown model: expected 400 or 503, got $status"
  FAIL=$((FAIL + 1))
fi

# Test 10: Auth rate limit — fire 15 requests, expect some 429s
echo "  → testing auth rate limit (15 rapid requests)..."
rate_limited=0
for i in $(seq 1 15); do
  status=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    "http://localhost:$PORT/qai/v1/auth/apple" \
    -H "Content-Type: application/json" \
    -d '{"id_token":"fake"}')
  if [ "$status" = "429" ]; then
    rate_limited=$((rate_limited + 1))
  fi
done
if [ "$rate_limited" -gt 0 ]; then
  echo "  ✓ Auth rate limit kicks in ($rate_limited/15 requests rate-limited)"
  PASS=$((PASS + 1))
else
  echo "  ✗ Auth rate limit not enforced"
  FAIL=$((FAIL + 1))
fi

# Test 11: CORS headers on OPTIONS
headers=$(curl -s -D - -o /dev/null -X OPTIONS "http://localhost:$PORT/qai/v1/chat")
assert_contains "OPTIONS includes CORS headers" "access-control-allow-origin" "$headers"

# ── Summary ─────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
if [ "$FAIL" = "0" ]; then
  echo "  All $PASS smoke tests passed"
  exit 0
else
  echo "  $PASS passed, $FAIL failed"
  echo ""
  echo "Server logs:"
  cat "$LOG_FILE"
  exit 1
fi
