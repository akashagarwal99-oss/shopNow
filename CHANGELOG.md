# Changelog and design rationale

This bundle has been through two passes: personalizing it for one AWS account, then aligning it
with the full Project 4 brief (11 pipeline stages, real test detection, Trivy scanning, PDBs,
expanded monitoring, externally-managed ECR). This file documents the current state — where the
guide and this bundle disagree, trust this file.

## Final values

| Setting | Value |
|---|---|
| Jenkins EC2 instance type | `c7i-flex.large` |
| EKS node instance type | `c7i-flex.large` |
| AWS region | `ap-south-1` |
| AWS account ID | `655383751644` |
| Project name | `akash-shopnow` |
| Kubernetes namespace | `akash-shopnow` |
| EKS cluster name | `akash-shopnow-eks` |
| ECR repositories (pre-existing, looked up not created) | `akash-shopnow/backend`, `/frontend`, `/admin` |
| Terraform state | bucket `akash-shopnow-tfstate-655383751644`, key `shopnow/dev/terraform.tfstate` |
| Node group | desired 2 / min 1 / max 3 |

## What changed this round, by file

**terraform/backend.tf** — bucket renamed `akash-shopnow-tfstate` → `akash-shopnow-tfstate-655383751644`
(account ID suffix guarantees global uniqueness without guessing); state key changed to
`shopnow/dev/terraform.tfstate` (the `/dev/` segment leaves room for a second environment to share
the bucket later without colliding); bootstrap commands in the header comment updated to match.

**terraform/ecr.tf** — rewritten from `resource "aws_ecr_repository"` + `aws_ecr_lifecycle_policy`
to `data "aws_ecr_repository"` lookups only. The three repos already exist in this account;
Terraform now only *reads* them (for the `repository_url` output) and will error at `plan` time if
any of the three don't exist, rather than trying to create or manage their lifecycle.

**terraform/outputs.tf** — `ecr_repository_urls` output updated to read from
`data.aws_ecr_repository.this` instead of the now-removed resource.

**ansible/playbook.yml** — four tools added to what it installs: **Terraform** (HashiCorp's apt
repo, deliberately pinned to the `noble` (24.04) suite rather than the host's actual `resolute`
(26.04) codename — HashiCorp doesn't have a `resolute` suite yet, and `noble` packages are
confirmed compatible; using the auto-detected codename here would 404), **Git** and **jq** (plain
apt packages), and **Trivy** — see the security note below, this one wasn't a plain `apt install`.

**jenkins/Jenkinsfile** — substantially expanded, from 6 stages to 10 (plus `post{}`
reporting/cleanup, which is the pipeline's 11th required capability — see the stage-count note
below). Detail in the dedicated section further down.

**kubernetes/{backend,frontend,admin}/pdb.yaml** — three new files, one each. `minAvailable: 1`
with 2 replicas: a voluntary disruption (node drain, cluster upgrade) can only take down one pod
at a time per app, never both at once.

**monitoring/shopnow-alerts.yaml** — grew from 3 alert rules to 8: pod crash-looping (unchanged),
a generalized desired-vs-available replica mismatch across all three Deployments (previously only
backend had a "down" alert — now all three do, plus a softer "mismatch" alert that catches a
struggling-but-not-fully-down deployment), high memory (unchanged), HPA sitting at max replicas
for 15+ minutes, node NotReady, node high CPU, node high memory.

**.gitignore** — new file. Covers `terraform.tfvars`, `*.tfstate*`, `*.pem`, `*.key`, `.env*`, the
Ansible inventory (which contains a real IP once you generate it), and similar.

**README.md, CHANGELOG.md** — rewritten to reflect all of the above.

## The Jenkinsfile, in detail

**Stages** (10, plus `post{}`):
`Checkout` → `Build & Test` → `Infrastructure Provisioning`\* → `Configuration Management`\* →
`Docker Build` → `Security Scan (Trivy)` → `ECR Push` → `Deploy to EKS`† → `Rollout & Health
Verification`† → `Testing and Monitoring`† → `post{ success / failure / always }`

\* parameterized, default off (`RUN_INFRA` / `RUN_CONFIG`) — see "why gated" below.
† gated to `DEPLOY_BRANCH` (`main`) only — see "why branch-gated" below.

The brief's 11th item, "post-build reporting/cleanup," is implemented as the declarative
pipeline's `post {}` block rather than an 11th `stage()`. That's the idiomatic place for it in
Jenkins — stages are sequential build steps; post-actions are conditional finalization logic
(different behavior on success vs. failure, and cleanup that must run either way) that Jenkins
itself treats as a distinct pipeline section, not a stage.

**Image tagging** — `IMAGE_TAG` is computed in the Checkout stage from `git rev-parse --short
HEAD`, after the checkout (not in the top-level `environment{}` block, which evaluates *before*
Checkout and wouldn't have a repo to run `git` against yet). The `IMAGE_TAG` string parameter can
override this for a deliberate redeploy of a known tag; the default is always the Git SHA — never
`latest`.

**Build & Test — real detection, not a fabricated pass.** `backend/package.json` was inspected
directly from the actual repository: its `scripts` block has only `start` and `dev`, no `test` at
all. The stage checks for a `test` script with `jq -e '.scripts.test' package.json` per app before
attempting anything, and says so in the log rather than silently skipping or faking a result.
`frontend/package.json` and `admin/package.json` both define `"test": "react-scripts test"` (Jest
via Create React App) — that command *does* run for real, inside an ephemeral `node:18-alpine`
container (matching the Node version their own Dockerfiles use) with `CI=true` and
`--watchAll=false` so it doesn't hang in interactive watch mode. There are currently zero
`*.test.js` files anywhere in the repository, so `--passWithNoTests` keeps "nothing written yet"
(not a failure) distinct from "something written and broken" (a real failure). Add test files
later and this same stage starts running them for real, no pipeline changes needed.

**Security Scan (Trivy)** runs after Docker Build and before ECR Push — deliberately, and this is
worth flagging as a judgment call rather than hiding it: the brief's own numbered stage list orders
Docker Build → ECR Push → Security Scan, but its prose requirement just says "after build and
before deployment." Scanning before push means a vulnerable image never sits in the shared
registry even briefly; scanning after push (the literal list order) would let that happen for the
few seconds between push and scan. If you specifically want the literal list order instead, that's
a one-block move in the Jenkinsfile, not a redesign. `--severity HIGH,CRITICAL --exit-code 1` fails
the stage (and pipeline) on any HIGH/CRITICAL finding; `--ignore-unfixed` excludes CVEs with no
available fix (nothing actionable to do about those today). The documented exception mechanism is
the `ALLOW_VULNERABLE_IMAGES` boolean parameter (default `false`) — sets `--exit-code 0` instead,
so the scan still runs and still reports, it just doesn't fail the build. Nothing about it is
silent: the log says explicitly that the exception path is active.

**Why gated (RUN_INFRA / RUN_CONFIG default false):** Jenkins only exists because Terraform and
Ansible already ran once, by hand, to create it — a pipeline can't bootstrap the server it's
running on. What the parameters give you is the ability to *re-run* infra/config changes from
inside Jenkins later without re-running Terraform/Ansible on every ordinary code push. One more
thing worth knowing before ever setting `RUN_INFRA=true`: that stage's `terraform apply` manages
the very EC2 instance Jenkins is running on. A no-op apply (nothing changed) is safe; a change that
replaces the Jenkins instance itself (AMI, instance type), applied from a pipeline running on that
same instance, can pull the rug out from under the build mid-apply. This is a general hazard of
infrastructure managing the thing it runs on, not specific to this project.

**Why branch-gated:** `env.GIT_BRANCH` (set by the standard Git checkout step, typically as
`origin/main`) is checked rather than the declarative `branch` directive, because `branch` only
evaluates correctly inside a **Multibranch Pipeline** job — in the plain "Pipeline script from
SCM" job type this project uses, `branch` errors rather than just evaluating false. Feature
branches still run Checkout, Build & Test, Infra/Config (if requested), Docker Build, Trivy, and
ECR Push — full CI feedback on every push — they just stop before Deploy.

**Deployment mechanism** — `envsubst | kubectl apply -f -` against the full Deployment manifest,
not `kubectl set image`. Both are "safe" in the sense the brief asks for (neither recreates the
Deployment object), but `apply` also reconciles anything else that changed in the manifest
(resource limits, probes, env), where `set image` only ever touches the image field. `apply` is the
more complete mechanism, so that's what's used; `set image` is mentioned here as the alternative in
case you want the narrower behavior instead.

**Rollout & Health Verification** (separate stage from Deploy) — `kubectl rollout status` for all
three Deployments, then explicitly checks each Deployment's `Available` condition, then checks
every pod's readiness via `containerStatuses[0].ready`. Any failure here fails the stage with a
specific message about which Deployment or app failed, rather than a generic timeout.

**Testing and Monitoring** — retries on *two* things, not one: the ALB hostname appearing on the
Ingress (up to 3 minutes; a fresh ALB is not instant) and then the `/api/health` endpoint
responding 200 (up to 2 minutes) once the hostname exists. The health endpoint itself was verified
against the real `backend/server.js` (`app.get('/api/health', ...)` on `PORT` — default `5000`),
not assumed.

## Answers for the viva — why these choices

- **Managed EKS node group, not self-managed EC2** — AWS patches and replaces the worker AMI for
  you; the alternative is fighting EKS's own node lifecycle instead of using it. Ansible therefore
  configures the *Jenkins* box (a plain EC2 instance Terraform created), not the EKS nodes
  themselves — there's nothing for Ansible to configure on a managed node group.
- **IAM instance profile on the Jenkins EC2, not access keys** — every `aws`, `kubectl`, and `helm`
  command on that box picks up credentials automatically from instance metadata. No long-lived
  secret sits on disk or in Jenkins' credential store to leak.
- **S3 for Terraform state** — durable, versioned, shared if more than one person/machine ever
  needs to run `terraform apply`. `use_lockfile = true` (Terraform ≥ 1.11's native S3 locking)
  replaces the older DynamoDB-table pattern — one fewer always-on resource, same protection against
  concurrent applies corrupting state.
- **Immutable Git-SHA image tags, never `latest`** — a tag tells you exactly which commit is
  running; `latest` is a moving target that makes rollback a guess. Rollback becomes "redeploy the
  previous SHA," not "hope you remember what was there before."
- **HPA** on all three Deployments — the assignment specifically asks for autoscaling under load;
  CPU-based scaling from 2 to 4 replicas is the standard mechanism, and it needs `metrics-server`
  installed on the cluster to function (covered in the guide's cluster-bootstrap section).
- **Health checks** (`readinessProbe`/`livenessProbe`) — readiness controls whether a pod receives
  traffic at all during a rollout; liveness restarts a pod that's stuck. Without both, a rolling
  deploy can send traffic to a pod that isn't ready yet, and a hung pod never gets restarted.
- **AWS Load Balancer Controller / ALB, not ingress-nginx** — ingress-nginx was retired upstream in
  March 2026 (no further security patches). ALB is AWS's actively-maintained, native alternative,
  and it's what actually provisions the "load balancer" the brief's architecture diagram asks for.
- **Two separate ALBs (frontend, admin), not one shared ALB with path routing** — the frontend and
  admin apps are built with a `PUBLIC_URL` baked into their static assets at build time, and
  nothing in this stack rewrites paths at the ingress layer the way `ingress-nginx` used to (ALB
  Ingress has no equivalent annotation). Building both apps for root (`USER_NAME=""`) and giving
  each its own ALB sidesteps that mismatch entirely, rather than patching nginx `alias` rules
  inside the containers to fake path-stripping.

## Cost optimization — what's already built in, and what isn't free

| Decision | Where |
|---|---|
| `c7i-flex.large` instead of a larger instance | Free-Tier-eligible in this account, 2 vCPU/4 GiB is enough for this workload |
| Minimum practical node count (2, scalable 1–3) | Not over-provisioned for a course project's traffic |
| Single NAT Gateway, not one per AZ | Halves the NAT Gateway hourly + data-processing cost |
| ECR repos managed externally, not duplicated | No risk of Terraform creating a second, unused set |
| Ansible on the Jenkins EC2, not extra infrastructure | No additional compute just to run configuration management |
| No DynamoDB lock table | Native S3 locking does the same job for $0 extra |

**Not free, and not claimed to be:** the EKS control plane (~$0.10/hr regardless of node instance
type), the NAT Gateway, two Application Load Balancers, the Jenkins EC2 instance, and any EBS
volumes all bill by the hour whether or not you're actively using them — Free Tier eligibility on
the *instance type* doesn't make EKS, NAT, ALB, or EBS free. Destroying the environment after
you've captured your demo evidence (screenshots, `kubectl`/`terraform` output) and re-applying next
session is the single most effective cost control here — recreating the stack takes roughly
15–20 minutes.

## Security notes

- **Trivy is pinned to v0.74.0, installed from a checksum-verified direct download, not
  `apt install trivy` against the aquasecurity repo.** This isn't caution for its own sake:
  Trivy versions v0.69.4–v0.69.6 were a real supply-chain compromise (CVE-2026-33634, credential-
  stealing malware, publicly disclosed March 2026). Every release from v0.69.3 onward is
  GitHub-immutable (confirmed directly by the Trivy maintainers in their own incident discussion),
  so v0.74.0 is safe to use — the Ansible playbook downloads it plus its official
  `checksums.txt` and verifies the `.deb` against that checksum with `sha256sum -c` before
  installing anything, as defense in depth on top of the immutability guarantee.
- `.gitignore` excludes `terraform.tfvars`, all `*.tfstate*` files, `*.pem`/`*.key`, `.env*`, and
  the generated Ansible inventory (which contains a real IP address once you create it).
- No AWS access keys anywhere in this bundle — the Jenkins EC2's IAM instance profile is the only
  AWS credential path, on purpose (see "Answers for the viva" above).
- No passwords, tokens, or PEM contents were invented anywhere in this bundle. Every credential
  (Mongo root/app-user passwords, Grafana admin password, the Jenkins EC2 SSH key) is either
  generated at apply-time with `openssl rand`/AWS's own key-pair creation, or left as a clearly
  marked placeholder for you to fill in.

## Old → new (both rounds, consolidated)

| Old value | New value |
|---|---|
| `shopnow-eks` | `akash-shopnow-eks` |
| `t3.medium` (node group + Jenkins EC2) | `c7i-flex.large` |
| `shopnow-jenkins-key` | `akash-shopnow-jenkins-key` |
| `akash-shopnow-tfstate` / key `akash-shopnow/terraform.tfstate` | `akash-shopnow-tfstate-655383751644` / key `shopnow/dev/terraform.tfstate` |
| `namespace: shopnow` (×13 files) | `namespace: akash-shopnow` |
| `${ECR_REGISTRY}` placeholder in K8s manifests | `655383751644.dkr.ecr.ap-south-1.amazonaws.com` (hardcoded — fixed per-account value) |
| `resource "aws_ecr_repository"` (Terraform creates repos) | `data "aws_ecr_repository"` (Terraform only reads pre-existing repos) |
| `IMAGE_TAG` = Jenkins `BUILD_NUMBER` | `IMAGE_TAG` = short Git SHA |
| Jenkinsfile: dynamic `aws sts get-caller-identity` for account ID | literal `655383751644` |
| Jenkins pipeline: 6 stages, no Trivy, fabricated-if-anything test stage | 10 stages + post{}, real test detection, Trivy with a documented exception path |
| 3 monitoring alerts (backend-only "down" check) | 8 alerts (all 3 apps, + HPA, node readiness, node CPU/memory) |
| No PDBs | `minAvailable: 1` PDB per app |
| No `.gitignore` | `.gitignore` covering tfstate/tfvars/keys/secrets |

## Left unchanged, and why

- `student_username="akash"`, `aws_region="ap-south-1"`, `azs` — already exactly your values.
- The `${var.student_username}-shopnow-*` templates in `pod-identity.tf`/`jenkins-ec2.tf`/`vpc.tf`
  — not hardcoded strings, already-correct templates resolving to `akash-shopnow-*`.
- `backend-service`/`frontend-service`/`admin-service` — the frontend/admin nginx configs baked
  into the Docker images proxy to `backend-service` by literal hostname; renaming breaks that, and
  the fix is inside the app images, outside this bundle.
- App-level identifiers: `app:` labels, Deployment names, the MongoDB database name `shopnow`,
  Secret names, alert identifiers (`ShopNowPodCrashLooping` etc.) — these name the *application*,
  per your explicit instruction, not the infrastructure project.
- `cluster_version="1.34"` / Ansible's `kubectl_version: v1.34.0` — no Kubernetes version change
  was requested; kept in sync with each other.
- `terraform/policies/alb-iam-policy.json` — generic AWS-published IAM policy, nothing
  project-specific in it to change.
- Two separate ALBs for frontend/admin (not consolidated to one) — this was already the correct,
  deliberate design from the previous round (see "Answers for the viva" above), and your brief
  explicitly says to preserve it if it's required by the PUBLIC_URL/nginx design, which it is.

## Assumptions made

1. **Trivy version**: pinned to v0.74.0 (current at the time of writing) rather than the last
   pre-incident version (v0.69.3), because the Trivy maintainers have confirmed every release from
   v0.69.3 onward is immutable/safe, and a 5+-month-old scanner binary would miss real scanner-side
   improvements. If you'd rather pin to v0.69.3 specifically, that's a one-line change to
   `trivy_version` in `ansible/playbook.yml`.
2. **Trivy scan ordering**: placed before ECR Push rather than after (the brief's numbered stage
   list implies after) — reasoning is in "The Jenkinsfile, in detail" above.
3. **`jenkins_key_name` default**: changed to `akash-shopnow-jenkins-key` for naming consistency.
   No key pair with that name was created — you still need to create it (or point the variable at
   one you already have).
4. **No ConfigMap added**: the brief lists ConfigMaps among things that need consistent namespacing
   *if present*; there's no non-secret configuration in this app that would justify inventing one
   (the only backend config is `MONGODB_URI`, which is a Secret, correctly, not a ConfigMap).
5. **`ecr_services` local list unchanged** (`backend`, `frontend`, `admin`) — matches the three
   repository names you confirmed already exist.

## Still needs a human

1. **`my_ip_cidr`** in your own (uncommitted) `terraform.tfvars` — `curl -s https://checkip.amazonaws.com`.
2. **EC2 key pair `akash-shopnow-jenkins-key`**:
   ```bash
   aws ec2 create-key-pair --key-name akash-shopnow-jenkins-key --region ap-south-1 \
     --query 'KeyMaterial' --output text > ~/.ssh/akash-shopnow-jenkins-key.pem
   chmod 400 ~/.ssh/akash-shopnow-jenkins-key.pem
   ```
3. **S3 bucket `akash-shopnow-tfstate-655383751644`** — one-time bootstrap before `terraform init`;
   commands are in the comment at the top of `terraform/backend.tf`.
4. **Confirm the three ECR repos really exist** before the first `terraform plan`:
   ```bash
   aws ecr describe-repositories --region ap-south-1 \
     --repository-names akash-shopnow/backend akash-shopnow/frontend akash-shopnow/admin
   ```
   If any are missing, `data.aws_ecr_repository` will fail with a clear "repository not found"
   error at plan time — that's intentional, not a bug.
5. **Jenkins job's SCM config** (repo URL, credentials) — Jenkins UI, not a file in this bundle.
6. **Grafana/Mongo secrets** — created via `kubectl create secret` per the guide, not files here;
   use `-n akash-shopnow`.
7. **PDBs, Service, HPA, Ingress, StorageClass, Namespace** are applied once during initial setup,
   the same way they always were — the Jenkinsfile's Deploy stage only re-applies the three
   Deployment manifests on every run (that's the thing that actually changes between builds).

## Validation performed on this pass

No `terraform` binary or live cluster was available in the environment that made these edits.
Validation performed instead: every `.tf` file parsed with a real HCL2 parser (catches syntax
errors); every `var.*`, `module.*`, and resource/data attribute reference in the Terraform config
cross-checked against what's actually defined anywhere in `terraform/*.tf` (catches dangling
references, including after the `ecr.tf` resource→data rewrite); every `.yaml`/`.yml` file
(including the three new PDBs and the expanded monitoring rules) parsed with a YAML parser; the
Jenkinsfile's braces/parens/quotes counted for balance. All of it passed. This is not a substitute
for `terraform validate` against the real AWS provider schema, or a real Jenkins syntax check —
run the commands in the accompanying report before `terraform apply` or triggering a build.

## Update: AWS Load Balancer Controller bootstrap script

**New file: `scripts/install-alb-controller.sh`.** Everything else up to this point assumed the
ALB controller got installed by following the guide's prose instructions (`helm install
aws-load-balancer-controller ...`, §7.4) — there was no corresponding file in this bundle, even
though `terraform/pod-identity.tf` already provisioned the IAM role and Pod Identity association
for it from the very first pass. This closes that gap: a real, runnable script instead of a
command you have to go find in a separate document.

What it does, in order, and why:
1. `aws eks update-kubeconfig` — points kubectl at `akash-shopnow-eks`.
2. **Precondition check**: calls `aws eks list-pod-identity-associations` filtered to
   `kube-system` / `aws-load-balancer-controller` and fails fast with a clear message if nothing
   comes back — that would mean `terraform apply` (specifically `pod-identity.tf`) hasn't run yet,
   and installing the controller before that exists would just produce a controller that can
   never authenticate to AWS, a confusing failure to debug later.
3. Resolves the VPC ID from `terraform output -raw vpc_id` (falling back to a tag lookup if the
   Terraform directory isn't reachable from wherever the script is run).
4. `helm upgrade --install` — idempotent, safe to re-run. `serviceAccount.create=true` +
   `serviceAccount.name=aws-load-balancer-controller` and **no `serviceAccount.annotations`** is
   the entire credential wiring: no IAM role ARN annotation, no OIDC provider, nothing IRSA-shaped.
   The binding is external to Kubernetes entirely — it's the Pod Identity association from step 2,
   matched purely by namespace + service account name.
5. **Post-install verification**, three checks: (a) the ServiceAccount doesn't carry a stray
   `eks.amazonaws.com/role-arn` annotation (that would indicate an accidental IRSA-style
   configuration, inconsistent with how this project is wired), (b) the controller's pods are
   actually `Running`, (c) the `alb` IngressClass exists — it's normally created automatically by
   the Helm chart, but the script creates it explicitly as a fallback if that ever changes.

Nothing else changed. `terraform/pod-identity.tf` was inspected against this script's parameters
and confirmed already correct — namespace and service account name match exactly, so no Terraform
edit was needed.

**README.md** — one line added to the folder map and the "copy these folders" list for `scripts/`.
No other content changed.
