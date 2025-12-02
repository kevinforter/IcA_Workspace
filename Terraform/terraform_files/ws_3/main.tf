terraform {
  required_version = ">= 1.6.0"

  cloud {
    organization = "infc_workshop"

    workspaces {
      name = "workshop-3"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# Provider configuration
# Connects Terraform to the AWS cloud in the N. Virginia region.
provider "aws" {
  region = "us-east-1"
}

##########################
# Networking (VPC & Subnets)
##########################

# 1. VPC (Virtual Private Cloud)
# Creates an isolated network environment in the cloud.
resource "aws_vpc" "web_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "tf-web-vpc"
  }
}

# 2. Internet Gateway
# The "door" that allows traffic to enter and leave the VPC to the wider internet.
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.web_vpc.id

  tags = {
    Name = "tf-web-igw"
  }
}

# 3. Route Table
# A set of rules that tells network traffic where to go. 
# Here, we send all traffic (0.0.0.0/0) to the Internet Gateway.
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

# 4. Subnets
# To use an AWS Load Balancer, we need subnets in at least two different Availability Zones.
# This ensures that if one data center (AZ) fails, the other keeps working.

# Subnet 1 in Zone A
resource "aws_subnet" "subnet_1" {
  vpc_id                  = aws_vpc.web_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true # Automatically gives instances a public IP so we can download updates

  tags = {
    Name = "tf-subnet-1"
  }
}

# Subnet 2 in Zone B
resource "aws_subnet" "subnet_2" {
  vpc_id                  = aws_vpc.web_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true

  tags = {
    Name = "tf-subnet-2"
  }
}

# 5. Route Table Associations
# Connects our subnets to the route table so they have internet access.
resource "aws_route_table_association" "rta_1" {
  subnet_id      = aws_subnet.subnet_1.id
  route_table_id = aws_route_table.web_rt.id
}

resource "aws_route_table_association" "rta_2" {
  subnet_id      = aws_subnet.subnet_2.id
  route_table_id = aws_route_table.web_rt.id
}

##########################
# Security Groups
##########################

# 6. Security Group for the Load Balancer
# Acts as a virtual firewall for the Load Balancer.
# Allows HTTP traffic from anywhere (world) to reach the Balancer.
resource "aws_security_group" "lb_sg" {
  name        = "tf-lb-sg"
  description = "Allow HTTP to Load Balancer"
  vpc_id      = aws_vpc.web_vpc.id

  ingress {
    description = "HTTP from Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 7. Security Group for EC2 Instances
# Firewall for the actual servers.
# Ideally, we only allow traffic coming FROM the Load Balancer, not directly from the internet.
resource "aws_security_group" "ec2_sg" {
  name        = "tf-ec2-sg"
  description = "Allow HTTP from LB"
  vpc_id      = aws_vpc.web_vpc.id

  ingress {
    description     = "HTTP from Load Balancer"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.lb_sg.id] # Only accept traffic from the LB SG
  }

  # We also need SSH (22) or generic internet access to install Apache
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

##########################
# Load Balancer Setup
##########################

# 8. Application Load Balancer (ALB)
# The entry point for users. It accepts traffic and distributes it across our subnets.
resource "aws_lb" "app_lb" {
  name               = "tf-web-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = [aws_subnet.subnet_1.id, aws_subnet.subnet_2.id]

  tags = {
    Name = "tf-web-lb"
  }
}

# 9. Target Group
# Logical group of targets (servers). The LB sends traffic to this group.
# Checks health on port 80 to make sure the server is actually running.
resource "aws_lb_target_group" "web_tg" {
  name     = "tf-web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.web_vpc.id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# 10. Listener
# Listens for incoming traffic on the LB (Port 80) and forwards it to the Target Group.
resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}

##########################
# Compute (EC2 Instances)
##########################

# Get latest Ubuntu Image
data "aws_ami" "ubuntu" {
  owners      = ["099720109477"]
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# 11. EC2 Instances
# We use 'count = 2' to create two identical servers.
# We alternate subnets using the modulo operator (%) so one is in Zone A and one in Zone B.
resource "aws_instance" "web" {
  count         = 2
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"

  # Select subnet based on whether the count index is even or odd
  subnet_id = count.index % 2 == 0 ? aws_subnet.subnet_1.id : aws_subnet.subnet_2.id

  vpc_security_group_ids = [aws_security_group.ec2_sg.id]

  # Script runs on startup. It installs Apache and writes the specific server ID to the HTML page
  # so we can see which server answers our request.
  user_data = <<-EOF
    #!/bin/bash
    sudo apt-get update
    sudo apt-get install -y apache2
    sudo systemctl start apache2
    sudo systemctl enable apache2
    echo "<h1>Hello from Instance ${count.index + 1}</h1>" | sudo tee /var/www/html/index.html
  EOF

  tags = {
    Name = "tf-web-instance-${count.index + 1}"
  }
}

# 12. Attach Instances to Target Group
# This connects the newly created instances to the Load Balancer's target group.
resource "aws_lb_target_group_attachment" "web_attach" {
  count            = 2
  target_group_arn = aws_lb_target_group.web_tg.arn
  target_id        = aws_instance.web[count.index].id
  port             = 80
}

##########################
# Outputs
##########################

# 13. Output the DNS Name
# This is the URL we put in the browser to access our website.
output "load_balancer_dns" {
  description = "The DNS name of the load balancer"
  value       = aws_lb.app_lb.dns_name
}