# BankObs on EKS — Fault-Injection Lab (Instructor Runbook)

A hands-on lab for the `project-eks` BankObs stack: inject five common production faults,
then trace each one **end-to-end in Grafana** following the golden path
**metric dashboard → trace → logs**. Every step below is a copy-pasteable command that was
run and verified on the live two-cluster stack.

> **Environment:** two EKS clusters — `obs-v1-observability` (obs stack) and `obs-v1-bankobs`
> (the 60-service BankObs app), VPC-peered, telemetry flowing privately to
> `otel-collector.obs.internal:4317`.
> **UIs:** Grafana `https://grafana.raghudevopsb88.online` · Jaeger `https://jaeger.raghudevopsb88.online`
> · Prometheus `https://prometheus.raghudevopsb88.online` · App `https://bankobs.raghudevopsb88.online`
> (demo login `CUST-00000001` / `Training@123`).

---

## 0. What makes end-to-end tracing possible here

BankObs apps **only push traces** (no `/metrics` of their own, no app logs exporter — the node
agent tails stdout to Loki). On its own that leaves a hole: you cannot *start* an investigation
from a metric dashboard, because there are no app metrics.

**The fix applied to this stack:** the OTel Collector runs a **`spanmetrics` connector**
(`observability/values/otel-collector.yaml`). It turns every span into per-service RED metrics —
`calls_total` and `duration_milliseconds` — and remote-writes them to Prometheus **with
`trace_id` exemplars**. That single change lights up metric dashboards for all 60 services and
makes the metric→trace jump possible.

The pivot chain is wired once, at the datasource level (`observability/values/kube-prometheus-stack.yaml`),
so every panel inherits it:

```
Grafana RED panel (Prometheus)
   │  exemplar trace_id  (exemplarTraceIdDestinations)
   ▼
Jaeger trace  ──tracesToLogsV2──►  Loki logs  ──derived field trace_id──►  back to Jaeger
   │                                                   ▲
   └── a Loki log line's trace_id is itself clickable ─┘
```

**The two metric dashboards used throughout (provisioned from `observability/dashboards/`):**
- **`BankObs — RED (spanmetrics)`** — the cockpit. Per-service request rate, error %, p95/p99
  latency (exemplars on), fleet error-rate table (click → Jaeger), and a Loki error panel.
- **`BankObs — Service Health (logs + traces)`** — log throughput / error rate / log volume by
  level + a Loki logs panel, per `$service`.

Both come from the tested prompt pack in `observability/dashboards/DASHBOARD-PROMPTS.md` (updated
in this lab so the RED/metric prompts are no longer gated off — see §6).

> **One reality to teach:** the BankObs cluster has **no cAdvisor / kube-state-metrics** in this
> Prometheus (the agent only forwards traces→spanmetrics and logs). So "pod restarts" and
> "container CPU" are **not** Prometheus series for BankObs. The metric signal for *every* fault
> below is therefore a **RED signal** (rate collapse, error %, or latency), which is exactly what
> spanmetrics gives us. Infra root-cause (OOMKilled, throttling) is confirmed with `kubectl`.

---

## 1. Setup (once)

```bash
# 1) bring up both clusters + obs stack + app  (~40–60 min)
make up ZONE_ID=<zone> DOMAIN=raghudevopsb88.online ACM_ARN=<acm-arn> LICENSE_KEY=<key>

# 2) generate continuous customer load (login → browse → pay), in-cluster k6
kubectl --context obs-v1-bankobs -n bankobs create configmap loadgen-script \
  --from-file=journey.js=loadgen/journey.js --dry-run=client -o yaml | \
  kubectl --context obs-v1-bankobs -n bankobs apply -f -
kubectl --context obs-v1-bankobs -n bankobs apply -f loadgen/loadgen.yaml
#   scale:  kubectl --context obs-v1-bankobs -n bankobs set env deploy/loadgen VUS=20
#   watch:  kubectl --context obs-v1-bankobs -n bankobs logs -f deploy/loadgen

# 3) provision the dashboards (Grafana sidecar picks them up in ~25s)
kubectl --context obs-v1-observability apply -f observability/dashboards/bankobs-red-spanmetrics.yaml
kubectl --context obs-v1-observability apply -f observability/dashboards/bankobs-service-health.yaml
```

Confirm metrics exist before starting: in Grafana open **BankObs — RED (spanmetrics)**; the
request-rate and latency panels should be populated for services like `gateway-service`,
`ledger-service`, `auth-service`, `account-service`, `fraud-detection`.

---

## 2. The five faults

Each fault has: **the scenario**, the **inject** command, the **detect** path
(metric → trace → logs, with the exact Grafana queries), the **evidence** captured live, the
**fix / recover** command, and an **end-to-end verdict**.

### Fault 1 — Pod crashloop / OOMKill (`account-service`)

**Scenario.** A bad deploy ships `account-service` with a memory limit far below what the JVM
needs. The container is **OOMKilled** on startup and enters `CrashLoopBackOff`. `account-service`
sits on the balance/validate path, so the payment tier fails with it.

**Inject.**
```bash
K="kubectl --context obs-v1-bankobs -n bankobs"
# crush the memory limit → JVM OOMs on start
$K set resources deploy/account-service --requests=cpu=100m,memory=8Mi --limits=cpu=500m,memory=16Mi
# make it a REAL outage (no healthy fallback): Recreate strategy, so the single replica is the bad one
$K patch deploy account-service -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
```
> **Teaching note.** With the *default* RollingUpdate on a single replica, this bad deploy causes
> **no outage** — the old healthy pod keeps serving while the new pod crashloops (we saw exactly
> that: traffic steady at ~3.3 req/s, zero 5xx). That is why a crashloop alone may not page. The
> `Recreate` patch (or the fault hitting *all* replicas) is what turns it into a user-visible
> incident. Show both.

**Detect — metric → trace → logs (all in Grafana).**
1. **Metric** — open **BankObs — RED (spanmetrics)**, `$service = account-service`:
   - *Request rate* panel **collapses to 0** (`sum(rate(calls_total{service_name="account-service",span_kind="SPAN_KIND_SERVER"}[$__rate_interval]))`).
   - *Fleet — Error rate by service* table lights up for **gateway-service, upi-service,
     payment-gateway** (`sum by (service_name)(rate(calls_total{status_code="STATUS_CODE_ERROR"}[$__rate_interval]))`) — the blast radius.
2. **Trace** — click an exemplar on the fleet latency panel, or the error row → Jaeger. The trace
   shows `gateway-service → account-service` failing (span status ERROR, "connection refused").
3. **Logs** — from the trace, **Logs for this span** → Loki; the error line carries the same
   `trace_id`. Or read the RED board's Loki error panel directly.

**Evidence captured live.**
| Signal | Value |
|---|---|
| Pod state | `CrashLoopBackOff`, **reason `OOMKilled`, exitCode 137**, 6 restarts |
| `account-service` req/s | **0** (was ~3.3) |
| Blast radius (error calls/s) | gateway-service 0.73, upi-service 0.73, payment-gateway 0.70 |
| Correlated trace | `93d8f7d48c893656414cd6f76bf431ac` (resolves in Jaeger → its logs) |

**Fix / recover.**
```bash
$K set resources deploy/account-service --requests=cpu=100m,memory=128Mi --limits=cpu=500m,memory=512Mi
$K patch deploy account-service -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"}}}}'
```
The real-world fix: raise the memory limit (or fix the leak) and roll forward.

**End-to-end verdict:** ✅ Traceable. Metric (rate→0 + caller errors) → trace (failed
`account-service` span) → logs (same `trace_id`) → root cause (`OOMKilled` via `kubectl`).
### Fault 2 — Dependency outage → elevated 5xx (`fraud-detection` down)

**Scenario.** The `fraud-detection` service (every UPI payment must clear it) is scaled to zero —
a dependency outage. Payments can no longer be risk-checked, so the **payment tier errors**.

**Inject.**
```bash
K="kubectl --context obs-v1-bankobs -n bankobs"
$K scale deploy/fraud-detection --replicas=0
```

**Detect — metric → trace → logs.**
1. **Metric** — **BankObs — RED (spanmetrics)**:
   - `$service = fraud-detection` → *request rate* **→ 0** (the dependency is gone).
   - `$service = payment-gateway` → *Error rate (%)* stat jumps to **~86%**
     (`100*sum(rate(calls_total{service_name="payment-gateway",status_code="STATUS_CODE_ERROR"}[$__rate_interval]))/clamp_min(sum(rate(calls_total{service_name="payment-gateway",span_kind="SPAN_KIND_SERVER"}[$__rate_interval])),0.001)`).
   - *Fleet error table*: payment-gateway, gateway-service, upi-service climbing.
2. **Trace** — error row / exemplar → Jaeger: the payment trace runs
   `upi-service → payment-gateway → fraud-detection` and **fails at the fraud-detection hop**
   (no healthy upstream / connection refused).
3. **Logs** — trace → Loki: the error line (same `trace_id`) names the failed fraud-detection call.

**Evidence captured live.**
| Signal | Value |
|---|---|
| `fraud-detection` req/s | **0** |
| `payment-gateway` error % | **86.3 %** |
| Blast radius (error calls/s) | payment-gateway 0.10, gateway-service 0.076, upi-service 0.076 |
| Correlated trace | `16aa1fca50cda0a37643f075072e0971` |

**Fix / recover.**
```bash
$K scale deploy/fraud-detection --replicas=1
```

**End-to-end verdict:** ✅ Traceable. Metric (error % spike + dependency rate→0) → trace (failed
`fraud-detection` hop) → logs (same `trace_id`).
### Fault 3 — CPU saturation → cascading latency (`gateway-service`)

**Scenario.** `gateway-service` fronts every request. A resource-limit mistake starves it of CPU
(40 m). It cannot keep up, requests queue, and **latency cascades across the whole fleet** — the
classic "one throttled hop melts everything downstream."

> **Why the gateway, not a leaf service:** BankObs leaf services are fast (~2 ms) and low-RPS, so
> CPU-throttling one barely moves its latency. The gateway carries *all* traffic, so starving its
> CPU is what produces a real, teachable latency incident. (Tried first on `ledger-service` and
> `auth-service` — the throttled pod just failed readiness or got starved of traffic; documented
> here as a lesson in picking the right injection point.)

**Inject.**
```bash
K="kubectl --context obs-v1-bankobs -n bankobs"
$K set env deploy/loadgen VUS=25                        # a bit more pressure
$K patch deploy gateway-service -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
$K set resources deploy/gateway-service --requests=cpu=40m,memory=128Mi --limits=cpu=40m,memory=512Mi
```

**Detect — metric → trace → logs.**
1. **Metric** — **BankObs — RED (spanmetrics)**:
   - `$service = gateway-service` → *p95/p99 latency* panels climb into **seconds**.
   - *Fleet* latency widens — rail/batch services show multi-second p95. Use
     `histogram_quantile(0.95, sum by (le,service_name)(rate(duration_milliseconds_bucket{span_kind="SPAN_KIND_SERVER"}[$__rate_interval])))`.
2. **Trace** — click an exemplar on the p95 panel → Jaeger: a single trace is **seconds** long, the
   time spent waiting on the saturated gateway span.
3. **Logs** — trace → Loki: the slow request's log line (same `trace_id`).

**Evidence captured live.**
| Signal | Value |
|---|---|
| `gateway-service` p95 (5-min window) | **3,886 ms** (baseline ~tens of ms) |
| Cascade p95 | imps-service **8,964 ms**, interest-engine **8,964 ms**, neft-service 8,833 ms, statement-service 8,792 ms, rtgs-service 1,793 ms |
| Correlated trace | `319fb14cf88766ef37a53bfa0d4e3c48` |

**Fix / recover.**
```bash
$K set resources deploy/gateway-service --requests=cpu=100m,memory=128Mi --limits=cpu=500m,memory=512Mi
$K patch deploy gateway-service -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"}}}}'
$K set env deploy/loadgen VUS=20
```
Real-world fix: right-size the CPU limit / add replicas + HPA so the entry tier can't be starved.

**End-to-end verdict:** ✅ Traceable. Metric (p95 → seconds, fleet cascade) → trace (multi-second
span) → logs (same `trace_id`). Root cause (CPU limit) confirmed with `kubectl describe`.
### Fault 4 — Primary datastore outage (`postgres` down)

**Scenario.** The PostgreSQL StatefulSet is scaled to zero — the database is gone. Services bound
to it (here, **`identity-vault`**) can no longer open connections and fail with **connection
refused**; the error bubbles up to the gateway.

**Inject.**
```bash
K="kubectl --context obs-v1-bankobs -n bankobs"
$K scale statefulset/postgres --replicas=0
```

**Detect — metric → trace → logs.**
1. **Metric** — **BankObs — RED (spanmetrics)**: *Fleet — Error rate by service* lights up for
   **identity-vault** (the postgres-backed service) and **gateway-service** (propagated). Fleet
   total error rate steps up.
2. **Trace** — error row → Jaeger: the trace shows `identity-vault` failing on its DB client span
   (connection refused to `postgres:5432`).
3. **Logs** — trace → Loki: the `identity-vault` error line (same `trace_id`) — `connection refused`.

**Evidence captured live.**
| Signal | Value |
|---|---|
| `identity-vault` error calls/s | **0.10** (was 0) |
| `gateway-service` error calls/s (propagated) | 0.67 |
| Fleet error calls/s | **0.77** |
| Error log | `identity-vault` … **connection refused** |
| Correlated trace | `3827a478dd13e042e4c7911222ec088a` |

> **Teaching note.** Blast radius is small here because most BankObs services use Oracle/Mongo;
> `identity-vault` is the Postgres-backed one. The point: the **same** metric→trace→log path finds
> *which* service and *which* dependency broke, with zero prior knowledge of the topology.

**Fix / recover.**
```bash
$K scale statefulset/postgres --replicas=1   # PVC persists; reconnects on its own
```

**End-to-end verdict:** ✅ Traceable. Metric (identity-vault error rate) → trace (failed DB span)
→ logs (`connection refused`, same `trace_id`).
### Fault 5 — Cache / session store outage (`redis` down)

**Scenario.** Redis (session, idempotency, velocity/rate-limit state) is scaled to zero. A
*different* slice of the fleet from Fault 4 breaks — the **payment + session + rate-limit tier** —
showing that the same detection path localizes any dependency failure.

**Inject.**
```bash
K="kubectl --context obs-v1-bankobs -n bankobs"
$K scale statefulset/redis --replicas=0
```

**Detect — metric → trace → logs.**
1. **Metric** — **BankObs — RED (spanmetrics)** → *Fleet error-rate table* now ranks
   **payment-gateway, upi-service, velocity-checker, auth-service, rate-limiter** — a visibly
   different blast radius than the Postgres outage.
2. **Trace** — error row → Jaeger: a payment trace fails on the Redis client span (connection refused).
3. **Logs** — trace → Loki: `connection refused` to `redis:6379`, same `trace_id`.

**Evidence captured live.**
| Signal | Value |
|---|---|
| Error calls/s | payment-gateway **0.32**, upi-service 0.24, velocity-checker 0.11, auth-service 0.11, rate-limiter 0.11 |
| Fleet error calls/s | **0.90** |
| Error log | `connection refused` (redis) |
| Correlated trace | `018dfb27ba4bbc4460be67f0886bf5cf` |

**Fix / recover.**
```bash
$K scale statefulset/redis --replicas=1
```
> Expect a brief error *spike* on recovery (reconnection storm) before it settles to baseline — a
> good thing to point out: recovery is not always instantaneous.

**End-to-end verdict:** ✅ Traceable. Metric (payment/session tier error rate) → trace (failed
Redis span) → logs (`connection refused`, same `trace_id`). Contrast the blast radius with Fault 4.

---

## 3. End-to-end traceability scorecard

Every fault was followed **Grafana metric → trace → logs** without a dead end. The metric entry
point is the **BankObs — RED (spanmetrics)** board; the trace and log hops are the pre-wired
datasource pivots.

| # | Fault | Metric signal (entry) | → Trace | → Logs | Correlated trace_id | E2E |
|---|-------|-----------------------|---------|--------|---------------------|-----|
| 1 | OOM crashloop (`account-service`) | req rate **→ 0** + caller errors (gateway/upi/payment) | failed `account-service` span | `connection refused`, `OOMKilled` | `93d8f7d4…` | ✅ |
| 2 | Dependency outage (`fraud-detection`) | payment-gateway error **86%** | failed `fraud-detection` hop | fraud call failure | `16aa1fca…` | ✅ |
| 3 | CPU saturation cascade (`gateway-service`) | gateway p95 **3.9 s**, rails **→ 9 s** | multi-second span | slow-request log | `319fb14c…` | ✅ |
| 4 | Datastore outage (`postgres`) | identity-vault error rate ↑ | failed DB span | `connection refused` (pg) | `3827a478…` | ✅ |
| 5 | Cache outage (`redis`) | payment/session tier error ↑, fleet 0.90/s | failed Redis span | `connection refused` (redis) | `018dfb27…` | ✅ |

**Verdict: 5 / 5 traceable end-to-end from Grafana, no miss.** The single enabler is the
**spanmetrics connector** — without it there is no metric to start from and the chain cannot begin
at a dashboard. Two reliability lessons worth teaching came out of building this:
- **k8s self-heals a bad single-replica deploy** (RollingUpdate keeps the old pod) — a crashloop
  is only a user-visible incident when there's no healthy fallback (Fault 1's `Recreate` step).
- **Pick the injection point for the symptom you want:** CPU-throttling a fast, low-RPS leaf shows
  nothing; throttle the high-RPS entry (gateway) to get a real latency cascade (Fault 3).

**What was fixed in the repo during this lab** (see `git diff`):
- `observability/values/otel-collector.yaml` — added the **spanmetrics connector** (+ exemplars).
- `observability/dashboards/bankobs-red-spanmetrics.yaml` — **new** RED metric dashboard.
- `observability/dashboards/DASHBOARD-PROMPTS.md` — corrected the "BankObs has no metrics" premise;
  added the RED (PROMPT 0) prompt and un-gated RED panels in PROMPT 4.
- `loadgen/journey.js` + `loadgen/loadgen.yaml` — **new** k6 traffic generator.

---

## 4. Teardown

```bash
make destroy   # app → observability → cluster (deletes LB Services first, then terraform destroy)
```
