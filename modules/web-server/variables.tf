variable "project_name" {
  type        = string
  description = "Resource name prefix."
}

variable "aws_region" {
  type        = string
  description = "AWS region used by the instance AWS CLI."
}

variable "ami_id" {
  type        = string
  description = "Ubuntu 24.04 AMI ID."
}

variable "instance_type" {
  type        = string
  description = "Web EC2 instance type."
}

variable "subnet_id" {
  type        = string
  description = "Public web subnet ID."
}

variable "security_group_id" {
  type        = string
  description = "Web security group ID."
}

variable "key_pair_name" {
  type        = string
  description = "Optional existing key pair for SSH."
  default     = null
  nullable    = true
}

variable "database_host" {
  type        = string
  description = "Private database address."
}

variable "database_name" {
  type        = string
  description = "Application database name."
}

variable "database_user" {
  type        = string
  description = "Application database username."
}

variable "database_secret_arn" {
  type        = string
  description = "Secrets Manager ARN containing the application database credentials."
}

variable "artifacts_bucket" {
  type        = string
  description = "S3 deployment artifacts bucket."
}

variable "application_port" {
  type        = number
  description = "Local Node.js application port."
}

variable "tags" {
  type        = map(string)
  description = "Common resource tags."
}
