# Phase 1 — Centralized Logging Pipeline

**Validation date:** 2026-11-18

## Architecture

Three Node.js services produce structured JSON logs using Pino.

Two centralized logging pipelines:

1. Filebeat → Logstash → Elasticsearch → Kibana
2. Grafana Alloy → Loki → Grafana

Nginx provides HTTPS reverse-proxy access to Kibana and Grafana.

## Implemented capabilities

- Structured JSON logging across user, order, and payment services.
- Request ID propagation across service calls.
- Elasticsearch indexing through Filebeat and Logstash.
- Loki ingestion through Grafana Alloy.
- Sensitive-field redaction in application logs.
- Query-string protection in request logging.
- Logstash filtering of `/health` requests.
- Kibana data view and five-panel application-log dashboard.
- Grafana application-log dashboard.
- Grafana application error alert.
- Alert firing and recovery validation.
- Kibana saved-object export.
- Grafana alert configuration export.
- End-to-end integration tests: 16 passed.

## Grafana alert

- UID: `app-error-logs`
- Name: `ApplicationErrorLogs`
- Query: `sum(count_over_time({job="application", level="50"}[1m]))`
- Condition: greater than 5
- Pending duration: 1 minute
- Evaluation interval: 60 seconds
- Severity: warning

A controlled error test produced six matching errors in the one-minute window. Grafana entered the `firing` state with health `ok`. After the error window cleared, the alert returned to `inactive`.

Alert export:

`grafana-stack/exports/application-error-alert.json`

This is an API export/backup, not an automatically provisioned Grafana rule.

## Kibana dashboard

Dashboard: `Centralized Application Logs`

Panels:
1. Log Volume Over Time
2. Logs by Service
3. Logs by Severity
4. Top Request Paths
5. Top Log Messages

Saved-object export:

`kibana/exports/centralized-application-logs.ndjson`

## Validation coverage

- Docker Compose configuration.
- Application health endpoints.
- Loki readiness.
- Kibana and Grafana HTTPS endpoints.
- Elasticsearch cluster health.
- Grafana alert firing and recovery.
- Logstash health-check filtering.
- Saved dashboard and alert export structure.
- Sixteen end-to-end integration checks.

## Known limitations and future improvements

- GeoIP enrichment is deferred until client IP addresses are reliably available through a trusted reverse proxy.
- `traceId` currently mirrors the request ID; it is not a real OpenTelemetry distributed trace ID.
- External alert notification delivery has not been validated.
- Retention and lifecycle policies require separate validation before claiming a production retention guarantee.
- Arbitrary free-form log messages are not automatically guaranteed to be free of sensitive information.

## Start the stack

`docker compose up -d`

Import the Kibana saved-object export through Kibana Saved Objects when needed. The Grafana alert JSON is retained as a backup/reference and requires a separate restore or provisioning step.
