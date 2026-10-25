output "application_url" {
  description = "HTTP URL of the application."
  value       = "http://${module.web_server.public_dns}"
}

output "web_server_public_ip" {
  description = "Public IPv4 address of the web server."
  value       = module.web_server.public_ip
}

output "web_server_public_dns" {
  description = "Public DNS name of the web server."
  value       = module.web_server.public_dns
}

output "vpc_id" {
  description = "Application VPC ID."
  value       = module.networking.vpc_id
}

output "public_subnet_id" {
  description = "Public web subnet ID."
  value       = module.networking.public_subnet_id
}

output "private_subnet_id" {
  description = "Private database subnet ID."
  value       = module.networking.private_subnet_id
}

output "public_availability_zone" {
  description = "Availability Zone containing the public subnet and NAT Gateway."
  value       = module.networking.public_availability_zone
}

output "private_availability_zone" {
  description = "Availability Zone containing the private database subnet."
  value       = module.networking.private_availability_zone
}

output "nat_gateway_id" {
  description = "NAT Gateway used for private subnet outbound internet access."
  value       = module.networking.nat_gateway_id
}

output "database_private_ip" {
  description = "Private IPv4 address of the database instance."
  value       = module.database_server.private_ip
}

output "deployment_bucket" {
  description = "Private, versioned S3 bucket for application deployment artifacts."
  value       = aws_s3_bucket.deployment_artifacts.id
}

output "database_secret_arn" {
  description = "Secrets Manager ARN; secret value is created by database bootstrap."
  value       = aws_secretsmanager_secret.database.arn
}

output "web_instance_id" {
  description = "Web instance ID used by the Jenkins SSM deployment step."
  value       = module.web_server.instance_id
}

output "database_instance_id" {
  description = "Database instance ID used by the Jenkins readiness step."
  value       = module.database_server.instance_id
}
