module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.24.0"

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access  = true
  endpoint_private_access = true

  # Automatically grants the identity running `terraform apply` cluster-admin access
  # (via an EKS access entry) so you can `aws eks update-kubeconfig` immediately.
  enable_cluster_creator_admin_permissions = false

  kms_key_administrators = [
    aws_iam_role.jenkins.arn
  ]

  addons = {
    coredns                = {
      addon_version = var.eks_addon_versions.coredns
    }
    kube-proxy             = {
      addon_version = var.eks_addon_versions.kube_proxy
    }
    vpc-cni                = { 
      addon_version  = var.eks_addon_versions.vpc_cni
      before_compute = true
    }
    
    eks-pod-identity-agent = { 
      addon_version  = var.eks_addon_versions.eks_pod_identity_agent
      before_compute = true
    } # needed for the roles in pod-identity.tf
    
    aws-ebs-csi-driver     = {
      addon_version = var.eks_addon_versions.aws_ebs_csi_driver
    }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND" # switch to "SPOT" for extra savings once things are stable — see §15
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size

      ami_release_version            = var.node_ami_release_version
      use_latest_ami_release_version = false
    }
  }

  security_group_additional_rules = {
    jenkins_to_cluster_api = {
      description              = "Allow Jenkins EC2 to access the EKS Kubernetes API"
      protocol                 = "tcp"
      from_port                = 443
      to_port                  = 443
      type                     = "ingress"
      source_security_group_id = aws_security_group.jenkins.id
    }
  }

  # Let the Jenkins EC2 instance's IAM role run kubectl/helm against this cluster
  access_entries = {
    jenkins = {
      principal_arn = aws_iam_role.jenkins.arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  tags = {
    Environment = "capstone"
  }
}
