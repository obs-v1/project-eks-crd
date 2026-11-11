# project-eks/app — BankObs on EKS

BankObs is **59 microservices + a platform tier**, laid out so a student can run their own
CI/CD without ever seeing the source.

## Layout

```
app/
├── _generate.sh          # stamps the 59 per-service chart folders (idempotent; `make regen`)
├── Makefile              # deploy everything, or any single service
├── platform/             # StatefulSet DBs + license-checker + web-portal + init jobs (gp3)
└── <service>/            # one per microservice:
    ├── Chart.yaml
    ├── values.yaml       # image.registry / tag / port / otel endpoint — all overridable
    ├── Dockerfile        # FROM the published image — NO source (passthrough)
    ├── Makefile          # build · push · deploy · undeploy  (this service only)
    └── templates/{deployment,service}.yaml
```

### The "no source" model

Each `Dockerfile` is just `FROM public.ecr.aws/w8x4g9h7/obs-v1/<service>:1.0.0`. Rebuilding
re-tags that published image — no source leaks. To run your **own** pipeline:

```bash
cd upi-service
make build push deploy ECR=<your-account>.dkr.ecr.us-east-1.amazonaws.com/bankobs
```

The chart's `image.registry` defaults to the public ECR, so with no `ECR=` it just runs as-is.

## Deploy everything

```bash
# point kubectl at the bankobs cluster first:  make -C ../cluster kubeconfig
make all DOMAIN=lab.example.com
```

- `make platform` — the StatefulSet databases (postgres, oracle, mongodb, redis, cassandra,
  elasticsearch, kafka, rabbitmq) + `license-checker` + `web-portal` + init jobs, all on **gp3**.
- `make services` — `helm upgrade --install` for all 59 charts, **one after another, no waiting**.
- `make frontend DOMAIN=…` — `web-portal` at `bankobs.<DOMAIN>` via Traefik (TLS at the NLB).

## Telemetry

Every service's `OTEL_EXPORTER_OTLP_ENDPOINT` points at **`http://otel-collector.obs.internal:4317`** —
the observability cluster's Collector, reached **privately** over the VPC peering. `OBSERVABILITY_MODE=full`
is on, so spans/metrics/logs flow the moment the service starts.
