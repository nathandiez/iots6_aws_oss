# terraform/main.tf - AWS version of IoTS6 with local-exec provisioners (fixed)
terraform {
  required_version = ">= 1.0"
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

# Data source for current AWS region AZs
data "aws_availability_zones" "available" {
  state = "available"
}

# Data source for Ubuntu AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Create VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name    = "${var.project_name}-vpc"
    Project = var.project_name
  }
}

# Create Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "${var.project_name}-igw"
    Project = var.project_name
  }
}

# Create public subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name    = "${var.project_name}-public-subnet"
    Project = var.project_name
  }
}

# Create route table for public subnet
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name    = "${var.project_name}-public-rt"
    Project = var.project_name
  }
}

# Associate route table with public subnet
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Security group for IoT server
resource "aws_security_group" "iot_server" {
  name_prefix = "${var.project_name}-"
  vpc_id      = aws_vpc.main.id

  # SSH access
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # MQTT broker
  ingress {
    from_port   = 1883
    to_port     = 1883
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # TimescaleDB
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Grafana
  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # All outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-sg"
    Project = var.project_name
  }
}

# Create EC2 key pair
resource "aws_key_pair" "main" {
  key_name   = var.key_pair_name
  public_key = file(var.ssh_public_key_path)

  tags = {
    Name    = "${var.project_name}-keypair"
    Project = var.project_name
  }
}

# Launch EC2 instance
resource "aws_instance" "iot_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.main.key_name
  vpc_security_group_ids = [aws_security_group.iot_server.id]
  subnet_id              = aws_subnet.public.id

  root_block_device {
    volume_type = "gp3"
    volume_size = var.disk_size_gb
    encrypted   = true
  }

  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y python3 python3-pip
              # Wait for cloud-init to complete
              cloud-init status --wait
              EOF

  tags = {
    Name    = var.vm_name
    Project = var.project_name
  }
}

# Create Elastic IP for stable public IP
resource "aws_eip" "main" {
  instance = aws_instance.iot_server.id
  domain   = "vpc"

  tags = {
    Name    = "${var.project_name}-eip"
    Project = var.project_name
  }

  depends_on = [aws_internet_gateway.main]
}

# Local-exec provisioners (separate resource to avoid circular dependency)
resource "null_resource" "deployment" {
  count = var.enable_local_exec ? 1 : 0

  # Wait for SSH to become available
  provisioner "local-exec" {
    command = "${path.module}/scripts/wait-for-ssh.sh"
    environment = {
      VM_IP = aws_eip.main.public_ip
    }
  }

  # Run Ansible deployment
  provisioner "local-exec" {
    command = "${path.module}/scripts/run-ansible.sh"
    environment = {
      VM_IP = aws_eip.main.public_ip
    }
  }

  # Verify deployment
  provisioner "local-exec" {
    command = "${path.module}/scripts/verify-deployment.sh"
    environment = {
      VM_IP = aws_eip.main.public_ip
    }
  }

  depends_on = [aws_eip.main]

  triggers = {
    instance_id = aws_instance.iot_server.id
    eip_id      = aws_eip.main.id
  }
}