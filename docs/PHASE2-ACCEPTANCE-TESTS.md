# Phase 2 — Acceptance and Performance Tests

**Test date:** 2026-11-19

This document records the acceptance checks performed against the running
Centralized Logging Pipeline. Results distinguish verified behavior from
configuration that has not yet been observed over its full lifecycle.

## Acceptance summary

| Area | Verification | Result |
|---|---|---|
| PII redaction | Elasticsearch scan of 12,495 documents | PASS |
| Error alert | Controlled firing and recovery test | PASS |
| ILM configuration | 7-day rollover and 30-day deletion policy inspected | PASS — configuration |
| Elasticsearch heap | 398.08 MiB used, 512 MiB maximum | PASS |
| Filebeat to Elasticsearch latency | 3.86 seconds | PASS |
| Loki 24-hour query | Maximum 0.089 seconds across three trials | PASS |
| Filebeat to Logstash TLS | TLS 1.3 handshake and end-to-end event verified | PASS |
| Kibana authentication | Unauthenticated request 401; authenticated request 200 | PASS |
| Trace ID filtering | Loki structured-metadata query returned matching event | PASS — backend |

## 1. PII redaction

Scanned 12,495 Elasticsearch documents across `app-logs-*`.

- Email-pattern matches: **0**
- Non-redacted sensitive field values: **0**
- Sensitive fields encountered included email, password, authorization,
  accessToken, and cardNumber.
- The separate PII test fixture contained two valid JSON records and eight
  redacted sensitive values, with zero email-pattern matches.

**Result:** PASS for the scanned data. This is a point-in-time verification,
not a guarantee about future events or untested logging paths.

## 2. Grafana error alert

Verified the `ApplicationErrorLogs` rule.

- Query: `sum(count_over_time({job="application", level="50"}[1m]))`
- Threshold: greater than 5 errors in one minute.
- Pending duration: 1 minute.
- Evaluation interval: 60 seconds.
- Severity: warning.

A controlled error-log test caused the rule to enter the `firing` state.
After the test events aged out of the evaluation window, the rule returned
to `inactive`.

**Result:** PASS — firing and recovery verified.

External notification delivery was not tested.

## 3. Elasticsearch index lifecycle configuration

Verified the `application-logs-policy` and write alias.

- Rollover: maximum age 7 days or primary shard size 5 GB.
- Deletion: minimum age 30 days.
- Write alias: `app-logs-write`.
- Current write index at verification: `app-logs-000001`.

The ILM explain API reported the index as managed and in the hot phase,
checking rollover readiness.

**Result:** PASS — policy and lifecycle state verified.

The actual 7-day rollover and 30-day deletion events have not been
observed; no forced rollover or deletion was performed for this test.

## 4. Elasticsearch JVM heap

Observed Elasticsearch JVM heap statistics:

| Metric | Value |
|---|---:|
| Heap used | 398.08 MiB |
| Heap maximum | 512 MiB |
| Acceptance ceiling | 2 GiB |

**Result:** PASS — observed heap usage was below the 2 GiB ceiling.

## 5. Filebeat-to-Elasticsearch ingestion latency

The initial test measured 17.88 seconds. Filebeat's filestream scanner
interval was changed to 1 second, the configuration was validated, and
Filebeat was recreated.

The subsequent test wrote a fresh unique JSON event and polled
Elasticsearch until that exact marker appeared.

| Measurement | Result |
|---|---:|
| Initial latency | 17.88 seconds |
| Retest latency | 3.86 seconds |
| Acceptance target | Under 5 seconds |

The retest event was found in `app-logs-000001`.

**Result:** PASS — 3.86 seconds.

## 6. Loki 24-hour query performance

Executed the same query three times against the previous 24-hour range:

`{job="application"}`

The query used a 1,000-entry result limit and backward direction.

| Trial | Duration | Entries returned | Bytes processed |
|---|---:|---:|---:|
| 1 | 0.089 s | 1,000 | 959,243 |
| 2 | 0.074 s | 1,000 | 959,243 |
| 3 | 0.080 s | 1,000 | 959,243 |

- Average: **0.081 seconds**
- Maximum: **0.089 seconds**
- Acceptance target: under 1 second.

**Result:** PASS for this query and result limit. This does not measure
an unlimited full-range export.

## 7. Transport security and Kibana access

### Filebeat to Logstash

- Filebeat validates the Logstash server certificate against the configured
  private CA and verifies the `logstash` hostname.
- TLS handshake succeeded using TLS 1.3.
- Beats protocol communication succeeded.
- A uniquely identified test event was subsequently found in Elasticsearch.

**Result:** PASS — end-to-end Filebeat → TLS → Logstash → Elasticsearch
verification.

Client certificate authentication (mutual TLS) is not enabled.

### Kibana reverse-proxy authentication

Verified the HTTPS Nginx reverse proxy:

- Request without credentials: HTTP 401.
- Request with the configured `kibana-admin` credentials: HTTP 200.
- Grafana health endpoint remained accessible.

**Result:** PASS — reverse-proxy Basic Authentication verified.

This does not enable native Elasticsearch security. Internal network
clients that bypass the proxy are outside this authentication check.

## 8. Trace ID filtering

Verified that `traceId` is extracted by Grafana Alloy and stored as Loki
structured metadata rather than a high-cardinality stream label.

A LogQL query using the structured metadata filter:

`{job="application"} | traceId="<trace-id>"`

returned the matching event.

A Grafana Loki datasource derived field named `traceId` was also saved
and read back through the Grafana API.

**Result:** PASS — backend filtering and derived-field configuration
verified. Browser-based clicking of the derived-field link remains
pending.

## 9. Backup and restore verification

- Elasticsearch snapshot completed successfully with 14 shards and no
  failed shards.
- An Elasticsearch application index restore test recovered all 6,877
  documents into a separate test index.
- Loki, Grafana, and Alloy volume archives were created and archive
  contents were validated.
- Temporary restore-test volumes were populated and extraction was
  validated.
- A manual backup script completed successfully.
- A systemd user timer was enabled for daily execution at 02:00 IST.

A complete production recovery exercise, offsite backup, and automated
backup-failure alerting have not been completed. The WSL environment must
be running for the scheduled timer to execute; persistent scheduling
allows a missed run to be caught up when the environment starts again.

See [Phase 2 Backup and Restore](PHASE2-BACKUP-RESTORE.md).

## Remaining verification and operational work

- Observe actual ILM rollover and deletion when their configured ages are
  reached.
- Verify Loki retention deletion after its retention period.
- Complete a browser-based Grafana trace ID derived-field click test.
- Validate external alert notification delivery if a notification
  destination is configured.
- Plan offsite backup storage, backup pruning, and a full recovery exercise.
- Monitor certificate expiry and perform renewal before expiration.
