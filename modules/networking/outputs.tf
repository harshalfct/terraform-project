output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "private_subnet_id" {
  value = aws_subnet.private.id
}

output "web_security_group_id" {
  value = aws_security_group.web.id
}

output "database_security_group_id" {
  value = aws_security_group.database.id
}

output "public_availability_zone" {
  value = aws_subnet.public.availability_zone
}

output "private_availability_zone" {
  value = aws_subnet.private.availability_zone
}

output "nat_gateway_id" {
  value = aws_nat_gateway.this.id
}
