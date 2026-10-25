locals {
  common_tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

module "networking" {
  source = "./modules/networking"

  project_name              = var.project_name
  vpc_cidr                  = var.vpc_cidr
  public_subnet_cidr        = var.public_subnet_cidr
  private_subnet_cidr       = var.private_subnet_cidr
  public_availability_zone  = var.public_availability_zone
  private_availability_zone = var.private_availability_zone
  ssh_trusted_cidr          = var.ssh_trusted_cidr
  tags                      = local.common_tags
}

resource "aws_s3_bucket" "deployment_artifacts" {
  bucket_prefix = "${var.project_name}-deploy-"
  force_destroy = false
  tags          = local.common_tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "deployment_artifacts" {
  bucket = aws_s3_bucket.deployment_artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "deployment_artifacts" {
  bucket = aws_s3_bucket.deployment_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "deployment_artifacts" {
  bucket                  = aws_s3_bucket.deployment_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_secretsmanager_secret" "database" {
  name                    = "${var.project_name}/mysql/application"
  description             = "Runtime credentials for the application MySQL account."
  recovery_window_in_days = 7
  tags                    = local.common_tags

  lifecycle {
    prevent_destroy = true
  }
}

module "database_server" {
  source = "./modules/database-server"

  project_name      = var.project_name
  aws_region        = var.aws_region
  ami_id            = var.database_ami_id
  instance_type     = var.database_instance_type
  subnet_id         = module.networking.private_subnet_id
  security_group_id = module.networking.database_security_group_id
  secret_arn        = aws_secretsmanager_secret.database.arn
  database_name     = var.application_database_name
  database_user     = var.application_database_user
  tags              = local.common_tags

  depends_on = [module.networking, aws_s3_bucket_public_access_block.deployment_artifacts]
}

module "web_server" {
  source = "./modules/web-server"

  project_name        = var.project_name
  aws_region          = var.aws_region
  ami_id              = data.aws_ami.ubuntu_2404.id
  instance_type       = var.web_instance_type
  subnet_id           = module.networking.public_subnet_id
  security_group_id   = module.networking.web_security_group_id
  key_pair_name       = var.key_pair_name
  database_host       = module.database_server.private_ip
  database_name       = var.application_database_name
  database_user       = var.application_database_user
  database_secret_arn = aws_secretsmanager_secret.database.arn
  artifacts_bucket    = aws_s3_bucket.deployment_artifacts.id
  application_port    = var.application_port
  tags                = local.common_tags

  depends_on = [module.database_server]
}
