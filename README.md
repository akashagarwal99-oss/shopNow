# ShopNow Capstone Implementation Pack

## What this pack is

Copy this directory into the root of your fork of ShopNow. It does not replace the supplied application source or its existing Kubernetes manifests. It adds the files that the capstone expects: Terraform, Ansible, Jenkins CI/CD, availability YAML, monitoring and helper scripts.

The pack has already been configured with these values:

| Placeholder | Meaning | Example |
| --- | --- | --- |
| Your name | akash |
| Kubernetes namespace and project name | akash-shopnow |
| EKS cluster name | akash-shopnow-eks |
| AWS Region | ap-south-1 |
| AWS account ID | 655383751644 |
| YOUR.PUBLIC.IP.ADDRESS/32 | your current public IP CIDR | 203.0.113.5/32 |

## Expected final repository structure

    shopNow/
      admin/
      backend/
      frontend/
      kubernetes/                 supplied source manifests
      infra/                      copy from this pack
      ansible/                    copy from this pack
      monitoring/                 copy from this pack
      scripts/                    copy helper scripts from this pack
      Jenkinsfile                 copy from this pack
      .gitignore                  merge the supplied rules

## Phase 0: one-time AWS and local setup

1. Create or use an AWS account. For a learning lab, your IAM identity must be able to create EKS, VPC, EC2, IAM roles, ECR, S3 and CloudFormation stacks. Use an administrator role only for initial testing; write a least-privilege policy before production.
2. Install Git, Docker Desktop, AWS CLI v2, Terraform, kubectl, Helm and WSL Ubuntu. Install Ansible in WSL with:

       sudo apt update
       sudo apt install -y ansible

3. Configure AWS and verify identity:

       aws configure --profile capstone
       $env:AWS_PROFILE = 'capstone'
       aws sts get-caller-identity

4. Create an EC2 key pair in the selected Region. Save its PEM file in your WSL .ssh folder and set restrictive owner permissions:

       chmod 400 ~/.ssh/YOUR_KEY.pem

5. Find your public address:

       curl https://checkip.amazonaws.com

## Phase 1: fork, clone and customize ShopNow

1. Fork the provided repository in GitHub.
2. Clone the fork and create a working branch:

       git clone https://github.com/YOUR_GITHUB_USER/shopNow.git
       cd shopNow
       git checkout -b devops-capstone

3. Copy this pack contents into that cloned directory, preserving supplied folders.
4. Search all hard-coded examples:

       rg -n "aryan|shopnow-demo|shopnow/(frontend|backend|admin)" .

5. The source repository specifically requires:
   - Change ARG USER_NAME in frontend/Dockerfile and admin/Dockerfile.
   - Change ingress paths to slash akash and slash akash-admin.
   - Replace username paths in frontend/admin Nginx ConfigMaps.
   - Change raw manifest namespace fields.
   - Change all ECR image paths in Deployment YAML, Helm values, and Jenkins pipeline.
6. Never commit a real secret. Merge this pack's .gitignore rules before the first commit.

## Phase 2: local-only Docker test (do this now)

Do this phase entirely in WSL. Do not create EKS, Jenkins EC2, NAT Gateway, load balancer, monitoring, or S3 state yet.

    docker build -t akash-shopnow-backend:local backend
    docker build --build-arg USER_NAME=akash -t akash-shopnow-frontend:local frontend
    docker build --build-arg USER_NAME=akash -t akash-shopnow-admin:local admin
    docker image ls | grep akash-shopnow

You already created the ECR repositories, so leave them unchanged. Jenkins will authenticate to them and push the first Git-SHA-tagged images only after the Jenkins server and EKS exist.

## Phase 3: prepare infrastructure files locally (do this now)

Copy the pack files into your ShopNow clone and customise the supplied ShopNow ingress, namespace, Nginx and image references. Copy infra/terraform.tfvars.example to infra/terraform.tfvars and set your EC2 key-pair name and public IP. Do not commit terraform.tfvars.

Validate Terraform locally without creating an AWS resource:

    cd infra
    terraform init -backend=false
    terraform fmt -recursive
    terraform validate

The template pins EKS 1.35. Before applying, verify that it remains supported for ap-south-1. Do not run terraform apply at this stage.

## Phase 4: final cloud demo session (paid resources start here)

Do this only when the local Docker builds and Terraform validation pass and you have time to finish the demo. The state bucket name must be globally unique:

    export STATE_BUCKET='akash-shopnow-tf-state-655383751644'
    aws s3api create-bucket --bucket "$STATE_BUCKET" --region ap-south-1 --create-bucket-configuration LocationConstraint=ap-south-1
    aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" --versioning-configuration Status=Enabled
    aws s3api put-public-access-block --bucket "$STATE_BUCKET" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    cd infra
    terraform init -reconfigure -backend-config="bucket=$STATE_BUCKET" -backend-config="key=shopnow/dev/terraform.tfstate" -backend-config="region=ap-south-1" -backend-config="encrypt=true" -backend-config="use_lockfile=true"
    terraform plan -out=tfplan
    terraform apply tfplan
    terraform output cluster_name
    terraform output jenkins_public_ip

After Terraform completes, EKS, NAT Gateway, Jenkins EC2, worker nodes, and their charges are active. Finish the remaining phases in the same session where possible.

## Phase 5: configure Jenkins with Ansible

Copy ansible/inventory.ini.example to ansible/inventory.ini and substitute public IP and PEM path. Run:

    cd ansible
    ansible all -i inventory.ini -m ping
    ansible-playbook -i inventory.ini jenkins.yml

Then SSH to Jenkins and check the installed tools:

    ssh -i ~/.ssh/YOUR_KEY.pem ec2-user@JENKINS_PUBLIC_IP
    sudo systemctl status jenkins
    docker version
    terraform version
    kubectl version --client
    helm version

Install Trivy on Jenkins before creating the pipeline, using the current official Trivy package instructions for Amazon Linux. Confirm:

    trivy --version

The Jenkins EC2 IAM role uses ECR and EKS policies and is mapped to the EKS access entry by Terraform. That makes AWS credentials unnecessary in Jenkins for this capstone. For a production system replace broad managed policies and cluster-admin access with task-specific policies/RBAC.

Open http://JENKINS_PUBLIC_IP:8080. Retrieve the one-time password:

    sudo cat /var/lib/jenkins/secrets/initialAdminPassword

Install suggested plugins plus: Pipeline, Git, Docker Pipeline, Kubernetes CLI, AnsiColor, OWASP Dependency-Check and Slack Notification if you use Slack.

## Phase 6: EKS prerequisites and ShopNow deployment

From your repository root in WSL:

    chmod +x scripts/bootstrap-cluster.sh scripts/verify-deployment.sh
    ./scripts/bootstrap-cluster.sh

Create database credentials without committing them:

    kubectl -n akash-shopnow create secret generic mongodb-credentials --from-literal=MONGO_INITDB_ROOT_USERNAME=shopuser --from-literal=MONGO_INITDB_ROOT_PASSWORD=YOUR_STRONG_PASSWORD

If ECR pull access has not been given to node roles, make a temporary ECR pull secret:

    ECR_PASSWORD="$(aws ecr get-login-password --region ap-south-1)"
    kubectl -n akash-shopnow create secret docker-registry ecr-secret --docker-server=655383751644.dkr.ecr.ap-south-1.amazonaws.com --docker-username=AWS --docker-password="$ECR_PASSWORD"

Apply the supplied ShopNow raw manifests in dependency order:

    kubectl apply -f kubernetes/k8s-manifests/database/ -n akash-shopnow
    kubectl apply -f kubernetes/k8s-manifests/backend/ -n akash-shopnow
    kubectl apply -f kubernetes/k8s-manifests/frontend/ -n akash-shopnow
    kubectl apply -f kubernetes/k8s-manifests/admin/ -n akash-shopnow
    kubectl apply -f kubernetes/k8s-manifests/ingress/ -n akash-shopnow
    kubectl apply -f k8s/hpa-backend.yaml
    kubectl apply -f k8s/hpa-frontend.yaml
    kubectl apply -f k8s/pdb-backend.yaml

After mongo-0 is Running, create shopuser in mongosh with the same password used in mongodb-credentials. Then restart backend:

    kubectl -n akash-shopnow exec -it mongo-0 -- mongosh
    use admin
    db.createUser({user:'shopuser',pwd:'YOUR_STRONG_PASSWORD',roles:[{role:'readWrite',db:'shopnow'},{role:'dbAdmin',db:'shopnow'}]})
    exit
    kubectl -n akash-shopnow rollout restart deployment/backend
    ./scripts/verify-deployment.sh

The resource-probe example is deliberately not applied automatically: its backend port and health URL must first be confirmed from the ShopNow backend source. Merge it into each Deployment after validation.

## Phase 7: Jenkins CI/CD

Copy Jenkinsfile into your repository root. Its AWS account, Region, user, project, cluster, and namespace values are already set. First inspect the application scripts:

    npm --prefix backend run
    npm --prefix frontend run
    npm --prefix admin run

If backend lacks a test script, create one before final evaluation. Do not leave a false passing test stage. Confirm container names before Jenkins uses kubectl set image:

    kubectl get deployment backend -n akash-shopnow -o jsonpath="{.spec.template.spec.containers[*].name}"
    kubectl get deployment frontend -n akash-shopnow -o jsonpath="{.spec.template.spec.containers[*].name}"
    kubectl get deployment admin -n akash-shopnow -o jsonpath="{.spec.template.spec.containers[*].name}"

In Jenkins create a Multibranch Pipeline and connect it to your GitHub fork. Set its Jenkinsfile path to Jenkinsfile. Add GitHub webhook:

    http://JENKINS_PUBLIC_IP:8080/github-webhook/

Only main deploys. Feature branches must test/build/scan but must not modify EKS. Each deployment tag is the Git SHA; do not use latest.

## Phase 8: monitoring (install only after deployment works)

Install the monitored stack:

    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update
    kubectl create namespace monitoring
    helm upgrade --install monitoring prometheus-community/kube-prometheus-stack -n monitoring -f monitoring/values.yaml
    kubectl apply -f monitoring/shopnow-alerts.yaml
    kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80

Grafana is at http://localhost:3000. Change the supplied admin password immediately. Show dashboards for node CPU/memory, node readiness, pod restarts, desired versus available replicas, HPA, and ingress traffic. Set Alertmanager Slack/email configuration through secrets, never a tracked live webhook.

## Phase 9: final validation, screenshots and rollback

For the capstone demonstration make a harmless code change, push main, and show Jenkins checkout, tests, ECR SHA tags, Trivy result, rollout, app ingress, HPA and Grafana. Then show a safe rollback:

    kubectl -n akash-shopnow rollout history deployment/backend
    kubectl -n akash-shopnow rollout undo deployment/backend
    kubectl -n akash-shopnow rollout status deployment/backend --timeout=180s

Debug in this sequence:

    kubectl get pods -n akash-shopnow
    kubectl describe pod POD_NAME -n akash-shopnow
    kubectl logs POD_NAME -n akash-shopnow --previous
    kubectl get events -n akash-shopnow --sort-by=.lastTimestamp
    kubectl top nodes
    kubectl top pods -n akash-shopnow

## Phase 10: teardown immediately after evidence is saved

Run only after all screenshots, logs and reports have been saved:

    cd infra
    terraform destroy

The ECR repositories were created manually and are intentionally not managed or deleted by this runbook. Leave the versioned state bucket until every collaborator confirms they no longer need it. Then empty and delete it.
