#!/bin/sh
# bootstrap_new_deploy_ci.sh — Wire up a GitHub repo + AWS account to this project's deploy pipeline.
#
# Usage:
#   bootstrap_new_deploy_ci.sh <project_name> [<aws_region>]
#   bootstrap_new_deploy_ci.sh <github_owner/repo> <project_name> [<aws_region>]
#
#   <github_owner/repo>  Optional. GitHub repo to scope the OIDC trust policy to
#                        (e.g., zazer0/temp-shrouded-inference). If omitted, it
#                        is auto-detected from .git/config (origin remote) and
#                        then `gh repo view` as a fallback.
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
# Argument parsing — github_owner/repo is optional and auto-detected
# ---------------------------------------------------------------------------
# Forms:
#   bootstrap_new_deploy_ci.sh <project_name> [<aws_region>]
#   bootstrap_new_deploy_ci.sh <github_owner/repo> <project_name> [<aws_region>]
# Disambiguated by whether arg1 contains a `/`.
if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  printf 'Usage: %s <project_name> [<aws_region>]\n' "$0" >&2
  printf '       %s <github_owner/repo> <project_name> [<aws_region>]\n' "$0" >&2
  exit 1
fi

case "$1" in
  */*)
    GITHUB_REPO="$1"
    PROJECT_NAME="${2:-}"
    AWS_REGION="${3:-us-west-2}"
    ;;
  *)
    GITHUB_REPO=""
    PROJECT_NAME="$1"
    AWS_REGION="${2:-us-west-2}"
    ;;
esac

if [ -z "$PROJECT_NAME" ]; then
  printf 'Error: <project_name> is required.\n' >&2
  exit 1
fi

# Validate PROJECT_NAME matches [a-z0-9-]+
case "$PROJECT_NAME" in
  *[!a-z0-9-]*)
    printf 'Error: <project_name> must match [a-z0-9-]+. Got: %s\n' "$PROJECT_NAME" >&2
    exit 1
    ;;
esac

# Autodetect github_owner/repo if not provided.
if [ -z "$GITHUB_REPO" ]; then
  # 1) Parse .git/config for the origin remote URL.
  if [ -f "$REPO_ROOT/.git/config" ]; then
    origin_url="$(awk '
      /^\[remote "origin"\]/ {in_section=1; next}
      /^\[/                  {in_section=0}
      in_section && $1=="url" {print $3; exit}
    ' "$REPO_ROOT/.git/config")"
    case "$origin_url" in
      git@github.com:*)
        GITHUB_REPO="${origin_url#git@github.com:}"
        GITHUB_REPO="${GITHUB_REPO%.git}"
        ;;
      https://github.com/*)
        GITHUB_REPO="${origin_url#https://github.com/}"
        GITHUB_REPO="${GITHUB_REPO%.git}"
        ;;
      ssh://git@github.com/*)
        GITHUB_REPO="${origin_url#ssh://git@github.com/}"
        GITHUB_REPO="${GITHUB_REPO%.git}"
        ;;
    esac
  fi

  # 2) Fall back to `gh` CLI.
  if [ -z "$GITHUB_REPO" ] && command -v gh >/dev/null 2>&1; then
    GITHUB_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  fi

  # 3) Give up — require the user to pass it.
  if [ -z "$GITHUB_REPO" ]; then
    printf 'Error: could not auto-detect <github_owner/repo>.\n' >&2
    printf '       Tried: .git/config (origin remote), then "gh repo view".\n' >&2
    printf '       Pass it as the first arg.\n' >&2
    exit 1
  fi

  printf 'Auto-detected GitHub repo: %s\n' "$GITHUB_REPO"
fi

# Validate GITHUB_REPO contains a slash (handles bad autodetect or bad explicit input)
case "$GITHUB_REPO" in
  */*) ;;
  *)
    printf 'Error: <github_owner/repo> must contain a slash. Got: %s\n' "$GITHUB_REPO" >&2
    exit 1
    ;;
esac

# Force CDK and AWS CLI to agree on region. Without these exports CDK reads
# CDK_DEFAULT_REGION from the caller's shell (often diverging from AWS_REGION),
# while Step 4's `describe-stacks --region "$AWS_REGION"` looks elsewhere ->
# silent split-region failures.
export AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"
export CDK_DEFAULT_REGION="$AWS_REGION"

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
# Step 2 — Derive the two distinct names CDK vs CloudFormation each need
# ---------------------------------------------------------------------------
# `cdk deploy <id>` matches by *construct id* — the first arg passed to
# `new GithubOidcStack(app, '<id>', ...)` in infra/bin/infra.ts. In prod
# (the only env this script supports) that id is the literal "GithubOidcStack".
CDK_STACK_ID="GithubOidcStack"

# `aws cloudformation describe-stacks --stack-name <n>` wants the *physical*
# stack name from the stack's `stackName` prop, which infra.ts builds as
# `${pascalProjectName}GithubOidcStack`.
PASCAL_PROJECT="$(printf '%s' "$PROJECT_NAME" \
  | awk -F- '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1' OFS='')"
CFN_STACK_NAME="${PASCAL_PROJECT}GithubOidcStack"

printf 'CDK construct id (for cdk deploy):     %s\n' "$CDK_STACK_ID"
printf 'CFN stack name  (for describe-stacks): %s\n\n' "$CFN_STACK_NAME"

# ---------------------------------------------------------------------------
# Step 3 — Deploy the OIDC stack (matched by CDK construct id, not CFN name)
# ---------------------------------------------------------------------------
printf 'Deploying construct %s (CFN stack: %s) in %s...\n' \
  "$CDK_STACK_ID" "$CFN_STACK_NAME" "$AWS_REGION"

cd "$REPO_ROOT/infra"
npx cdk deploy "$CDK_STACK_ID" \
  --context githubRepo="$GITHUB_REPO" \
  --context projectName="$PROJECT_NAME" \
  --require-approval never

printf '\nCDK deploy complete.\n\n'

# ---------------------------------------------------------------------------
# Step 4 — Read DeployRoleArn from CloudFormation outputs
# ---------------------------------------------------------------------------
printf 'Reading DeployRoleArn from CloudFormation stack outputs...\n'

# Query all outputs as JSON and extract DeployRoleArn with jq to avoid JMESPath backtick
# literals, which shellcheck SC2016 flags as potential unintended expansions.
DEPLOY_ROLE_ARN="$(aws cloudformation describe-stacks \
  --stack-name "$CFN_STACK_NAME" \
  --region "$AWS_REGION" \
  --query "Stacks[0].Outputs" \
  --output json \
  | jq -r '.[] | select(.OutputKey=="DeployRoleArn") | .OutputValue')"

# ---------------------------------------------------------------------------
# Step 5 — Validate the ARN
# ---------------------------------------------------------------------------
if [ -z "$DEPLOY_ROLE_ARN" ]; then
  printf 'Error: DeployRoleArn output not found in stack %s. Check the CDK stack definition.\n' "$CFN_STACK_NAME" >&2
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
