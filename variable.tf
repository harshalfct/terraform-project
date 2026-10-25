variable "aws_region" {
  description = "AWS region for the application infrastructure."
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Short name used to identify resources."
  type        = string
  default     = "three-tier-app"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,35}$", var.project_name))
    error_message = "project_name must be 3-35 lowercase letters, numbers, or hyphens."
  }
}

variable "vpc_cidr" {
  description = "IPv4 CIDR for the application VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "IPv4 CIDR for the public web subnet."
  type        = string
  default     = "10.20.1.0/24"
}

variable "private_subnet_cidr" {
  description = "IPv4 CIDR for the private database subnet."
  type        = string
  default     = "10.20.2.0/24"
}

variable "ssh_trusted_cidr" {
  description = "Optional trusted IPv4 CIDR allowed to SSH to the web instance. Empty disables SSH."
  type        = string
  default     = ""

  validation {
    condition     = var.ssh_trusted_cidr == "" || can(cidrnetmask(var.ssh_trusted_cidr))
    error_message = "ssh_trusted_cidr must be an IPv4 CIDR or an empty string."
  }
}

variable "key_pair_name" {
  description = "Optional existing EC2 key pair for SSH access to the web instance."
  type        = string
  default     = null
  nullable    = true
}

variable "web_instance_type" {
  description = "EC2 instance type for the web server."
  type        = string
  default     = "t3.micro"
}

variable "database_instance_type" {
  description = "EC2 instance type for the MySQL server."
  type        = string
  default     = "t3.micro"
}

variable "application_port" {
  description = "Loopback-only Node.js listener port."
  type        = number
  default     = 3000

  validation {
    condition     = var.application_port >= 1 && var.application_port <= 65535
    error_message = "application_port must be between 1 and 65535."
  }
}

variable "application_database_name" {
  description = "Name of the application database."
  type        = string
  default     = "appdb"

  validation {
    condition     = can(regex("^[A-Za-z0-9_]+$", var.application_database_name))
    error_message = "application_database_name may contain only letters, numbers, and underscores."
  }
}

variable "application_database_user" {
  description = "Least-privilege MySQL account used by the application."
  type        = string
  default     = "app_user"

  validation {
    condition     = can(regex("^[A-Za-z0-9_]+$", var.application_database_user))
    error_message = "application_database_user may contain only letters, numbers, and underscores."
  }
}

variable "database_ami_id" {
  description = "Ubuntu 24.04 amd64 AMI with AWS CLI, Python 3, OpenSSL, and SSM Agent; MySQL is installed through the NAT Gateway."
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]+$", var.database_ami_id))
    error_message = "database_ami_id must be an AWS AMI ID such as ami-0123456789abcdef0."
  }
}
