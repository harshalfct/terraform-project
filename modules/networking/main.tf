data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = merge(var.tags, { Name = "${var.project_name}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.project_name}-igw" })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = merge(var.tags, { Name = "${var.project_name}-public" })
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false
  tags                    = merge(var.tags, { Name = "${var.project_name}-private" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, { Name = "${var.project_name}-public" })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.project_name}-private" })
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = merge(var.tags, { Name = "${var.project_name}-s3" })
}

data "aws_region" "current" {}

resource "aws_security_group" "web" {
  name        = "${var.project_name}-web"
  description = "HTTP and optional trusted SSH to the web instance."
  vpc_id      = aws_vpc.this.id
  egress      = []
  tags        = merge(var.tags, { Name = "${var.project_name}-web" })
}

resource "aws_vpc_security_group_ingress_rule" "web_http" {
  security_group_id = aws_security_group.web.id
  description       = "Public HTTP via Nginx."
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "web_ssh" {
  count = var.ssh_trusted_cidr == "" ? 0 : 1

  security_group_id = aws_security_group.web.id
  description       = "SSH from the configured trusted CIDR."
  cidr_ipv4         = var.ssh_trusted_cidr
  from_port         = 22
  ip_protocol       = "tcp"
  to_port           = 22
}

resource "aws_vpc_security_group_egress_rule" "web_all" {
  security_group_id = aws_security_group.web.id
  description       = "Outbound traffic for package/artifact retrieval and database access."
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "endpoints" {
  name        = "${var.project_name}-endpoints"
  description = "HTTPS ingress to private AWS service endpoints from the database."
  vpc_id      = aws_vpc.this.id
  egress      = []
  tags        = merge(var.tags, { Name = "${var.project_name}-endpoints" })
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id            = aws_security_group.endpoints.id
  description                  = "HTTPS from the database instance to private AWS APIs."
  referenced_security_group_id = aws_security_group.database.id
  from_port                    = 443
  ip_protocol                  = "tcp"
  to_port                      = 443
}

resource "aws_vpc_endpoint" "private_apis" {
  for_each = toset(["ssm", "ssmmessages", "ec2messages", "secretsmanager"])

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  tags                = merge(var.tags, { Name = "${var.project_name}-${each.key}" })
}

resource "aws_security_group" "database" {
  name        = "${var.project_name}-database"
  description = "MySQL ingress is restricted to the web security group."
  vpc_id      = aws_vpc.this.id
  egress      = []
  tags        = merge(var.tags, { Name = "${var.project_name}-database" })
}

resource "aws_vpc_security_group_ingress_rule" "database_mysql" {
  security_group_id            = aws_security_group.database.id
  description                  = "MySQL only from the web instance security group."
  referenced_security_group_id = aws_security_group.web.id
  from_port                    = 3306
  ip_protocol                  = "tcp"
  to_port                      = 3306
}

resource "aws_vpc_security_group_egress_rule" "database_s3" {
  security_group_id = aws_security_group.database.id
  description       = "HTTPS to S3 through the private S3 gateway endpoint."
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id
  from_port         = 443
  ip_protocol       = "tcp"
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "database_private_apis" {
  security_group_id            = aws_security_group.database.id
  description                  = "HTTPS to the required private AWS service endpoints."
  referenced_security_group_id = aws_security_group.endpoints.id
  from_port                    = 443
  ip_protocol                  = "tcp"
  to_port                      = 443
}
