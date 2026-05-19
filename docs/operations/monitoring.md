# LawVoice Monitoring and Load Testing

## Stack

The Docker Compose stack now includes:

- `prometheus` for metrics scraping and alert rule evaluation
- `grafana` for dashboards
- `alertmanager` for alert routing

The provisioning files live under `ops/monitoring/`.

## Backend metrics

The backend exports Prometheus metrics at `/metrics`.

Key metric groups:

- `lawvoice_http_*` for route throughput and latency
- `lawvoice_knowledge_search_*` for RAG retrieval rate, latency and hit counts
- `lawvoice_action_plan_*` for grounded plan generation
- `lawvoice_llm_*` for embedding and action-plan LLM latency
- `lawvoice_component_up` for coarse component health
- `lawvoice_knowledge_documents` and `lawvoice_knowledge_chunks` for RAG footprint

The endpoint is private by default:

- `METRICS_PRIVATE_ONLY=true` allows only private-network scrapers such as Docker-internal Prometheus
- `METRICS_AUTH_TOKEN` can be configured for explicit header-based access if needed

## Readiness and health

- Health endpoint: `/api/health`
- Readiness endpoint: `/api/ready`

`/api/ready` is intended for deployment checks and simple uptime monitoring.

## Grafana

Grafana is provisioned with:

- a Prometheus datasource
- the `LawVoice Observability` dashboard

By default, Grafana is bound to `127.0.0.1:3001` in Docker Compose to avoid public exposure.

## Alerting

Prometheus loads alert rules from `ops/monitoring/prometheus/alerts.yml`.

Current baseline alerts:

- backend scrape unavailable
- elevated 5xx rate
- high empty-retrieval rate
- high p95 action-plan latency

Alertmanager is included with a placeholder receiver so the stack is deployable without immediately wiring external notifications.

## Multi-user load testing

Use `tools/run_multiuser_loadtest.mjs` for basic concurrent smoke testing.

Example:

```bash
BASE_URL=http://127.0.0.1:3000 CONCURRENCY=8 REQUESTS_PER_WORKER=20 SCENARIO=knowledge-search node tools/run_multiuser_loadtest.mjs
```

Action-plan scenario:

```bash
BASE_URL=http://127.0.0.1:3000 CONCURRENCY=5 REQUESTS_PER_WORKER=10 SCENARIO=action-plan node tools/run_multiuser_loadtest.mjs
```

If the environment does not expose `/api/auth/token`, provide a pre-issued bearer token via `AUTH_TOKEN`.
