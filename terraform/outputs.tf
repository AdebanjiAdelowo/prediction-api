output "ecr_repository_url" {
  description = "ECR repository URL. Set ECR_REPO in the deploy workflow to the last path segment."
  value       = aws_ecr_repository.api.repository_url
}

output "ec2_public_ip" {
  description = "Public IP address of the EC2 instance."
  value       = aws_instance.api.public_ip
}

output "ec2_public_dns" {
  description = "Public DNS hostname of the EC2 instance."
  value       = aws_instance.api.public_dns
}

output "api_url" {
  description = "Direct URL to reach the running API (after user_data completes)."
  value       = "http://${aws_instance.api.public_ip}:8000"
}

output "api_health_url" {
  description = "Health-check endpoint."
  value       = "http://${aws_instance.api.public_ip}:8000/health"
}

output "s3_models_bucket" {
  description = "S3 bucket name for model artefact storage."
  value       = aws_s3_bucket.models.bucket
}

output "github_actions_role_arn" {
  description = <<-EOT
    IAM Role ARN for GitHub Actions OIDC.
    Add this as repository secret AWS_ROLE_ARN in GitHub → Settings → Secrets.
  EOT
  value = aws_iam_role.github_actions.arn
}

output "ssh_command" {
  description = "SSH command to connect to the instance (requires key_name to be set)."
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_instance.api.public_ip}"
}
