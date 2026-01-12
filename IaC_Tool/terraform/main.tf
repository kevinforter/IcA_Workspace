terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# -----------------------------
# Variables
# -----------------------------
variable "key_name" {
  type    = string
  default = "vockey"
}

variable "node_count" {
  type    = number
  default = 2
}

variable "project_name" {
  type    = string
  default = "progress-chef"
}

# -----------------------------
# Data Sources
# -----------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "ubuntu_2204" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# -----------------------------
# Security Groups
# -----------------------------

# SG for Chef Server
resource "aws_security_group" "chef_server_sg" {
  name        = "chef-server-sg"
  description = "Allow Chef Server traffic"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# SG for Chef Clients
resource "aws_security_group" "chef_client_sg" {
  name        = "${var.project_name}-chef-client-sg"
  description = "Allow SSH and HTTP to Chef client nodes"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -----------------------------
# EC2 Instances
# -----------------------------

# Chef Infra Server
resource "aws_instance" "chef_infra_server" {
  ami                    = "ami-0fc5d935ebf8bc3bc"
  instance_type          = "t3.medium"
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.chef_server_sg.id]

  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y wget
              wget https://packages.chef.io/files/stable/chef-server/15.7.0/ubuntu/22.04/chef-server-core_15.7.0-1_amd64.deb
              dpkg -i chef-server-core_15.7.0-1_amd64.deb
              mkdir -p /etc/opscode
              echo "license['chef_license'] = 'accept'" > /etc/opscode/chef-server.rb
              chef-server-ctl reconfigure --chef-license=accept
              sleep 30
              chef-server-ctl user-create admin Chef Admin admin@example.com 'ChefPassword123' --filename /home/ubuntu/admin.pem
              chef-server-ctl org-create my_org 'My Company Organization' --association_user admin --filename /home/ubuntu/my_org-validator.pem
              chown ubuntu:ubuntu /home/ubuntu/*.pem
              EOF

  tags = {
    Name = "Chef-Infra-Server"
  }
}

# Chef Client Nodes
resource "aws_instance" "chef_client" {
  count                  = var.node_count
  ami                    = data.aws_ami.ubuntu_2204.id
  instance_type          = "t2.micro"
  key_name               = var.key_name
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.chef_client_sg.id]

  tags = {
    Name = "${var.project_name}-node-${count.index + 1}"
    Role = "chef-client"
  }
}

# -----------------------------
# Outputs
# -----------------------------
output "chef_server_public_dns" {
  value = aws_instance.chef_infra_server.public_dns
}

output "chef_server_public_ip" {
  value = aws_instance.chef_infra_server.public_ip
}

output "client_public_ips" {
  value = [for i in aws_instance.chef_client : i.public_ip]
}
