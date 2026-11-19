# Phase 2 — Backup, Retention and Recovery

## 1. Backup strategy

The pipeline uses two backup methods:

1. Elasticsearch native filesystem snapshots.
2. Offline archives of Loki, Grafana and Alloy Docker volumes.

Runtime backup data is stored under `backups/` and excluded from Git.

## 2. Backup locations

| Component | Backup location |
|---|---|
| Elasticsearch | `backups/elasticsearch/` |
| Loki | `backups/loki/` |
| Grafana | `backups/grafana/` |
| Alloy | `backups/alloy/` |

## 3. Elasticsearch snapshot

Repository: `local_fs_backup`

Container path: `/usr/share/elasticsearch/snapshots`

Host path: `backups/elasticsearch/`

Snapshot:
- Name: `centralized-logging-2026.11.19`
- Status: SUCCESS
- Indices: 14
- Successful shards: 14
- Failed shards: 0
- Global state: Included
- Kibana feature state: Included

### Verify snapshots

```bash
docker compose exec -T elasticsearch \
  curl -sS 'http://localhost:9200/_cat/snapshots/local_fs_backup?v'
```

### Create a future snapshot

Replace the snapshot name with a unique name.

```bash
docker compose exec -T elasticsearch \
  curl -sS -X PUT \
  'http://localhost:9200/_snapshot/local_fs_backup/REPLACE_WITH_SNAPSHOT_NAME?wait_for_completion=true&pretty' \
  -H 'Content-Type: application/json' \
  -d '{
    "indices": "app-logs-*",
    "feature_states": ["kibana"],
    "include_global_state": true,
    "partial": false
  }'
```

Verify that the snapshot reports SUCCESS and zero failed shards.

## 4. Loki, Grafana and Alloy volume archives

The following Docker volumes were archived while their respective services were stopped:

- `centralized-logging-pipeline_loki_data`
- `centralized-logging-pipeline_grafana_data`
- `centralized-logging-pipeline_alloy_data`

Services were restarted after archive creation.

Backup timestamp: `20261119T060347Z`

| Component | Archive | Approximate size |
|---|---|---:|
| Loki | `backups/loki/loki-data-20261119T060347Z.tar.gz` | 1 MB |
| Grafana | `backups/grafana/grafana-data-20261119T060347Z.tar.gz` | 22 MB |
| Alloy | `backups/alloy/alloy-data-20261119T060347Z.tar.gz` | 8 KB |

Archive integrity and listing checks passed.

### SHA-256 checksums

| Component | SHA-256 |
|---|---|
| Loki | `be06f90402b55cd0afe22e0b9f5a33537db574297c5c55d1f68656b3ac30614c` |
| Grafana | `8e9899e6c82299b98d27cd9c55f8acd1b00d1022105e2685ede3745d97269304` |
| Alloy | `19311df376a1819b3f780fd6f3f90203c7510246afe7c4c8a3b282991bf4fa1d` |

Verify checksums:

```bash
sha256sum \
  backups/loki/loki-data-20261119T060347Z.tar.gz \
  backups/grafana/grafana-data-20261119T060347Z.tar.gz \
  backups/alloy/alloy-data-20261119T060347Z.tar.gz
```

## 5. Retention configuration

### Elasticsearch

The `application-logs-policy` ILM policy is configured with:

- Rollover after 7 days or when the primary shard reaches 5 GB.
- Delete phase after 30 days in the delete phase.

For rolled-over indices, delete-phase age is measured from the rollover lifecycle transition. Actual retention from initial index creation can therefore exceed 30 days.

Legacy date-named application indices use `application-logs-legacy-retention`, with a 30-day delete phase.

The application index template sets replicas to zero because this deployment uses a single Elasticsearch node. Revisit this setting for a multi-node production cluster.

### Loki

`grafana-stack/loki/loki-config.yml` configures:

- Retention period: `720h` (30 days).
- Compactor working directory: `/loki/compactor`.
- Retention enabled.
- Filesystem delete request store.

Configuration validation passed and Loki readiness returned HTTP 200 after restart. Actual retention deletion has not yet been independently verified.

## 6. Safe recovery procedures

**Important:** Never restore directly over live data during a recovery test. Preserve the existing Docker volumes and indices.

### Elasticsearch recovery

1. Verify the snapshot repository and snapshot status.
2. Identify the exact indices or feature states required.
3. Restore into an isolated test environment or use a renamed index.
4. Verify document counts, mappings and index settings.
5. Do not restore global state into the live cluster without reviewing its impact.

For an isolated index restore, Elasticsearch supports `rename_pattern` and `rename_replacement`. Confirm that the destination index does not already exist.

Example request body:

```json
{
  "indices": "app-logs-000001",
  "include_global_state": false,
  "rename_pattern": "app-logs-000001",
  "rename_replacement": "restore-test-app-logs-000001"
}
```

Use this only after confirming the destination index does not exist.

### Loki, Grafana and Alloy recovery

1. Keep the original volumes untouched.
2. Create separate temporary Docker volumes for recovery testing.
3. Extract each archive into its corresponding temporary volume.
4. Inspect the extracted files and ownership.
5. For application-level validation, run isolated test containers with separate ports and configuration.
6. Remove temporary test resources only after confirming they are isolated and no longer needed.

Do not extract archives into production volumes while services are running.

## 7. Backup limitations and operational notes

- The Elasticsearch snapshot is verified successful, but a full restore test is pending.
- Loki, Grafana and Alloy archives passed integrity/listing checks, but full service restore tests are pending.
- `scripts/backup.sh` supports manual execution, and a systemd user timer is enabled for daily execution at 02:00 Asia/Kolkata.
- The timer runs only while the WSL environment is available. With `Persistent=true`, a missed run can be caught up when the user systemd manager starts again.
- These are point-in-time backups, not continuous replication.
- Store an additional copy outside this machine for disaster recovery.
- Protect backup files because they may contain application logs, dashboards and operational metadata.
- Do not commit runtime backup archives or secrets to Git.

## 8. Post-backup service verification

Verification performed on 2026-11-19:

| Component | Result |
|---|---|
| Elasticsearch | GREEN; 40 active shards; 0 unassigned |
| Elasticsearch snapshot | SUCCESS; 14 successful shards; 0 failed |
| Loki | Readiness HTTP 200 |
| Grafana internal health | HTTP 200 |
| Grafana through Nginx | HTTP 200 after Nginx restart |
| Kibana through Nginx | HTTP 200 |
| Alloy | Container running |
| Backup directories | Present and ignored by Git |

## Restore Validation — 2026-11-19

Restore tests were performed using isolated destinations. Production data
volumes and original Elasticsearch application indices were preserved.

### Elasticsearch snapshot restore

- Snapshot: `centralized-logging-2026.11.19`
- Snapshot state: `SUCCESS`
- Snapshot shards: 14 successful, 0 failed
- Restored source index: `app-logs-000001`
- Restore destination: `restore-test-app-logs-000001`
- Restored shards: 1 successful, 0 failed
- Original document count: 6,877
- Restored document count: 6,877
- Restored index health: green
- Cluster health after restore: green, 0 unassigned shards

The restore used a renamed index, without restoring aliases or global state.
The original application index was not overwritten.

This validates restoration of one application index. A full-cluster restore
and Kibana feature-state restore have not been tested.

### Filesystem archive restore tests

Each archive was extracted into a separate temporary Docker volume.
The live service volumes were not modified.

| Component | Test volume | Extracted size | Files | Result |
|---|---|---:|---:|---|
| Loki | `restore_test_loki` | 1.9 MB | 79 | Passed |
| Grafana | `restore_test_grafana` | 50.8 MB | 262 | Passed |
| Alloy | `restore_test_alloy` | 20 KB | 2 | Passed |

Archive integrity checks and extraction completed successfully.
These tests validate archive readability and extraction, not application-level
startup or service recovery from the restored volumes.

Temporary restore volumes are intentionally retained pending cleanup approval.

### Production health after restore tests

- Elasticsearch cluster: GREEN, 41 active shards, 0 unassigned
- Loki readiness: HTTP 200
- Grafana health: database OK, HTTP 200
- Kibana status endpoint: HTTP 200
- Alloy: running
- User, Order, Payment services: healthy
- Filebeat and Logstash: running
- Nginx: running

All checked production services remained operational after the restore tests.

## Health Checks & Service Monitoring — 2026-11-19

Docker Compose health checks are configured for all 11 services.

| Service | Health-check endpoint / method | Result |
|---|---|---|
| Elasticsearch | `/_cluster/health` | Healthy |
| Kibana | `/api/status` | Healthy |
| Logstash | `:9600/` monitoring API | Healthy |
| Filebeat | `:5066/` HTTP monitoring endpoint | Healthy |
| Loki | `/ready` | Healthy |
| Grafana | `/api/health` | Healthy |
| Nginx | HTTPS `/api/status` through local proxy | Healthy |
| Alloy | `/-/ready` on port 12345 | Healthy |
| User service | `/health` on port 3001 | Healthy |
| Order service | `/health` on port 3002 | Healthy |
| Payment service | `/health` on port 3003 | Healthy |

### Configuration and verification

- Health-check intervals: 30 seconds for the newly added checks.
- Health-check timeouts: 10 seconds.
- Retry count: 5 for the newly added checks.
- Startup grace periods are configured according to service startup requirements.
- Filebeat HTTP monitoring is enabled on container loopback port 5066.
- Alloy readiness is checked using Bash TCP connectivity because its image
  does not include curl or wget.
- Existing Elasticsearch and application-service health checks were preserved.
- Existing service dependencies and restart policies were preserved.
- Docker Compose configuration validation passed.
- All 11 containers reported `healthy` after deployment.
- Kibana HTTPS route through Nginx returned HTTP 200.
- Grafana HTTPS route through Nginx returned HTTP 200.

Health checks expose service health to Docker Compose. They do not, by
themselves, automatically restart containers when a health check fails.

## Automated Daily Backups — 2026-11-19

### Schedule

A user-level systemd timer runs the backup script every day at **02:00 Asia/Kolkata (IST)**.

- Script: `scripts/backup.sh`
- Service: `centralized-logging-backup.service`
- Timer: `centralized-logging-backup.timer`
- Timer configuration: `~/.config/systemd/user/centralized-logging-backup.timer`
- Service configuration: `~/.config/systemd/user/centralized-logging-backup.service`
- Schedule: `OnCalendar=*-*-* 02:00:00 Asia/Kolkata`
- `Persistent=true`: a missed scheduled run is triggered when the user systemd manager becomes available again.
- User lingering is enabled so the user timer can run without an active login session.

Enable or inspect the timer:

    systemctl --user enable --now centralized-logging-backup.timer
    systemctl --user status centralized-logging-backup.timer
    systemctl --user list-timers --all

### Backup procedure

The script:

1. Checks that Elasticsearch is healthy.
2. Creates a named Elasticsearch snapshot of `app-logs-*`, including Kibana feature state and global state.
3. Verifies that the snapshot completed successfully with no failed shards.
4. Records which of Loki, Grafana, and Alloy were running.
5. Stops those running services to create consistent filesystem archives of their persistent volumes.
6. Validates each archive by listing its contents.
7. Generates SHA-256 checksums.
8. Restarts the services that were running before the backup, including on script failure through its exit cleanup handler.

Backup data is stored under the ignored `backups/` directory:
- `backups/elasticsearch/` — Elasticsearch snapshot repository and snapshot response metadata.
- `backups/loki/` — Loki persistent-volume archives.
- `backups/grafana/` — Grafana persistent-volume archives.
- `backups/alloy/` — Alloy persistent-volume archives.
- `backups/logs/` — execution logs and checksum files.

### Validation performed

- The backup script passed Bash syntax validation.
- A manual backup run completed successfully.
- A systemd oneshot service run completed successfully.
- Elasticsearch snapshots reported `SUCCESS` with zero failed shards.
- Loki, Grafana, and Alloy archives passed tar integrity/listing validation.
- SHA-256 checksums were generated.
- After the systemd backup run, all 11 Compose services were healthy.
- Loki readiness returned `ready`.
- Kibana HTTPS returned HTTP 200.
- Grafana HTTPS initially returned HTTP 502 after the Grafana restart; restarting Nginx refreshed its upstream connection, after which Grafana HTTPS returned HTTP 200.

### Operational limitations

- Backups are stored locally; off-machine or off-site replication is not configured.
- Automatic backup pruning/retention is not configured. Backup storage will grow until a cleanup policy is deliberately introduced.
- The timer does not keep WSL running. If the WSL distribution is stopped at the scheduled time, `Persistent=true` can trigger a catch-up run when the distribution and user systemd manager start again.
- The automated procedure backs up Elasticsearch through snapshots and archives the Loki, Grafana, and Alloy data volumes. It does not create a complete image of the host or back up every application/configuration file.
- Configuration files should remain version-controlled separately. Protect `.env` and other secrets through a separate secure backup process; do not add them to ordinary project archives.
- Archive extraction and a selected Elasticsearch index restore were tested. A complete service-level disaster recovery exercise, including starting restored Loki and Grafana data, remains outstanding.
- If Grafana returns HTTP 502 through Nginx after a backup restart, check Grafana health and restart Nginx if its upstream connection is stale.
