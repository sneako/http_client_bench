variable "region" {
  type        = string
  description = "AWS region for the benchmark infrastructure."
  default     = "eu-central-1"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the benchmark VPC."
  default     = "10.50.0.0/16"
}

variable "public_subnet_cidr" {
  type        = string
  description = "CIDR block for the public subnet."
  default     = "10.50.1.0/24"
}

variable "client_instance_type" {
  type        = string
  description = "EC2 instance type for the benchmark client."
  default     = "c7a.2xlarge"
}

variable "server_instance_type" {
  type        = string
  description = "EC2 instance type for the benchmark server."
  default     = "c7a.2xlarge"
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to the public SSH key for EC2 access."
}

variable "admin_cidr" {
  type        = string
  description = "CIDR block allowed to SSH into the instances."
  default     = "0.0.0.0/0"
}

variable "bench_port" {
  type        = number
  description = "TCP port that the benchmark server listens on."
  default     = 8080
}

variable "ami_id" {
  type        = string
  description = "Optional AMI ID override. Leave blank to use the latest Ubuntu 22.04 AMD64 AMI."
  default     = ""
}

variable "erlang_version" {
  type        = string
  description = "Erlang version to install via mise on the client VM."
  default     = "28.3.1"
}

variable "elixir_version" {
  type        = string
  description = "Elixir version to install via mise on the client VM."
  default     = "1.19.5-otp-28"
}
