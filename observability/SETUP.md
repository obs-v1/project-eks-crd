# Observability stack — step-by-step setup (CRD-alerting variant)

This guide installs the **full observability stack** on the `obs-v1-observability` EKS cluster,
tool by tool, in the order they must go in. Every step shows the **one `make` command** a student
runs *and* the **raw `helm`/`kubectl` command it expands to**, so you can see exactly what each tool
is and verify it before moving on.

> **This is the CRD-alerting variant** (`project-eks-crd`). Metric collection is identical to the
> base `project-eks` (OTel-only), but alerting is defined declaratively with Prometheus Operator CRDs
> and delivered by Amazon SES e-mail. Two extra steps appear below — the **SES secret** (Step 3b) and
> the per-app **alerting chart** (Step 14). The full alerting design, SES setup and verification live
> in **[ALERTING-CRD.md](ALERTING-CRD.md)**; this guide just slots them into the deploy order.

> The cluster itself (two EKS clusters, VPC peering, private zone, Traefik, external-dns, EBS CSI)
> is **already provisioned and stays exactly as-is** — see [Step 0](#step-0--prerequisites-cluster-stays-as-is).
> This document is only about the observability services that run *on top* of it.

---

## What you are building

```
          OBSERVABILITY CLUSTER (obs-v1-observability, ns: monitoring)
  ┌───────────────────────────────────────────────────────────────────────┐
  │                                                                         │
  │   obs-agent (DaemonSet) ─┐     ┌─▶ Jaeger (traces)                      │
  │   obs-cluster (1 pod) ───┤     │                                        │
  │                          ▼     │                                        │
  │                   ┌─────────────────┐   remote-write   ┌─────────────┐  │
  │   ... OTLP ──────▶│  otel-collector │─────────────────▶│ Prometheus  │  │
  │                   │   (gateway)     │   (metrics)       │  (TSDB)     │  │
  │                   └─────────────────┘                   └─────────────┘  │
  │                          │   │  └────────────▶ Loki (logs)              │
  │                          │   └───────────────▶ spanmetrics ─▶ Prom (RED)│
  │                          │                                              │
  │                          │                     Pyroscope (profiles)     │
  │                   ┌──────┴───────┐                                      │
  │                   │ internal NLB │  otel-collector.obs.internal:4317    │
  │                   └──────▲───────┘   Grafana ◀── reads all of the above │
  └──────────────────────────┼──────────────────────────────────────────────┘
                             │ (OTLP over VPC peering, private)
  ┌──────────────────────────┼──────────────────────────────────────────────┐
  │   APP CLUSTER (obs-v1-bankobs, ns: bankobs)                              │
  │   bankobs-agent (DaemonSet) + bankobs-cluster (1 pod) ──────────────────┘
  │   BankObs apps ─ traces(OTLP) / metrics(/metrics scrape) / logs(stdout tail)
  └───────────────────────────────────────────────────────────────────────┘
```

**Metrics are OTel-only on both clusters.** The OTel collectors gather node/pod/container usage
(`hostmetrics` + `kubeletstats`) and cluster state (`k8s_cluster`); Prometheus is a pure
remote-write store. kube-prometheus-stack's own node-exporter / kube-state-metrics / kubelet
scrapers are **disabled** — see `values/kube-prometheus-stack.yaml`.

---

## The order (and why)

| # | Step | Chart / manifest | Version | Why it goes here |
|---|------|------------------|---------|------------------|
| 0 | Prerequisites | *(cluster, already up)* | — | kubectl contexts + Traefik + external-dns must exist |
| 1 | Helm repos | — | — | register the chart sources |
| 2 | Namespace | `monitoring` | — | everything lives here |
| 3b | SES secret | `alertmanager-ses-smtp` | — | SES SMTP password for Alertmanager — must exist **before** kps (mounted into the Alertmanager pod) |
| 3 | kube-prometheus-stack | `prometheus-community/kube-prometheus-stack` | `92.17.0` | installs the **Prometheus Operator CRDs** everything else may reference; Grafana + Prometheus TSDB; **Alertmanager SES transport** |
| 4 | Loki | `grafana/loki` | `7.5.0` | logs backend (must exist before the collector forwards logs) |
| 5 | Jaeger | `jaegertracing/jaeger` | `4.13.1` | traces backend (**pinned — read the note**) |
| 6 | Pyroscope | `grafana/pyroscope` | `2.4.2` | profiles backend |
| 7 | OTel Collector (gateway) | `open-telemetry/opentelemetry-collector` | `0.178.1` | the hub — needs Jaeger/Loki/Prometheus to send to |
| 8 | Pyrra | manifests | `v0.10.2` CRD | SLOs / error-budget burn |
| 9 | Collector internal NLB | `k8s/collector-internal-lb.yaml` | — | private ingest endpoint for the app cluster |
| 10 | Ingress (UIs) | `ingress/ui-ingress.yaml` | — | publishes grafana/jaeger/… hosts |
| 11 | Dashboards | `dashboards/*.yaml` | — | Grafana sidecar auto-loads them |
| 12 | OBS collectors | `agent/values-obs-*.yaml` | `0.178.1` | this cluster's own infra metrics |
| 13 | BankObs collectors | `agent/values-*.yaml` | `0.178.1` | the app cluster's metrics + logs |
| 14 | App alerting (CRDs) | `app-monitoring/` chart | — | per-app `PrometheusRule` + `AlertmanagerConfig` (what to alert on / who is paged) |

> **Shortcut:** `make all DOMAIN=lab.example.com SES_SMTP_USERNAME=… SES_SMTP_PASSWORD=… SES_FROM=…`
> runs every step (3b and 14 included) in exactly this order. The steps below are the same thing, one
> at a time. See **[ALERTING-CRD.md](ALERTING-CRD.md)** for the alerting design and SES details.

---

## Step 0 — Prerequisites (cluster stays as-is)

You need three CLIs and the two clusters already provisioned by `../cluster`:

```bash
kubectl version --client      # any recent kubectl
helm version                  # Helm 3.12+
aws sts get-caller-identity   # AWS creds for us-east-1, account 739561048503
```

Point kubectl at **both** clusters (the cluster module already created them):

```bash
make -C ../cluster kubeconfig     # adds contexts: obs-v1-observability + obs-v1-bankobs
kubectl config get-contexts | grep obs-v1
```

You should see both:

```
obs-v1-observability   # CONTEXT   — the monitoring stack goes here
obs-v1-bankobs         # AGENT_CTX — the app + its collectors
```

**Inputs used throughout** (all have defaults except `DOMAIN`):

| Variable | Default | Meaning |
|---|---|---|
| `CONTEXT` | `obs-v1-observability` | kube context of the obs cluster |
| `AGENT_CTX` | `obs-v1-bankobs` | kube context of the app cluster |
| `NS` | `monitoring` | namespace for the whole stack |
| `COLLECTOR_HOST` | `otel-collector.obs.internal` | private name the app cluster pushes OTLP to |
| `REGION` | `us-east-1` | AWS region |
| `DOMAIN` | *(none)* | base domain for the public UIs — **required for Step 10** |

---

## Step 1 — Register the Helm repositories

```bash
make repos
```

Expands to:

```bash
helm repo add open-telemetry       https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana              https://grafana.github.io/helm-charts
helm repo add jaegertracing        https://jaegertracing.github.io/helm-charts
helm repo update
```

**Verify:**

```bash
helm search repo kube-prometheus-stack --versions | head -1   # should list 92.17.0
```

---

## Step 2 — Create the namespace

```bash
make namespace
```

Expands to:

```bash
kubectl --context obs-v1-observability create namespace monitoring \
  --dry-run=client -o yaml | kubectl --context obs-v1-observability apply -f -
```

**Verify:** `kubectl --context obs-v1-observability get ns monitoring` → `Active`.

---

## Step 3b — SES secret (before kps)

Alertmanager delivers alert e-mail via Amazon SES, reading the SMTP **password** from a mounted
secret. It must exist **before** kps, because the operator mounts it into the Alertmanager pod.

```bash
make alertmanager-secret SES_SMTP_PASSWORD='<ses-smtp-password>'
```

Expands to a `kubectl create secret generic alertmanager-ses-smtp … --from-literal=smtp_password=…`.
If you omit `SES_SMTP_PASSWORD`, a placeholder is stored so the stack still boots (e-mail just won't
authenticate until you re-run with the real value). The SES **username** and **From** are passed to
Step 3 via `SES_SMTP_USERNAME=` / `SES_FROM=` (injected with `--set-string`, so they stay out of git).
Full SES setup (verified identity, sandbox) is in **[ALERTING-CRD.md](ALERTING-CRD.md)**.

**Verify:** `kubectl --context obs-v1-observability -n monitoring get secret alertmanager-ses-smtp`

---

## Step 3 — kube-prometheus-stack (Prometheus + Grafana + CRDs)

This is **first among the backends** because it installs the Prometheus Operator CRDs and brings up
Grafana (with all datasources pre-wired), the Prometheus TSDB, and **Alertmanager with the SES
transport** (the central "how e-mail is sent"; per-app routing is added in Step 14).

```bash
make kube-prometheus-stack
```

Expands to:

```bash
helm --kube-context obs-v1-observability upgrade --install kps \
  prometheus-community/kube-prometheus-stack --version 92.17.0 \
  -n monitoring -f values/kube-prometheus-stack.yaml --wait --timeout 15m
```

**What the values do (highlights):**
- Prometheus runs as a **pure remote-write TSDB** (`enableRemoteWriteReceiver: true`); its own
  `nodeExporter`, `kubeStateMetrics`, and `kubelet` scrapers are **turned off** (OTel owns metrics).
- Grafana is pinned to the **non-distroless** `13.3.0` image (the distroless sqlite build crashes on
  first boot — see the comment in the values file).
- Grafana ships four datasources already wired together: **Prometheus** (with exemplars → Jaeger),
  **Loki** (derived `trace_id` → Jaeger), **Jaeger** (`tracesToLogsV2` → Loki, `tracesToProfiles`
  → Pyroscope), and **Pyroscope**.

**Verify:**

```bash
kubectl --context obs-v1-observability -n monitoring get pods | grep -E 'kps|prometheus|grafana'
# kps-grafana, prometheus-kps-..., alertmanager-kps-... all Running
```

Grafana login is `admin` / `admin` (service `kps-grafana:80`).

---

## Step 4 — Loki (logs)

```bash
make loki
```

Expands to:

```bash
helm --kube-context obs-v1-observability upgrade --install loki \
  grafana/loki --version 7.5.0 -n monitoring -f values/loki.yaml
```

**What it is:** a single-binary, EBS-persistent Loki that ingests **native OTLP** on `/otlp`, keeps
`trace_id` as structured metadata (so Grafana's derived field can jump to Jaeger), with raised rate
limits for a busy 60-service fleet.

**Verify:**

```bash
kubectl --context obs-v1-observability -n monitoring get pods -l app.kubernetes.io/name=loki
kubectl --context obs-v1-observability -n monitoring get pvc | grep loki   # 20Gi gp3, Bound
```

---

## Step 5 — Jaeger (traces)  ⚠️ version-pinned

```bash
make jaeger
```

Expands to:

```bash
helm --kube-context obs-v1-observability upgrade --install jaeger \
  jaegertracing/jaeger --version 4.13.1 -n monitoring -f values/jaeger.yaml
```

**What it is:** Jaeger v2 all-in-one (one `jaeger` Deployment + Service, in-memory storage), exposing
OTLP on `:4317/:4318` and the query UI/API on `:16686`.

> **⚠️ Do not bump the chart past `4.13.1` (Jaeger `2.20.0`).** Jaeger **2.21.0 removed the legacy v1
> query API** (`/api/services`, `/api/traces`) that Grafana's Jaeger datasource still calls — on
> 2.21+ the datasource 404s (health check, service/operation pickers, search) even though the Jaeger
> UI itself keeps working. `2.20.0` is the last release that serves v1; the Grafana plugin supports
> ≥2.19, so this is the safe pin. Full detail is in the header of `values/jaeger.yaml`.

**Verify:**

```bash
kubectl --context obs-v1-observability -n monitoring get pod -l app.kubernetes.io/instance=jaeger \
  -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image,STATUS:.status.phase
# IMAGE must be jaegertracing/jaeger:2.20.0
```

Once traces are flowing, confirm the v1 API Grafana needs (empty list is fine before traffic):

```bash
kubectl --context obs-v1-observability -n monitoring run q --rm -it --restart=Never \
  --image=curlimages/curl -- curl -s -o /dev/null -w '%{http_code}\n' http://jaeger:16686/api/services
# expect 200
```

---

## Step 6 — Pyroscope (profiles)

```bash
make pyroscope
```

Expands to:

```bash
helm --kube-context obs-v1-observability upgrade --install pyroscope \
  grafana/pyroscope --version 2.4.2 -n monitoring -f values/pyroscope.yaml
```

**What it is:** single-binary, EBS-persistent profiling backend. Apps push profiles to
`http://pyroscope:4040`.

**Verify:** `kubectl --context obs-v1-observability -n monitoring get pods -l app.kubernetes.io/name=pyroscope`

---

## Step 7 — OTel Collector (the gateway)

```bash
make otel-collector
```

Expands to:

```bash
helm --kube-context obs-v1-observability upgrade --install otel-collector \
  open-telemetry/opentelemetry-collector --version 0.178.1 \
  -n monitoring -f values/otel-collector.yaml
```

**What it is:** the **hub** (deployment, 1 replica). It receives OTLP and fans it out:
- **traces** → Jaeger, *and* into the **spanmetrics** connector;
- **metrics** → Prometheus via `prometheusremotewrite` (with
  `resource_to_telemetry_conversion` so pod/namespace/node/cluster become real labels);
- **logs** → Loki.

It must come **after** Jaeger/Loki/Prometheus exist, because those are its export targets.

**Verify:**

```bash
kubectl --context obs-v1-observability -n monitoring get pods -l app.kubernetes.io/instance=otel-collector
kubectl --context obs-v1-observability -n monitoring get svc otel-collector   # ClusterIP :4317/:4318
```

---

## Step 8 — Pyrra (SLOs)

```bash
make pyrra
```

Expands to (CRD pinned, then operator, then sample SLO):

```bash
kubectl --context obs-v1-observability apply -f \
  https://raw.githubusercontent.com/pyrra-dev/pyrra/v0.10.2/examples/kubernetes/manifests/setup/pyrra-slo-CustomResourceDefinition.yaml
kubectl --context obs-v1-observability apply -f pyrra/pyrra.yaml
kubectl --context obs-v1-observability apply -f pyrra/slo.yaml
```

> The sample SLO targets `demo-app` — repoint it at a real BankObs metric once the app is up.

**Verify:** `kubectl --context obs-v1-observability -n monitoring get servicelevelobjectives`

---

## Step 9 — Collector internal NLB (private ingest)

```bash
make collector-lb
```

Expands to (substitutes `COLLECTOR_HOST` then applies):

```bash
sed 's|${COLLECTOR_HOST}|otel-collector.obs.internal|g' k8s/collector-internal-lb.yaml \
  | kubectl --context obs-v1-observability apply -f -
```

**What it is:** a **private** NLB in front of the gateway. external-dns publishes it as
`otel-collector.obs.internal` in the shared private zone, so the app cluster (other VPC) pushes OTLP
to it over the peering — never the public internet. It only accepts the two lab VPC CIDRs.

**Verify:**

```bash
kubectl --context obs-v1-observability -n monitoring get svc otel-collector-internal \
  -o wide   # EXTERNAL-IP = an internal-... NLB hostname
nslookup otel-collector.obs.internal   # resolves once external-dns syncs (give it ~1–2 min)
```

---

## Step 10 — Ingress (public UIs)  — needs `DOMAIN`

```bash
make ingress DOMAIN=lab.example.com
```

Expands to:

```bash
sed 's|${DOMAIN}|lab.example.com|g' ingress/ui-ingress.yaml \
  | kubectl --context obs-v1-observability apply -f -
```

**What it is:** a Traefik Ingress publishing five hosts (TLS at the Traefik NLB, records via
external-dns):

```
https://grafana.lab.example.com       → kps-grafana:80
https://prometheus.lab.example.com    → kps-prometheus:9090
https://alertmanager.lab.example.com  → kps-alertmanager:9093
https://jaeger.lab.example.com        → jaeger:16686
https://pyroscope.lab.example.com     → pyroscope:4040
```

**Verify:** `kubectl --context obs-v1-observability -n monitoring get ingress observability-uis`,
then browse `https://grafana.<DOMAIN>` once DNS propagates.

---

## Step 11 — Dashboards

```bash
make dashboards
```

Expands to:

```bash
kubectl --context obs-v1-observability -n monitoring apply -f dashboards/
```

**What it is:** each file is a **ConfigMap labeled `grafana_dashboard: "1"`**; the Grafana sidecar
auto-loads them into the **BankObs** folder. `kubectl` applies only the `*.yaml`/`*.json` files, so
`DASHBOARD-PROMPTS.md` is ignored. Needs Grafana (Step 3) running first.

Ships with RED/spanmetrics dashboards, service-health dashboards, and the two OTel-native infra
dashboards (`bankobs-infra-otel`, `k8s-cluster-state-otel`).

**Verify:** in Grafana → Dashboards → **BankObs** folder, or:

```bash
kubectl --context obs-v1-observability -n monitoring get cm -l grafana_dashboard=1
```

---

## Step 12 — OBS cluster's own collectors (node + cluster)

```bash
make obs-agent
```

Expands to:

```bash
helm --kube-context obs-v1-observability upgrade --install obs-agent \
  open-telemetry/opentelemetry-collector --version 0.178.1 -n monitoring -f agent/values-obs-node.yaml
helm --kube-context obs-v1-observability upgrade --install obs-cluster \
  open-telemetry/opentelemetry-collector --version 0.178.1 -n monitoring -f agent/values-obs-cluster.yaml
```

**What it is:** the obs cluster monitoring *itself*:
- **`obs-agent`** — a DaemonSet (`hostmetrics` + `kubeletstats`) → local gateway;
- **`obs-cluster`** — a **single pod** (`k8s_cluster` cluster-state). It **must be 1 replica**, or
  every node would re-emit the whole cluster's state and Prometheus remote-write would reject the
  duplicates.

Both stamp `k8s.cluster.name=obs-v1-observability` and forward to the local gateway
(`otel-collector.monitoring.svc.cluster.local:4317`).

**Verify:**

```bash
kubectl --context obs-v1-observability -n monitoring get pods | grep -E 'obs-agent|obs-cluster'
```

---

## Step 13 — BankObs (app) cluster collectors

```bash
make agent
```

Expands to (runs in the **app** cluster context):

```bash
helm --kube-context obs-v1-bankobs upgrade --install bankobs-agent \
  open-telemetry/opentelemetry-collector --version 0.178.1 -n monitoring --create-namespace -f agent/values-agent.yaml
helm --kube-context obs-v1-bankobs upgrade --install bankobs-cluster \
  open-telemetry/opentelemetry-collector --version 0.178.1 -n monitoring --create-namespace -f agent/values-cluster.yaml
```

**What it is:** the same pattern, but in the app cluster, forwarding **across the VPC peering** to
`otel-collector.obs.internal:4317`:
- **`bankobs-agent`** — DaemonSet: scrapes bankobs pods' `/metrics`, tails node logs, and collects
  `hostmetrics` + `kubeletstats`;
- **`bankobs-cluster`** — single pod: `k8s_cluster` state (1 replica, same reason as above).

Both stamp `k8s.cluster.name=obs-v1-bankobs`. This step comes **last** because it needs the gateway
and its internal NLB (Steps 7 and 9) to exist.

**Verify:**

```bash
kubectl --context obs-v1-bankobs -n monitoring get pods | grep -E 'bankobs-agent|bankobs-cluster'
```

---

## Step 14 — App alerting (CRDs)

Deploy the per-application alerting as CRDs — a `PrometheusRule` (what to alert on, PromQL over the
OTel metrics) and an `AlertmanagerConfig` (which team/e-mail each alert routes to).

```bash
make app-monitoring
```

Expands to:

```bash
helm --kube-context obs-v1-observability upgrade --install bankobs-monitoring ./app-monitoring \
  -n monitoring -f app-monitoring/values-bankobs.yaml
```

Add another app by writing `app-monitoring/values-<app>.yaml` and installing a second release. The
operator merges each `AlertmanagerConfig` into the base SES config from Step 3 — no kps change needed.
Design, alert catalogue and a live test (`--set enableTestAlert=true`) are in
**[ALERTING-CRD.md](ALERTING-CRD.md)**.

**Verify:**

```bash
kubectl --context obs-v1-observability -n monitoring get prometheusrule bankobs-alerts
kubectl --context obs-v1-observability -n monitoring get alertmanagerconfig bankobs-routing
```

---

## Final end-to-end check

After a minute or two of traffic, confirm all four pillars land in Grafana:

```bash
# Metrics — both clusters report (OTel-only):
kubectl --context obs-v1-observability -n monitoring exec deploy/kps-grafana -c grafana -- \
  curl -s -u admin:admin 'http://kps-prometheus:9090/api/v1/label/k8s_cluster_name/values'
# expect: ["obs-v1-bankobs","obs-v1-observability"]

# Traces — Jaeger datasource healthy (the v1-API fix from Step 5):
kubectl --context obs-v1-observability -n monitoring exec deploy/kps-grafana -c grafana -- \
  curl -s -u admin:admin 'http://localhost:3000/api/datasources/uid/jaeger/health'
# expect: {"message":"Data source is working","status":"OK"}
```

In Grafana: open a dashboard in **BankObs**, click a spike → trace in Jaeger → logs in Loki →
profile in Pyroscope. That full click-through means the stack is wired end-to-end.

---

## Teardown

```bash
make destroy      # uninstalls all releases on both clusters (PVCs/CRDs kept)
```

PVCs and CRDs are intentionally kept — delete them manually for a clean slate.

---

## One-shot (what students normally run)

```bash
make -C ../cluster kubeconfig          # Step 0
make all DOMAIN=lab.example.com \
  SES_SMTP_USERNAME='<ses-user>' SES_SMTP_PASSWORD='<ses-pass>' SES_FROM='alerts@your-domain'
# runs steps 1–14 in order (SES secret + app alerting included). Omit the SES_* vars to bring the
# stack up with a placeholder password — e-mail just won't authenticate until you set them.
```
