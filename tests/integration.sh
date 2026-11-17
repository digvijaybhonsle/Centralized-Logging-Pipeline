#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BASE_DIR"

ES_URL="http://localhost:9200"
LOKI_URL="http://localhost:3101"
REQUEST_ID="integration-$(python3 -c 'import uuid; print(uuid.uuid4())')"

PASS=0
FAIL=0

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass() {
  echo "[PASS] $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "[FAIL] $1"
  FAIL=$((FAIL + 1))
}

echo "========================================"
echo " CENTRALIZED LOGGING INTEGRATION TEST"
echo "========================================"
echo "Request ID: $REQUEST_ID"
echo

# 1. Check application health endpoints.
declare -A SERVICES=(
  ["user-service"]="http://localhost:3102/health"
  ["order-service"]="http://localhost:3103/health"
  ["payment-service"]="http://localhost:3104/health"
)

for service in "${!SERVICES[@]}"; do
  if curl -fsS "${SERVICES[$service]}" -o "$TMP_DIR/health.json" &&
     python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get("status") == "healthy" and d.get("service") == sys.argv[2] else 1)
' "$TMP_DIR/health.json" "$service"; then
    pass "$service health"
  else
    fail "$service health"
  fi
done

echo
echo "========== GENERATE CORRELATED LOG =========="

# 2. Generate one request with a known request ID.
HTTP_CODE=$(curl -sS \
  -D "$TMP_DIR/headers.txt" \
  -o "$TMP_DIR/body.json" \
  -w '%{http_code}' \
  -H "X-Request-ID: $REQUEST_ID" \
  http://localhost:3102/health || true)

if [ "$HTTP_CODE" = "200" ]; then
  pass "User service HTTP response"
else
  fail "User service HTTP response (HTTP $HTTP_CODE)"
fi

RESPONSE_ID=$(awk 'tolower($1) == "x-request-id:" {gsub("\r", "", $2); print $2}' "$TMP_DIR/headers.txt")

if [ "$RESPONSE_ID" = "$REQUEST_ID" ]; then
  pass "Request ID propagated in response header"
else
  fail "Request ID response header"
fi

echo
echo "========== ELASTICSEARCH INGESTION =========="

# 3. Poll Elasticsearch for the correlated event.
ES_QUERY=$(python3 -c '
import json, sys
print(json.dumps({
  "size": 1,
  "query": {"term": {"requestId.keyword": sys.argv[1]}}
}))
' "$REQUEST_ID")

ES_FOUND=0

for attempt in $(seq 1 30); do
  if curl -fsS \
    -H 'Content-Type: application/json' \
    -d "$ES_QUERY" \
    "$ES_URL/app-logs-write/_search" \
    -o "$TMP_DIR/es.json" 2>/dev/null &&
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get("hits", {}).get("total", {}).get("value", 0) > 0 else 1)
' "$TMP_DIR/es.json"; then
    ES_FOUND=1
    break
  fi
  sleep 2
done

if [ "$ES_FOUND" -eq 1 ]; then
  pass "Correlated log found in Elasticsearch"
else
  fail "Correlated log found in Elasticsearch (30 attempts)"
fi

echo
echo "========== LOKI INGESTION =========="

# 4. Poll Loki for the same request ID in structured metadata.
LOKI_QUERY="{job=\"application\"} | requestId=\"$REQUEST_ID\""
LOKI_FOUND=0

for attempt in $(seq 1 30); do
  if curl -fsSG \
    --data-urlencode "query=$LOKI_QUERY" \
    --data-urlencode "limit=10" \
    "$LOKI_URL/loki/api/v1/query" \
    -o "$TMP_DIR/loki.json" 2>/dev/null &&
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get("status") == "success" and len(d.get("data", {}).get("result", [])) > 0 else 1)
' "$TMP_DIR/loki.json"; then
    LOKI_FOUND=1
    break
  fi
  sleep 2
done

if [ "$LOKI_FOUND" -eq 1 ]; then
  pass "Correlated log found in Loki"
else
  fail "Correlated log found in Loki (30 attempts)"
fi

echo
echo "========== HTTPS ENDPOINTS =========="

# 5. Verify HTTPS reverse proxies.
for endpoint in \
  "Kibana|https://localhost:8443/" \
  "Grafana|https://localhost:8444/"; do

  name="${endpoint%%|*}"
  url="${endpoint#*|}"

  code=$(curl -k -sS -o /dev/null -w '%{http_code}' "$url" || true)

  if [ "$code" = "200" ] || [ "$code" = "302" ]; then
    pass "$name HTTPS (HTTP $code)"
  else
    fail "$name HTTPS (HTTP $code)"
  fi
done

echo
echo "========================================"
echo " RESULTS: $PASS passed, $FAIL failed"
echo "========================================"

echo "Test request ID: $REQUEST_ID"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

echo "INTEGRATION TEST SUCCESSFUL"
