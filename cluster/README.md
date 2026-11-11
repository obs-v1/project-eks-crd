# project-eks/cluster — two EKS clusters, one `terraform apply`

Provisions the whole foundation:

- **Two VPCs** (non-overlapping CIDRs) — one per cluster.
- **Two EKS clusters** (public API endpoint, so you can `kubectl` from anywhere):
  - `obs-v1-observability` — runs the monitoring stack.
  - `obs-v1-bankobs` — runs the app.
- **Spot managed node groups**, each with a diversified instance set so a single Spot
  pool interruption can't drain the cluster, plus **Cluster Autoscaler**.
- **VPC peering** + a **shared Route53 private zone** (`obs.internal`) so BankObs reaches
  the observability Collector at `otel-collector.obs.internal:4317` **privately** — telemetry
  never leaves the two VPCs.
- Per-cluster addons: **EBS CSI** (gp3 default StorageClass), **external-dns**, **Traefik**
  (public NLB, TLS terminated at the NLB with your **ACM** cert).

## The three inputs you supply

| Input | What it is |
|---|---|
| `ZONE_ID` | your Route53 **public** hosted zone id |
| `DOMAIN` | base domain, e.g. `lab.example.com` → UIs become `grafana.lab.example.com`, … |
| `ACM_ARN` | an ACM **wildcard** cert `*.lab.example.com` (TLS for the public NLB) |

## Run it

```bash
make apply ZONE_ID=Z0123... DOMAIN=lab.example.com ACM_ARN=arn:aws:acm:us-east-1:111122223333:certificate/abcd
make kubeconfig        # point kubectl at both clusters
make output            # see the collector endpoint, cluster names, etc.
```

Tear down with `make destroy` (same vars).

## What the other folders consume

- `../observability` deploys the stack to the **observability** cluster and exposes the
  Collector on an **internal** NLB that external-dns publishes as `otel-collector.obs.internal`.
- `../app` deploys **BankObs** to the **bankobs** cluster, pointing its OTLP exporter at that
  private endpoint, and the `web-portal` frontend at `bankobs.<DOMAIN>` via Traefik.

> State is **local** by default. For a shared/CI setup, add an S3 backend in `versions.tf`.
