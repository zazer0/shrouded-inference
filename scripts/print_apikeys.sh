#!/bin/sh
# print_apikeys.sh — Print raw API keys from Secrets Manager in a table.
#
# Usage:
#   print_apikeys.sh [<aws_region>]
#
#   <aws_region>   Optional, default us-west-2
#
# Environment variables (optional — set by bootstrap_new_deploy_ci.sh):
#   BOOTSTRAP_PROJECT_NAME  — project name, e.g. shrouded-inference
#
# If BOOTSTRAP_PROJECT_NAME is not set, the script derives it from infra/cdk.json.

# ---------------------------------------------------------------------------
# Resolve REPO_ROOT relative to this script's location
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
AWS_REGION="us-west-2"

if [ "$#" -ge 1 ]; then
  AWS_REGION="$1"
fi

export AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"
export CDK_DEFAULT_REGION="$AWS_REGION"

# ---------------------------------------------------------------------------
# Derive PROJECT_NAME
# ---------------------------------------------------------------------------
if [ -n "$BOOTSTRAP_PROJECT_NAME" ]; then
  PROJECT_NAME="$BOOTSTRAP_PROJECT_NAME"
else
  PROJECT_NAME="$(awk -F'"' '/"projectName"/ { print $4; exit }' "$REPO_ROOT/infra/cdk.json")"
fi

if [ -z "$PROJECT_NAME" ]; then
  printf 'Error: could not determine projectName from infra/cdk.json.\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Fetch raw-api-keys
# ---------------------------------------------------------------------------
secret_out="$(aws secretsmanager get-secret-value \
  --secret-id "${PROJECT_NAME}/raw-api-keys" \
  --region "$AWS_REGION" \
  --query SecretString \
  --output text)"
secret_rc=$?

if [ "$secret_rc" -ne 0 ]; then
  printf 'Error: %s/raw-api-keys not found. Run scripts/bootstrap_api_keys.sh first.\n' \
    "$PROJECT_NAME" >&2
  exit 1
fi

# Validate the result is a JSON object
printf '%s' "$secret_out" | jq -e 'type == "object"' > /dev/null
obj_rc=$?
if [ "$obj_rc" -ne 0 ]; then
  printf 'Error: %s/raw-api-keys does not contain a valid JSON object.\n' "$PROJECT_NAME" >&2
  printf 'Run scripts/bootstrap_api_keys.sh to (re)populate it.\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Print table
# ---------------------------------------------------------------------------
TAB="$(printf '\t')"
{
  printf '%s\n' "Tier${TAB}Key"
  printf '%s\n' "-----${TAB}---"
  printf '%s\n' "$secret_out" | jq -r \
    --arg t "$TAB" \
    '"small" + $t + .small, "large" + $t + .large, "all" + $t + .all'
} | column -t
