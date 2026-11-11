# ─────────────────────────────────────────────────────────────────────────────
#  project-eks/observability — the monitoring stack on the observability cluster
#
#  make all                 # everything, in dependency order
#  make otel-collector | kube-prometheus-stack | loki | jaeger | pyroscope | pyrra
#  make ingress | collector-lb
#
#  Inputs:
#    DOMAIN            public base domain for the UI hosts (grafana.$DOMAIN, …)   [required for `ingress`]
#    COLLECTOR_HOST    private name BankObs pushes OTLP to    [default otel-collector.obs.internal]
#    CONTEXT           kube context of the OBS cluster        [default obs-v1-observability]
#    SES_SMTP_USERNAME SES SMTP username (IAM-derived)        [for Alertmanager e-mail]
#    SES_SMTP_PASSWORD SES SMTP password                      [for Alertmanager e-mail]
#    SES_FROM          verified SES From address              [for Alertmanager e-mail]
# ─────────────────────────────────────────────────────────────────────────────
NS             ?= monitoring
CONTEXT        ?= obs-v1-observability
COLLECTOR_HOST ?= otel-collector.obs.internal
DOMAIN         ?=
REGION         ?= us-east-1

# SES e-mail creds for Alertmanager. Password goes into a Secret (never on the CLI history of
# a committed file); username/from are injected into the kps config via --set-string at deploy,
# so they stay out of git. All optional — the stack still comes up without them (e-mail just
# won't authenticate until you set them).
SES_SMTP_USERNAME ?=
SES_SMTP_PASSWORD ?=
SES_FROM          ?=
SES_SET = $(if $(SES_SMTP_USERNAME),--set-string alertmanager.config.global.smtp_auth_username=$(SES_SMTP_USERNAME),) \
          $(if $(SES_FROM),--set-string alertmanager.config.global.smtp_from=$(SES_FROM),)

H  = helm --kube-context $(CONTEXT) upgrade --install
K  = kubectl --context $(CONTEXT)
HN = -n $(NS)

AGENT_CTX ?= obs-v1-bankobs   # the agent runs IN the bankobs cluster

.PHONY: repos ensure-context namespace all otel-collector kube-prometheus-stack loki jaeger pyroscope pyrra ingress collector-lb dashboards agent obs-agent alertmanager-secret app-monitoring destroy

# OTel collectors in the BANKOBS cluster (metrics + logs, forwarded by OTLP across the peering):
#   bankobs-agent   (DaemonSet)  hostmetrics + kubeletstats + app /metrics scrape + log tail
#   bankobs-cluster (1 replica)  k8s_cluster cluster-state  (single instance → no duplicate series)
# OTel is the SOLE metrics collector — kps node-exporter/KSM/kubelet are disabled. (Deploy after
# the obs stack so the gateway LB exists.)
agent: repos
	@kubectl config get-contexts $(AGENT_CTX) >/dev/null 2>&1 || aws eks update-kubeconfig --region $(REGION) --name $(AGENT_CTX) --alias $(AGENT_CTX) >/dev/null
	helm --kube-context $(AGENT_CTX) upgrade --install bankobs-agent open-telemetry/opentelemetry-collector \
	  --version 0.178.1 -n monitoring --create-namespace -f agent/values-agent.yaml
	helm --kube-context $(AGENT_CTX) upgrade --install bankobs-cluster open-telemetry/opentelemetry-collector \
	  --version 0.178.1 -n monitoring --create-namespace -f agent/values-cluster.yaml
	@echo "  ✓ bankobs OTel collectors on $(AGENT_CTX): node agent (hostmetrics+kubeletstats+logs) + cluster collector (k8s_cluster) → obs gateway."

# OTel collectors for the OBS cluster's OWN infra (node/pod/container + cluster-state), forwarding
# to the LOCAL gateway. Same OTel-only design as the bankobs side. Needs the gateway deployed first.
obs-agent: repos namespace
	helm --kube-context $(CONTEXT) upgrade --install obs-agent open-telemetry/opentelemetry-collector \
	  --version 0.178.1 $(HN) -f agent/values-obs-node.yaml
	helm --kube-context $(CONTEXT) upgrade --install obs-cluster open-telemetry/opentelemetry-collector \
	  --version 0.178.1 $(HN) -f agent/values-obs-cluster.yaml
	@echo "  ✓ obs OTel collectors on $(CONTEXT): node agent (hostmetrics+kubeletstats) + cluster collector (k8s_cluster) → local gateway."

repos:
	helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo add grafana https://grafana.github.io/helm-charts
	helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
	helm repo update

# Create the kube context if it's missing, so you don't have to run `make -C ../cluster
# kubeconfig` first. The alias == cluster name == CONTEXT.
ensure-context:
	@kubectl config get-contexts $(CONTEXT) >/dev/null 2>&1 || aws eks update-kubeconfig --region $(REGION) --name $(CONTEXT) --alias $(CONTEXT) >/dev/null

namespace: ensure-context
	$(K) create namespace $(NS) --dry-run=client -o yaml | $(K) apply -f -

# Order: Prometheus Operator CRDs first (kps), then backends, then collector, then pyrra, then
# edges, then the agent in the bankobs cluster (scrapes bankobs → forwards to this collector).
all: repos namespace alertmanager-secret kube-prometheus-stack loki jaeger pyroscope otel-collector pyrra collector-lb ingress dashboards app-monitoring obs-agent agent
	@echo ""; echo "  ✓ observability stack deployed to $(CONTEXT) + OTel collectors to $(CONTEXT) & $(AGENT_CTX)."

# kps depends on alertmanager-secret so the SES password Secret exists before the Alertmanager
# pod tries to mount it (the operator wires it as a volume). SES_SET injects username/from.
kube-prometheus-stack: namespace alertmanager-secret
	$(H) kps prometheus-community/kube-prometheus-stack --version 92.17.0 $(HN) \
	  -f values/kube-prometheus-stack.yaml $(SES_SET) --wait --timeout 15m

# SES SMTP password → Secret alertmanager-ses-smtp (key smtp_password), mounted into Alertmanager
# and referenced by smtp_auth_password_file. Without SES_SMTP_PASSWORD a placeholder is stored so
# the stack still boots; re-run with the real value to enable delivery.
alertmanager-secret: namespace
	@PW='$(SES_SMTP_PASSWORD)'; \
	 if [ -z "$$PW" ]; then PW='PLACEHOLDER_SET_SES_SMTP_PASSWORD'; \
	   echo "  ⚠ SES_SMTP_PASSWORD not set — storing a placeholder; e-mail auth will fail until you re-run with it."; fi; \
	 $(K) create secret generic alertmanager-ses-smtp $(HN) --from-literal=smtp_password="$$PW" \
	   --dry-run=client -o yaml | $(K) apply -f - >/dev/null
	@echo "  ✓ secret alertmanager-ses-smtp present (mounted into Alertmanager)."

# Per-application alerting as CRDs: one Helm release per app renders a PrometheusRule (what to
# alert on) + an AlertmanagerConfig (who is paged). Add an app: write app-monitoring/values-<app>.yaml
# then `helm upgrade --install <app>-monitoring ./app-monitoring -n $(NS) -f app-monitoring/values-<app>.yaml`.
app-monitoring: namespace
	$(H) bankobs-monitoring ./app-monitoring $(HN) -f app-monitoring/values-bankobs.yaml
	@echo "  ✓ bankobs alerting applied (PrometheusRule bankobs-alerts + AlertmanagerConfig bankobs-routing)."

# BankObs dashboards: ConfigMaps (label grafana_dashboard=1) that the kps Grafana sidecar
# auto-loads into the "BankObs" folder. kubectl reads only *.yaml/*.yml/*.json from the dir,
# so DASHBOARD-PROMPTS.md is ignored. Needs kps (Grafana + sidecar) deployed first.
dashboards: namespace
	$(K) apply -f dashboards/
	@echo "  ✓ BankObs dashboards applied (sidecar loads them into Grafana → BankObs folder)."

loki: namespace
	$(H) loki grafana/loki --version 7.5.0 $(HN) -f values/loki.yaml

jaeger: namespace
	# Pin 4.13.1 (Jaeger 2.20.0). Do NOT bump past 4.14.x (Jaeger 2.21+) — 2.21 dropped the v1
	# query API (/api/services, /api/traces) that Grafana's Jaeger datasource still calls, which
	# 404s the datasource (health check + service/operation pickers + search). See values/jaeger.yaml.
	$(H) jaeger jaegertracing/jaeger --version 4.13.1 $(HN) -f values/jaeger.yaml

pyroscope: namespace
	$(H) pyroscope grafana/pyroscope --version 2.4.2 $(HN) -f values/pyroscope.yaml

otel-collector: namespace
	$(H) otel-collector open-telemetry/opentelemetry-collector --version 0.178.1 $(HN) \
	  -f values/otel-collector.yaml

pyrra: namespace
	# CRD first (pinned upstream release), then the operator + UI, then the sample SLO.
	$(K) apply -f https://raw.githubusercontent.com/pyrra-dev/pyrra/v0.10.2/examples/kubernetes/manifests/setup/pyrra-slo-CustomResourceDefinition.yaml
	$(K) apply -f pyrra/pyrra.yaml
	$(K) apply -f pyrra/slo.yaml

collector-lb: namespace
	@sed 's|$${COLLECTOR_HOST}|$(COLLECTOR_HOST)|g' k8s/collector-internal-lb.yaml | $(K) apply -f -

ingress: namespace
	@test -n "$(DOMAIN)" || { echo "ERROR: set DOMAIN=lab.example.com"; exit 1; }
	@sed 's|$${DOMAIN}|$(DOMAIN)|g' ingress/ui-ingress.yaml | $(K) apply -f -
	@echo "  UIs (once DNS propagates): https://grafana.$(DOMAIN)  https://jaeger.$(DOMAIN)  https://prometheus.$(DOMAIN)  https://alertmanager.$(DOMAIN)  https://pyroscope.$(DOMAIN)"

destroy:
	-helm --kube-context $(CONTEXT) uninstall bankobs-monitoring $(HN)
	-$(K) delete -f pyrra/slo.yaml --ignore-not-found
	-$(K) delete -f pyrra/pyrra.yaml --ignore-not-found
	-helm --kube-context $(CONTEXT) uninstall obs-agent obs-cluster $(HN)
	-helm --kube-context $(AGENT_CTX) uninstall bankobs-agent bankobs-cluster -n monitoring
	-helm --kube-context $(CONTEXT) uninstall otel-collector pyroscope jaeger loki kps $(HN)
	-$(K) delete secret alertmanager-ses-smtp $(HN) --ignore-not-found
	@echo "  ✓ stack removed (PVCs/CRDs kept — delete manually if you want a clean slate)."
