#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BASE_DIR"

PASS=0
FAIL=0
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REQUEST_ID="day10-$(python3 -c 'import uuid; print(uuid.uuid4())')"
PII_REQUEST_ID="${REQUEST_ID}-pii"
PII_EMAIL="pii-probe-${REQUEST_ID}@example.invalid"
PII_TOKEN="pii-token-${REQUEST_ID}"

pass() {
  echo "[PASS] $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "[FAIL] $1"
  FAIL=$((FAIL + 1))
}

check_json() {
  python3 - "$@" <<'PY'
import json
import sys

path, *checks = sys.argv[1:]
data = json.load(open(path))
for check in checks:
    if check == "success" and data.get("success") is not True:
        sys.exit(1)
    if check == "healthy" and data.get("status") != "healthy":
        sys.exit(1)
sys.exit(0)
PY
}

echo "=========================================="
echo " CENTRALIZED LOGGING - DAY 10 INTEGRATION"
echo "=========================================="
echo "Request ID: $REQUEST_ID"
echo

echo "========== 1. SERVICE HEALTH =========="

declare -A SERVICES=(
  ["user-service"]="http://localhost:3102/health"
  ["order-service"]="http://localhost:3103/health"
  ["payment-service"]="http://localhost:3104/health"
)

for service in "${!SERVICES[@]}"; do
  if curl -fsS "${SERVICES[$service]}" -o "$TMP_DIR/health.json" &&
     python3 - "$TMP_DIR/health.json" "$service" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1]))
sys.exit(0 if data.get("status") == "healthy"
         and data.get("service") == sys.argv[2] else 1)
PY
  then
    pass "$service health"
  else
    fail "$service health"
  fi
done

echo
echo "========== 2. APPLICATION API TESTS =========="

if curl -fsS http://localhost:3102/users -o "$TMP_DIR/users.json" &&
   check_json "$TMP_DIR/users.json" success; then
  pass "GET /users"
else
  fail "GET /users"
fi

if curl -fsS http://localhost:3103/orders -o "$TMP_DIR/orders.json" &&
   check_json "$TMP_DIR/orders.json" success; then
  pass "GET /orders"
else
  fail "GET /orders"
fi

if curl -fsS http://localhost:3104/payments -o "$TMP_DIR/payments.json" &&
   check_json "$TMP_DIR/payments.json" success; then
  pass "GET /payments"
else
  fail "GET /payments"
fi

echo
echo "========== 3. CROSS-SERVICE REQUEST =========="

HTTP_CODE=$(curl -sS \
  -D "$TMP_DIR/order-headers.txt" \
  -o "$TMP_DIR/order-body.json" \
  -w '%{http_code}' \
  -X POST http://localhost:3103/orders \
  -H "Content-Type: application/json" \
  -H "X-Request-ID: $REQUEST_ID" \
  -d '{"userId":1,"product":"Day 10 integration test","amount":1234}' \
  || true)

if [ "$HTTP_CODE" = "201" ] &&
   check_json "$TMP_DIR/order-body.json" success; then
  pass "Order created successfully (HTTP 201)"
else
  fail "Order creation (HTTP $HTTP_CODE)"
fi

RESPONSE_ID=$(awk 'tolower($1) == "x-request-id:" {
  gsub("\r", "", $2); print $2
}' "$TMP_DIR/order-headers.txt")

if [ "$RESPONSE_ID" = "$REQUEST_ID" ]; then
  pass "Order response preserves request ID"
else
  fail "Order response request ID"
fi

echo
echo "========== 4. ELASTICSEARCH CORRELATION =========="

ES_QUERY=$(python3 - "$REQUEST_ID" <<'PY'
import json
import sys

print(json.dumps({
    "size": 20,
    "query": {
        "bool": {
            "filter": [
                {"term": {"requestId": sys.argv[1]}},
                {"terms": {"service": [
                    "order-service", "user-service"
                ]}}
            ]
        }
    }
}))
PY
)

ES_FOUND=0

for attempt in $(seq 1 30); do
  if docker compose exec -T elasticsearch curl -fsS \
    -H 'Content-Type: application/json' \
    -d "$ES_QUERY" \
    http://localhost:9200/app-logs-write/_search \
    > "$TMP_DIR/es.json" 2>/dev/null &&
    python3 - "$TMP_DIR/es.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
hits = data.get("hits", {}).get("hits", [])
services = {hit.get("_source", {}).get("service") for hit in hits}
sys.exit(0 if {"order-service", "user-service"} <= services else 1)
PY
  then
    ES_FOUND=1
    break
  fi
  sleep 2
done

if [ "$ES_FOUND" -eq 1 ]; then
  pass "Same request ID found for order-service and user-service in Elasticsearch"
else
  fail "Cross-service Elasticsearch correlation"
fi

echo
echo "========== 5. LOKI CORRELATION =========="

LOKI_FOUND=1
START=$(date -u -d "15 minutes ago" +%s)000000000
END=$(date -u +%s)000000000

for service in order-service user-service; do
  FOUND=0
  LOKI_QUERY="{job=\"application\", service=\"$service\"} | requestId=\"$REQUEST_ID\""

  for attempt in $(seq 1 30); do
    if curl -fsSG \
      --data-urlencode "query=$LOKI_QUERY" \
      --data-urlencode "start=$START" \
      --data-urlencode "end=$END" \
      --data-urlencode "limit=10" \
      http://localhost:3101/loki/api/v1/query_range \
      -o "$TMP_DIR/loki-$service.json" 2>/dev/null &&
      python3 - "$TMP_DIR/loki-$service.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
results = data.get("data", {}).get("result", [])
sys.exit(0 if data.get("status") == "success" and results else 1)
PY
    then
      FOUND=1
      break
    fi
    sleep 2
  done

  if [ "$FOUND" -eq 1 ]; then
    pass "$service correlated event found in Loki"
  else
    fail "$service correlated event in Loki"
    LOKI_FOUND=0
  fi
done

echo
echo "========== 6. PII QUERY-STRING PROTECTION =========="

curl -fsS \
  -H "X-Request-ID: $PII_REQUEST_ID" \
  "http://localhost:3102/health?email=$PII_EMAIL&token=$PII_TOKEN" \
  -o "$TMP_DIR/pii-response.json" || true

PII_FOUND=0

for attempt in $(seq 1 30); do
  PII_QUERY=$(python3 - "$PII_REQUEST_ID" <<'PY'
import json
import sys
print(json.dumps({
    "size": 10,
    "query": {"term": {"requestId": sys.argv[1]}}
}))
PY
)

  if docker compose exec -T elasticsearch curl -fsS \
    -H 'Content-Type: application/json' \
    -d "$PII_QUERY" \
    http://localhost:9200/app-logs-write/_search \
    > "$TMP_DIR/pii-es.json" 2>/dev/null &&
    python3 - "$TMP_DIR/pii-es.json" "$PII_EMAIL" "$PII_TOKEN" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
hits = data.get("hits", {}).get("hits", [])
if not hits:
    sys.exit(1)

content = json.dumps([h.get("_source", {}) for h in hits])
sys.exit(0 if sys.argv[2] not in content
         and sys.argv[3] not in content else 1)
PY
  then
    PII_FOUND=1
    break
  fi
  sleep 2
done

if [ "$PII_FOUND" -eq 1 ]; then
  pass "Query-string email and token absent from Elasticsearch logs"
else
  fail "PII query-string protection in Elasticsearch"
fi

echo
echo "========== 7. HTTPS REVERSE PROXY =========="

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
echo "========== 8. DIRECT HTTP RESTRICTIONS =========="

for service_port in "kibana 5601" "grafana 3000"; do
  read -r service port <<< "$service_port"
  published_port=$(docker compose port "$service" "$port" 2>/dev/null || true)

  if [ -z "$published_port" ] || [ "$published_port" = ":0" ]; then
    pass "$service container port $port is not published to the host"
  else
    fail "$service container port $port is published at $published_port"
  fi
done

echo
echo "=========================================="
echo " RESULTS: $PASS passed, $FAIL failed"
echo "=========================================="
echo "Request ID: $REQUEST_ID"

if [ "$FAIL" -gt 0 ]; then
  echo "INTEGRATION TEST FAILED"
  exit 1
fi

echo "INTEGRATION TEST SUCCESSFUL"
