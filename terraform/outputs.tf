output "vpc_id" {
  value = module.vpc.vpc_id
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "ecr_repository_urls" {
  description = "Repository URLs for the pre-existing ECR repos (looked up, not managed by this config)"
  value       = { for k, v in data.aws_ecr_repository.this : k => v.repository_url }
}

output "jenkins_public_ip" {
  value = aws_instance.jenkins.public_ip
}

output "jenkins_ssh_command" {
  value = "ssh -i ~/.ssh/${var.jenkins_key_name}.pem ubuntu@${aws_instance.jenkins.public_ip}"
}

output "configure_kubectl_command" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
