# ShopNow – End-to-End DevOps CI/CD Pipeline

## 1. Project Overview

ShopNow is a three-tier e-commerce web application — a customer-facing storefront, an admin
dashboard, and a Node.js/Express API backed by MongoDB. This repository is the DevOps capstone
built around it: everything needed to take a code change from `git push` to a running, monitored
service on AWS EKS without a human running `kubectl apply` by hand.

**What was automated end to end:** provisioning the AWS infrastructure (VPC, EKS cluster, IAM,
Jenkins host) with Terraform; configuring the Jenkins host with Ansible; building, scanning, and
pushing container images; deploying to Kubernetes with health-checked, autoscaled rollouts;
verifying the live deployment with black-box smoke tests through the real load balancer; and
monitoring the result with Prometheus/Grafana alerting rules.

**Why this architecture:** the assignment specifically asks for Jenkins as the CI/CD orchestrator,
Terraform for infrastructure, Ansible for configuration management, and EKS as the deployment
target — so the shape of this repo follows directly from that brief rather than from a preference
for any particular tool. Within that brief, a few choices were deliberate rather than default:
a managed EKS node group instead of self-managed workers (AWS patches the worker AMI; Ansible's
job is configuring the *Jenkins* box, not fighting EKS's own node lifecycle); an EC2 IAM instance
profile instead of long-lived AWS keys in Jenkins; immutable Git-SHA image tags instead of
`latest`; and the AWS Load Balancer Controller for ingress, with both apps routed through a single
shared ALB.

**Technologies used, at a glance:** AWS (VPC, EKS, EC2, ECR, S3, IAM), Terraform, Ansible, Jenkins,
Docker, Trivy, Kubernetes, Helm, the AWS Load Balancer Controller, kube-prometheus-stack
(Prometheus + Grafana + Alertmanager), MongoDB, Node.js/Express, React.

## 2. Assignment Requirements Covered

| Requirement | Implementation | Evidence |
|---|---|---|
| Application architecture (load balancing, orchestration, monitoring) | Frontend/admin/backend/MongoDB on EKS behind a shared ALB; kube-prometheus-stack for monitoring | §3, §6, §15 |
| Dockerization | `backend/Dockerfile`, `frontend/Dockerfile`, `admin/Dockerfile` — multi-stage, non-root, health-checked | §7 |
| Terraform: VPC, subnets, EKS | `terraform/vpc.tf`, `terraform/eks.tf` | §8 |
| Terraform remote state in S3 | `terraform/backend.tf` — S3 + native locking | §9 |
| Configuration management with Ansible | `ansible/playbook.yml` | §10 |
| Jenkins CI/CD, build→test→deploy | `jenkins/Jenkinsfile` — 10 stages | §11 |
| Kubernetes/EKS deployment, scalability, resilience | `kubernetes/` — Deployments, Services, HPA, PDB, Ingress | §13 |
| Health checks | readiness/liveness probes on every Deployment | §13 |
| Horizontal Pod Autoscaling | `kubernetes/*/hpa.yaml`, load-tested | §14 |
| Prometheus monitoring | kube-prometheus-stack, `monitoring/shopnow-alerts.yaml` | §15 |
| Grafana dashboards | custom ShopNow dashboard, accessed via port-forward | §16 |
| Prometheus/Alertmanager alerting | 8 `PrometheusRule` alerts; Alertmanager email — see the note in §17 | §17 |
| Jenkins notifications | failure-email `post{}` block in the Jenkinsfile | §18 |
| End-to-end validation | push → webhook → build → scan → push → deploy → smoke test | §19 |
| Rollback | `kubectl rollout undo`, tested against a real revision | §20 |
| Cost optimization / teardown | single NAT gateway, right-sized nodes, environment destroyed after evidence capture | §23, §26 |
| Documentation | this file, plus `CHANGELOG.md` for design rationale | — |

## 3. Architecture

```
Developer
   |
   v
GitHub (akashagarwal99-oss/shopNow)
   |
   v  webhook (push to main)
Jenkins on EC2 (c7i-flex.large, public subnet)
   |-- Checkout
   |-- Build & Test              (jq-gated: only runs npm test where a real script exists)
   |-- Infrastructure Provisioning (parameterized, off by default)
   |-- Configuration Management    (parameterized, off by default)
   |-- Docker Build
   |-- Security Scan (Trivy)
   |-- ECR Push
   |-- Deploy to EKS               (main branch only)
   |-- Rollout & Health Verification
   `-- Testing and Monitoring      (live smoke tests through the ALB)
          |
          v
       AWS EKS (akash-shopnow-eks, private-subnet managed node group)
       namespace: akash-shopnow
       +-- frontend  (2 pods, HPA 2-4)  --\
       +-- admin     (2 pods, HPA 2-4)  ---+--> backend-service:5000 --> backend (2 pods, HPA 2-4)
       +-- mongo     (StatefulSet, 1 replica, gp3 PVC)                        |
                                                                         (Secret: MONGODB_URI)
          |
          v
       One shared ALB (AWS Load Balancer Controller, IngressGroup "shopnow")
       /akash        -> frontend-service
       /akash-admin  -> admin-service
          |
          v
       Users

Monitoring (separate namespace: monitoring):
EKS pods/nodes --> Prometheus (kube-prometheus-stack, Helm release "monitoring")
                       |
                       +--> Grafana (custom ShopNow dashboard, port-forward access)
                       `--> Alertmanager --> email (§17)
```

A few things worth calling out about this diagram:

- **One shared ALB, not one per app.** Both frontend and admin bake a `PUBLIC_URL` into their
  static assets at build time (`/akash` and `/akash-admin` respectively), and the ALB Ingress
  doesn't rewrite paths on its own — `kubernetes/frontend/nginx-configmap.yaml` and
  `kubernetes/admin/nginx-configmap.yaml` handle that instead, overriding the nginx config baked
  into each image with an internal `rewrite ... break` that strips the prefix before nginx looks
  the file up on disk. Both Ingress resources share `alb.ingress.kubernetes.io/group.name: shopnow`,
  which tells the AWS Load Balancer Controller to provision one ALB and route by path instead of
  one ALB per Ingress.
- **EKS Pod Identity, not IRSA**, for the AWS Load Balancer Controller and the EBS CSI driver
  (`terraform/pod-identity.tf`). No OIDC provider, no `eks.amazonaws.com/role-arn` ServiceAccount
  annotation — the credential binding is an `aws_eks_pod_identity_association` resource, matched
  purely by namespace + service account name.
- **Jenkins authenticates to AWS via an EC2 IAM instance profile**, never long-lived access keys.

## 4. Technology Stack

Versions below are what's actually pinned in the repository. Where a tool is installed via a
package manager without a version pin, that's stated explicitly rather than guessed.

| Tool | Version / detail | Where pinned |
|---|---|---|
| Terraform | `>= 1.11.0` (required for native S3 state locking) | `terraform/backend.tf` |
| AWS provider (Terraform) | `~> 5.0` | `terraform/providers.tf` |
| `terraform-aws-modules/vpc/aws` | `~> 6.0` | `terraform/vpc.tf` |
| `terraform-aws-modules/eks/aws` | `21.24.0` (exact pin) | `terraform/eks.tf` |
| Kubernetes (EKS) | `1.34` | `terraform/variables.tf` (`cluster_version`), passed as `K8S_VERSION` in the Jenkinsfile |
| EKS node instance type | `c7i-flex.large` (2 vCPU / 4 GiB) | `terraform/variables.tf` |
| Jenkins EC2 instance type | `c7i-flex.large` | `terraform/variables.tf` |
| Jenkins EC2 AMI | pinned to a specific AMI ID (`terraform/variables.tf`, `jenkins_ami_id`) rather than resolved dynamically — see §21 for why | `terraform/jenkins-ec2.tf` |
| Ansible-managed: kubectl | `v1.34.0` | `ansible/playbook.yml` |
| Ansible-managed: Helm | `v3.16.4` | `ansible/playbook.yml` |
| Ansible-managed: Trivy | `0.74.0`, checksum-verified install (see §22) | `ansible/playbook.yml` |
| Ansible-managed: Terraform, Docker, Java, Jenkins, jq, git | installed via apt (HashiCorp/Jenkins/Ubuntu repos); not version-pinned beyond what each repo currently serves | `ansible/playbook.yml` |
| AWS Load Balancer Controller | installed via Helm from `eks-charts`, chart version not pinned (tracks current) | `scripts/install-alb-controller.sh` |
| kube-prometheus-stack | `88.5.2` (Helm chart version), release name `monitoring` | (imperative — see §16) |
| MongoDB | `mongo:7.0` | `kubernetes/mongo/statefulset.yaml` |
| nginx (frontend/admin base image) | `nginx:1.24-alpine` | `frontend/Dockerfile`, `admin/Dockerfile` |
| Node.js (build stage, all 3 apps) | `node:18-alpine` | `backend/Dockerfile`, `frontend/Dockerfile`, `admin/Dockerfile` |
| Express | `^4.18.2` | `backend/package.json` |
| Mongoose | `^7.5.0` | `backend/package.json` |
| React | `^18.2.0` | `frontend/package.json`, `admin/package.json` |
| react-scripts | `5.0.1` | `frontend/package.json`, `admin/package.json` |

## 5. Repository Structure

```
shopNow/
├── backend/                  Express + MongoDB API (npm package "shopnow-backend")
├── frontend/                 React customer storefront (npm package "shopnow-frontend")
├── admin/                    React admin dashboard (npm package "shopnow-admin")
├── docs/                     Original application docs (architecture, K8s concepts, tooling, troubleshooting)
├── terraform/
│   ├── backend.tf            S3 remote state configuration
│   ├── providers.tf          AWS provider + default tags
│   ├── variables.tf          All input variables and their defaults
│   ├── vpc.tf                VPC module (2 AZ, public+private subnets, 1 NAT gateway)
│   ├── eks.tf                EKS cluster + managed node group
│   ├── ecr.tf                Data-source lookups for the 3 pre-existing ECR repos (not created here)
│   ├── pod-identity.tf       EKS Pod Identity roles: ALB controller, EBS CSI driver
│   ├── jenkins-ec2.tf        Jenkins EC2 instance, security group, IAM instance profile
│   ├── outputs.tf            vpc_id, cluster_name, cluster_endpoint, ecr URLs, Jenkins IP/SSH command
│   ├── bootstrap-versions.sh Resolves current EKS addon/AMI versions into deployment.auto.tfvars
│   ├── terraform.tfvars.example
│   └── policies/alb-iam-policy.json   AWS Load Balancer Controller's official IAM policy
├── ansible/
│   └── playbook.yml          Configures the Jenkins EC2: Docker, AWS CLI, kubectl, Helm, Terraform, Trivy, Jenkins
├── kubernetes/
│   ├── namespace.yaml
│   ├── storageclass-gp3.yaml
│   ├── mongo/                 statefulset.yaml, service.yaml (headless)
│   ├── backend/                deployment.yaml, service.yaml, hpa.yaml, pdb.yaml
│   ├── frontend/                deployment.yaml, service.yaml, hpa.yaml, pdb.yaml, ingress.yaml, nginx-configmap.yaml
│   └── admin/                   deployment.yaml, service.yaml, hpa.yaml, pdb.yaml, ingress.yaml, nginx-configmap.yaml
├── jenkins/
│   └── Jenkinsfile            10-stage declarative pipeline
├── monitoring/
│   └── shopnow-alerts.yaml    8 PrometheusRule alerts
├── scripts/
│   └── install-alb-controller.sh   One-time Helm bootstrap for the AWS Load Balancer Controller
├── .gitignore
├── CHANGELOG.md               Design rationale and change history for the DevOps implementation
└── README.md                  This file
```

A note on the repository's history: an earlier, more aspirational draft README (describing an
`infra/` directory, an Amazon-Linux Jenkins host, and a couple of scripts that were never actually
added) existed alongside this content. This document reflects what's actually in the
`terraform/`, `ansible/`, `kubernetes/`, `jenkins/`, and `monitoring/` directories as inspected
directly, not that earlier draft.

## 6. Application Architecture

Four components, three of them containerized application tiers and one a database:

- **backend** (`shopnow-backend`) — Express + Mongoose API. Listens on port `5000`
  (`backend/server.js`, `process.env.PORT || 5000`). Connects to MongoDB via the `MONGODB_URI`
  environment variable, sourced from a Kubernetes Secret. Exposes `/api/health` alongside the
  application's actual routes (`/api/products`, `/api/invoices`, `/api/users`, `/api/categories`,
  `/api/analytics/dashboard`, and a `/api/seed/products` convenience endpoint for populating
  sample data).
- **frontend** (`shopnow-frontend`) — React 18 storefront (Create React App), served by nginx.
  Built with `PUBLIC_URL=/akash` and `REACT_APP_API_BASE_URL=/akash/api` baked in at build time.
- **admin** (`shopnow-admin`) — React 18 admin dashboard, same build pattern, at `/akash-admin`.
- **mongo** — MongoDB 7.0, a single-replica StatefulSet with a `gp3` persistent volume.

**How they talk to each other:** the browser only ever talks to nginx (inside the frontend/admin
pods) and to the backend indirectly through it. Each nginx config
(`kubernetes/frontend/nginx-configmap.yaml`, `kubernetes/admin/nginx-configmap.yaml`) rewrites
`/akash/api/...` (or `/akash-admin/api/...`) to `/api/...` internally and proxies it to
`backend-service:5000` — a plain Kubernetes Service DNS name, resolved inside the cluster, never
exposed externally. The backend talks to MongoDB directly over the cluster network at
`mongo-0.mongo.akash-shopnow.svc.cluster.local:27017`, authenticating as a scoped `shopuser`
account (readWrite + dbAdmin on the `shopnow` database only — not the Mongo root account).

## 7. Dockerization

All three application images are two-stage-or-simpler, non-root where it matters, and built with
immutable tags rather than `latest`.

**backend/Dockerfile** — single-stage, `node:18-alpine`. `npm ci --only=production` for a lean
image; runs as a created non-root user (`appuser`/`appgroup`), not root. `EXPOSE 5000`.

```dockerfile
HEALTHCHECK --interval=15s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:${PORT}/health || exit 1
```

Worth flagging: this `HEALTHCHECK` checks `/health`, but the Express app only defines
`/api/health` — there's no `/health` route on the backend. This means `docker ps`/`docker inspect`
will report the backend container as unhealthy even while it's serving traffic correctly. It's a
real, currently-unfixed inconsistency, not a functional problem for the deployed app: Kubernetes
doesn't use a container's Docker `HEALTHCHECK` for its own readiness/liveness decisions —
`kubernetes/backend/deployment.yaml`'s probes are defined independently and do correctly target
`/api/health` on port `5000` — so the actual in-cluster health checking that matters is right. The
Dockerfile-level check is still worth fixing (change `/health` to `/api/health`) for anyone running
the image standalone with plain `docker run`.

**frontend/Dockerfile** and **admin/Dockerfile** — two-stage: `node:18-alpine AS builder` compiles
the React app, then a clean `nginx:1.24-alpine` stage serves only the built static output plus a
custom `nginx/default.conf` copied in from each app's own folder. Both take a
`USER_NAME` build argument (default `akash` in this repo, previously `aryan` upstream) that gets
baked into `PUBLIC_URL` and `REACT_APP_API_BASE_URL`:

```dockerfile
ARG USER_NAME=akash
ENV PUBLIC_URL=/${USER_NAME}
ENV REACT_APP_API_BASE_URL=/${USER_NAME}/api
```

(`admin/Dockerfile` follows the same pattern with a `-admin` suffix: `/${USER_NAME}-admin`.) Both
run nginx as the container's default user, with a `HEALTHCHECK` against a plain `/health` location
that's defined outside the `/akash` rewrite rules, so it isn't affected by the subpath — see §13
for how that rewrite is implemented.

**Image tags** are never `latest`. The Jenkinsfile computes `IMAGE_TAG` from
`git rev-parse --short HEAD` in the Checkout stage (overridable via a Jenkins parameter for a
deliberate redeploy of a known tag) and every `docker build`/`docker push` uses that tag. Images
are pushed to three ECR repositories that already existed in the AWS account before this
Terraform config was written — Terraform only reads them (`data "aws_ecr_repository"` in
`terraform/ecr.tf`), it doesn't create or manage their lifecycle:

```
655383751644.dkr.ecr.ap-south-1.amazonaws.com/akash-shopnow/backend:<git-sha>
655383751644.dkr.ecr.ap-south-1.amazonaws.com/akash-shopnow/frontend:<git-sha>
655383751644.dkr.ecr.ap-south-1.amazonaws.com/akash-shopnow/admin:<git-sha>
```

## 8. Terraform Infrastructure

Nine `.tf` files plus one helper script, all under `terraform/`. What each provisions:

| File | Provisions |
|---|---|
| `vpc.tf` | VPC (`terraform-aws-modules/vpc/aws ~> 6.0`), CIDR `10.0.0.0/16`, 2 AZs (`ap-south-1a`, `ap-south-1b`), 2 public + 2 private subnets, 1 NAT Gateway (not one per AZ — a deliberate cost choice, see §23), subnet tags for EKS/ALB discovery |
| `eks.tf` | EKS cluster (`terraform-aws-modules/eks/aws`, pinned to exact version `21.24.0`), Kubernetes `1.34`, one managed node group (`c7i-flex.large`, desired 2 / min 1 / max 3), an EKS access entry granting the Jenkins IAM role cluster-admin, and a security-group rule explicitly allowing the Jenkins host to reach the cluster API |
| `pod-identity.tf` | IAM roles + EKS Pod Identity associations for the AWS Load Balancer Controller and the EBS CSI driver (`kube-system` namespace) |
| `ecr.tf` | `data "aws_ecr_repository"` lookups for the 3 pre-existing repos — **not** `resource` blocks; Terraform never creates, modifies, or destroys these |
| `jenkins-ec2.tf` | Jenkins EC2 instance (`c7i-flex.large`, pinned AMI), its security group, and an IAM instance profile |
| `backend.tf` | S3 remote state configuration (§9) |
| `providers.tf` | AWS provider + default resource tags |
| `variables.tf` | Every input variable and its default |
| `outputs.tf` | `vpc_id`, `cluster_name`, `cluster_endpoint`, `ecr_repository_urls`, `jenkins_public_ip`, `jenkins_ssh_command`, `configure_kubectl_command` |
| `bootstrap-versions.sh` | Not a `.tf` file — a shell script the Jenkinsfile's Infrastructure Provisioning stage runs *before* `terraform plan`, which resolves the current recommended EKS addon versions and node-group AMI release version and writes them into `deployment.auto.tfvars` (auto-loaded by Terraform). See §21 for why this exists. |

**Module versioning:** the VPC module uses a version range (`~> 6.0`); the EKS module is pinned to
an exact version (`21.24.0`) rather than a range — a deliberate tightening, since an EKS module
upgrade can change node-group or add-on behavior in ways worth reviewing explicitly rather than
picking up silently on the next `terraform init`.

**IAM and secrets encryption:** `enable_cluster_creator_admin_permissions = false` — access to the
cluster is granted explicitly via the `access_entries` block (the Jenkins IAM role only), not
automatically to whoever happens to run `terraform apply`. The EKS module's default KMS key (used
for envelope-encrypting Kubernetes Secrets at rest) has its administrators explicitly set to the
Jenkins role via `kms_key_administrators`, rather than left unmanaged.

**Variables worth knowing** (`variables.tf`): `aws_region` (`ap-south-1`), `student_username`
(`akash` — used to namespace ECR-adjacent naming and AWS resource names), `cluster_name`
(`akash-shopnow-eks`), `cluster_version` (`1.34`), `node_instance_types` / `jenkins_instance_type`
(`c7i-flex.large`), `jenkins_ami_id` (a pinned AMI — no default; must be supplied), `jenkins_key_name`,
`my_ip_cidr` (no default — your workstation's IP, required), `eks_addon_versions` and
`node_ami_release_version` (no defaults — populated by `bootstrap-versions.sh` into
`deployment.auto.tfvars`, not hand-edited).

## 9. Terraform Remote State with S3

**File: `terraform/backend.tf`**
```hcl
backend "s3" {
  bucket       = "akash-shopnow-tfstate-655383751644"
  key          = "shopnow/dev/terraform.tfstate"
  region       = "ap-south-1"
  encrypt      = true
  use_lockfile = true   # native S3 locking (Terraform >= 1.11) — no DynamoDB table needed
}
```

Remote state matters here for two concrete reasons in this project specifically: the same state
needs to be readable both from a workstation (for `terraform plan` review) and from the Jenkins
EC2 (for the pipeline's parameterized Infrastructure Provisioning stage) — a local `.tfstate` file
would only exist on whichever machine last ran `apply`. And `use_lockfile = true` (Terraform's
native S3 conditional-write locking, available from Terraform 1.11 onward) prevents two concurrent
`apply` runs — one from a laptop, one triggered from Jenkins — from corrupting each other's state,
without needing a separate DynamoDB table for locking.

**Bucket setup is not part of this Terraform config** (a backend can't create the bucket it then
stores its own state in) — it's a one-time, out-of-band step:
```bash
aws s3api create-bucket --bucket akash-shopnow-tfstate-655383751644 --region ap-south-1 \
  --create-bucket-configuration LocationConstraint=ap-south-1
aws s3api put-bucket-versioning --bucket akash-shopnow-tfstate-655383751644 \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket akash-shopnow-tfstate-655383751644 \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket akash-shopnow-tfstate-655383751644 \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

**Initializing against the existing backend from a different machine** (a fresh workstation, or
after wiping local `.terraform/`):
```bash
cd terraform
terraform init -reconfigure
terraform state list
terraform plan
```
Per the project's own validation history, `terraform plan` against the already-provisioned
infrastructure reported `No changes. Your infrastructure matches the configuration.` — the
addon-version and AMI pinning described in §8 and §21 is specifically what makes that outcome
reproducible instead of Terraform wanting to change something on every run.

## 10. Ansible Configuration Management

**File: `ansible/playbook.yml`** — a single play, `hosts: all` (deliberately, not `hosts: jenkins`
— it runs two different ways, explained below), that turns a bare EC2 instance into a working
Jenkins host. No roles; the tasks are flat and readable top to bottom, which for a single-host
playbook of this size is a reasonable trade-off against role-based abstraction.

**What it installs/configures**, in order: base apt packages (`git`, `jq`, `gettext-base` for
`envsubst`, and the usual transport/cert prerequisites) → Docker (`docker.io`, enabled, `ubuntu`
user added to the `docker` group) → AWS CLI v2 (idempotent — skips reinstalling if
`/usr/local/bin/aws` already exists) → `kubectl` `v1.34.0` → Helm `v3.16.4` → Terraform (HashiCorp's
official apt repo, deliberately pinned to the `noble` (24.04) suite rather than the host's actual
codename — HashiCorp doesn't publish a `resolute` (26.04) suite, and `noble` packages are
confirmed compatible) → Trivy `0.74.0` (downloaded directly from GitHub releases and verified
against its published `sha256` checksums before installing — not `apt install` — see §22 for why)
→ OpenJDK 21 → Jenkins (official apt repo, current signing-key channel) → passwordless `sudo` for
the `jenkins` system user → `jenkins` user added to the `docker` group.

**Idempotency and the self-management problem:** two variables, `restart_jenkins` and
`initial_jenkins_setup` (both default `false`), gate the parts of this playbook that only make
sense on a truly fresh install — restarting the Jenkins service, and waiting for/reading the
one-time initial admin password file. The reason: this exact playbook runs twice in this project's
life. The first time, it's invoked over SSH from a workstation against a brand-new EC2 instance,
where a restart and reading the initial password both make sense. Every time after that, it's
invoked *by Jenkins itself*, as the pipeline's Configuration Management stage, running locally
(`ansible-playbook -i "localhost," -c local playbook.yml`) — and restarting the Jenkins service
from inside a Jenkins-triggered build kills the very build that's running it. Defaulting both
variables to `false` makes the ongoing, pipeline-triggered runs safe by default; the first-time
bootstrap run passes `-e restart_jenkins=true -e initial_jenkins_setup=true` explicitly.

**Jenkins integration:** the Configuration Management stage in the Jenkinsfile (§11) invokes this
exact playbook, locally, with no inventory file — `hosts: all` matches the ad-hoc `-i "localhost,"`
inventory the pipeline uses, where `hosts: jenkins` (matching a named inventory group) would match
nothing and silently do nothing.

**Validating a run:**
```bash
ansible -i inventory.ini all -m ping        # connectivity check before a real run
ansible-playbook -i inventory.ini playbook.yml -e restart_jenkins=true -e initial_jenkins_setup=true
```

## 11. Jenkins CI/CD

`jenkins/Jenkinsfile` — a declarative pipeline, 10 stages plus a `post {}` block. Triggered by a
GitHub webhook on push (see §19 for the connectivity note that required a security-group change).
This is a plain **Pipeline script from SCM** job, not a Multibranch Pipeline — that detail matters
for how branch gating is implemented below.

**Pipeline-level parameters:**

| Parameter | Default | Purpose |
|---|---|---|
| `RUN_INFRA` | `false` | Runs the Infrastructure Provisioning stage |
| `RUN_CONFIG` | `false` | Runs the Configuration Management stage (also runs automatically if `RUN_INFRA` is true — see the stage detail below) |
| `ALLOW_VULNERABLE_IMAGES` | `true` | Documented exception path for the Trivy stage — see §22 for why this default is worth reconsidering |
| `IMAGE_TAG` | *(blank)* | Leave blank to tag images with the Git SHA (recommended); set explicitly only to redeploy a known tag |
| `MY_IP_CIDR` | *(blank)* | Passed through to Terraform as `my_ip_cidr` when `RUN_INFRA` is set — see §8 |

**Pipeline-level environment:** `AWS_REGION=ap-south-1`, `AWS_ACCOUNT_ID=655383751644`,
`ECR_REGISTRY` (derived from those two), `CLUSTER_NAME=akash-shopnow-eks`,
`NAMESPACE=akash-shopnow`, `DEPLOY_BRANCH=main`, `K8S_VERSION=1.34`, and `PATH` explicitly
prepended with `/usr/local/bin` (kubectl/Helm live there; the Jenkins service's own environment
doesn't reliably inherit a login shell's `PATH`).

### Pipeline flow

**1. Checkout** — `checkout scm`, then computes `IMAGE_TAG` from `git rev-parse --short HEAD`
(or uses the `IMAGE_TAG` parameter if one was supplied). Logs the branch and the tag being built.

**2. Build & Test** — for each of `backend`, `frontend`, `admin`: checks
`jq -e '.scripts.test' <app>/package.json` first. `backend/package.json` has no `test` script at
all (only `start` and `dev`), so this stage logs that fact and skips it rather
than fabricating a pass. `frontend`/`admin` both define `"test": "react-scripts test"`, which *does*
run for real, inside an ephemeral `node:18-alpine` container with `CI=true` and `--watchAll=false`
so it doesn't hang in interactive watch mode. There are currently no `*.test.js` files anywhere in
the repository, so `--passWithNoTests` keeps "nothing written yet" from being treated as a failure
— add test files later and this stage starts running them for real, no pipeline change needed.
This is deployment-adjacent testing infrastructure, not unit-test coverage — see §12.

**3. Infrastructure Provisioning** *(runs only if `RUN_INFRA=true`)* — `terraform/bootstrap-versions.sh`
resolves current EKS addon and node-AMI versions into `deployment.auto.tfvars` first (§21), then
`terraform init` / `plan` / `apply`, passing `-var="my_ip_cidr=${MY_IP_CIDR}"`. Not run on ordinary
commits — see the "why gated" note below.

**4. Configuration Management** *(runs if `RUN_INFRA=true` **or** `RUN_CONFIG=true`)* — re-invokes
`ansible/playbook.yml` locally on the Jenkins box itself, with `restart_jenkins`/`initial_jenkins_setup`
left at their safe `false` defaults (§10). Linked to `RUN_INFRA` because a freshly (re-)provisioned
box generally wants its configuration re-asserted too.

**5. Docker Build** — `docker build` for all three apps, tagged
`<ecr-registry>/akash-shopnow/<app>:<IMAGE_TAG>`. Frontend/admin builds pass
`--build-arg USER_NAME=akash`.

**6. Security Scan (Trivy)** — `trivy image --severity HIGH,CRITICAL --ignore-unfixed` against all
three just-built images. `--ignore-unfixed` excludes CVEs with no available fix (nothing actionable
to do about those today). Whether a finding actually fails the build depends on
`ALLOW_VULNERABLE_IMAGES` — see §22.

**7. ECR Push** — `aws ecr get-login-password | docker login`, then `docker push` for all three
tags, to the three pre-existing repositories (§7).

**8. Deploy to EKS** *(branch-gated — `main` only)* — `aws eks update-kubeconfig`, then
`envsubst < kubernetes/<app>/deployment.yaml | kubectl apply -f -` for backend/frontend/admin.
Only `IMAGE_TAG` is templated in the manifests; the ECR registry host is hardcoded directly in
each `deployment.yaml` (fixed for this account, so nothing to substitute there).

**9. Rollout & Health Verification** *(branch-gated)* — `kubectl rollout status` for all three
Deployments, then explicitly checks each Deployment's `Available` condition, then checks every
pod's container readiness. Any failure names the specific Deployment/app that failed rather than
a generic timeout message.

**10. Testing and Monitoring** *(branch-gated)* — see §12; this is the smoke-test stage.

**Branch gating, precisely:** stages 8–10 check `env.GIT_BRANCH ?: env.BRANCH_NAME` against
`main` (bare or `origin/`-prefixed), not the declarative `when { branch 'main' }` directive — that
directive only evaluates correctly inside a Multibranch Pipeline job, and this project uses a plain
"Pipeline script from SCM" job, where `branch` would error rather than evaluate to false. Feature
branches still run Checkout, Build & Test, Infra/Config (if requested), Docker Build, Trivy, and
ECR Push — full CI feedback on every push — they just stop before touching the live cluster.

**Why Infrastructure Provisioning/Configuration Management are gated at all:** Jenkins only exists
because Terraform and Ansible already ran once, by hand, to create it — a pipeline can't bootstrap
the server it's running on. The parameters let you *re-run* infra/config changes from inside
Jenkins later without re-running Terraform/Ansible on every ordinary code push. One thing worth
knowing before ever setting `RUN_INFRA=true`: that stage's `terraform apply` manages the very EC2
instance Jenkins runs on. `aws_instance.jenkins` now has `lifecycle { prevent_destroy = true }` and
a pinned AMI specifically because of this — see §21.

**`post {}`:** `success` logs the tag and cluster deployed to; `failure` sends an email via
`emailext` (§18) and logs which stage to check; `always` runs `docker image prune -f` to keep the
Jenkins host's disk from filling up with build layers.

## 12. Application Smoke Testing

**Testing limitation:** the backend currently has no test script (`backend/package.json` defines
only `start` and `dev`), and while `frontend/package.json` and `admin/package.json` both define
`"test": "react-scripts test"`, the repository contains no `*.test.js` files for that command to
run against. The Build & Test stage (§11) checks for a real test script per app and reports the
result accordingly rather than reporting a pass where none exists. Deployment validation is
therefore performed primarily through black-box smoke tests against the live application.

**Black-box smoke testing against the live, deployed application through the real ALB** — the
Testing and Monitoring stage, after Deploy and Rollout & Health Verification have already
succeeded — checks four things, each against the real Ingress hostname (not `localhost`, not a
mock, not the application source):

| Check | URL | Expected |
|---|---|---|
| Frontend | `http://<alb-hostname>/akash/` | HTTP 200 |
| Admin UI | `http://<alb-hostname>/akash-admin/` | HTTP 200 (retried up to 12× at 10s intervals — the admin ALB target group can take a little longer to register as healthy right after a fresh deploy) |
| Backend health | `http://<alb-hostname>/akash/api/health` | HTTP 200 |
| Backend products API | `http://<alb-hostname>/akash/api/products?limit=1` | HTTP 200 |

Before any of the four checks run, the stage separately waits (up to 3 minutes) for the ALB
hostname to even be assigned on the Ingress object, and (up to 2 minutes) for the backend health
endpoint to start responding — cloud load balancers and fresh pods take time to become ready, and
the stage accounts for that rather than failing on a race condition. A failure at any of the four
checks fails the Jenkins build and prints the HTTP status actually received.

This is deployment validation, not unit testing. What
it proves is narrower but arguably more relevant to a deployment pipeline: that the thing Jenkins
just deployed is actually reachable, actually serving the right paths, and actually talking to the
database (the products endpoint only returns 200 if the backend successfully queried MongoDB).

## 13. Kubernetes Deployment

Everything application-level lives in the `akash-shopnow` namespace (`kubernetes/namespace.yaml`).
Cluster-scoped resources (the `gp3` StorageClass, the `monitoring` namespace and its contents) sit
outside it, as they should.

**Deployments** (`kubernetes/{backend,frontend,admin}/deployment.yaml`) — 2 replicas each at
steady state (HPA can take them to 4 — §14). Each has CPU/memory `requests` and `limits`, and both
a `readinessProbe` and a `livenessProbe`:

| App | Probe path | Port |
|---|---|---|
| backend | `/api/health` | `5000` |
| frontend | `/health` | `80` |
| admin | `/health` | `80` |

**Services** — `backend-service` (`5000`), `frontend-service` (`80`), `admin-service` (`80`), all
`ClusterIP`, never exposed directly outside the cluster. `backend-service`'s name is load-bearing:
both nginx ConfigMaps hardcode it as their proxy target, so it can't be renamed without also
updating both ConfigMaps.

**Secrets** — `mongo-root-secret` and `backend-secret` (holding `MONGODB_URI`) are created
imperatively with `kubectl create secret generic ...`, not committed as YAML — there's nothing
in this repository with a real password in it. `.gitignore` covers the local files that could
otherwise leak one (see §22).

**ConfigMaps** — `kubernetes/frontend/nginx-configmap.yaml` and `kubernetes/admin/nginx-configmap.yaml`
override the nginx config baked into each image at `/etc/nginx/conf.d/default.conf`, via a `subPath`
volume mount in the Deployment spec. This is what makes path-based routing work at all: each config
internally rewrites (`rewrite ... break`) `/akash/...` (or `/akash-admin/...`) down to the
unprefixed path before nginx looks the file up on disk, and separately proxies `/akash/api/...` to
`backend-service:5000/api/...`. Without this, the `PUBLIC_URL` baked into the React build and what
nginx actually serves at its own root would disagree, and every JS/CSS asset would 404.

**Ingress / ALB** — `kubernetes/frontend/ingress.yaml` (path `/akash`) and
`kubernetes/admin/ingress.yaml` (path `/akash-admin`) both carry
`alb.ingress.kubernetes.io/group.name: shopnow`, which tells the AWS Load Balancer Controller to
provision **one shared ALB** for both, routing by path, instead of one ALB per Ingress object.

**MongoDB** — `kubernetes/mongo/statefulset.yaml`, `mongo:7.0`, 1 replica, a `gp3` PVC via
`volumeClaimTemplates` (dynamically provisioned by the EBS CSI driver), and a headless Service
(`kubernetes/mongo/service.yaml`) giving it the stable DNS name
`mongo-0.mongo.akash-shopnow.svc.cluster.local`.

**PodDisruptionBudgets** — one per app (`kubernetes/{backend,frontend,admin}/pdb.yaml`),
`minAvailable: 1`. With 2 replicas, a voluntary disruption (node drain, cluster upgrade) can only
take one pod down at a time per app, never both.

**Deployment order and rollout verification** — Mongo first (`kubectl apply` on the StatefulSet +
headless Service, wait for `rollout status`), then the scoped `shopuser` MongoDB user is created
once by hand via `kubectl exec ... mongosh`, then backend/frontend/admin. The ongoing Jenkins
pipeline (§11, stages 8–9) only ever re-applies the three `deployment.yaml` files and waits on
`kubectl rollout status` plus an explicit `Available`-condition and pod-readiness check — Service,
Ingress, ConfigMap, HPA, and PDB objects are applied once during initial setup, not on every build.

## 14. HPA / Autoscaling

**Configuration** (`kubernetes/{backend,frontend,admin}/hpa.yaml`) — identical shape on all three
Deployments:
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
spec:
  minReplicas: 2
  maxReplicas: 4
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: 70 }
```
CPU-based scaling, 2–4 replicas, 70% average utilization target, on backend, frontend, and admin
alike. This depends on `metrics-server` being installed in the cluster (it isn't part of a default
EKS cluster and has to be added separately) — without it, the HPA controller has nothing to read
CPU utilization from and simply can't act.

**How it was tested:** load was generated against the backend and admin services using temporary
`busybox`-based pods (`kubectl run` one-off pods issuing repeated requests), not a committed load
script — this was an ad-hoc validation step, and the load-generator pods were deleted afterward,
so there's nothing under `kubernetes/` representing them. Under that load, the **backend** scaled
from 2 to 4 replicas; the Grafana dashboard (§16) showed both the CPU increase and the replica
count climbing in step, and `kubectl get hpa -n akash-shopnow` reflected the same thing from the
API server's side. Admin and frontend were exercised during the same testing pass but scaling to 4
on either of them specifically was not observed — the HPA *configuration* is
identical across all three, but the *observed* scale-up during testing was the backend's. Once load
stopped, replica count and CPU came back down toward the 2-replica floor as the HPA's normal
scale-down behavior took over.

## 15. Prometheus Monitoring

Installed via the `prometheus-community/kube-prometheus-stack` Helm chart, version `88.5.2` (Helm
release name `monitoring`, confirmed by the `release: monitoring` label on the custom alert rules
below — that label has to match the actual release name or Prometheus never picks the rules up at
all):
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version 88.5.2 \
  -n monitoring
```
This one chart brings Prometheus itself, Alertmanager, Grafana, `kube-state-metrics`, and
node-exporter together, pre-wired — which is the whole reason to use it here rather than installing
each component separately.

**Custom alerting: `monitoring/shopnow-alerts.yaml`** — a `PrometheusRule` with 8 rules, all scoped
to `namespace="akash-shopnow"` (except the two node-level rules, which are cluster-wide by nature):

| Alert | Fires when | Severity |
|---|---|---|
| `ShopNowPodCrashLooping` | A pod restarted more than 3 times in 15 minutes | warning |
| `ShopNowDeploymentReplicasMismatch` | Desired ≠ available replicas for 5+ minutes (longer than a normal rolling update takes) | warning |
| `ShopNowDeploymentDown` | A Deployment has 0 available replicas for 2+ minutes | critical |
| `ShopNowHighMemoryUsage` | A pod is using over 90% of its memory limit for 5+ minutes | warning |
| `ShopNowHPAAtMaxReplicas` | An HPA has sat at its max replica count for 15+ minutes | warning |
| `ShopNowNodeNotReady` | A node hasn't reported `Ready` for 5+ minutes | critical |
| `ShopNowNodeHighCPU` | A node has averaged over 85% CPU for 10+ minutes | warning |
| `ShopNowNodeHighMemory` | A node has used over 85% of memory for 10+ minutes | warning |

`kube-state-metrics` (bundled with the chart) is what makes the Kubernetes-object-level metrics
(`kube_deployment_status_replicas_available`, `kube_horizontalpodautoscaler_status_current_replicas`,
`kube_node_status_condition`, etc.) available to Prometheus at all; node-exporter is the source for
the raw `node_cpu_seconds_total`/`node_memory_*` metrics the two node-level alerts use.

## 16. Grafana

Grafana ships as part of the same `kube-prometheus-stack` release and is pre-wired to the cluster's
Prometheus as its data source — no separate data-source configuration step. It was never exposed
publicly; access was strictly via port-forward (optionally tunneled over SSH to the Jenkins box, if
run from there rather than a workstation with direct cluster access):
```bash
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
# -> http://localhost:3000
```
A custom "ShopNow" dashboard was built (not committed as a JSON file or ConfigMap in this
repository — it exists only in Grafana's own storage) covering backend CPU and memory usage,
application pod count, available replicas per Deployment, HPA current and desired replica counts,
and node CPU. That dashboard is what was actually watched during the HPA load test in §14 — replica
count and CPU both visibly climbing together as load increased, and dropping back once it stopped.

## 17. Alerting / Alertmanager

Two separate mechanisms make up alerting, and it's worth being precise about which does what:

- **`PrometheusRule`** (`monitoring/shopnow-alerts.yaml`, §15) defines *when* an alert should fire
  — the 8 rules and their thresholds.
- **Alertmanager** defines *what happens* once an alert fires — routing, grouping, and in this
  case, email delivery.

```
kube-prometheus-stack (Helm)
   |-- Prometheus
   |-- Alertmanager
   |-- Grafana
   |-- kube-state-metrics
   `-- node-exporter

PrometheusRule --> Prometheus --> Alertmanager --> Secret: alertmanager-shopnow-email --> Gmail SMTP --> Email
```

Alertmanager was installed as part of the `kube-prometheus-stack` Helm release, not as a separate
chart. Email routing was configured at runtime through a Kubernetes Secret named
`alertmanager-shopnow-email` in the `monitoring` namespace, containing an `alertmanager.yaml`
document with the SMTP receiver configuration (Gmail). The Helm-managed Alertmanager was pointed at
that Secret via:
```
alertmanager.alertmanagerSpec.useExistingSecret=true
alertmanager.alertmanagerSpec.configSecret=alertmanager-shopnow-email
```
The secret was intentionally not committed to the repository, since it contains credentials —
that's the same pattern this project already uses for the Grafana admin password and the Mongo
credentials, applied here to SMTP settings. It doesn't show up as a file in `monitoring/` for the
same reason those don't.

Alertmanager routed a fired alert to the configured email receiver, and the notification was
received successfully during validation, confirming the path end to end: `PrometheusRule` →
Prometheus → Alertmanager → Secret → SMTP → inbox.

## 18. Jenkins Notifications

The one notification path that **is** directly in the Jenkinsfile: the `post { failure { ... } }`
block sends a failure email via the `emailext` step, addressed to the project maintainer. It fires
whenever any stage fails, and its content is the standard `emailext` default (build result, job
name/number, and a link to the console output) — enough to go straight to the failing stage's log
without digging through Jenkins' UI first. This was exercised directly (a deliberately-broken build
triggered it) rather than left configured-but-untested.

There is no Slack integration anywhere in this repository.

## 19. End-to-End Validation

The full loop, in the order it actually happens:

1. **Push** — a commit is pushed to `main` on `akashagarwal99-oss/shopNow`.
2. **GitHub webhook** — configured against the Jenkins EC2's public IP on port `8080`; a push
   delivers a webhook payload that triggers the `shopnow-pipeline` job. (This required opening the
   Jenkins UI port to `0.0.0.0/0` rather than just the workstation's `/32` — see §22 for the
   trade-off, and §21 for the specific connectivity problem that forced it.)
3. **Checkout** — Jenkins pulls the commit; `IMAGE_TAG` is set to its short SHA.
4. **Build & Test** — real test scripts run where they exist (§12); backend has none, reported
   as such.
5. **Docker Build** — three images built, tagged with the SHA.
6. **Trivy scan** — all three images scanned for HIGH/CRITICAL vulnerabilities (§22 covers the
   current default for what happens if any are found).
7. **ECR push** — all three tags pushed to the pre-existing `akash-shopnow/*` repositories.
8. **Deploy to EKS** — (main branch only) the three Deployments are updated with the new tag via
   `kubectl apply`.
9. **Rollout & health verification** — `kubectl rollout status`, `Available` condition, and pod
   readiness all confirmed for backend, frontend, and admin.
10. **Smoke testing** — frontend, admin, backend health, and backend products API all checked
    through the live ALB (§12); the build only reports success once all four return HTTP 200.
11. **Monitoring** — Prometheus's own pod status is checked as part of the same stage; the
    dashboards and alert rules described in §15–§17 reflect the resulting deployment continuously,
    not just at build time.
12. **HPA load test** — a separate, manual validation pass (§14): synthetic load via temporary
    `busybox` pods, backend observed scaling 2→4, Grafana showing the CPU/replica correlation,
    load removed, replicas settling back down.
13. **Rollback** — a separate, manual validation pass (§20).

Every build that reached stage 10 in this project's history passed all four smoke tests before
being considered successful.

## 20. Rollback Demonstration

This was carried out as a live validation step against the running deployment, not a theoretical
command listing. Kubernetes Deployments keep a revision history by default, and that history is
what rollback uses — no custom tooling, just `kubectl rollout`:

```bash
kubectl rollout history deployment/backend -n akash-shopnow
kubectl rollout history deployment/backend -n akash-shopnow --revision=13
```

A rollback was performed against the backend Deployment as a deliberate validation step: revision
13 was inspected, then rolled back to:
```bash
kubectl rollout undo deployment/backend -n akash-shopnow --to-revision=13
kubectl rollout status deployment/backend -n akash-shopnow
```
The rollout completed and backend pods came back healthy, with `/api/health` (through the ALB)
returning:
```json
{"status":"OK","message":"ShopNow API is running"}
```
The Deployment was then restored forward to revision 14 the same way:
```bash
kubectl rollout undo deployment/backend -n akash-shopnow --to-revision=14
kubectl rollout status deployment/backend -n akash-shopnow
```
which also completed cleanly, with backend pods healthy again afterward. This confirms the rollback
path works in both directions — backward to a known-good prior revision, and forward again — using
nothing beyond what Kubernetes already tracks for every Deployment.

## 21. Troubleshooting

Real issues hit during this project, several of which map directly to
specific commits in this repository's history.

### Jenkins webhook not triggering
- Check the webhook URL in GitHub under **Settings → Webhooks** — it needs to be
  `http://<jenkins-ip>:8080/github-webhook/`, trailing slash included.
- If the Jenkins EC2 was stopped and restarted (not just the instance staying up), its public IP
  changes unless it has an Elastic IP — the webhook URL then silently points at a dead address.
  Check GitHub's **Recent Deliveries** tab on the webhook for the actual response code/error.
- This project's Jenkins UI port (`8080`) is open to `0.0.0.0/0`, specifically so GitHub's webhook
  servers (which don't publish one small stable IP range) can reach it — if you've locked this down
  to your own `/32`, the webhook will fail with a timeout, not an authentication error. See §22 for
  the trade-off this represents.

### Terraform plan wants to change things that shouldn't have changed
This was a real, repeated problem early on: EKS add-on versions (`vpc-cni`, `coredns`, etc.) and
node-group AMI release versions have AWS-side defaults that move forward over time. Leaving them
unpinned meant `terraform plan` — run fresh by Jenkins on every Infrastructure Provisioning stage —
could show a diff even when nothing in the actual `.tf` files had changed, because "the latest
default" had quietly moved between runs. The fix is `terraform/bootstrap-versions.sh`: it resolves
the *current* recommended versions once, up front, and pins them into `deployment.auto.tfvars`
(gitignored) for that run, rather than leaving Terraform to re-resolve "latest" every time. If you
see unexpected addon/AMI diffs, confirm this script actually ran before `terraform plan` and that
`deployment.auto.tfvars` exists and is populated.
```bash
cd terraform
terraform init -reconfigure
terraform state list        # confirm you're actually pointed at the real backend
./bootstrap-versions.sh     # regenerate deployment.auto.tfvars if it's missing/stale
terraform plan              # review before ever applying — don't apply blind
```

### `terraform apply` wants to replace the Jenkins instance
The Jenkins EC2's AMI was originally resolved dynamically (`most_recent = true` against Canonical's
Ubuntu AMIs) — which meant a newer Ubuntu point-release publishing between Terraform runs would
make Terraform want to *replace* the very instance Jenkins was running on, mid-pipeline, if that
apply happened to run from Jenkins itself. `terraform/variables.tf`'s `jenkins_ami_id` now pins an
exact AMI ID instead, and `aws_instance.jenkins` carries `lifecycle { prevent_destroy = true }` as
a second layer of protection. If you ever need to actually replace or destroy this instance on
purpose, that lifecycle block has to be removed first — Terraform will otherwise refuse outright.

### Jenkins restarts / a build gets killed mid-pipeline
If the Configuration Management stage's Ansible run is allowed to restart the Jenkins service, it
kills its own in-flight build. `ansible/playbook.yml`'s `restart_jenkins` and
`initial_jenkins_setup` variables default to `false` for exactly this reason (§10) — if a
pipeline-triggered run somehow restarts Jenkins, check that nothing in the invocation is passing
`-e restart_jenkins=true`.

### Grafana/Prometheus unavailable
```bash
kubectl get pods -n monitoring
kubectl get svc -n monitoring
```
If pods are `Running` but the port-forward connection drops or hangs, it's almost always the
port-forward itself, not the cluster — kill and restart it (`Ctrl+C`, re-run the `kubectl
port-forward` command from §16). If running from a workstation rather than the Jenkins box
directly, an SSH tunnel to the Jenkins EC2 first, then `kubectl port-forward` from there, avoids
needing direct network access to the cluster's API from your own machine. Check Prometheus's own
**Status → Targets** page for scrape health if metrics look stale rather than absent.

### Ingress 404 / 504
```bash
kubectl get ingress -n akash-shopnow
kubectl describe ingress frontend-ingress -n akash-shopnow
kubectl get endpoints -n akash-shopnow
```
A 404 on `/akash/...` or `/akash-admin/...` almost always means the request reached nginx but
didn't match the expected rewrite rule — check that the ConfigMap in
`kubernetes/{frontend,admin}/nginx-configmap.yaml` is actually mounted (`kubectl describe pod` and
look for the volume mount at `/etc/nginx/conf.d/default.conf`), not just applied. A 504 more often
points at the target group behind the ALB — confirm the Service has ready endpoints
(`kubectl get endpoints`) before suspecting the ALB itself.

### HPA not scaling
```bash
kubectl get hpa -n akash-shopnow
kubectl top pods -n akash-shopnow
kubectl get deployment metrics-server -n kube-system
```
If `kubectl top` returns nothing, `metrics-server` isn't installed or isn't ready — the HPA
controller has no CPU data to act on regardless of how the HPA object itself is configured. If
`kubectl top` works but the HPA's `TARGETS` column shows `<unknown>`, check that the Deployment's
containers actually have a CPU `request` set (§13) — utilization-based scaling is a percentage of
the request, and without one there's nothing to compute a percentage of.

### Terraform destroy blocked by dependencies
This happened during the actual teardown of this project's environment: the AWS Load Balancer
Controller creates real ALBs and their supporting security groups from *inside* the cluster, tied
to the VPC's subnets — but Terraform has no record of them, since it never created them. Destroying
the EKS cluster (and the controller along with it) before deleting the Kubernetes Ingress objects
left the ALB and its Kubernetes-created security groups orphaned in the VPC, with nothing left able
to clean them up automatically, and `terraform destroy` was unable to remove the VPC because of
those dependencies. The orphaned ALB and its security groups were identified and deleted manually
via the AWS Console/CLI, after which `terraform destroy` completed the VPC teardown successfully.
See §26 for the recommended order to avoid hitting this in the first place.

### Alert email not working
```bash
kubectl get secret alertmanager-shopnow-email -n monitoring
kubectl logs -n monitoring -l app.kubernetes.io/name=alertmanager
```
Most delivery failures come down to the SMTP credentials/host inside that Secret, or the
Alertmanager pod not having picked up the config — check `alertmanager.alertmanagerSpec.configSecret`
in the Helm values actually matches the Secret name above, and check the pod logs for an explicit
SMTP error before assuming routing/grouping rules are the problem.

## 22. Security Considerations

**IAM** — the Jenkins EC2 authenticates to AWS entirely through an IAM instance profile
(`terraform/jenkins-ec2.tf`); there are no long-lived AWS access keys anywhere in this repository,
in Jenkins' own credential store, or in any config file. The role attached to that instance profile
currently has `AdministratorAccess` — a deliberately broad grant for the Infrastructure
Provisioning stage runs Terraform, which needs to manage IAM/VPC/EKS/EC2 resources including,
awkwardly, its own execution role's permissions, and this is a single-student learning account. In
an organization, this would be scoped to exactly the services Terraform touches, or split so
infrastructure changes run under a more tightly-scoped identity than the one that builds and
deploys application code.

**Network access** — SSH (port 22) to the Jenkins EC2 is restricted to a single `/32` (the
workstation's IP, via the `my_ip_cidr` variable). The Jenkins UI (port `8080`) is **not** similarly
restricted — it's open to `0.0.0.0/0`, specifically so GitHub's webhook delivery can reach it
(§21). This widens Jenkins' exposure in exchange for webhook-triggered builds working at all. A
tighter alternative would be scoping port 8080 to GitHub's published webhook IP ranges instead of
the whole internet, or moving to a pull-based (Poll SCM) trigger instead of a push webhook.

**Kubernetes secrets** — the MongoDB root/app-user credentials and the `backend-secret` holding
`MONGODB_URI` are created with `kubectl create secret generic`, never committed as YAML with
plaintext values. The Alertmanager SMTP configuration follows the same pattern: a runtime Secret
(`alertmanager-shopnow-email`, §17), not a file in this repository. `.gitignore` covers
`terraform.tfvars`, all `*.tfstate*` files, `*.pem`/`*.key`, `.env*`, and the generated Ansible
inventory (which would contain a real IP address).

**Image scanning** — Trivy (§11, stage 6) scans every image for HIGH/CRITICAL vulnerabilities
before it's deployed. `ALLOW_VULNERABLE_IMAGES` currently defaults to
`true` in the Jenkinsfile, which means Trivy findings are reported but do **not** currently fail
the build unless that parameter is explicitly set to `false` at run time. That's the opposite of
the safer default (fail unless explicitly overridden) and is worth reconsidering — flipping the
default is a one-line change in the Jenkinsfile's `parameters {}` block.

**Trivy's own supply chain** — Trivy is installed from a pinned version (`0.74.0`), downloaded
directly from GitHub releases and verified against its official published SHA-256 checksums before
installation, rather than via `apt install trivy` against a floating "latest." This isn't caution
for its own sake: Trivy versions v0.69.4–v0.69.6 were a real, publicly disclosed supply-chain
compromise (credential-stealing malware) in March 2026. Every release from v0.69.3 onward is
GitHub-immutable — confirmed directly by the Trivy maintainers — so v0.74.0 is safe to use as-is,
with the checksum verification as defense in depth on top of that.

**Immutable tags** — no image is ever tagged or deployed as `latest` (§7); every tag is the Git SHA
that produced it, which is also what makes the rollback in §20 meaningful — "roll back" means
something specific and reproducible, not a guess.

## 23. Cost Optimization

| Decision | Effect |
|---|---|
| `c7i-flex.large` for both Jenkins and EKS nodes | Selected as a right-sized instance type (2 vCPU / 4 GiB) to balance performance and cost for this workload |
| Single NAT Gateway, not one per AZ | Roughly halves NAT Gateway hourly + data-processing cost |
| One shared ALB via an IngressGroup, not one per app | Avoids paying for a second ALB's hourly + LCU cost |
| ECR repositories externally managed | Terraform never risks creating a duplicate, unused set |
| EKS node group: desired 2, max 3 | Not over-provisioned for a course project's actual traffic |
| No CloudWatch-based monitoring | Prometheus/Grafana (self-hosted in-cluster) instead of CloudWatch Container Insights — no additional CloudWatch ingestion/storage cost |
| Application traffic kept inside the cluster where possible | Frontend/admin talk to the backend over the internal Service network, not through the external load balancer |

None of this makes the architecture free: the EKS control plane bills hourly regardless of node
instance type, and the NAT Gateway, the ALB, the Jenkins EC2 instance, and any EBS volumes all bill
by the hour whether or not anything is actively happening.

> The strongest cost-optimization action in this project was tearing down the environment after
> validation, so that EKS, EC2, the ALB, the NAT Gateway, EBS, and related resources would not
> continue incurring charges. After capturing the validation evidence in §19–§20, the environment
> was deliberately destroyed — it is not running today. §26 covers the teardown itself, including
> the `prevent_destroy` guard on the Jenkins instance (§21) that a future teardown needs to account
> for.

## 24. Final Evidence / Screenshots

No screenshots exist in this repository yet — there is no `docs/screenshots/` directory or any
image file anywhere in the tree. Every entry below is a placeholder: create `docs/screenshots/`
and add each file as it's captured, using the exact filename shown so the references below start
resolving automatically.

### CI/CD

> **Screenshot placeholder:** `docs/screenshots/01-github-webhook.png`
>
> GitHub webhook configuration. Proves push-triggered Jenkins integration (§19 step 2).

> **Screenshot placeholder:** `docs/screenshots/02-github-delivery-success.png`
>
> A successful webhook delivery in GitHub's **Recent Deliveries** view. Confirms the connectivity
> path GitHub → Jenkins actually works, not just that it's configured (§19, §21).

> **Screenshot placeholder:** `docs/screenshots/03-jenkins-success.png`
>
> A successful Jenkins pipeline run, all stages green. Supports §11.

> **Screenshot placeholder:** `docs/screenshots/04-jenkins-smoke-tests.png`
>
> Jenkins console output showing the 4 smoke tests (frontend, admin, backend health, backend
> products API) each returning HTTP 200. Supports §12.

> **Screenshot placeholder:** `docs/screenshots/05-ecr-images.png`
>
> The three ECR repositories with SHA-tagged images. Supports §7.

### Infrastructure

> **Screenshot placeholder:** `docs/screenshots/06-terraform-s3-state.png`
>
> The Terraform state object present in the S3 bucket. Supports §9.

> **Screenshot placeholder:** `docs/screenshots/07-terraform-plan-no-changes.png`
>
> `terraform plan` reporting `No changes. Your infrastructure matches the configuration.` Supports
> §9 and the drift-prevention work described in §21.

> **Screenshot placeholder:** `docs/screenshots/08-eks-nodes.png`
>
> `kubectl get nodes` showing the `c7i-flex.large` nodes in `Ready` state. Supports §8.

### Kubernetes

> **Screenshot placeholder:** `docs/screenshots/09-kubernetes-pods.png`
>
> `kubectl get pods -n akash-shopnow`, all pods `Running`. Supports §13.

> **Screenshot placeholder:** `docs/screenshots/10-kubernetes-services.png`
>
> `kubectl get svc -n akash-shopnow`. Supports §13.

> **Screenshot placeholder:** `docs/screenshots/11-kubernetes-ingress.png`
>
> `kubectl get ingress -n akash-shopnow`, showing the shared ALB address on both Ingress objects.
> Supports §13.

> **Screenshot placeholder:** `docs/screenshots/12-hpa.png`
>
> `kubectl get hpa -n akash-shopnow`, target vs. current CPU and replica counts. Supports §14.

### Monitoring

> **Screenshot placeholder:** `docs/screenshots/13-grafana-dashboard.png`
>
> The custom ShopNow Grafana dashboard. Supports §16.

> **Screenshot placeholder:** `docs/screenshots/14-hpa-scale-up.png`
>
> Grafana showing CPU and replica count both climbing during the HPA load test. Supports §14.

> **Screenshot placeholder:** `docs/screenshots/15-prometheus-alerts.png`
>
> The Prometheus **Alerts** page with all 8 rules loaded. Supports §15.

> **Screenshot placeholder:** `docs/screenshots/16-alertmanager.png`
>
> Alertmanager UI or configuration view, if useful alongside the email evidence below. Supports §17.

> **Screenshot placeholder:** `docs/screenshots/17-alertmanager-email.png`
>
> The Alertmanager email notification received in Gmail after a real alert fired. This is
> confirmed evidence for a feature that was actually built and tested — see §17 for the full
> configuration path (`PrometheusRule` → Prometheus → Alertmanager → `alertmanager-shopnow-email`
> → SMTP → inbox).

> **Screenshot placeholder:** `docs/screenshots/18-jenkins-failure-email.png`
>
> The Jenkins failure-notification email from a deliberately-broken build. Supports §18.

### Rollback

> **Screenshot placeholder:** `docs/screenshots/19-rollout-history.png`
>
> `kubectl rollout history deployment/backend -n akash-shopnow`, showing revisions 13 and 14.
> Supports §20.

> **Screenshot placeholder:** `docs/screenshots/20-rollback-success.png`
>
> The `kubectl rollout undo --to-revision=13` command and its rollout-status output. Supports §20.

> **Screenshot placeholder:** `docs/screenshots/21-rollback-health.png`
>
> Backend pods healthy after the rollback, with `/api/health` returning
> `{"status":"OK","message":"ShopNow API is running"}`. Supports §20.

> **Screenshot placeholder:** `docs/screenshots/22-restored-backend.png`
>
> Restoration back to revision 14 and its rollout-status output. Supports §20.

## 25. Reproduction / Setup Guide

From a clean checkout, in order:

```bash
# 1. Prerequisites: AWS CLI, Terraform >= 1.11, Ansible, kubectl, Helm, jq, git — configured with
#    credentials for AWS account 655383751644, region ap-south-1.
aws sts get-caller-identity

# 2. Clone
git clone https://github.com/akashagarwal99-oss/shopNow.git
cd shopNow

# 3. One-time S3 state bucket (§9) — Terraform can't create the bucket it stores state in
aws s3api create-bucket --bucket akash-shopnow-tfstate-655383751644 --region ap-south-1 \
  --create-bucket-configuration LocationConstraint=ap-south-1
aws s3api put-bucket-versioning --bucket akash-shopnow-tfstate-655383751644 \
  --versioning-configuration Status=Enabled

# 4. terraform.tfvars — copy the example and fill in your own IP + AMI
cd terraform
cp terraform.tfvars.example terraform.tfvars
sed -i "s#203.0.113.10/32#$(curl -s https://checkip.amazonaws.com)/32#" terraform.tfvars
# jenkins_ami_id is required — either reuse the pinned one already in tfvars.example or resolve a current one:
aws ec2 describe-images --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text

# 5. Resolve current EKS addon/AMI versions (§21) before planning
./bootstrap-versions.sh   # AWS_REGION=ap-south-1 CLUSTER_NAME=akash-shopnow-eks K8S_VERSION=1.34

# 6. Terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# 7. Ansible — first-time bootstrap (restart + initial password ARE wanted here, unlike ongoing pipeline runs)
cd ../ansible
echo "[jenkins]" > inventory.ini
echo "$(terraform -chdir=../terraform output -raw jenkins_public_ip) ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/akash-shopnow-key.pem" >> inventory.ini
ansible-playbook -i inventory.ini playbook.yml -e restart_jenkins=true -e initial_jenkins_setup=true

# 8. Point kubectl at the cluster
aws eks update-kubeconfig --region ap-south-1 --name akash-shopnow-eks
kubectl get nodes

# 9. AWS Load Balancer Controller (uses the existing Pod Identity association — §3)
./scripts/install-alb-controller.sh

# 10. Kubernetes: namespace, storage, database, then the app
cd ..
kubectl apply -f kubernetes/namespace.yaml
kubectl apply -f kubernetes/storageclass-gp3.yaml
kubectl apply -f kubernetes/mongo/service.yaml -f kubernetes/mongo/statefulset.yaml
kubectl rollout status statefulset/mongo -n akash-shopnow
# create mongo-root-secret and backend-secret here (kubectl create secret — see §13), then the scoped
# shopuser via mongosh, then apply backend/frontend/admin deployment+service+hpa+pdb, then the two
# ConfigMaps and the two Ingress objects.

# 11. Monitoring
kubectl create namespace monitoring
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# First install: brings up Prometheus, Grafana, kube-state-metrics, node-exporter, and Alertmanager
# with its default (no-op) configuration.
helm upgrade --install monitoring \
  prometheus-community/kube-prometheus-stack \
  --version 88.5.2 \
  -n monitoring

# Create the Alertmanager SMTP configuration separately, as a runtime Secret — this is not part of
# this repository, and the actual SMTP credentials must never be committed to Git (§17, §22).
kubectl create secret generic alertmanager-shopnow-email \
  -n monitoring \
  --from-file=alertmanager.yaml=/path/to/alertmanager.yaml

# Point the already-installed release at that Secret.
helm upgrade monitoring \
  prometheus-community/kube-prometheus-stack \
  --version 88.5.2 \
  -n monitoring \
  --reuse-values \
  --set alertmanager.alertmanagerSpec.useExistingSecret=true \
  --set alertmanager.alertmanagerSpec.configSecret=alertmanager-shopnow-email

kubectl apply -f monitoring/shopnow-alerts.yaml

# 12. Jenkins: browse to http://<jenkins-public-ip>:8080, complete setup, install the plugins
#     noted in CHANGELOG.md, create a Pipeline-script-from-SCM job pointed at jenkins/Jenkinsfile,
#     add a GitHub webhook to http://<jenkins-public-ip>:8080/github-webhook/.

# 13. First build: trigger manually (RUN_INFRA/RUN_CONFIG unchecked — infra/config are already
#     done), confirm all 10 stages pass, then push a small change to confirm the webhook triggers
#     a build on its own.
```

## 26. Teardown

**These are the commands for a future teardown — the environment described by them is not
currently running.** The actual teardown that produced the "currently destroyed" state this
document describes surfaced a real dependency problem (§21) that the order below is written to
avoid.

Recommended order:
1. Delete Kubernetes Ingress resources.
2. Allow the AWS Load Balancer Controller to clean up the ALB it created.
3. Remove the application namespace and its PVC-backed resources.
4. Uninstall cluster-level components (AWS Load Balancer Controller, monitoring stack).
5. Destroy the Terraform-managed infrastructure.
6. If Terraform reports a dependency error anyway, check for and manually remove any orphaned
   load balancer or security group left behind before retrying.

Kubernetes-created AWS resources (the shared ALB, and the EBS volume behind Mongo's PVC) aren't in
Terraform's state — the AWS Load Balancer Controller and the EBS CSI driver created them from
inside the cluster. Delete those first, or `terraform destroy` will hang or leave them orphaned:

```bash
# 1. Let the ALB controller clean up the load balancer it created
kubectl delete ingress --all -n akash-shopnow
kubectl get ingress -n akash-shopnow            # wait for "No resources found"

# 2. Delete the app namespace (also deletes Mongo's PVC -> triggers EBS volume deletion)
kubectl delete namespace akash-shopnow

# 3. Uninstall the cluster-level Helm releases
helm uninstall aws-load-balancer-controller -n kube-system
helm uninstall monitoring -n monitoring
kubectl delete namespace monitoring

# 4. The Jenkins instance is protected — terraform destroy will refuse until this is addressed.
#    Temporarily remove the `lifecycle { prevent_destroy = true }` block from
#    terraform/jenkins-ec2.tf (or comment it out) before proceeding.

# 5. Now it's safe to tear down the infrastructure
cd terraform
terraform destroy

# 6. If step 1 didn't fully catch it, check for and manually remove any orphaned load balancer /
#    security group left behind in the VPC before terraform destroy will succeed on the VPC itself:
aws elbv2 describe-load-balancers --region ap-south-1 --query 'LoadBalancers[].LoadBalancerArn'
```

**What's retained:** the S3 state bucket (`akash-shopnow-tfstate-655383751644`) and its contents
are kept, not deleted — it's the record of what was built, and re-provisioning later starts from
`terraform init -reconfigure` against it rather than from nothing. **ECR repositories** were never
Terraform-managed in the first place (§7) — Jenkins pushed SHA-tagged images to them throughout the
project, and the repository evidence (§24) was captured before teardown. Terraform destroying the
rest of the infrastructure has no effect on them either way, since it never had authority over
their lifecycle to begin with.

## 27. Lessons Learned

**Immutable tags aren't a nice-to-have.** Rollback in §20 only means something specific because
every deployed image is traceable to an exact commit. A `latest` tag would have made "roll back to
revision 13" meaningless — there'd be no way to know what was actually running at any prior point.

**Infrastructure that manages the thing it's running on will eventually bite you.** This project
predicted that risk in the abstract (the Jenkins EC2 running the Terraform that can modify itself)
and then hit a concrete version of it: a floating "most recent" Ubuntu AMI meant `terraform apply`
could want to replace the Jenkins box mid-pipeline. Pinning the AMI and adding `prevent_destroy`
turned a theoretical hazard into a handled one — but only after hitting it.

**"Latest" isn't just a tagging problem — it's a Terraform problem too.** The same instinct that
says "don't deploy `latest`" applies to EKS add-on versions and node AMIs: leaving them to resolve
to "whatever's current" meant every `terraform plan` was a small gamble on whether AWS had changed
a default since the last run. `bootstrap-versions.sh` exists because "pin it explicitly, resolve
the pin once, review the pin like any other change" turned out to matter for infrastructure the
same way it does for application images.

**A pipeline that can restart its own execution environment needs to know that about itself.**
Ansible restarting Jenkins mid-build is obvious in hindsight and easy to miss in advance — it only
became visible by actually running the Configuration Management stage from inside a real pipeline,
not by reasoning about the playbook in isolation.

**CI/CD validation is only as honest as its weakest stage.** Reporting "Build & Test: passed" when
`backend/package.json` has no test script would have been technically true and substantively
misleading. Saying so directly, and leaning on black-box smoke tests against the real deployed
application instead, is a narrower claim — but it's one this project can actually back up.

**Observability earns its keep at exactly the moment things go wrong, which is also the worst
moment to be setting it up.** Having Grafana and the alert rules in place *before* the HPA load
test meant the scale-up was something to watch happen, not something to reconstruct afterward from
logs.

**Path-based routing and static-asset builds don't mix for free.** `PUBLIC_URL` baked into a React
build and an ALB that doesn't rewrite paths will disagree unless something in between reconciles
them — either avoid the subpath entirely, or make nginx aware of it explicitly (the ConfigMap
`rewrite` approach here). Both are legitimate; picking one implicitly (or not picking at all) is
what actually breaks.

**Cost control is a habit, not a setting.** None of the per-resource optimizations in §23 matter as
much as the discipline of tearing the environment down once evidence is captured — a course
project's AWS bill is driven far more by "left running over a weekend" than by instance-type
choice.

## 28. Limitations / Future Improvements

Known limitations:

- **No backend unit or integration test coverage.** `backend/package.json` has no `test` script.
  The project's validation strategy is deployment-level smoke testing (§12), which confirms the
  deployed system works but doesn't exercise business logic in isolation the way unit tests would.
- **No HTTPS/TLS.** The ALB serves plain HTTP. Adding TLS would mean an ACM certificate and an
  HTTPS listener on the Ingress (or the ALB directly) — not currently implemented.
- **Secrets are Kubernetes Secrets, not a managed secrets service.** Real, but base64-encoded at
  rest rather than in AWS Secrets Manager or similar — adequate for a course project, a gap for
  anything handling real user data.
- **No blue/green or canary deployment.** `kubectl apply` on the Deployment is a standard rolling
  update; a bad deploy is caught by health checks and smoke tests *after* it's already rolling out,
  not prevented from receiving any traffic in the first place.
- **No centralized log aggregation.** `kubectl logs` per-pod is the only log access; nothing ships
  logs to CloudWatch, Loki, or similar.
- **IAM is broader than least-privilege.** The Jenkins role's `AdministratorAccess` is a deliberate,
  named trade-off (§22) for a single-account learning project, not a production-appropriate default.
- **The EKS node group scales by node *count* limits only** (min 1 / max 3) — there's no Cluster
  Autoscaler or Karpenter managing node-level capacity based on pending-pod pressure; HPA (§14)
  scales pods, not nodes.
- **MongoDB is a single, self-managed replica**, not a replica set and not a managed database
  service (e.g., DocumentDB or Atlas) — no built-in database-level HA or automated backups.
- **Single environment.** The Terraform state key (`shopnow/dev/terraform.tfstate`) anticipates a
  second environment sharing the same bucket, but no staging/prod separation actually exists yet.
- **Trivy's `ALLOW_VULNERABLE_IMAGES` currently defaults to `true`** (§22) — findings are reported,
  not enforced, unless explicitly overridden per build. Worth flipping.
- **Alertmanager's SMTP configuration lives only in a runtime Secret, not in this repository**
  (§17) — reproducing the exact email-alerting setup on a fresh cluster means recreating that
  Secret by hand; it isn't a `terraform apply`/`kubectl apply` step you can just run from a file.

## 29. Final Project Status

| Area | Status |
|---|---|
| GitHub → Jenkins webhook | ✅ Complete |
| Dockerization | ✅ Complete |
| ECR image publishing | ✅ Verified |
| Trivy scanning | ✅ Verified |
| Terraform infrastructure | ✅ Complete |
| Terraform S3 remote state | ✅ Verified |
| Ansible configuration management | ✅ Verified |
| EKS | ✅ Verified |
| Kubernetes deployment | ✅ Verified |
| Services / Ingress | ✅ Verified |
| Health checks | ✅ Verified |
| HPA | ✅ Verified — backend 2 → 4 replicas |
| Smoke testing | ✅ Verified |
| Prometheus | ✅ Verified |
| Grafana | ✅ Verified |
| Custom ShopNow dashboard | ✅ Verified |
| Prometheus alert rules | ✅ Verified |
| Alertmanager | ✅ Verified |
| Alertmanager email | ✅ Successfully tested |
| Jenkins failure email | ✅ Successfully tested |
| Kubernetes rollback | ✅ Successfully tested |
| Cost optimization | ✅ Complete |
| Environment teardown | ✅ Complete |
| Documentation | ✅ Complete |
