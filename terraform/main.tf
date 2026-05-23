terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      # Used to fetch the OIDC provider thumbprint for GitHub Actions.
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Uncomment to store state remotely (recommended for teams):
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "prediction-api/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-locks"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# ── Data sources ──────────────────────────────────────────────────────────────

# Current AWS account ID — used to build resource ARNs.
data "aws_caller_identity" "current" {}

# Use the account's default VPC to avoid having to create one.
data "aws_vpc" "default" {
  default = true
}

# All subnets in the default VPC.
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Latest Amazon Linux 2023 AMI — avoids hard-coding AMI IDs that differ per
# region and go stale over time.
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
