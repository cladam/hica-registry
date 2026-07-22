#!/usr/bin/env bash
# tests/integration_test.sh — End-to-end integration tests for hica-registry

set -euo pipefail

# Configuration
PORT=8080
DB_PATH="test_reg.db"
TARBALL_DIR="./test_tarballs"
TOKEN="hica-admin-CHANGEME" # Seed token

# Check for jq
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required for this integration test."
  exit 1
fi

echo "=== 1. Preparing clean test environment ==="
rm -f "$DB_PATH" server.log testpkg-1.0.0.tar.gz search_*.json
rm -rf "$TARBALL_DIR"

# Ensure no orphan registry process is running on port $PORT
if curl -s "http://localhost:$PORT/health" >/dev/null; then
  echo "Warning: Port $PORT is already in use. Attempting to kill orphan main processes..."
  killall main 2>/dev/null || true
  sleep 1
fi

# Create dummy tarball
echo "dummy tarball content" > dummy.txt
tar -czf testpkg-1.0.0.tar.gz dummy.txt
rm dummy.txt

# Ensure clean exit and server teardown on script exit/signals
SERVER_PID=""
cleanup() {
  echo "=== Cleanup ==="
  if [ -n "$SERVER_PID" ]; then
    echo "Stopping registry server (PID: $SERVER_PID)..."
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  echo "Removing test artifacts..."
  rm -f "$DB_PATH" testpkg-1.0.0.tar.gz server.log search_*.json
  rm -rf "$TARBALL_DIR"
  echo "Done."
}
trap cleanup EXIT

echo "=== 2. Building and Starting registry server ==="
~/.local/bin/hica build
HICA_DB_PATH="$DB_PATH" HICA_TARBALL_DIR="$TARBALL_DIR" ./src/main > server.log 2>&1 &
SERVER_PID=$!

echo "Waiting for server to become healthy on port $PORT..."
HEALTHY=false
for i in {1..15}; do
  if curl -s "http://localhost:$PORT/health" | jq -e '.status == "ok"' &>/dev/null; then
    HEALTHY=true
    break
  fi
  sleep 1
done

if [ "$HEALTHY" = "false" ]; then
  echo "ERROR: Server failed to start or report healthy."
  echo "--- Server Log ---"
  cat server.log
  exit 1
fi
echo "Server is healthy!"

echo "=== 3. Testing health endpoint ==="
HEALTH_RESP=$(curl -s "http://localhost:$PORT/health")
echo "Health Response: $HEALTH_RESP"
DB_STATUS=$(echo "$HEALTH_RESP" | jq -r '.db')
if [ "$DB_STATUS" != "ok" ]; then
  echo "ERROR: Database health is degraded ($DB_STATUS)"
  exit 1
fi

echo "=== 4. Testing search (expect empty) ==="
SEARCH_RESP=$(curl -s "http://localhost:$PORT/api/v1/search?q=testpkg")
echo "Initial Search Response: $SEARCH_RESP"
TOTAL_FOUND=$(echo "$SEARCH_RESP" | jq '.total')
if [ "$TOTAL_FOUND" -ne 0 ]; then
  echo "ERROR: Expected 0 packages matching testpkg, found $TOTAL_FOUND"
  exit 1
fi

echo "=== 5. Testing publish (multipart PUT) ==="
PUBLISH_RESP=$(curl -s -X PUT "http://localhost:$PORT/api/v1/packages/testpkg/1.0.0" \
  -H "Authorization: Bearer $TOKEN" \
  -F 'metadata={"description":"Test package","license":"MIT","repository":"https://github.com/test/pkg"}' \
  -F "tarball=@testpkg-1.0.0.tar.gz")

echo "Publish Response: $PUBLISH_RESP"
STATUS=$(echo "$PUBLISH_RESP" | jq -r '.status')
if [ "$STATUS" != "queued" ]; then
  echo "ERROR: Publish did not report status queued ($STATUS)"
  exit 1
fi

# Give background worker cooperative loop a second to process from sqlite queue
echo "Waiting for background worker to process publish task..."
sleep 2

echo "=== 6. Verify publish via search and details ==="
SEARCH_RESP_2=$(curl -s "http://localhost:$PORT/api/v1/search?q=testpkg")
echo "Post-publish Search Response: $SEARCH_RESP_2"
TOTAL_FOUND_2=$(echo "$SEARCH_RESP_2" | jq '.total')
if [ "$TOTAL_FOUND_2" -ne 1 ]; then
  echo "ERROR: Package did not appear in search results (total: $TOTAL_FOUND_2)"
  exit 1
fi

PKG_RESP=$(curl -s "http://localhost:$PORT/api/v1/packages/testpkg")
echo "Package Detail Response: $PKG_RESP"
LATEST_VER=$(echo "$PKG_RESP" | jq -r '.latest')
if [ "$LATEST_VER" != "1.0.0" ]; then
  echo "ERROR: Package details does not list correct latest version ($LATEST_VER)"
  exit 1
fi

echo "=== 7. Testing parallel requests (cooperative concurrency verification) ==="
echo "Sending 10 parallel search requests..."
PIDS=()
for i in {1..10}; do
  curl -s --connect-timeout 2 -m 5 "http://localhost:$PORT/api/v1/search?q=testpkg" > "search_$i.json" 2>/dev/null </dev/null &
  PIDS+=($!)
done
wait "${PIDS[@]}" # Wait only for the parallel search requests to complete

echo "Verifying parallel responses..."
for i in {1..10}; do
  if [ ! -f "search_$i.json" ] || [ ! -s "search_$i.json" ]; then
    echo "ERROR: Parallel request $i failed or output file is empty."
    exit 1
  fi
  TOTAL=$(jq '.total' "search_$i.json")
  VER_PARALLEL=$(jq -r '.results[0].version' "search_$i.json")
  echo "Parallel Request $i - Package Version: $VER_PARALLEL"
  if [ "$TOTAL" -ne 1 ]; then
    echo "ERROR: Parallel request $i returned unexpected total packages: $TOTAL"
    exit 1
  fi
  if [ "$VER_PARALLEL" != "1.0.0" ]; then
    echo "ERROR: Parallel request $i returned unexpected package version: $VER_PARALLEL"
    exit 1
  fi
done
echo "All 10 parallel requests completed and verified successfully!"

echo "=== 8. Testing download redirects ==="
DOWNLOAD_RESP_HEADERS=$(curl -s -i "http://localhost:$PORT/api/v1/packages/testpkg/1.0.0/download")
echo "Download Response Headers:"
echo "$DOWNLOAD_RESP_HEADERS"
if ! echo "$DOWNLOAD_RESP_HEADERS" | grep -qi 'location:'; then
  echo "ERROR: Download request did not redirect"
  exit 1
fi

echo "=== 9. Testing yank ==="
YANK_RESP=$(curl -s -X DELETE "http://localhost:$PORT/api/v1/packages/testpkg/1.0.0/yank" \
  -H "Authorization: Bearer $TOKEN")
echo "Yank Response: $YANK_RESP"
YANKED_STATE=$(echo "$YANK_RESP" | jq '.yanked')
if [ "$YANKED_STATE" != "true" ]; then
  echo "ERROR: Version was not successfully yanked ($YANKED_STATE)"
  exit 1
fi

# Verify package detail lists yanked=true
PKG_RESP_2=$(curl -s "http://localhost:$PORT/api/v1/packages/testpkg")
YANKED_IN_DETAIL=$(echo "$PKG_RESP_2" | jq '.versions[0].yanked')
if [ "$YANKED_IN_DETAIL" != "true" ]; then
  echo "ERROR: Yank state was not updated in package details ($YANKED_IN_DETAIL)"
  exit 1
fi

echo "=== 10. Testing unyank ==="
UNYANK_RESP=$(curl -s -X PUT "http://localhost:$PORT/api/v1/packages/testpkg/1.0.0/unyank" \
  -H "Authorization: Bearer $TOKEN")
echo "Unyank Response: $UNYANK_RESP"
YANKED_STATE_2=$(echo "$UNYANK_RESP" | jq '.yanked')
if [ "$YANKED_STATE_2" != "false" ]; then
  echo "ERROR: Version was not successfully unyanked ($YANKED_STATE_2)"
  exit 1
fi

echo "=== Integration Test PASSED successfully with cooperative parallel requests! ==="
