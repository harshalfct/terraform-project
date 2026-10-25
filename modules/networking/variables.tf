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

variable "public_availability_zone" {
  type        = string
  description = "Availability Zone for the public subnet and NAT Gateway."
}

variable "private_availability_zone" {
  type        = string
  description = "Availability Zone for the private subnet."
}

variable "ssh_trusted_cidr" {
  type        = string
  description = "Optional trusted IPv4 CIDR for SSH."
}

variable "tags" {
  type        = map(string)
  description = "Common resource tags."
}
