#!/bin/sh
# bootstrap_new_deploy_ci.sh — Wire up a GitHub repo + AWS account to this project's deploy pipeline.
#
# Usage: bootstrap_new_deploy_ci.sh <github_owner/repo> <project_name> [<aws_region>]
#
#   <github_owner/repo>  GitHub repo to scope the OIDC trust policy to (e.g., zazer0/temp-shrouded-inference)
#   <project_name>       AWS resource namespace (e.g., shrouded-inference). Must match [a-z0-9-]+.
#   [<aws_region>]       Optional, default us-west-2.
#
# This script is idempotent: CDK deploy is a no-op if nothing changed; gh secret set overwrites.

set -eu

# ---------------------------------------------------------------------------
# Resolve REPO_ROOT relative to this script's location
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  printf 'Usage: %s <github_owner/repo> <project_name> [<aws_region>]\n' "$0" >&2
  exit 1
fi

GITHUB_REPO="$1"
PROJECT_NAME="$2"
AWS_REGION="${3:-us-west-2}"

# Validate GITHUB_REPO contains a slash
case "$GITHUB_REPO" in
  */*) ;;
  *)
    printf 'Error: <github_owner/repo> must contain a slash (e.g., zazer0/my-repo). Got: %s\n' "$GITHUB_REPO" >&2
    exit 1
    ;;
esac

# Validate PROJECT_NAME matches [a-z0-9-]+
case "$PROJECT_NAME" in
  *[!a-z0-9-]*)
    printf 'Error: <project_name> must match [a-z0-9-]+. Got: %s\n' "$PROJECT_NAME" >&2
    exit 1
    ;;
  '')
    printf 'Error: <project_name> must not be empty.\n' >&2
    exit 1
    ;;
esac

printf 'Bootstrap starting...\n'
printf '  GitHub repo:  %s\n' "$GITHUB_REPO"
printf '  Project name: %s\n' "$PROJECT_NAME"
printf '  AWS region:   %s\n' "$AWS_REGION"
printf '\n'

# ---------------------------------------------------------------------------
# Step 1 — Write projectName into infra/cdk.json via jq
# ---------------------------------------------------------------------------
CDK_JSON="$REPO_ROOT/infra/cdk.json"

if [ ! -f "$CDK_JSON" ]; then
  printf 'Error: %s not found. Is REPO_ROOT correct? (%s)\n' "$CDK_JSON" "$REPO_ROOT" >&2
  exit 1
fi

printf 'Writing projectName="%s" to %s...\n' "$PROJECT_NAME" "$CDK_JSON"

CDK_JSON_TMP="${CDK_JSON}.bootstrap_tmp"
jq --arg name "$PROJECT_NAME" '.context.projectName = $name' "$CDK_JSON" > "$CDK_JSON_TMP" \
  && mv "$CDK_JSON_TMP" "$CDK_JSON"

printf 'cdk.json updated.\n\n'

# ---------------------------------------------------------------------------
# Step 2 — Derive PascalCase stack name
# ---------------------------------------------------------------------------
PASCAL_PROJECT="$(printf '%s' "$PROJECT_NAME" \
  | awk -F- '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1' OFS='')"
STACK_NAME="${PASCAL_PROJECT}GithubOidcStack"

printf 'Derived stack name: %s\n\n' "$STACK_NAME"

# ---------------------------------------------------------------------------
# Step 3 — Deploy the OIDC stack
# ---------------------------------------------------------------------------
printf 'Deploying %s...\n' "$STACK_NAME"

cd "$REPO_ROOT/infra"
npx cdk deploy "$STACK_NAME" \
  --context githubRepo="$GITHUB_REPO" \
  --context projectName="$PROJECT_NAME" \
  --require-approval never

printf '\nCDK deploy complete.\n\n'

# ---------------------------------------------------------------------------
# Step 4 — Read DeployRoleArn from CloudFormation outputs
# ---------------------------------------------------------------------------
printf 'Reading DeployRoleArn from CloudFormation stack outputs...\n'

# Derive the CloudFormation stack name CDK uses: it is the CDK stack ID (same as STACK_NAME here)
# CDK names the CF stack as <stackId> when no env prefix is present.
# Query all outputs as JSON and extract DeployRoleArn with jq to avoid JMESPath backtick
# literals, which shellcheck SC2016 flags as potential unintended expansions.
DEPLOY_ROLE_ARN="$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$AWS_REGION" \
  --query "Stacks[0].Outputs" \
  --output json \
  | jq -r '.[] | select(.OutputKey=="DeployRoleArn") | .OutputValue')"

# ---------------------------------------------------------------------------
# Step 5 — Validate the ARN
# ---------------------------------------------------------------------------
if [ -z "$DEPLOY_ROLE_ARN" ]; then
  printf 'Error: DeployRoleArn output not found in stack %s. Check the CDK stack definition.\n' "$STACK_NAME" >&2
  exit 1
fi

printf 'DeployRoleArn: %s\n\n' "$DEPLOY_ROLE_ARN"

# ---------------------------------------------------------------------------
# Step 6 — Set the GitHub secret
# ---------------------------------------------------------------------------
printf 'Setting AWS_DEPLOY_ROLE_ARN secret on %s...\n' "$GITHUB_REPO"

printf '%s' "$DEPLOY_ROLE_ARN" | gh secret set AWS_DEPLOY_ROLE_ARN --repo "$GITHUB_REPO" --body -

printf 'Secret set.\n\n'

# ---------------------------------------------------------------------------
# Completion message + follow-up checklist
# ---------------------------------------------------------------------------
printf 'Bootstrap complete.\n'
printf '\n'
printf 'Role ARN:   %s\n' "$DEPLOY_ROLE_ARN"
printf 'GitHub repo: %s\n' "$GITHUB_REPO"
printf 'Secret set:  AWS_DEPLOY_ROLE_ARN on %s\n' "$GITHUB_REPO"
printf '\n'
printf 'Follow-up steps (one-time, if migrating from an existing pipeline):\n'
printf '  1. Trigger a push to main on %s — CI will deploy all stacks.\n' "$GITHUB_REPO"
printf '  2. If moving model artifacts: aws s3 sync s3://<old_bucket>/ s3://%s-model-artifacts-<account>/\n' "$PROJECT_NAME"
printf '  3. If migrating API keys: copy raw-api-keys secret to %s/raw-api-keys in Secrets Manager.\n' "$PROJECT_NAME"
