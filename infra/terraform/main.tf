provider "aws" {
  region = var.region
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

locals {
  ami_id = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu.id
}

resource "aws_vpc" "bench" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "finch-bench-vpc"
  }
}

resource "aws_internet_gateway" "bench" {
  vpc_id = aws_vpc.bench.id

  tags = {
    Name = "finch-bench-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.bench.id
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true

  tags = {
    Name = "finch-bench-public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.bench.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.bench.id
  }

  tags = {
    Name = "finch-bench-public"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "client" {
  name        = "finch-bench-client"
  description = "Benchmark client security group"
  vpc_id      = aws_vpc.bench.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "finch-bench-client"
  }
}

resource "aws_security_group" "server" {
  name        = "finch-bench-server"
  description = "Benchmark server security group"
  vpc_id      = aws_vpc.bench.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description     = "Benchmark HTTP from client"
    from_port       = var.bench_port
    to_port         = var.bench_port
    protocol        = "tcp"
    security_groups = [aws_security_group.client.id]
  }

  ingress {
    description = "Benchmark HTTP from admin"
    from_port   = var.bench_port
    to_port     = var.bench_port
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "finch-bench-server"
  }
}

resource "aws_key_pair" "bench" {
  key_name   = "finch-bench-key"
  public_key = file(var.ssh_public_key_path)
}

resource "aws_instance" "client" {
  ami                         = local.ami_id
  instance_type               = var.client_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.client.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.bench.key_name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/user_data_client.sh", {
    erlang_version = var.erlang_version
    elixir_version = var.elixir_version
  })

  tags = {
    Name = "finch-bench-client"
  }
}

resource "aws_instance" "server" {
  ami                         = local.ami_id
  instance_type               = var.server_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.server.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.bench.key_name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  user_data = file("${path.module}/user_data_server.sh")

  tags = {
    Name = "finch-bench-server"
  }
}
