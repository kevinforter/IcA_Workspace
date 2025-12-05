terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Get latest Ubuntu 24.04 LTS AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  # Match common Ubuntu 22.04 LTS names
  filter {
    name = "name"
    values = [
      "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*",
      "ubuntu/images/hvm-ssd/ubuntu-*-22.04-amd64-server-*"
    ]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Default VPC
data "aws_vpc" "default" {
  default = true
}

# Security group with SSH, HTTP, HTTPS open
resource "aws_security_group" "web_sg" {
  name        = "lab-web-sg"
  description = "Allow SSH, HTTP, HTTPS"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Three Ubuntu EC2 instances
resource "aws_instance" "ubuntu_lab" {
  count         = 3
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"
  key_name      = "vockey" # UPDATED KEY NAME

  vpc_security_group_ids = [aws_security_group.web_sg.id]

  tags = {
    Name = "ubuntu-lab-${count.index + 1}"
  }
}

# Outputs for SSH
output "instance_public_ips" {
  description = "Public IPs of the 3 Ubuntu instances"
  value       = [for i in aws_instance.ubuntu_lab : i.public_ip]
}

output "instance_public_dns" {
  description = "Public DNS names of the 3 Ubuntu instances"
  value       = [for i in aws_instance.ubuntu_lab : i.public_dns]
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}
