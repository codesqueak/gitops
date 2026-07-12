# Port Usage Reference

## Infrastructure

| Port | Protocol | Component | Purpose |
|------|----------|-----------|---------|
| 80   | HTTP     | ingress-nginx | HTTP ingress |
| 443  | HTTPS    | ingress-nginx | HTTPS ingress |

## Observability

| Port | Protocol | Component | Purpose |
|------|----------|-----------|---------|
| 8333 | HTTP     | SeaweedFS | S3 API — used by Mimir, Loki and Tempo for object storage |
| 80   | HTTP     | Grafana | Dashboard UI |
| 4317 | gRPC     | Alloy | OTLP gRPC receiver — accepts telemetry from Spring Boot apps |
| 4318 | HTTP     | Alloy | OTLP HTTP receiver — accepts telemetry from Spring Boot apps |
| 12345 | HTTP    | Alloy | Alloy's own UI/metrics endpoint (self-monitoring, not for app telemetry) |
| 4317 | gRPC     | Tempo distributor | OTLP gRPC ingestion from Alloy |
| 4318 | HTTP     | Tempo distributor | OTLP HTTP ingestion from Alloy |
| 3200 | HTTP     | Tempo query-frontend | Trace query API — used by Grafana datasource |
| 8080 | HTTP     | kube-state-metrics | Prometheus metrics scrape endpoint |
| 9100 | HTTP     | prometheus-node-exporter | Prometheus metrics scrape endpoint |

## Application Services

Allocated block: **8000–8099**

| Port      | Protocol | Component | Purpose                      |
|-----------|----------|-----------|------------------------------|
| 8000      | HTTP     | motd      | Spring Boot service          |
| 8001      | HTTP     | api       | Spring Boot service          |
| 8002      | HTTP     | auth      | Spring Boot service          |
| 8003      | HTTP     | frontend  | Spring Boot service          |
| 8004      | HTTP     | scheduler | Spring Boot service          |
| 8005      | HTTP     | worker    | Spring Boot service          |
| 8006-8099 | -        | reserved  | Future application services  |

`motd-ui` isn't part of this block - it's a React SPA served via nginx, not a Spring Boot service. Its
container listens on nginx's own default of `8080` (Service `80` → container `8080`, per
`gitops-repo/charts/motd-ui/values.yaml`), which happens to fall numerically inside 8000-8099 but isn't
allocated from it - don't assign a future Spring Boot service `8080` without checking this first.

| Port | Protocol | Component | Purpose |
|------|----------|-----------|---------|
| 8080 | HTTP | motd-ui | nginx container port (Service exposes `80`) - static SPA + `/api/` reverse proxy to motd |

## Notes

- Mimir and Loki are accessed internally via their gateway service on port 80 — no fixed external port required.
- Spring Boot services must not use port 8333 (SeaweedFS S3 API).
- OTLP ports 4317 and 4318 are the OpenTelemetry standard and should be used consistently across all Spring Boot services.
