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
  description = "Ubuntu 24.04 AMI with MySQL preinstalled, or an image that can be bootstrapped from an S3 package bundle."
}

variable "instance_type" {
  type        = string
  description = "Database EC2 instance type."
}

variable "subnet_id" {
  type        = string
  description = "Private subnet ID."
}

variable "security_group_id" {
  type        = string
  description = "Database security group ID."
}

variable "secret_arn" {
  type        = string
  description = "Secrets Manager secret ARN."
}

variable "database_name" {
  type        = string
  description = "Application database name."
}

variable "database_user" {
  type        = string
  description = "Application database account name."
}

variable "tags" {
  type        = map(string)
  description = "Common resource tags."
}
