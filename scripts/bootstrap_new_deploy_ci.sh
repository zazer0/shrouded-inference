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
  if [ -z "$GITHUB_REPO" ] && command -v gh >/dev/null; then
    gh_out="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
    gh_rc=$?
    if [ "$gh_rc" -eq 0 ]; then
      GITHUB_REPO="$gh_out"
    fi
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
if ! jq --arg name "$PROJECT_NAME" '.context.projectName = $name' "$CDK_JSON" > "$CDK_JSON_TMP"; then
  printf 'Error: jq failed to update %s.\n' "$CDK_JSON" >&2
  exit 1
fi
if ! mv "$CDK_JSON_TMP" "$CDK_JSON"; then
  printf 'Error: could not replace %s with updated version.\n' "$CDK_JSON" >&2
  exit 1
fi

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

cd "$REPO_ROOT/infra" || exit 1
if ! npx cdk deploy "$CDK_STACK_ID" \
  --context githubRepo="$GITHUB_REPO" \
  --context projectName="$PROJECT_NAME" \
  --require-approval never; then
  printf 'Error: cdk deploy %s failed.\n' "$CDK_STACK_ID" >&2
  exit 1
fi

printf '\nCDK deploy complete.\n\n'

# ---------------------------------------------------------------------------
# Step 4 — Read DeployRoleArn from CloudFormation outputs
# ---------------------------------------------------------------------------
printf 'Reading DeployRoleArn from CloudFormation stack outputs...\n'

# Query all outputs as JSON and extract DeployRoleArn with jq to avoid JMESPath backtick
# literals, which shellcheck SC2016 flags as potential unintended expansions.
# Split into two steps so each command's exit code can be checked independently.
CFN_OUTPUTS_JSON="$(aws cloudformation describe-stacks \
  --stack-name "$CFN_STACK_NAME" \
  --region "$AWS_REGION" \
  --query "Stacks[0].Outputs" \
  --output json)"
cfn_rc=$?
if [ "$cfn_rc" -ne 0 ]; then
  printf 'Error: aws cloudformation describe-stacks failed (rc=%s).\n' "$cfn_rc" >&2
  exit 1
fi

DEPLOY_ROLE_ARN="$(printf '%s' "$CFN_OUTPUTS_JSON" \
  | jq -r '.[] | select(.OutputKey=="DeployRoleArn") | .OutputValue')"
jq_rc=$?
if [ "$jq_rc" -ne 0 ]; then
  printf 'Error: jq failed to parse CloudFormation outputs (rc=%s).\n' "$jq_rc" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 5 — Validate the ARN
# ---------------------------------------------------------------------------
if [ -z "$DEPLOY_ROLE_ARN" ]; then
  printf 'Error: DeployRoleArn output not found in stack %s. Check the CDK stack definition.\n' "$CFN_STACK_NAME" >&2
  exit 1
fi

case "$DEPLOY_ROLE_ARN" in
  arn:aws:iam::*:role/*) ;;
  *)
    printf 'Error: DeployRoleArn output is not a full IAM role ARN: %s\n' "$DEPLOY_ROLE_ARN" >&2
    printf '       Expected pattern: arn:aws:iam::<account>:role/<name>\n' >&2
    printf '       Refusing to set GitHub secret with a non-ARN value.\n' >&2
    exit 1
    ;;
esac

printf 'DeployRoleArn: |%s|\n\n' "$DEPLOY_ROLE_ARN"

# ---------------------------------------------------------------------------
# Step 6 — Set the GitHub secret
# ---------------------------------------------------------------------------
printf 'Setting AWS_DEPLOY_ROLE_ARN secret on %s...\n' "$GITHUB_REPO"

if ! gh secret set AWS_DEPLOY_ROLE_ARN --repo "$GITHUB_REPO" --body "$DEPLOY_ROLE_ARN"; then
  printf 'Error: gh secret set failed.\n' >&2
  exit 1
fi

printf 'Secret set.\n\n'

# ---------------------------------------------------------------------------
# Step 7 — Seed model artifacts
# ---------------------------------------------------------------------------
printf 'Seeding model artifacts into S3...\n'

export BOOTSTRAP_GITHUB_REPO="$GITHUB_REPO"
export BOOTSTRAP_PROJECT_NAME="$PROJECT_NAME"

if ! sh "$REPO_ROOT/scripts/first_time_setup_models.sh" "$AWS_REGION"; then
  printf 'Error: model seeding failed. Resolve the error above, then re-run:\n' >&2
  printf '  sh scripts/first_time_setup_models.sh %s\n' "$AWS_REGION" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 8 — Bootstrap API keys (idempotent)
# ---------------------------------------------------------------------------
printf 'Bootstrapping API keys in Secrets Manager...\n'

if ! sh "$REPO_ROOT/scripts/bootstrap_api_keys.sh" "$AWS_REGION"; then
  printf 'Error: API key bootstrap failed. Resolve the error above, then re-run:\n' >&2
  printf '  sh scripts/bootstrap_api_keys.sh %s\n' "$AWS_REGION" >&2
  exit 1
fi

printf 'API keys bootstrapped.\n\n'

# ---------------------------------------------------------------------------
# Completion message + follow-up checklist
# ---------------------------------------------------------------------------
printf 'Bootstrap complete.\n'
printf '\n'
printf 'Role ARN:    %s\n' "$DEPLOY_ROLE_ARN"
printf 'GitHub repo: %s\n' "$GITHUB_REPO"
printf 'Secret set:  AWS_DEPLOY_ROLE_ARN on %s\n' "$GITHUB_REPO"
printf 'Artifacts:   graphsage + equiformer seeded into S3\n'
printf 'API keys:    3 tiers bootstrapped in Secrets Manager\n'
printf '\n'
printf 'Follow-up steps (one-time, if migrating from an existing pipeline):\n'
printf '  1. Trigger a push to main on %s — CI will deploy all stacks.\n' "$GITHUB_REPO"
printf '  2. Retrieve your API keys: sh scripts/print_apikeys.sh\n'
