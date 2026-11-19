#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_ROOT="$PROJECT_DIR/backups"
VOLUME_PREFIX="centralized-logging-pipeline"
STAMP="$(date -u +%Y%m%dt%H%M%Sz | tr '[:upper:]' '[:lower:]')"
SNAPSHOT="centralized-logging-$STAMP"
LOG_FILE="$BACKUP_ROOT/logs/backup-$STAMP.log"

cd "$PROJECT_DIR"
mkdir -p "$BACKUP_ROOT"/{elasticsearch,loki,grafana,alloy,logs}

exec > >(tee -a "$LOG_FILE") 2>&1

echo "========== BACKUP START: $STAMP =========="

services_to_restart=()
services_stopped=0

cleanup() {
    local result=$?
    trap - EXIT

    if (( services_stopped )); then
        echo "========== RESTARTING PREVIOUSLY RUNNING SERVICES =========="
        if ((${#services_to_restart[@]})); then
            docker compose start "${services_to_restart[@]}" || result=1
        fi
    fi

    echo "========== BACKUP EXIT: $result =========="
    exit "$result"
}
trap cleanup EXIT

# Confirm Elasticsearch is healthy.
ES_HEALTH="$(docker inspect --format '{{.State.Health.Status}}' elasticsearch)"
if [[ "$ES_HEALTH" != "healthy" ]]; then
    echo "ERROR: Elasticsearch is not healthy: $ES_HEALTH"
    exit 1
fi

# Create and verify the Elasticsearch snapshot.
echo "========== ELASTICSEARCH SNAPSHOT =========="

SNAPSHOT_RESPONSE="$(
    docker exec elasticsearch curl -fsS -X PUT \
      "http://localhost:9200/_snapshot/local_fs_backup/$SNAPSHOT?wait_for_completion=true" \
      -H 'Content-Type: application/json' \
      -d '{"indices":"app-logs-*","feature_states":["kibana"],"include_global_state":true,"partial":false}'
)"

printf '%s\n' "$SNAPSHOT_RESPONSE" \
    > "$BACKUP_ROOT/elasticsearch/$SNAPSHOT.json"

printf '%s' "$SNAPSHOT_RESPONSE" | python3 -c '
import json, sys
snapshot = json.load(sys.stdin)["snapshot"]
print("Snapshot:", snapshot.get("snapshot"))
print("State:", snapshot.get("state"))
print("Shards:", snapshot.get("shards"))
sys.exit(0 if snapshot.get("state") == "SUCCESS"
         and snapshot.get("shards", {}).get("failed") == 0 else 1)
'

echo "Elasticsearch snapshot verified."

# Remember which services were running before the backup.
for service in loki grafana alloy; do
    if docker compose ps --services --status running | grep -Fxq "$service"; then
        services_to_restart+=("$service")
    fi
done

# Stop running services for consistent filesystem archives.
if ((${#services_to_restart[@]})); then
    services_stopped=1
    echo "Stopping: ${services_to_restart[*]}"
    docker compose stop "${services_to_restart[@]}"
fi

# Archive and validate each persistent volume.
archive_volume() {
    local component="$1"
    local volume="$2"
    local archive="$3"
    local volume_name="${VOLUME_PREFIX}_${volume}"
    local archive_path="$BACKUP_ROOT/$component/$archive"

    echo "========== BACKUP $component =========="

    docker volume inspect "$volume_name" >/dev/null

    docker run --rm --network none \
        -v "$volume_name:/source:ro" \
        -v "$BACKUP_ROOT/$component:/backup" \
        nginx:alpine \
        tar -czpf "/backup/$archive" -C /source .

    docker run --rm --network none \
        -v "$BACKUP_ROOT/$component:/backup:ro" \
        nginx:alpine \
        tar -tzf "/backup/$archive" >/dev/null

    echo "Archive verified: $archive_path"
    du -h "$archive_path"
}

archive_volume loki loki_data "loki-data-$STAMP.tar.gz"
archive_volume grafana grafana_data "grafana-data-$STAMP.tar.gz"
archive_volume alloy alloy_data "alloy-data-$STAMP.tar.gz"

# Record checksums for this backup run.
sha256sum \
    "$BACKUP_ROOT/loki/loki-data-$STAMP.tar.gz" \
    "$BACKUP_ROOT/grafana/grafana-data-$STAMP.tar.gz" \
    "$BACKUP_ROOT/alloy/alloy-data-$STAMP.tar.gz" \
    "$BACKUP_ROOT/elasticsearch/$SNAPSHOT.json" \
    > "$BACKUP_ROOT/logs/backup-$STAMP.sha256"

echo "========== BACKUP SUCCESS =========="
cat "$BACKUP_ROOT/logs/backup-$STAMP.sha256"
