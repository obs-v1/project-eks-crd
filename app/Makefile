# ─────────────────────────────────────────────────────────────────────────────
#  project-eks/app — BankObs on the bankobs EKS cluster
#
#  make all LICENSE_KEY=…      # license secret + platform + all 60 service charts + frontend
#  make license LICENSE_KEY=…  # just the bankobs-license secret the app images require
#  make platform              # databases, license-checker, web-portal, init jobs (StatefulSets)
#  make services              # helm upgrade --install every service, one after another (no wait)
#  make frontend DOMAIN=…     # expose web-portal at bankobs.<DOMAIN> via Traefik
#  make -C <service> deploy   # a single service on its own (build/push/deploy live in each folder)
#  make regen                 # re-stamp the per-service charts from _generate.sh
#
#  Inputs:  LICENSE_KEY (required; inline or in a local .env) · CTX · ECR · TAG · DOMAIN · NS
# ─────────────────────────────────────────────────────────────────────────────
NS     ?= bankobs
CTX    ?= obs-v1-bankobs
ECR    ?= public.ecr.aws/w8x4g9h7/obs-v1
TAG    ?= 1.0.0
DOMAIN ?=
REGION ?= us-east-1

# License for the bankobs app images — license-checker validates it and EVERY Java service
# refuses to start until it does. Pass inline (make all LICENSE_KEY=eyJ...) or drop
# LICENSE_KEY=eyJ... into a local .env file. HOST_* are optional (the test key is hw-wildcard).
LICENSE_KEY     ?= $(shell grep '^LICENSE_KEY=' .env 2>/dev/null | cut -d= -f2-)
HOST_MACHINE_ID ?=
HOST_MAC        ?=
HOST_HOSTNAME   ?=

K = kubectl --context $(CTX)

# Every folder that is a service chart (has a Chart.yaml) — platform/ has none.
SERVICES := $(patsubst %/Chart.yaml,%,$(wildcard */Chart.yaml))

.PHONY: all ensure-context namespace license configmaps platform services frontend list regen destroy

# Create the kube context if it's missing (alias == cluster name == CTX).
ensure-context:
	@kubectl config get-contexts $(CTX) >/dev/null 2>&1 || aws eks update-kubeconfig --region $(REGION) --name $(CTX) --alias $(CTX) >/dev/null

all: namespace platform services frontend
	@echo ""; echo "  ✓ BankObs deployed to context $(CTX) ($(words $(SERVICES)) services + platform)."

namespace: ensure-context
	$(K) create namespace $(NS) --dry-run=client -o yaml | $(K) apply -f -

# The license secret every bankobs app image requires. license-checker validates it; the Java
# services call license-checker on boot and refuse to start until it says OK.
license: namespace
	@test -n "$(LICENSE_KEY)" || { echo "ERROR: LICENSE_KEY is empty. Pass it: make all LICENSE_KEY=eyJ...  (or put LICENSE_KEY=... in ./.env)"; exit 1; }
	@$(K) create secret generic bankobs-license \
	  --from-literal=LICENSE_KEY='$(LICENSE_KEY)' \
	  --from-literal=HOST_MACHINE_ID='$(HOST_MACHINE_ID)' \
	  --from-literal=HOST_MAC='$(HOST_MAC)' \
	  --from-literal=HOST_HOSTNAME='$(HOST_HOSTNAME)' \
	  -n $(NS) --dry-run=client -o yaml | $(K) apply -f -
	@echo "  ✓ bankobs-license secret applied."

# Init ConfigMaps the DB StatefulSets mount (built from platform/infrastructure/).
configmaps: namespace
	$(K) create configmap oracle-init            --from-file=platform/infrastructure/databases/oracle/init-scripts        -n $(NS) --dry-run=client -o yaml | $(K) apply -f -
	$(K) create configmap postgres-init          --from-file=platform/infrastructure/databases/postgres/init-scripts      -n $(NS) --dry-run=client -o yaml | $(K) apply -f -
	$(K) create configmap mongo-init             --from-file=platform/infrastructure/databases/mongodb/init-scripts       -n $(NS) --dry-run=client -o yaml | $(K) apply -f -
	$(K) create configmap cassandra-init-scripts --from-file=platform/infrastructure/databases/cassandra/init-scripts     -n $(NS) --dry-run=client -o yaml | $(K) apply -f -
	$(K) create configmap es-init-scripts        --from-file=platform/infrastructure/databases/elasticsearch/init-scripts -n $(NS) --dry-run=client -o yaml | $(K) apply -f -
	$(K) create configmap kafka-init-scripts     --from-file=platform/infrastructure/messaging/kafka                      -n $(NS) --dry-run=client -o yaml | $(K) apply -f -
	$(K) create configmap rabbitmq-definitions   --from-file=platform/infrastructure/messaging/rabbitmq/definitions.json  -n $(NS) --dry-run=client -o yaml | $(K) apply -f -
	$(K) create configmap redis-conf             --from-file=platform/infrastructure/databases/redis/redis.conf           -n $(NS) --dry-run=client -o yaml | $(K) apply -f -

# StatefulSet databases + license-checker + web-portal + init jobs. Needs the license secret
# first (license-checker won't start without it). The *.tpl ingress is skipped here (kubectl
# ignores non-.yaml); it is applied by `make frontend`.
platform: namespace license configmaps
	$(K) apply -n $(NS) -f platform/

# Fire each chart in sequence; do NOT wait for pods (helm returns once resources are applied).
services: namespace
	@for s in $(SERVICES); do \
	  echo "  → $$s"; \
	  helm --kube-context $(CTX) upgrade --install $$s ./$$s -n $(NS) \
	    --set image.registry=$(ECR) --set image.tag=$(TAG) >/dev/null || exit 1; \
	done
	@echo "  ✓ $(words $(SERVICES)) service charts applied."

frontend:
	@test -n "$(DOMAIN)" || { echo "ERROR: set DOMAIN=lab.example.com"; exit 1; }
	@sed 's|$${DOMAIN}|$(DOMAIN)|g' platform/web-portal-ingress.yaml.tpl | $(K) apply -f -
	@echo "  frontend (once DNS propagates): https://bankobs.$(DOMAIN)"

list:
	@echo $(SERVICES) | tr ' ' '\n'

regen:
	bash _generate.sh

destroy:
	-@for s in $(SERVICES); do helm --kube-context $(CTX) uninstall $$s -n $(NS) 2>/dev/null; done
	-$(K) delete -n $(NS) -f platform/ --ignore-not-found
	@echo "  ✓ BankObs removed (PVCs kept)."
