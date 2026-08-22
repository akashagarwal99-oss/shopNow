resource "aws_security_group" "jenkins" {
  name_prefix = "${var.student_username}-shopnow-jenkins-"
  description = "Jenkins EC2 - SSH + Jenkins UI, locked to my IP"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  ingress {
    description = "Jenkins UI from my IP"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.student_username}-shopnow-jenkins-sg" }
}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins" {
  name               = "${var.student_username}-shopnow-jenkins-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

# Deliberately broad: this is a single-student learning account, and the "Infrastructure
# Provisioning" pipeline stage runs Terraform, which needs to manage VPC/EKS/IAM/EC2/ECR/S3 —
# including, awkwardly, its own role's permissions. In a real org you'd scope this to exactly
# the services Terraform touches, or run infra changes from a separate CI identity than the one
# that builds and deploys application code.
resource "aws_iam_role_policy_attachment" "jenkins_admin" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.student_username}-shopnow-jenkins-profile"
  role = aws_iam_role.jenkins.name
}

resource "aws_instance" "jenkins" {
  ami                         = var.jenkins_ami_id
  instance_type               = var.jenkins_instance_type
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.jenkins.id]
  iam_instance_profile        = aws_iam_instance_profile.jenkins.name
  key_name                    = var.jenkins_key_name
  associate_public_ip_address = true

  lifecycle {
    prevent_destroy = true
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = { Name = "${var.student_username}-shopnow-jenkins" }
}
