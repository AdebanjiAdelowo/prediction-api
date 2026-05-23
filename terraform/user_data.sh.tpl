#!/bin/bash
# EC2 bootstrap script rendered by Terraform templatefile().
# Runs once at first boot as root; output is logged to /var/log/user-data.log.
set -euo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "==> [1/4] Installing Docker"
dnf install -y docker
systemctl enable --now docker
# Allow ec2-user to run Docker without sudo (effective after next login).
usermod -aG docker ec2-user

echo "==> [2/4] Authenticating with ECR (${aws_region})"
aws ecr get-login-password --region "${aws_region}" \
  | docker login \
      --username AWS \
      --password-stdin \
      "${account_id}.dkr.ecr.${aws_region}.amazonaws.com"

echo "==> [3/4] Pulling image: ${ecr_image_uri}"
docker pull "${ecr_image_uri}"

echo "==> [4/4] Starting prediction-api container"
docker run \
  --detach \
  --name prediction-api \
  --restart unless-stopped \
  --publish 8000:8000 \
  --env DATABASE_URL="${database_url}" \
  --env MODEL_VERSION="${model_version}" \
  --env MODEL_PATH="/app/model.pt" \
  --log-driver awslogs \
  --log-opt awslogs-region="${aws_region}" \
  --log-opt awslogs-group="/prediction-api" \
  --log-opt awslogs-create-group=true \
  "${ecr_image_uri}"

echo "==> Done. API available at http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):8000"
