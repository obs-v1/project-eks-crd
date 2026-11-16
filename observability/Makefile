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

# SES e-mail settings for Alertmanager — all three live in ONE Secret (alertmanager-ses-smtp),
# created/updated by the `alertmanager-secret` target. The password is mounted into Alertmanager as a
# file (smtp_auth_password_file); username/From have no file support in Alertmanager, so the
# `kube-prometheus-stack` target reads them back out of that same Secret and injects them with
# --set-string at deploy. Pass any subset; a key you don't pass keeps its current value in the Secret,
# so a re-run never wipes it. All optional — the stack boots without them (e-mail just won't auth).
SES_SMTP_USERNAME ?=
SES_SMTP_PASSWORD ?=
SES_FROM          ?=

H  = helm --kube-context $(CONTEXT) upgrade --install
K  = kubectl --context $(CONTEXT)
HN = -n $(NS)

AGENT_CTX ?= obs-v1-bankobs   # the agent runs IN the bankobs cluster

.PHONY: repos ensure-context namespace all otel-collector kube-prometheus-stack loki jaeger pyroscope pyrra ingress collector-lb dashboards agent obs-agent alertmanager-secret app-monitoring pipeline-test pipeline-test-off destroy

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

# kps depends on alertmanager-secret so the one SES Secret exists before the Alertmanager pod mounts
# it (the operator wires it as a volume). Password is read from the mounted file; username/From can't
# be file-sourced in Alertmanager, so we read them back out of the Secret and --set-string them.
kube-prometheus-stack: namespace alertmanager-secret
	@U="$$($(K) get secret alertmanager-ses-smtp $(HN) -o jsonpath='{.data.smtp_auth_username}' 2>/dev/null | base64 -d)"; \
	 F="$$($(K) get secret alertmanager-ses-smtp $(HN) -o jsonpath='{.data.smtp_from}' 2>/dev/null | base64 -d)"; \
	 SET=""; \
	 case "$$U" in ''|PLACEHOLDER_*) ;; *) SET="$$SET --set-string alertmanager.config.global.smtp_auth_username=$$U";; esac; \
	 [ -n "$$F" ] && SET="$$SET --set-string alertmanager.config.global.smtp_from=$$F"; \
	 $(H) kps prometheus-community/kube-prometheus-stack --version 92.17.0 $(HN) \
	   -f values/kube-prometheus-stack.yaml $$SET --wait --timeout 15m

# ALL SES settings → one Secret alertmanager-ses-smtp (keys smtp_auth_username / smtp_password /
# smtp_from). Password is mounted as smtp_auth_password_file; username/From are read back by the kps
# target (Alertmanager has no file source for them) and --set-string'd. Pass any subset — a key you
# don't pass keeps its current value in the Secret, so re-running this (or kps) never wipes what you
# set before. Unset-and-never-set keys fall back to a placeholder (username/password) or the default
# From address.
alertmanager-secret: namespace
	@cur() { $(K) get secret alertmanager-ses-smtp $(HN) -o jsonpath="{.data.$$1}" 2>/dev/null | base64 -d 2>/dev/null; }; \
	 U='$(SES_SMTP_USERNAME)'; [ -n "$$U" ] || U="$$(cur smtp_auth_username)"; [ -n "$$U" ] || U='PLACEHOLDER_SET_SES_SMTP_USERNAME'; \
	 P='$(SES_SMTP_PASSWORD)'; [ -n "$$P" ] || P="$$(cur smtp_password)";      [ -n "$$P" ] || P='PLACEHOLDER_SET_SES_SMTP_PASSWORD'; \
	 F='$(SES_FROM)';          [ -n "$$F" ] || F="$$(cur smtp_from)";          [ -n "$$F" ] || F='observability-alerts@lab.example.com'; \
	 $(K) create secret generic alertmanager-ses-smtp $(HN) \
	   --from-literal=smtp_auth_username="$$U" \
	   --from-literal=smtp_password="$$P" \
	   --from-literal=smtp_from="$$F" \
	   --dry-run=client -o yaml | $(K) apply -f - >/dev/null; \
	 case "$$U" in PLACEHOLDER_*) echo "  ⚠ SES_SMTP_USERNAME unset — stored placeholder (e-mail won't authenticate).";; esac; \
	 case "$$P" in PLACEHOLDER_*) echo "  ⚠ SES_SMTP_PASSWORD unset — stored placeholder (e-mail won't authenticate).";; esac; \
	 echo "  ✓ secret alertmanager-ses-smtp present (smtp_auth_username + smtp_password + smtp_from)."

# CRD alerting — each service owns BOTH halves in its own chart:
#   • RULES (what to alert on)   — app/<svc>/templates/prometheusrule.yaml     → <svc>-alerts
#   • ROUTING (who is paged)     — app/<svc>/templates/alertmanagerconfig.yaml → <svc>-routing
#     (its own emails/criticalEmails, from that service's values.yaml monitoring: block)
# Both are disabled in the normal app release (that lands on the bankobs cluster, which has no
# PrometheusRule/AlertmanagerConfig CRD); here we render each with monitoring.enabled=true and
# apply it to THIS (obs) cluster, where the operator lives. The only central piece is the SES
# transport in the kps values. The optional SES smoke-test is `make pipeline-test` (below).
APP_DIR ?= ../app
# Optionally scope to ONE chart for a fast dev loop:  make app-monitoring SVC=upi-service
app-monitoring: namespace
	@dirs="$(APP_DIR)/*/"; \
	if [ -n "$(SVC)" ]; then \
	  [ -d "$(APP_DIR)/$(SVC)" ] || { echo "  ✗ no such service chart: $(APP_DIR)/$(SVC)"; exit 1; }; \
	  dirs="$(APP_DIR)/$(SVC)/"; \
	  echo "  → applying $(SVC) PrometheusRule + AlertmanagerConfig to $(CONTEXT)…"; \
	else \
	  echo "  → applying each service's own PrometheusRule + AlertmanagerConfig (from $(APP_DIR)/*/) to $(CONTEXT)…"; \
	fi; \
	n=0; for d in $$dirs ; do \
	  svc=$$(basename $$d); \
	  [ -f "$$d/templates/prometheusrule.yaml" ] || continue; \
	  helm template $$svc $$d -s templates/prometheusrule.yaml -s templates/alertmanagerconfig.yaml \
	    --set monitoring.enabled=true --set monitoring.namespace=$(NS) 2>/dev/null \
	    | $(K) apply -f - >/dev/null && n=$$((n+1)) || echo "    ⚠ $$svc skipped"; \
	done; \
	echo "  ✓ per-service alerting applied: $$n × (PrometheusRule <svc>-alerts + AlertmanagerConfig <svc>-routing)."
	@echo "  ℹ optional SES end-to-end check: 'make pipeline-test' then 'make pipeline-test-off'."

# Optional end-to-end SES smoke-test: an always-firing probe + its own route to
# app-monitoring/values-bankobs.yaml:testEmail. Fire it, confirm the e-mail, then turn it off.
# It does NOT route any real alert — that is each service's own AlertmanagerConfig.
pipeline-test: namespace
	$(H) bankobs-monitoring ./app-monitoring $(HN) -f app-monitoring/values-bankobs.yaml --set enableTestAlert=true
	@echo "  ✓ probe armed — within ~1 min bankobsAlertPipelineTest fires → SES e-mails testEmail. Turn off with 'make pipeline-test-off'."
pipeline-test-off: namespace
	$(H) bankobs-monitoring ./app-monitoring $(HN) -f app-monitoring/values-bankobs.yaml --set enableTestAlert=false
	@echo "  ✓ probe disarmed."

# BankObs dashboards: ConfigMaps (label grafana_dashboard=1) that the kps Grafana sidecar
# auto-loads into the "BankObs" folder. kubectl reads only *.yaml/*.yml/*.json from the dir,
# so DASHBOARD-PROMPTS.md is ignored. Needs kps (Grafana + sidecar) deployed first.
dashboards: namespace
	$(K) apply -f dashboards/
	@echo "  → applying each service's chart-sourced dashboard threshold series (from $(APP_DIR)/*/)…"
	@n=0; for d in $(APP_DIR)/*/ ; do \
	  svc=$$(basename $$d); \
	  [ -f "$$d/templates/thresholds.yaml" ] || continue; \
	  helm template $$svc $$d -s templates/thresholds.yaml \
	    --set monitoring.enabled=true --set monitoring.namespace=$(NS) 2>/dev/null \
	    | $(K) apply -f - >/dev/null && n=$$((n+1)) || echo "    ⚠ $$svc thresholds skipped"; \
	done; \
	echo "  ✓ BankObs dashboards applied (sidecar → BankObs folder) + $$n per-service threshold series (the boards' limit lines)."

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
	-$(K) delete prometheusrule -l app.kubernetes.io/managed-by=app-monitoring $(HN) --ignore-not-found
	-$(K) delete prometheusrule -l app.kubernetes.io/managed-by=bankobs-dashboards $(HN) --ignore-not-found
	-$(K) delete alertmanagerconfig -l app.kubernetes.io/managed-by=app-monitoring $(HN) --ignore-not-found
	-$(K) delete -f pyrra/slo.yaml --ignore-not-found
	-$(K) delete -f pyrra/pyrra.yaml --ignore-not-found
	-helm --kube-context $(CONTEXT) uninstall obs-agent obs-cluster $(HN)
	-helm --kube-context $(AGENT_CTX) uninstall bankobs-agent bankobs-cluster -n monitoring
	-helm --kube-context $(CONTEXT) uninstall otel-collector pyroscope jaeger loki kps $(HN)
	-$(K) delete secret alertmanager-ses-smtp $(HN) --ignore-not-found
	@echo "  ✓ stack removed (PVCs/CRDs kept — delete manually if you want a clean slate)."
