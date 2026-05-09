#!/usr/bin/env bash
set -e

# Optional first arg: env name (default "prod"). Non-prod envs suffix repo names
# with "-<env>" so ephemeral environments (e.g. pr-42) don't clobber prod images.
ENV="${1:-prod}"
if [ "$ENV" = "prod" ]; then
  SUFFIX=""
else
  SUFFIX="-$ENV"
fi

ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
REGION="us-west-2"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
# 763104351884 is AWS's public Deep Learning Container registry — not our account
DLC_REGISTRY="763104351884.dkr.ecr.${REGION}.amazonaws.com"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Authenticate with our ECR
aws ecr get-login-password --region "${REGION}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# Authenticate with DLC ECR (for base images)
aws ecr get-login-password --region "${REGION}" | docker login --username AWS --password-stdin "${DLC_REGISTRY}"

# Build with latest tag, also tag with the provided tag, then push both.
# Args: context_dir repo_name tag
build_and_push() {
  context_dir="$1"
  repo_name="$2"
  tag="$3"

  docker build --provenance=false -t "${ECR_REGISTRY}/${repo_name}:latest" "${context_dir}"
  docker tag "${ECR_REGISTRY}/${repo_name}:latest" "${ECR_REGISTRY}/${repo_name}:${tag}"
  docker push "${ECR_REGISTRY}/${repo_name}:latest"
  docker push "${ECR_REGISTRY}/${repo_name}:${tag}"
}

# Day 1 builds
build_and_push "${REPO_ROOT}/models/graphsage" "graphsage-inference${SUFFIX}" "$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
build_and_push "${REPO_ROOT}/dispatcher" "dispatcher${SUFFIX}" "$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"

# Day 2 builds
build_and_push "${REPO_ROOT}/models/equiformer" "equiformer-inference${SUFFIX}" "$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
