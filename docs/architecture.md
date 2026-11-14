# System Logging Architecture

## Overview
This document outlines the logging architecture for our three core Node.js microservices (**User Service**, **Order Service**, and **Payment Service**). 

All services write structured JSON logs to a shared log directory or standard output. Two parallel pipelines (**Pipeline A: ELK Stack** and **Pipeline B: Grafana Stack**) consume these exact same logs independently for indexing, querying, and visualization.

---

## Shared Log Source
* **Services:** User Service, Order Service, Payment Service (Node.js).
* **Output Format:** Structured JSON logs (including timestamps, log levels, service names, and trace IDs).
* **Shared Consumption:** Both Filebeat and Grafana Alloy tail the same log files simultaneously, ensuring zero code duplication inside the Node.js applications.

---

## Pipeline A — ELK Stack

### Architecture Flow
```text
User Service ──┐
Order Service ─┼── JSON Logs
Payment Service┘
                  |
               Filebeat
                  |
               Logstash
                  |
            Elasticsearch
                  |
                Kibana
```

### Component Breakdown
* **Filebeat (Log Shipper):** Monitors the shared JSON log files on the host and forwards new log lines to Logstash with minimal CPU overhead.
* **Logstash (Processor):** Parses incoming JSON logs, enriches fields, filters out debug noise, and formats the data for indexing.
* **Elasticsearch (Storage & Search):** Stores the processed logs and indexes every field for fast, full-text search and complex queries.
* **Kibana (Visualization):** Connects to Elasticsearch to provide deep log exploration, search dashboards, and error tracking.

---

## Pipeline B — Grafana Stack

### Architecture Flow
```text
Three Node.js Services
          |
      JSON Logs
          |
     Grafana Alloy
          |
         Loki
          |
       Grafana
```

### Component Breakdown
* **Grafana Alloy (Telemetry Collector):** Tails the same shared JSON log files, extracts key metadata labels (such as `service_name` and `level`), and pushes the stream to Loki.
* **Loki (Log Aggregation):** Stores compressed log chunks indexed only by metadata labels rather than full text, keeping storage lightweight and cost-effective.
* **Grafana (Visualization):** Queries Loki using LogQL to display real-time log streams, error rate panels, and system alerts.

---

## Pipeline Comparison

| Feature | Pipeline A (ELK) | Pipeline B (Grafana) |
| :--- | :--- | :--- |
| **Log Collector** | Filebeat + Logstash | Grafana Alloy |
| **Storage Engine** | Elasticsearch | Loki |
| **Indexing Method** | Full-text indexing of all JSON fields | Label-only indexing (lightweight) |
| **Primary Strength** | Deep, complex text searches and analytics | Fast tailing, lower storage cost, unified metrics/logs |
