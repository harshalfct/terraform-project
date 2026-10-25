resource "aws_iam_role" "database" {
  name = "${var.project_name}-database"
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
  role       = aws_iam_role.database.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "bootstrap" {
  name = "${var.project_name}-database-bootstrap"
  role = aws_iam_role.database.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue"]
        Resource = var.secret_arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "database" {
  name = "${var.project_name}-database"
  role = aws_iam_role.database.name
  tags = var.tags
}

resource "aws_instance" "this" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [var.security_group_id]
  iam_instance_profile        = aws_iam_instance_profile.database.name
  associate_public_ip_address = false
  user_data_replace_on_change = false
  user_data = templatefile("${path.module}/templates/mysql-bootstrap.sh.tftpl", {
    aws_region    = var.aws_region
    secret_arn    = var.secret_arn
    database_name = var.database_name
    database_user = var.database_user
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

  tags = merge(var.tags, { Name = "${var.project_name}-database" })

  depends_on = [
    aws_iam_role_policy_attachment.ssm,
    aws_iam_role_policy.bootstrap,
  ]

  lifecycle {
    prevent_destroy = true
  }
}
