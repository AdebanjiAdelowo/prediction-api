# ── S3 bucket for model artefacts ─────────────────────────────────────────────
# Stores model.pt files so you can roll back to a previous version without
# rebuilding the Docker image.  The EC2 instance role (ec2.tf) has s3:GetObject
# permission so the running container can download models at startup if needed.

resource "aws_s3_bucket" "models" {
  # Include the account ID to guarantee a globally unique bucket name.
  bucket = "${var.project_name}-models-${data.aws_caller_identity.current.account_id}"
}

# Versioning keeps every uploaded model.pt, enabling instant rollback.
resource "aws_s3_bucket_versioning" "models" {
  bucket = aws_s3_bucket.models.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt all objects at rest with AWS-managed keys.
resource "aws_s3_bucket_server_side_encryption_configuration" "models" {
  bucket = aws_s3_bucket.models.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true   # reduces KMS API call costs
  }
}

# Block all public access — models should never be publicly readable.
resource "aws_s3_bucket_public_access_block" "models" {
  bucket                  = aws_s3_bucket.models.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
