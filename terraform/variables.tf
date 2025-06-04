# terraform/variables.tf - AWS version for IoTS6

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name of the project (used for resource naming)"
  type        = string
  default     = "awiots6"
}

variable "vm_name" {
  description = "Name of the EC2 instance"
  type        = string
  default     = "awiots6"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.small"
}

variable "disk_size_gb" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 40
}

variable "admin_username" {
  description = "Admin username for the EC2 instance"
  type        = string
  default     = "nathan"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key file"
  type        = string
  default     = "~/.ssh/id_rsa_aws.pub"
}

variable "key_pair_name" {
  description = "Name for the AWS key pair"
  type        = string
  default     = "awiots6-keypair"
}

variable "enable_local_exec" {
  description = "Enable local-exec provisioners for automated deployment"
  type        = bool
  default     = false
}
