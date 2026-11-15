SVC := eligibility-engine
ECR ?= public.ecr.aws/w8x4g9h7/obs-v1
TAG ?= 1.0.0
NS  ?= bankobs
CTX ?= obs-v1-bankobs

.PHONY: build push deploy undeploy

build:
	docker build -t $(ECR)/$(SVC):$(TAG) .

push:
	docker push $(ECR)/$(SVC):$(TAG)

# monitoring.enabled is ON by default (alerting is mandatory); the bankobs cluster has no
# PrometheusRule/AlertmanagerConfig CRD, so the deploy here opts out. The alerting CRs are
# applied to the obs cluster by: make -C ../../observability app-monitoring
deploy:
	helm --kube-context $(CTX) upgrade --install $(SVC) . -n $(NS) --create-namespace --set image.registry=$(ECR) --set image.tag=$(TAG) --set monitoring.enabled=false

undeploy:
	helm --kube-context $(CTX) uninstall $(SVC) -n $(NS)
