# project-eks/observability — the monitoring stack (obs cluster)

Everything you taught, on the observability EKS cluster, via Helm with EBS persistence:

| Component | Chart | Role |
|---|---|---|
| OTel Collector | `open-telemetry/opentelemetry-collector` | OTLP hub → Jaeger / Prometheus / Loki; **internal NLB** for cross-VPC ingest |
| kube-prometheus-stack | `prometheus-community/kube-prometheus-stack` | Prometheus (exemplars + remote-write, **TSDB only**) · Alertmanager · Grafana |
| OTel collectors (×2 clusters) | `open-telemetry/opentelemetry-collector` | **sole metrics collector** on BOTH clusters — node agent (hostmetrics+kubeletstats+logs) + cluster collector (k8s_cluster) → gateway |
| Loki | `grafana/loki` | logs (native OTLP, structured-metadata `trace_id`) |
| Jaeger | `jaegertracing/jaeger` | traces (all-in-one, Badger on EBS) |
| Pyroscope | `grafana/pyroscope` | profiles |
| Pyrra | manifests | SLOs / error-budget burn (from 3.1.10) |

Grafana ships **pre-wired** with all four pivots: exemplars → Jaeger, Loki `derivedFields` → Jaeger,
Jaeger `tracesToLogsV2` → Loki and `tracesToProfiles` → Pyroscope.

### Metrics are OTel-only, on both clusters

Infra metrics (node / pod / container usage and cluster-state) are collected by the **OTel Collector**
on **both** clusters — not by Prometheus scraping. Prometheus is a pure remote-write TSDB. So kps's
own `nodeExporter`, `kubeStateMetrics` and `kubelet` scrapers are **disabled** (`values/kube-prometheus-stack.yaml`):

| What | OTel receiver | Runs as | Metric names |
|---|---|---|---|
| node cpu/mem/disk/net/load | `hostmetrics` | node agent (DaemonSet) | `system_*` |
| pod & container cpu/mem/fs/net | `kubeletstats` | node agent (DaemonSet) | `k8s_pod_*` / `container_*` |
| cluster state (phase, replicas, **restarts**, conditions, quotas) | `k8s_cluster` | cluster collector (**1 replica**) | `k8s_pod_phase`, `k8s_container_restarts`, … |
| app RED | `spanmetrics` connector (gateway) | gateway | `calls_total`, `duration_milliseconds_*` |

Per cluster: a **node agent** DaemonSet (`agent/values-agent.yaml`, `agent/values-obs-node.yaml`) and a
single-replica **cluster collector** (`agent/values-cluster.yaml`, `agent/values-obs-cluster.yaml`) — the
latter MUST be one replica or every node re-emits the whole cluster's state → remote-write duplicate
rejects. Every series is stamped `k8s_cluster_name` (`obs-v1-bankobs` / `obs-v1-observability`) so you
filter by cluster. The gateway's `prometheusremotewrite` sets `resource_to_telemetry_conversion: true`
so pod/namespace/node land as labels (not stranded in `target_info`). Names are OTel-native, so the stock
kps "Compute Resources" dashboards stay empty by design — the course uses OTel-named panels. coreDNS +
kube-apiserver ServiceMonitors are left on (OTel has no equivalent for those control-plane `/metrics`).

## Deploy

```bash
# point kubectl at the obs cluster first:  make -C ../cluster kubeconfig
make all DOMAIN=lab.example.com
```

`make all` runs in dependency order (kps CRDs → backends → collector → pyrra → edges). Individual
targets exist for every component (`make loki`, `make jaeger`, …).

## Cross-VPC ingest

`make collector-lb` creates an **internal** NLB and external-dns publishes it as
`otel-collector.obs.internal` into the shared private zone. BankObs (other VPC) sends OTLP there over
the peering — never the public internet. Override the name with `COLLECTOR_HOST=…` if you changed
`private_dns_domain` in `../cluster`.

## UIs

`make ingress DOMAIN=…` publishes `grafana.<DOMAIN>`, `jaeger.<DOMAIN>`, `prometheus.<DOMAIN>`,
`alertmanager.<DOMAIN>`, `pyroscope.<DOMAIN>` via Traefik (TLS at the NLB, records via external-dns).

> The sample Pyrra SLO (`pyrra/slo.yaml`) targets `demo-app` — point it at a real bankobs metric
> once the app is up.
