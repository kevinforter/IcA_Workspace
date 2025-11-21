terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

#region us-east-1 gemäss Vorgabe
provider "aws" {
  region = "us-east-1"
}

#default-VPC und Subnets
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default_vpc_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Ubuntu AMI 22.04 LTS
data "aws_ami" "ubuntu" {
  owners      = ["099720109477"]
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Security Group:
resource "aws_security_group" "web_sg" {
  name        = "tf-web-sg"
  description = "Allow HTTP in, all egress"
  vpc_id      = data.aws_vpc.default.id

  #HTTP (80/tcp) von überall rein
  ingress {
    description      = "HTTP"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  #alles raus erlauben
  egress {
    description      = "All egress"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "tf-web-sg"
  }
}

# EC2-Instance: t2.micro, Public IP, User Data startet Apache
resource "aws_instance" "web" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t2.micro"
  subnet_id                   = data.aws_subnets.default_vpc_subnets.ids[0]
  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  associate_public_ip_address = true

  #vorgegebenes user data script
  user_data = <<-EOF
    #!/bin/bash
    sudo apt-get update
    sudo apt-get install -y apache2
    sudo systemctl start apache2
    sudo systemctl enable apache2
    echo "<h1>Hello World</h1>" | sudo tee /var/www/html/index.html
  EOF

  tags = {
    Name = "tf-apache"
  }
}

# wartet, bis Apache antwortet
resource "null_resource" "check_http" {
  triggers = {
    public_dns = aws_instance.web.public_dns
  }

  provisioner "local-exec" {
    command = "bash -c 'for i in {1..30}; do curl -sSf http://${aws_instance.web.public_dns} >/dev/null && echo OK && exit 0; echo retry-$i; sleep 5; done; echo FAILED; exit 1'"
  }

  depends_on = [aws_instance.web]
}

# Output: Public DNS der Instanz
output "instance_public_dns" {
  description = "Public DNS of the EC2 instance"
  value       = aws_instance.web.public_dns
}
