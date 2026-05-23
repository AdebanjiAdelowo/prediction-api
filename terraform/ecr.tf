# ── Amazon ECR ────────────────────────────────────────────────────────────────
# The GitHub Actions CI/CD pipeline builds the Docker image and pushes it here.
# The EC2 instance pulls from this repository at startup.

resource "aws_ecr_repository" "api" {
  name                 = var.project_name
  image_tag_mutability = "MUTABLE"   # allows re-tagging :latest on each push

  # Automatically scan new images for known CVEs.
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  # Allows `terraform destroy` to remove the repo even if images are present.
  # Remove this if you want to protect images from accidental deletion.
  force_delete = true
}

# Keep the last 10 images; expire anything older to control storage costs.
resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire images beyond the 10 most recent"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}
