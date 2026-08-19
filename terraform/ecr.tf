# The three ECR repositories (akash-shopnow/backend, /frontend, /admin) already exist in this
# AWS account and are managed outside this Terraform config. These are read-only lookups, not
# managed resources — Terraform will refuse to `plan`/`apply` if any of the three don't already
# exist, and `terraform destroy` will never touch them. If you ever DO want Terraform to own their
# lifecycle (e.g. the ECR lifecycle policy that expires untagged images), that's a deliberate,
# separate decision — swap these `data` blocks for `resource "aws_ecr_repository"` blocks with
# `import` first, don't just add resources with the same names.
locals {
  ecr_services = ["backend", "frontend", "admin"]
}

data "aws_ecr_repository" "this" {
  for_each = toset(local.ecr_services)
  name     = "${var.student_username}-shopnow/${each.key}"
}
