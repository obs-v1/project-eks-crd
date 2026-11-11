SVC := payment-gateway
ECR ?= public.ecr.aws/w8x4g9h7/obs-v1
TAG ?= 1.0.0
NS  ?= bankobs
CTX ?= obs-v1-bankobs

.PHONY: build push deploy undeploy

build:
	docker build -t $(ECR)/$(SVC):$(TAG) .

push:
	docker push $(ECR)/$(SVC):$(TAG)

deploy:
	helm --kube-context $(CTX) upgrade --install $(SVC) . -n $(NS) --create-namespace --set image.registry=$(ECR) --set image.tag=$(TAG)

undeploy:
	helm --kube-context $(CTX) uninstall $(SVC) -n $(NS)
