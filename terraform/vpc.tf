module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${var.student_username}-shopnow-vpc"
  cidr = var.vpc_cidr

  azs             = var.azs
  public_subnets  = [for i, az in var.azs : cidrsubnet(var.vpc_cidr, 8, i)]      # 10.0.0.0/24, 10.0.1.0/24
  private_subnets = [for i, az in var.azs : cidrsubnet(var.vpc_cidr, 8, i + 10)] # 10.0.10.0/24, 10.0.11.0/24

  enable_nat_gateway   = true
  single_nat_gateway   = true # cost optimization: 1 NAT GW instead of 1-per-AZ (see §15)
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Required so the AWS Load Balancer Controller can auto-discover subnets
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}
