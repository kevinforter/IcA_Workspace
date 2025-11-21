terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# AWS Provider – Region us-east-1
# Wenn du ein anderes Profil als "default" verwendest:
# provider "aws" {
#   region  = "us-east-1"
#   profile = "myprofile"
# }
provider "aws" {
  region = "us-east-1"
}

########################
# Netzwerk – VPC & Co. #
########################

# 1) VPC
resource "aws_vpc" "web_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "tf-web-vpc"
  }
}

# 2) Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.web_vpc.id

  tags = {
    Name = "tf-web-igw"
  }
}

# 3) Custom Route Table (Default Route ins Internet)
resource "aws_route_table" "web_rt" {
  vpc_id = aws_vpc.web_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "tf-web-rt"
  }
}

# 4) Subnet
resource "aws_subnet" "web_subnet" {
  vpc_id                  = aws_vpc.web_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = false # Wir nutzen eine ENI + Elastic IP

  tags = {
    Name = "tf-web-subnet"
  }
}

# 5) Subnet mit Route Table verknüpfen
resource "aws_route_table_association" "web_rta" {
  subnet_id      = aws_subnet.web_subnet.id
  route_table_id = aws_route_table.web_rt.id
}

##############################
# Security Group & Netzwerk #
##############################

# 6) Security Group (HTTP rein, alles raus)
resource "aws_security_group" "web_sg" {
  name        = "tf-web-sg"
  description = "Allow HTTP in, all egress"
  vpc_id      = aws_vpc.web_vpc.id

  # ingress: TCP Port 80
  ingress {
    description      = "HTTP"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  # egress: alles erlaubt
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

# 7) Network Interface (ENI) mit IP im Subnet
resource "aws_network_interface" "web_eni" {
  subnet_id       = aws_subnet.web_subnet.id
  private_ips     = ["10.0.1.50"]
  security_groups = [aws_security_group.web_sg.id]

  tags = {
    Name = "tf-web-eni"
  }
}

# 8) Elastic IP für die ENI
resource "aws_eip" "web_eip" {
  domain                    = "vpc"
  network_interface         = aws_network_interface.web_eni.id
  associate_with_private_ip = "10.0.1.50"

  # Stellt sicher, dass das IGW existiert, bevor die EIP im VPC-Kontext verwendet wird
  depends_on = [aws_internet_gateway.igw]

  tags = {
    Name = "tf-web-eip"
  }
}

#########################
# EC2 + Apache (Ubuntu) #
#########################

# Ubuntu AMI dynamisch finden (Canonical, Ubuntu 22.04 LTS)
data "aws_ami" "ubuntu" {
  owners      = ["099720109477"] # Canonical
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

# 9) EC2 Instance
resource "aws_instance" "web" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"

  # Wir hängen die ENI explizit als Network Interface an
  network_interface {
    network_interface_id = aws_network_interface.web_eni.id
    device_index         = 0
  }

  user_data = <<-EOF
    #!/bin/bash
    sudo apt-get update
    sudo apt-get install -y apache2
    sudo systemctl start apache2
    sudo systemctl enable apache2
    echo "<h1>Hello World</h1>" | sudo tee /var/www/html/index.html
  EOF

  tags = {
    Name = "tf-apache-instance"
  }
}

############################
# Output + Reachability    #
############################

# 10) Public IP ausgeben (von der Elastic IP)
output "instance_public_ip" {
  description = "Public IP of the EC2 instance (Elastic IP)"
  value       = aws_eip.web_eip.public_ip
}

# 11) Check, ob der Webserver erreichbar ist
resource "null_resource" "check_http" {
  triggers = {
    public_ip = aws_eip.web_eip.public_ip
  }

  provisioner "local-exec" {
    command = "bash -c 'for i in {1..30}; do curl -sSf http://${aws_eip.web_eip.public_ip} >/dev/null && echo OK && exit 0; echo retry-$i; sleep 5; done; echo FAILED; exit 1'"
  }

  depends_on = [aws_instance.web]
}
