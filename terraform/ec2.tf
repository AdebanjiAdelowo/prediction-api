# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "api" {
  name        = "${var.project_name}-sg"
  description = "Allow inbound API traffic (8000) and optional SSH (22)"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Prediction API"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH — restrict to known IPs in production"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidrs
  }

  egress {
    description = "Allow all outbound (ECR pull, system updates, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-sg" }
}

# ── IAM Role for the EC2 instance ─────────────────────────────────────────────
# Grants least-privilege access: ECR pull + S3 model read + CloudWatch logs.
# No IAM user credentials are stored on the instance.

resource "aws_iam_role" "ec2" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ec2" {
  name = "${var.project_name}-ec2-policy"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        # GetAuthorizationToken is not resource-scoped.
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:DescribeImages",
        ]
        Resource = aws_ecr_repository.api.arn
      },
      {
        Sid    = "S3ModelRead"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.models.arn,
          "${aws_s3_bucket.models.arn}/*",
        ]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ── EC2 instance ──────────────────────────────────────────────────────────────

locals {
  ecr_image_uri = "${aws_ecr_repository.api.repository_url}:latest"
}

resource "aws_instance" "api" {
  ami           = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type

  # Place in the first available default subnet.
  subnet_id              = tolist(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids = [aws_security_group.api.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  # Pass null when no key is specified so AWS doesn't reject the request.
  key_name = var.key_name != "" ? var.key_name : null

  # Bootstrap script: install Docker, pull from ECR, start the container.
  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    aws_region    = var.aws_region
    account_id    = data.aws_caller_identity.current.account_id
    ecr_image_uri = local.ecr_image_uri
    database_url  = var.database_url
    model_version = var.model_version
  })

  # Replace the instance (and re-run user_data) when the launch config changes.
  user_data_replace_on_change = true

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    # Require IMDSv2 tokens — prevents SSRF-based credential theft.
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = { Name = var.project_name }
}
