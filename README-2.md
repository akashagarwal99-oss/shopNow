This folder is a companion to `ShopNow-Capstone4-DevOps-Pipeline-Guide.md` — every file here was
originally extracted from that guide, then revised twice to match one specific AWS account's
values and to fully satisfy the Project 4 brief (11-stage Jenkins pipeline, Trivy scanning, real
test detection, PDBs, expanded monitoring). It is not a substitute for reading the guide: several
steps (creating Secrets, running Ansible, applying manifests in the right order, creating the
scoped MongoDB user) are commands you run, not files, and they only make sense with the
explanation around them. Where this README and the original guide's section numbers disagree on a
detail, this README and `CHANGELOG.md` describe the current, correct state.

**Personalized for:**

| | |
|---|---|
| Project name | `akash-shopnow` |
| Kubernetes namespace | `akash-shopnow` |
| EKS cluster name | `akash-shopnow-eks` |
| AWS account | `655383751644` |
| AWS region | `ap-south-1` (AZs: `ap-south-1a`, `ap-south-1b`) |
| Jenkins EC2 / EKS node instance type | `c7i-flex.large` (2 vCPU / 4 GiB — swapped from t3.medium, which this account doesn't offer) |
| ECR repositories | `akash-shopnow/backend`, `akash-shopnow/frontend`, `akash-shopnow/admin` — **pre-existing, not created by Terraform** (see below) |
| Terraform state | S3 bucket `akash-shopnow-tfstate-655383751644`, key `shopnow/dev/terraform.tfstate` |

**ECR repositories already exist and are treated as external.** `terraform/ecr.tf` only contains
`data "aws_ecr_repository"` lookups, not `resource` blocks — `terraform destroy` will never touch
them, and `terraform plan` will error (correctly) if any of the three don't already exist in this
account.

Still yours to fill in before `terraform apply` — nobody but you can know these:
- `terraform/terraform.tfvars` (copy from `.tfvars.example`): your real `my_ip_cidr`.
- An EC2 key pair literally named `akash-shopnow-jenkins-key` in `ap-south-1`, or override
  `jenkins_key_name` in `terraform.tfvars` with one you already have.
- The S3 state bucket `akash-shopnow-tfstate-655383751644` — one-time `aws s3api create-bucket`
  before the first `terraform init`; exact commands are in the comment at the top of
  `terraform/backend.tf`.

How to use this:

1. Copy the relevant folder's contents into your own `shopNow` fork at the same path
   (`terraform/`, `ansible/`, `kubernetes/`, `scripts/`, `jenkins/`, `monitoring/`, `.gitignore`).
2. Follow the guide section by section for the overall flow — it tells you when to run
   `terraform apply`, when to run the Ansible playbook, when to `kubectl apply` which manifest,
   and in what order. `CHANGELOG.md` in this folder documents everywhere the actual files now
   differ from what the guide originally described.
3. `terraform/policies/alb-iam-policy.json` is included here as a convenience (fetched directly
   from the aws-load-balancer-controller v2.14.1 release for you).
4. `terraform/terraform.tfvars.example` — copy to `terraform.tfvars` and fill in your own
   `my_ip_cidr` before running `terraform init`. Never commit the real `terraform.tfvars` — the
   included `.gitignore` already excludes it, along with `*.pem`, `*.key`, and other credential
   patterns.

Everything in `terraform/*.tf` has been syntax-checked with a real HCL2 parser (not just eyeballed)
— every file parses, every `var.*` reference resolves to a defined variable, every resource/data/
module reference resolves to something actually defined. Everything in `kubernetes/`, `ansible/`,
and `monitoring/` has been YAML-validated. That catches syntax mistakes, not AWS-account-specific
issues — you'll still want `terraform validate`/`terraform plan` (§7 of the accompanying report)
before trusting this against your real account.

Folder map:
```
terraform/    VPC, EKS cluster, IAM/Pod Identity roles, Jenkins EC2 (ECR repos looked up, not created)
ansible/      playbook.yml — Docker, AWS CLI, kubectl, Helm, Terraform, jq, Trivy, Jenkins
kubernetes/   namespace, storageclass, mongo, backend/frontend/admin (deploy/svc/hpa/pdb), ingress
scripts/      install-alb-controller.sh — one-time Helm bootstrap for the ALB controller
jenkins/      the Jenkinsfile — 10 stages + post-build reporting
monitoring/   Prometheus alerting rules — pod/node/deployment/HPA health
.gitignore    keeps tfstate, tfvars, keys, and other secrets out of version control
CHANGELOG.md  what changed, why, and what's still a manual step — read this before the guide
```
