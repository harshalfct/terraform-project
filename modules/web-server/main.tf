resource "aws_iam_role" "web" {
  name = "${var.project_name}-web"
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.web.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "application" {
  name = "${var.project_name}-web-runtime"
  role = aws_iam_role.web.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = var.database_secret_arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${var.artifacts_bucket}/releases/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "web" {
  name = "${var.project_name}-web"
  role = aws_iam_role.web.name
  tags = var.tags
}

resource "aws_instance" "this" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [var.security_group_id]
  iam_instance_profile        = aws_iam_instance_profile.web.name
  associate_public_ip_address = true
  key_name                    = var.key_pair_name
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/web-bootstrap.sh.tftpl", {
    aws_region          = var.aws_region
    project_name        = var.project_name
    application_port    = var.application_port
    database_host       = var.database_host
    database_name       = var.database_name
    database_user       = var.database_user
    database_secret_arn = var.database_secret_arn
    artifacts_bucket    = var.artifacts_bucket
  })

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 20
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = merge(var.tags, { Name = "${var.project_name}-web" })

  depends_on = [
    aws_iam_role_policy_attachment.ssm,
    aws_iam_role_policy.application,
  ]
}
