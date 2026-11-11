# ─────────────────────────────────────────────────────────────────────────────
#  project-eks/cluster — two EKS clusters (observability + bankobs) with Terraform
#
#  Pass the three required inputs as make args (or put them in terraform.tfvars):
#    make apply ZONE_ID=Z0... DOMAIN=lab.example.com ACM_ARN=arn:aws:acm:...:certificate/...
#
#  Targets: init · plan · apply · destroy · kubeconfig · output
# ─────────────────────────────────────────────────────────────────────────────
REGION ?= us-east-1

# Terraform state lives OUTSIDE the repo so a re-clone / `git clean` / checkout can't wipe it
# (a repo-local terraform.tfstate was lost once, leaving `destroy` unable to see anything). It is
# passed to the `local` backend at init time. Override with `make ... STATE_FILE=/some/path.tfstate`.
STATE_FILE ?= $(HOME)/.terraform/state/project-eks-cluster.tfstate

# Map friendly make args → TF_VAR_* so the student doesn't touch tfvars if they
# don't want to. Anything already in terraform.tfvars still works.
ifdef ZONE_ID
export TF_VAR_public_hosted_zone_id = $(ZONE_ID)
endif
ifdef DOMAIN
export TF_VAR_public_domain_name = $(DOMAIN)
endif
ifdef ACM_ARN
export TF_VAR_acm_certificate_arn = $(ACM_ARN)
endif
# ADMIN_ARN: grant cluster-admin to an extra principal (the role running apply, e.g. an EC2
# instance role). Needed when not applying as an interactive SSO/user principal.
#   make apply ... ADMIN_ARN=arn:aws:iam::<acct>:role/workstation
ifdef ADMIN_ARN
export TF_VAR_cluster_admin_arns = ["$(ADMIN_ARN)"]
endif
export TF_VAR_aws_region = $(REGION)

.PHONY: init plan apply destroy clean-lbs fmt validate kubeconfig output

init:
	@mkdir -p $(dir $(STATE_FILE))
	terraform init -input=false -reconfigure -backend-config="path=$(STATE_FILE)"
	@echo "  ✓ terraform state → $(STATE_FILE) (outside the repo; survives re-clones)"

fmt:
	terraform fmt -recursive

validate:
	terraform validate

plan: init
	terraform plan

apply: init
	terraform apply -auto-approve
	@$(MAKE) kubeconfig     # point kubectl at both clusters so the obs/app deploys work right away

# Full teardown. The Traefik and OTLP-collector NLBs are created by the in-tree AWS
# cloud provider from k8s LoadBalancer Services, NOT by Terraform — so they must be
# deleted FIRST. Leaving them orphans their ENIs + SG rules and makes `terraform
# destroy` hang on VPC/subnet deletion. Order: delete LB Services → wait for AWS to
# reap the load balancers → terraform destroy (clusters, nodegroups, VPCs, peering,
# private zone, IAM).
destroy: clean-lbs
	@echo "⏳ waiting for cloud load balancers in both VPCs to disappear..."
	@OBS_VPC=$$(terraform output -raw observability_vpc_id 2>/dev/null); \
	 BNK_VPC=$$(terraform output -raw bankobs_vpc_id 2>/dev/null); \
	 for i in $$(seq 1 36); do \
	   n=$$(aws elbv2 describe-load-balancers --region $(REGION) --query "length(LoadBalancers[?VpcId=='$$OBS_VPC' || VpcId=='$$BNK_VPC'])" --output text 2>/dev/null); \
	   m=$$(aws elb describe-load-balancers --region $(REGION) --query "length(LoadBalancerDescriptions[?VPCId=='$$OBS_VPC' || VPCId=='$$BNK_VPC'])" --output text 2>/dev/null); \
	   n=$${n:-0}; m=$${m:-0}; \
	   if [ "$$n" = "0" ] && [ "$$m" = "0" ]; then echo "  ✓ no load balancers left in either VPC"; break; fi; \
	   echo "  still present: $$n NLB(v2) + $$m classic ELB — retry $$i/36"; sleep 10; \
	 done
	@OBS=$$(terraform output -raw observability_cluster_name 2>/dev/null); \
	 BNK=$$(terraform output -raw bankobs_cluster_name 2>/dev/null); \
	 ZID=$$(terraform output -raw public_hosted_zone_id 2>/dev/null); \
	 terraform destroy -auto-approve && { \
	   echo "  removing EKS control-plane log groups (EKS-owned, not in TF state)..."; \
	   aws logs delete-log-group --region $(REGION) --log-group-name /aws/eks/$$OBS/cluster 2>/dev/null || true; \
	   aws logs delete-log-group --region $(REGION) --log-group-name /aws/eks/$$BNK/cluster 2>/dev/null || true; \
	   echo "  removing external-dns records from the public zone (upsert-only never deletes them)..."; \
	   python3 scripts/cleanup-external-dns-records.py --zone-id "$$ZID" --owner "$$OBS" --owner "$$BNK" || true; \
	   echo "  removing orphaned EBS volumes tagged for these clusters..."; \
	   for c in "$$OBS" "$$BNK"; do \
	     for v in $$(aws ec2 describe-volumes --region $(REGION) --filters Name=status,Values=available Name=tag:ebs-owner-cluster,Values=$$c --query "Volumes[].VolumeId" --output text 2>/dev/null); do \
	       echo "    - deleting volume $$v ($$c)"; aws ec2 delete-volume --region $(REGION) --volume-id $$v 2>/dev/null || true; \
	     done; \
	   done; \
	 }
	@echo "  ✓ clusters, VPCs, peering, private zone, log groups, DNS records and EBS volumes destroyed."
	@echo "  NOTE: EBS cleanup covers volumes tagged ebs-owner-cluster=<cluster> — i.e. every PV"
	@echo "        volume provisioned once this storageclass change is live. Volumes created"
	@echo "        BEFORE it carry no such tag; list any stragglers with:"
	@echo "        aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId'"

# Delete every type=LoadBalancer Service in both clusters so the AWS cloud provider
# tears down their NLBs/ELBs (and the ENIs/SG rules that would block VPC deletion).
# Best-effort: ignores a cluster/context that is already gone.
clean-lbs: init
	-@aws eks update-kubeconfig --region $(REGION) --name $$(terraform output -raw observability_cluster_name 2>/dev/null) --alias $$(terraform output -raw observability_cluster_name 2>/dev/null) >/dev/null 2>&1
	-@aws eks update-kubeconfig --region $(REGION) --name $$(terraform output -raw bankobs_cluster_name 2>/dev/null)       --alias $$(terraform output -raw bankobs_cluster_name 2>/dev/null)       >/dev/null 2>&1
	@for c in $$(terraform output -raw observability_cluster_name 2>/dev/null) $$(terraform output -raw bankobs_cluster_name 2>/dev/null); do \
	  echo "  → deleting LoadBalancer Services in $$c"; \
	  kubectl --context $$c get svc -A -o go-template='{{range .items}}{{if eq .spec.type "LoadBalancer"}}{{.metadata.namespace}} {{.metadata.name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null \
	    | while read ns name; do [ -n "$$name" ] && echo "      - $$ns/$$name" && kubectl --context $$c -n $$ns delete svc $$name --wait=false >/dev/null 2>&1; done; \
	done
	@echo "  (LB Services deleted; AWS is now reaping the NLBs/ELBs)"

# Point kubectl at both clusters (aliases match the cluster names).
kubeconfig: init
	@aws eks update-kubeconfig --region $(REGION) --name $$(terraform output -raw observability_cluster_name) --alias $$(terraform output -raw observability_cluster_name)
	@aws eks update-kubeconfig --region $(REGION) --name $$(terraform output -raw bankobs_cluster_name) --alias $$(terraform output -raw bankobs_cluster_name)
	@echo "  ✓ kubeconfig updated for both clusters."

output: init
	terraform output
