#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-ap-south-1}"
CLUSTER_NAME="${CLUSTER_NAME:-akash-shopnow-eks}"
K8S_VERSION="${K8S_VERSION:-1.34}"
OUTPUT_FILE="deployment.auto.tfvars"

echo "=== ShopNow EKS version bootstrap ==="
echo "Region:  ${REGION}"
echo "Cluster: ${CLUSTER_NAME}"

cluster_exists=false

if aws eks describe-cluster \
    --name "${CLUSTER_NAME}" \
    --region "${REGION}" >/dev/null 2>&1; then
    cluster_exists=true
fi

get_addon_version() {
    local addon="$1"

    if [ "${cluster_exists}" = true ]; then
        aws eks describe-addon \
            --cluster-name "${CLUSTER_NAME}" \
            --addon-name "${addon}" \
            --region "${REGION}" \
            --query 'addon.addonVersion' \
            --output text
    else
        aws eks describe-addon-versions \
            --addon-name "${addon}" \
            --kubernetes-version "${K8S_VERSION}" \
            --region "${REGION}" \
            --output json |
        jq -r '
          .addons[0].addonVersions[]
          | select(any(.compatibilities[]?; .defaultVersion == true))
          | .addonVersion
        ' | head -1
    fi
}

if [ "${cluster_exists}" = true ]; then
    NODEGROUP=$(aws eks list-nodegroups \
        --cluster-name "${CLUSTER_NAME}" \
        --region "${REGION}" \
        --query 'nodegroups[0]' \
        --output text)

    NODE_RELEASE=$(aws eks describe-nodegroup \
        --cluster-name "${CLUSTER_NAME}" \
        --nodegroup-name "${NODEGROUP}" \
        --region "${REGION}" \
        --query 'nodegroup.releaseVersion' \
        --output text)
else
    NODE_RELEASE=$(aws ssm get-parameter \
        --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/standard/recommended/release_version" \
        --region "${REGION}" \
        --query 'Parameter.Value' \
        --output text)
fi

COREDNS=$(get_addon_version "coredns")
KUBE_PROXY=$(get_addon_version "kube-proxy")
VPC_CNI=$(get_addon_version "vpc-cni")
POD_IDENTITY=$(get_addon_version "eks-pod-identity-agent")
EBS_CSI=$(get_addon_version "aws-ebs-csi-driver")

cat > "${OUTPUT_FILE}" <<EOF
eks_addon_versions = {
  coredns                = "${COREDNS}"
  kube_proxy             = "${KUBE_PROXY}"
  vpc_cni                = "${VPC_CNI}"
  eks_pod_identity_agent = "${POD_IDENTITY}"
  aws_ebs_csi_driver     = "${EBS_CSI}"
}

node_ami_release_version = "${NODE_RELEASE}"
EOF

echo
echo "Generated ${OUTPUT_FILE}:"
cat "${OUTPUT_FILE}"