variable "aws_region" {
  description = "AWS region to deploy all resources into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix applied to every resource name and the ECR repository."
  type        = string
  default     = "prediction-api"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "environment" {
  description = "Deployment environment tag (e.g. dev, staging, prod)."
  type        = string
  default     = "prod"
}

variable "instance_type" {
  description = "EC2 instance type for the API server."
  type        = string
  default     = "t3.small"
}

variable "key_name" {
  description = "Name of an existing EC2 Key Pair for SSH access. Leave empty to disable SSH."
  type        = string
  default     = ""
}

variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed to reach port 22. Restrict to your IP in production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "database_url" {
  description = <<-EOT
    PostgreSQL DSN injected into the container as DATABASE_URL.
    Example: postgresql://user:pass@your-rds-endpoint:5432/predictions
    If empty, the API starts without database logging (predictions still work).
  EOT
  type      = string
  default   = ""
  sensitive = true
}

variable "model_version" {
  description = "Semantic version string reported by the /health endpoint."
  type        = string
  default     = "1.0.0"
}

variable "github_owner" {
  description = "GitHub username or organisation that owns the repository (for OIDC trust policy)."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (for OIDC trust policy)."
  type        = string
  default     = "prediction-api"
}
