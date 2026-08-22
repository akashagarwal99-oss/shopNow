variable "aws_region" {
  description = "AWS region for everything in this project"
  type        = string
  default     = "ap-south-1" # change if you'd rather deploy elsewhere
}

variable "student_username" {
  description = "Short personalization tag — used to namespace ECR repo names and AWS resource names"
  type        = string
  default     = "akash"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability zones to spread subnets across (need at least 2 for EKS)"
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}

variable "cluster_name" {
  type    = string
  default = "akash-shopnow-eks"
}

variable "cluster_version" {
  description = "EKS Kubernetes version. Check `aws eks describe-cluster-versions` for what's currently in STANDARD support before applying — this changes over time and un-supported versions cost extra."
  type        = string
  default     = "1.34"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["c7i-flex.large"] # 2 vCPU / 4 GiB — swapped from t3.medium: not offered in this account, c7i-flex.large is Free Tier eligible here instead
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 3
}

variable "jenkins_instance_type" {
  type    = string
  default = "c7i-flex.large" # 2 vCPU / 4 GiB — same reasoning as node_instance_types above
}

variable "jenkins_key_name" {
  description = "EC2 key pair name for SSH access to the Jenkins box. This must already exist in ap-south-1 under this exact name (aws ec2 create-key-pair --key-name akash-shopnow-jenkins-key --query 'KeyMaterial' --output text > ~/.ssh/akash-shopnow-jenkins-key.pem && chmod 400 ~/.ssh/akash-shopnow-jenkins-key.pem), or override this variable in terraform.tfvars with a key pair you already have."
  type        = string
  default     = "akash-shopnow-key"
}

variable "my_ip_cidr" {
  description = "Your workstation's public IP in CIDR form, e.g. 103.10.20.5/32 — restricts SSH/Jenkins UI access. Get it with: curl -s https://checkip.amazonaws.com"
  type        = string
}

variable "jenkins_ami_id" {
  description = "Pinned Ubuntu AMI ID for Jenkins in ap-south-1"
  type        = string
  default     = "ami-07c5bdc05185b65c6"
}

variable "eks_addon_versions" {
  description = "EKS add-on versions selected during environment bootstrap"
  type = object({
    coredns                = string
    kube_proxy             = string
    vpc_cni                = string
    eks_pod_identity_agent = string
    aws_ebs_csi_driver     = string
  })
}

variable "node_ami_release_version" {
  description = "EKS managed node group AMI release selected during environment bootstrap"
  type        = string
}