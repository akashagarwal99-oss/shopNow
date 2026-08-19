#!/usr/bin/env bash
#
# Installs the AWS Load Balancer Controller into akash-shopnow-eks via Helm.
#
# One-time cluster bootstrap step: run once after `terraform apply` has created the cluster
# and the controller's EKS Pod Identity association (terraform/pod-identity.tf), and before
# applying any Ingress manifests (kubernetes/{frontend,admin}/ingress.yaml). Safe to re-run
# (uses `helm upgrade --install`) — this is not part of the Jenkins pipeline, the same way
# metrics-server and the gp3 StorageClass aren't; it's cluster-level setup done once, not
# something that needs to happen on every application deploy.
#
# Credentials: this does NOT use IRSA / OIDC ServiceAccount annotations. Authentication is
# handled entirely by EKS Pod Identity — terraform/pod-identity.tf's
# aws_eks_pod_identity_association.alb_controller binds namespace "kube-system" + service
# account "aws-load-balancer-controller" to an IAM role. That exact pairing is what's created
# below; change either name here and the binding breaks silently (the pod starts fine, but
# every AWS API call it makes gets denied).

set -euo pipefail

AWS_REGION="ap-south-1"
CLUSTER_NAME="akash-shopnow-eks"
SERVICE_ACCOUNT="aws-load-balancer-controller"
TF_DIR="${TF_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)}"

echo "==> Checking required tools are on PATH"
for cmd in aws helm kubectl terraform; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: '$cmd' not found on PATH. ansible/playbook.yml installs all of these on the Jenkins box." >&2
    exit 1
  }
done

echo "==> Pointing kubectl at ${CLUSTER_NAME}"
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

echo "==> Checking the EKS Pod Identity association for ${SERVICE_ACCOUNT} exists (precondition)"
ASSOCIATION_COUNT=$(aws eks list-pod-identity-associations \
  --cluster-name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --namespace kube-system \
  --service-account "${SERVICE_ACCOUNT}" \
  --query 'length(associations)' --output text)

if [ "${ASSOCIATION_COUNT}" = "0" ]; then
  echo "ERROR: no Pod Identity association found for kube-system/${SERVICE_ACCOUNT}." >&2
  echo "That means terraform/pod-identity.tf (aws_eks_pod_identity_association.alb_controller)" >&2
  echo "hasn't been applied yet. Run 'terraform apply' first, then re-run this script." >&2
  exit 1
fi
echo "    OK: Pod Identity association exists (${ASSOCIATION_COUNT} match)."

echo "==> Resolving VPC ID from Terraform output (dir: ${TF_DIR})"
VPC_ID=$(terraform -chdir="${TF_DIR}" output -raw vpc_id 2>/dev/null || true)
if [ -z "${VPC_ID}" ]; then
  echo "    'terraform output vpc_id' unavailable from ${TF_DIR} — falling back to an AWS tag lookup" >&2
  VPC_ID=$(aws ec2 describe-vpcs --region "${AWS_REGION}" \
    --filters "Name=tag:Name,Values=akash-shopnow-vpc" \
    --query 'Vpcs[0].VpcId' --output text)
fi
if [ -z "${VPC_ID}" ] || [ "${VPC_ID}" = "None" ]; then
  echo "ERROR: could not determine the VPC ID (terraform output was empty and the tag lookup found nothing)." >&2
  echo "Has 'terraform apply' run yet? Set TF_DIR if this script isn't next to your terraform/ directory." >&2
  exit 1
fi
echo "    Using VPC: ${VPC_ID}"

echo "==> Adding/updating the eks-charts Helm repo"
helm repo add eks https://aws.github.io/eks-charts >/dev/null
helm repo update >/dev/null

echo "==> Installing/upgrading the AWS Load Balancer Controller"
# No serviceAccount.annotations here — on purpose. Pod Identity, not IRSA (see header note).
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="${CLUSTER_NAME}" \
  --set region="${AWS_REGION}" \
  --set vpcId="${VPC_ID}" \
  --set serviceAccount.create=true \
  --set serviceAccount.name="${SERVICE_ACCOUNT}"

echo "==> Waiting for the controller deployment to become available"
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=180s

echo "==> Verifying credentials come from Pod Identity, not a stray IRSA annotation"
SA_ANNOTATIONS=$(kubectl get serviceaccount "${SERVICE_ACCOUNT}" -n kube-system -o jsonpath='{.metadata.annotations}')
if echo "${SA_ANNOTATIONS}" | grep -q 'eks.amazonaws.com/role-arn'; then
  echo "WARNING: found an IRSA 'eks.amazonaws.com/role-arn' annotation on the ServiceAccount." >&2
  echo "This project uses Pod Identity, not IRSA — that annotation is unexpected here and worth investigating." >&2
else
  echo "    OK: no IRSA annotation present, as expected."
fi

echo "==> Verifying the controller pods are Running"
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

echo "==> Verifying the 'alb' IngressClass exists"
if kubectl get ingressclass alb >/dev/null 2>&1; then
  echo "    OK: IngressClass 'alb' already exists (created automatically by the Helm chart)."
else
  echo "    Not found — creating it explicitly."
  kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: alb
spec:
  controller: ingress.k8s.aws/alb
EOF
  kubectl get ingressclass alb
fi

echo ""
echo "Done. The AWS Load Balancer Controller is installed and authenticating via EKS Pod Identity."
echo "Next: kubectl apply -f kubernetes/namespace.yaml, then the rest of kubernetes/ per the README."
