variable "project_name" {
  type        = string
  description = "Resource name prefix."
}

variable "vpc_cidr" {
  type        = string
  description = "VPC IPv4 CIDR."
}

variable "public_subnet_cidr" {
  type        = string
  description = "Public subnet IPv4 CIDR."
}

variable "private_subnet_cidr" {
  type        = string
  description = "Private subnet IPv4 CIDR."
}

variable "ssh_trusted_cidr" {
  type        = string
  description = "Optional trusted IPv4 CIDR for SSH."
}

variable "tags" {
  type        = map(string)
  description = "Common resource tags."
}
