# BankObs dashboard-generation prompts (tested & grounded on the live stack, updated 2026-11-09)

These are tuned against the real `project-eks` stack, not assumptions. Paste **SHARED CONTEXT**
once at the start of the agent session, then feed the dashboard prompts one at a time.

> **UPDATE 2026-11-09 — BankObs now HAS Prometheus RED metrics.** The OTel Collector runs a
> **`spanmetrics` connector** (`observability/values/otel-collector.yaml`): every BankObs span is
> turned into `calls_total` + `duration_milliseconds` per `service_name`, remote-written to
> Prometheus **with `trace_id` exemplars**. So you can now build real metric dashboards for
> BankObs and start an investigation from a metric (the grafana→metric→trace→log path). The
> reference board is `observability/dashboards/bankobs-red-spanmetrics.yaml`. The notes below that
> say "bankobs has no metrics / no histograms" are superseded — read them as "no *scraped app*
> metrics (no `/metrics`, no kube-state/cAdvisor for bankobs); RED comes from spanmetrics."

## What live testing established (the facts every prompt is grounded in)

- **BankObs app services expose no `/metrics` of their own** — no scraped app metrics, and the obs
  Prometheus has no kube-state-metrics/cAdvisor for the bankobs cluster (those are per-cluster).
  **BUT** the `spanmetrics` connector now derives per-service **RED metrics from traces**
  (`calls_total`, `duration_milliseconds_*`, labels incl. `service_name`, `status_code`,
  `http_status_code`, `span_kind`) **with exemplars** → Prometheus. So BankObs dashboards can be
  **metric (RED) + Loki + Jaeger**, all three. Logs + traces are still the richest per-service
  signal; use metrics for the golden-signal overview and the metric→trace exemplar jump.
- **Datasource UIDs** (reference via datasource template vars, never hardcode): `prometheus`,
  `loki`, `jaeger`, `pyroscope`.
- **Click-through is already wired at the datasource level** — panels inherit it, don't rebuild it:
  - log line → trace: Loki `derivedFields` on `trace_id` → Jaeger
  - trace → logs: Jaeger `tracesToLogsV2` → Loki (`filterByTraceID`, tag `service.name→service_name`)
  - trace → profiles: Jaeger `tracesToProfiles` → Pyroscope
  - metric → trace: Prometheus exemplar `trace_id` → Jaeger — now works for **bankobs** too, via
    the spanmetrics `duration_milliseconds_bucket` exemplars (verified live)
- **Real Loki labels**: `service_name`, `service_namespace` (="bankobs"), `k8s_namespace_name`,
  `k8s_pod_name`, `k8s_deployment_name`, `k8s_container_name`, `detected_level`,
  `deployment_environment`. **Log level is NOT a selector label** — group by `detected_level`,
  but match errors with a line filter: `` |~ `(?i)\b(error|exception|fatal|panic)\b` ``.
- **App logs carry `trace_id`** (confirmed on payment-gateway) — that is the logs↔traces join key.
- **Service dropdown** = Loki query variable `label_values({service_namespace="bankobs"}, service_name)`.
- **Jaeger query API base path** is `/jaeger`; use the `jaeger` datasource for trace panels/search.
- **Provisioning**: Kubernetes ConfigMap in namespace `monitoring`, label `grafana_dashboard: "1"`,
  annotation `grafana_folder: "<Folder>"`, data key `<name>.json`. The kube-prometheus-stack
  Grafana sidecar (WATCH) picks it up in ~20s. Working template:
  `observability/dashboards/bankobs-service-health.yaml`.

---

## SHARED CONTEXT — paste once, first

```
You generate Grafana dashboards for the project-eks observability lab. GROUND TRUTH (already
verified on the live stack — do not re-litigate, but DO verify your own queries return data):

DATA REALITY
- BankObs (the app, ~60 services in a SEPARATE cluster) pushes LOGS (Loki) and TRACES (Jaeger),
  AND — via the Collector's spanmetrics connector — per-service RED METRICS to Prometheus
  (`calls_total`, `duration_milliseconds_*`, with trace_id exemplars). So a BankObs dashboard can
  use Prometheus (RED/golden signals, metric→trace exemplars), Loki (logs) and Jaeger (traces).
  What BankObs still does NOT have in this Prometheus: scraped app `/metrics`, and kube-state/
  cAdvisor for the bankobs cluster (node/pod CPU, mem, restarts) — those are per-cluster, obs only.
- Datasource UIDs: prometheus, loki, jaeger, pyroscope. Reference them via datasource template
  variables (${ds_loki} etc.), never a hardcoded uid.

CLICK-THROUGH (HARD REQUIREMENT, inherited from datasource config — do not rebuild it):
  log line --trace_id--> Jaeger trace --tracesToLogsV2--> Loki logs  (--> Pyroscope profile)
  EVERY dashboard MUST include at least one Loki logs panel (so trace_id is clickable → Jaeger)
  and, where traces are relevant, a Jaeger trace panel/search. That single logs panel is what
  guarantees "click to a trace, and from the trace back to logs" on every board.

LOKI FACTS
- Labels: service_name, service_namespace(="bankobs"), k8s_namespace_name, k8s_pod_name,
  k8s_deployment_name, k8s_container_name, detected_level, deployment_environment.
- Log level is NOT a label selector. Group by detected_level; match errors with a LINE FILTER:
  |~ `(?i)\b(error|exception|fatal|panic)\b`
- Service dropdown variable: label_values({service_namespace="bankobs"}, service_name)
- Rates use [$__rate_interval]; a "request rate" proxy for bankobs is log-line rate.

PROMETHEUS FACTS
- BankObs RED (from spanmetrics, these ARE per bankobs service):
    calls_total{service_name, status_code, http_status_code, http_method, http_route, span_kind}
    duration_milliseconds_bucket/_sum/_count{...same labels..., le}
  For RED filter span_kind="SPAN_KIND_SERVER" (inbound). Error rate =
    sum(rate(calls_total{service_name="$svc",status_code="STATUS_CODE_ERROR"}[$__rate_interval]))
    / clamp_min(sum(rate(calls_total{service_name="$svc",span_kind="SPAN_KIND_SERVER"}[...])),0.001)
  (or http_status_code=~"5.."). p95 =
    histogram_quantile(0.95, sum by (le)(rate(duration_milliseconds_bucket{service_name="$svc",
    span_kind="SPAN_KIND_SERVER"}[$__rate_interval]))). Service dropdown (metric side):
    label_values(calls_total{span_kind="SPAN_KIND_SERVER"}, service_name). Exemplars: enable
    "exemplar" on duration panels → trace_id → Jaeger.
- OBS CLUSTER + STACK (not bankobs): node-exporter (node_*), kube-state-metrics (kube_*, label
  `namespace`), cAdvisor (container_*), the obs components (label `service_name`), otelcol/collector
  + Loki + Prometheus self-metrics, Pyrra recording rules.

PROVISIONING
- Output each dashboard as a ConfigMap in namespace `monitoring`, label `grafana_dashboard: "1"`,
  annotation `grafana_folder: "<folder>"`, data key `<name>.json`. Model it on
  observability/dashboards/bankobs-service-health.yaml. Extend a `make dashboards` target that
  applies observability/dashboards/*.yaml with the obs-v1-observability context.

CONVENTIONS
- Always include datasource template vars + a `service` var where per-service. Multi-select +
  chained where it helps. Short legends ({{service_name}}, {{detected_level}}). Consistent units.
  Group panels into labelled rows. All dashboards should look like one system.

DONE = VERIFIED, NOT just valid JSON. Apply the ConfigMap, confirm Grafana ingested it
(GET /api/search and /api/dashboards/uid/<uid> via admin:admin@kps-grafana), run some traffic,
and confirm no panel is empty. Report any panel you cannot populate and why. Deliver one
dashboard per prompt; wait for each prompt.
```

---

# GROUP A — BankObs dashboards. Every one has the click-through.

## PROMPT 0 — RED (spanmetrics)  [reference already built — the metric cockpit]
```
Build/refresh "BankObs — RED (spanmetrics)" on the Prometheus datasource — the board an operator
opens FIRST and drills metric→trace→log from. Templated by $service
(label_values(calls_total{span_kind="SPAN_KIND_SERVER"}, service_name)). Panels: request rate,
error % (green/yellow/red at 1/5%), p95 & p99 latency stats; request-rate-by-status_code
timeseries; a p50/p95/p99 latency timeseries WITH exemplars enabled (trace_id → Jaeger); a fleet
"error rate by service" timeseries + a table ranked by error rate whose rows data-link to Jaeger;
and — so the board also satisfies metric→trace→log on one screen — a Loki error-logs panel for
$service (trace_id clickable). Use calls_total / duration_milliseconds_bucket, span_kind=
"SPAN_KIND_SERVER". Folder "BankObs". A working version exists at
observability/dashboards/bankobs-red-spanmetrics.yaml — treat it as the template to extend.
```

## PROMPT 1 — Service Health (logs + traces)  [reference already built]
```
Build/refresh "BankObs — Service Health (logs + traces)", templated by a $service variable
(label_values({service_namespace="bankobs"}, service_name), default payment-gateway). Panels:
log throughput (lines/s) stat; error-log rate stat (line-filter errors) with green/red threshold;
log volume by detected_level (stacked timeseries); request-vs-error timeseries; and a Loki LOGS
panel for the service with log details enabled (trace_id clickable → Jaeger → tracesToLogsV2 back
to Loki). Folder "BankObs". A working version exists at
observability/dashboards/bankobs-service-health.yaml — treat it as the template to extend.
```

## PROMPT 2 — Payment Tier Deep-Dive (the correlation showcase)
```
Build "BankObs — Payment Tier" for the Go payment services (gateway-service, payment-gateway,
payment-router, upi-service, and any neft/rtgs/imps/nach rail services present — confirm via
label_values). This tier is OTel-traced and stamps trace_id into logs, so it's the correlation
star. Rows: per-rail LOG request/error rate (Loki, grouped by service_name); an embedded Jaeger
trace-search panel for the selected rail (datasource jaeger); a Loki logs panel of the tier's
error lines (|~ error-regex) with trace_id clickable; and a short text panel describing the demo
path: error spike → click a log's trace_id → Jaeger trace → "Logs for this span" → back to Loki.
Variables: ds_loki, ds_jaeger, rail/service multi-select. Folder "BankObs".
```

## PROMPT 3 — Error Triage / Logs Explorer (fleet-wide)
```
Build "BankObs — Error Triage" on Loki across all of namespace bankobs. Panels: total error-log
rate over time (line-filter errors); top offending services by error rate (sum by (service_name),
table, sorted desc, each row links to the Service Health dashboard passing $service); log volume
by detected_level stacked; a live-tail Loki logs panel filtered by $service/$level/$search with
details enabled (trace_id → Jaeger). Add a `search` text variable piped into a |= filter and a
`level` variable over detected_level. Variables: ds_loki, service (All), level, search. Folder
"BankObs".
```

## PROMPT 4 — Traces Overview
```
Build "BankObs — Traces" on the Jaeger datasource. Panels: an embedded Jaeger trace-search panel
(service variable from the Jaeger service list), a panel/notes for slowest and errored traces,
and — crucially — a companion Loki logs panel for the same $service so a trace's trace_id and the
logs line up on one screen (trace → logs via tracesToLogsV2, logs → trace via derived field).
The collector's spanmetrics connector IS enabled now, so ALSO add a trace-derived RED row from
Prometheus (request rate, error %, p95 from calls_total/duration_milliseconds_bucket for $service)
with exemplars on the latency panel → Jaeger. Variables: ds_jaeger, ds_loki, ds_prom, service.
Folder "BankObs".
```

## PROMPT 5 — Fleet Overview (log-derived golden signals)
```
Build "BankObs — Fleet Overview", the single top pane, entirely from Loki. Stat row: total log
throughput, total error-log rate, # services logging, # services currently emitting errors.
Timeseries: log rate by service_name (top N), error rate by service_name (top N). Table: services
ranked by error rate, each row data-linking to the Service Health dashboard ($service) and to
Jaeger for that service. Include one fleet-wide Loki logs panel of recent errors (trace_id
clickable) so even the overview satisfies logs→trace→logs. Variables: ds_loki, ds_jaeger. Folder
"BankObs".
```

## PROMPT 6 — Incident Drill
```
Build "BankObs — Incident Drill" tuned to an induced incident (pick a drill from
FAULT-SCENARIOS.md, e.g. scaling a dependency down). One-screen before/during/after story from logs+traces for a
$target service and its dependents: error-log rate for the target, error blast radius across
services (sum by service_name), a Loki logs panel of the target's errors with trace_id clickable,
and an embedded Jaeger search for the target so the instructor clicks a failing trace → its logs.
Enable dashboard annotations so drill start/stop marks the timelines. Variables: ds_loki,
ds_jaeger, target service. Folder "BankObs".
```

# GROUP B — Platform / Infra dashboards (Prometheus — OBS cluster + stack only)

## PROMPT 7 — Observability Cluster USE
```
Build "Platform — Obs Cluster USE" from node-exporter + kube-state-metrics + cAdvisor (these
describe the OBSERVABILITY cluster only). UTILIZATION: node CPU/mem %, disk, network. SATURATION:
load vs cores, memory pressure, pods pending, throttled containers. ERRORS: NotReady nodes,
OOMKills, pod restarts, failed pods. Note explicitly in a text panel that this covers the obs
cluster; bankobs-cluster node/pod metrics are not in this Prometheus. Variables: ds_prom, node.
Folder "Platform".
```

## PROMPT 8 — Telemetry Pipeline Health (meta-observability)
```
Build "Platform — Telemetry Pipeline" to watch the stack itself and explain gaps. OTel collector:
received/refused/dropped spans+metrics+logs, exporter send failures, queue size (discover the real
otelcol_* names first). bankobs-agent (DaemonSet in the bankobs cluster, forwards over peering):
scrape up/down, forward errors. Prometheus: remote-write/ingestion rate, TSDB series, scrape
failures. Loki: ingestion rate, rejected lines. Add a panel that surfaces WHY bankobs has no app
metrics (only target_info) so students see the pipeline reality. Variables: ds_prom. Folder
"Platform".
```

## PROMPT 9 — SLO & Error Budget (Pyrra)
```
Build "Platform — SLOs" from Pyrra's recording rules (discover the generated series and the SLO
CRs; do not reinvent burn-rate math). Per SLO: current SLI vs objective, error budget remaining,
multi-window burn rate, 30-day budget burndown; a table ranking SLOs by budget burned. IMPORTANT:
Pyrra SLOs can only be computed on metrics that EXIST — i.e. obs-stack/pipeline or log-derived
recording rules, NOT bankobs request metrics (which don't exist). If the only SLOs defined are
sample ones, show those and note in a text panel that app-level SLOs need a request signal (e.g. a
Loki recording rule). Variables: ds_prom, slo. Folder "SLO".
```

## PROMPT 10 — Continuous Profiling (Pyroscope)
```
Build "Platform — Continuous Profiling" on the Pyroscope datasource. Discover which services push
profiles (not all bankobs services do). Panels: CPU flame graph and alloc flame graph for a
$service, CPU/alloc over time, and a profile-type selector. Add a note on using a profile
alongside the trace for the same latency spike (Jaeger tracesToProfiles → Pyroscope is wired).
Variables: ds_pyroscope, service, profile_type. Folder "Profiling".
```

---

## Not buildable today (tell the agent to skip, don't chase empty panels)
- **Metric-based per-service RED for bankobs** — no app metrics / no spanmetrics. Use logs
  (Group A) instead.
- **BankObs node/pod USE** — kube-state-metrics/cAdvisor don't cover the bankobs cluster from
  here. Would require deploying node-exporter + kube-state-metrics (or a metrics-scraping agent)
  INSIDE the bankobs cluster and forwarding — a separate infra change, out of scope for dashboards.
