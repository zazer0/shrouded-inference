#!/bin/sh
# bootstrap_api_keys.sh — Generate API keys and populate Secrets Manager.
#
# Usage:
#   bootstrap_api_keys.sh [<aws_region>]
#
#   <aws_region>   Optional, default us-west-2
#
# Environment variables (optional — set by bootstrap_new_deploy_ci.sh):
#   BOOTSTRAP_PROJECT_NAME  — project name already written to cdk.json,
#                             e.g. shrouded-inference
#
# If BOOTSTRAP_PROJECT_NAME is not set, the script derives it from infra/cdk.json.
#
# Idempotent: if raw-api-keys is already fully populated and api-keys is valid
# JSON, the script exits 0 without modifying anything.

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
# Print header
# ---------------------------------------------------------------------------
printf 'API key bootstrap starting...\n'
printf '  Project: %s\n' "$PROJECT_NAME"
printf '  Region:  %s\n' "$AWS_REGION"
printf '\n'

# ---------------------------------------------------------------------------
# Resolve AWS account
# ---------------------------------------------------------------------------
caller_json="$(aws sts get-caller-identity --output json)"
caller_rc=$?
if [ "$caller_rc" -ne 0 ]; then
  printf 'Error: aws sts get-caller-identity failed (rc=%s).\n' "$caller_rc" >&2
  exit 1
fi

ACCOUNT="$(printf '%s' "$caller_json" | jq -r '.Account')"
if [ -z "$ACCOUNT" ] || [ "$ACCOUNT" = "null" ]; then
  printf 'Error: could not parse Account from get-caller-identity output.\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Resolve API_KEYS_ARN — api-keys secret must exist (SecretsStack deploys it)
# ---------------------------------------------------------------------------
api_keys_out="$(aws secretsmanager describe-secret \
  --secret-id "${PROJECT_NAME}/api-keys" \
  --region "$AWS_REGION" \
  --output json)"
api_keys_rc=$?
if [ "$api_keys_rc" -ne 0 ]; then
  printf 'Error: %s/api-keys secret not found. SecretsStack must be deployed first.\n' \
    "$PROJECT_NAME" >&2
  exit 1
fi

API_KEYS_ARN="$(printf '%s' "$api_keys_out" | jq -r '.ARN')"
if [ -z "$API_KEYS_ARN" ] || [ "$API_KEYS_ARN" = "null" ]; then
  printf 'Error: could not parse ARN from describe-secret output.\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Idempotence check — attempt to read raw-api-keys
# ---------------------------------------------------------------------------
raw_err_out="$(aws secretsmanager get-secret-value \
  --secret-id "${PROJECT_NAME}/raw-api-keys" \
  --region "$AWS_REGION" \
  --output json 2>&1)"
raw_rc=$?

RAW_SECRET_EXISTS=1

if [ "$raw_rc" -eq 0 ]; then
  # Secret exists — check if small and large are both populated
  raw_small="$(printf '%s' "$raw_err_out" | jq -r '.SecretString | fromjson | .small // empty')"
  raw_large="$(printf '%s' "$raw_err_out" | jq -r '.SecretString | fromjson | .large // empty')"

  if [ -n "$raw_small" ] && [ -n "$raw_large" ]; then
    printf 'raw-api-keys already populated; skipping key generation.\n'

    # Check if api-keys is also valid JSON (not a placeholder)
    existing_api_out="$(aws secretsmanager get-secret-value \
      --secret-id "$API_KEYS_ARN" \
      --region "$AWS_REGION" \
      --query SecretString \
      --output text)"
    existing_api_rc=$?

    if [ "$existing_api_rc" -eq 0 ]; then
      # Validate it is a JSON object (not the 32-char placeholder)
      printf '%s' "$existing_api_out" | jq -e 'type == "object"' > /dev/null
      obj_rc=$?
      if [ "$obj_rc" -eq 0 ]; then
        printf 'api-keys already contains valid JSON; nothing to do.\n'
        printf '\n'
        printf 'API keys are fully configured.\n'
        printf '  Retrieve keys anytime with: sh scripts/print_apikeys.sh\n'
        exit 0
      fi
      printf 'api-keys contains a placeholder; will rewrite hashes from existing raw keys.\n'
    fi

    # api-keys needs writing — derive from the already-present raw keys
    SMALL="$raw_small"
    LARGE="$raw_large"

    ALL="$(uv run python -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode('utf-8')).hexdigest())" "${SMALL}|${LARGE}")"
    all_rc=$?
    if [ "$all_rc" -ne 0 ]; then
      printf 'Error: uv failed to derive all key.\n' >&2
      exit 1
    fi

    # Skip to hash-and-write section
    SKIP_KEY_GENERATION=1
  elif [ -n "$raw_small" ] && [ -z "$raw_large" ]; then
    printf 'Error: %s/raw-api-keys is partially populated (has small but not large). Fix manually before re-running.\n' \
      "$PROJECT_NAME" >&2
    exit 1
  elif [ -z "$raw_small" ] && [ -n "$raw_large" ]; then
    printf 'Error: %s/raw-api-keys is partially populated (has large but not small). Fix manually before re-running.\n' \
      "$PROJECT_NAME" >&2
    exit 1
  else
    # Neither present — fall through to generation
    printf 'raw-api-keys exists but is empty; generating fresh keys.\n'
    SKIP_KEY_GENERATION=0
  fi
else
  # get-secret-value failed — distinguish ResourceNotFoundException vs other errors
  if printf '%s' "$raw_err_out" | grep -q 'ResourceNotFoundException'; then
    RAW_SECRET_EXISTS=0
    SKIP_KEY_GENERATION=0
  else
    printf 'Error: unexpected failure reading %s/raw-api-keys:\n' "$PROJECT_NAME" >&2
    printf '%s\n' "$raw_err_out" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Generate fresh keys (skipped if raw-api-keys already had both tiers)
# ---------------------------------------------------------------------------
if [ "${SKIP_KEY_GENERATION:-0}" -eq 0 ]; then
  SMALL="$(uv run python -c 'import secrets; print(secrets.token_urlsafe(32))')"
  small_rc=$?
  if [ "$small_rc" -ne 0 ]; then
    printf 'Error: uv failed to generate small key.\n' >&2
    exit 1
  fi

  LARGE="$(uv run python -c 'import secrets; print(secrets.token_urlsafe(32))')"
  large_rc=$?
  if [ "$large_rc" -ne 0 ]; then
    printf 'Error: uv failed to generate large key.\n' >&2
    exit 1
  fi

  # Derive the all-tier key — same formula as secrets-stack.ts:262:
  #   hashlib.sha256(f'{small}|{large}'.encode('utf-8')).hexdigest()
  ALL="$(uv run python -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode('utf-8')).hexdigest())" "${SMALL}|${LARGE}")"
  all_rc=$?
  if [ "$all_rc" -ne 0 ]; then
    printf 'Error: uv failed to derive all key.\n' >&2
    exit 1
  fi

  # Construct raw-api-keys JSON safely via jq
  raw_json="$(jq -n --arg s "$SMALL" --arg l "$LARGE" --arg a "$ALL" \
    '{small:$s, large:$l, all:$a}')"
  jq_rc=$?
  if [ "$jq_rc" -ne 0 ]; then
    printf 'Error: jq failed to construct raw-api-keys JSON.\n' >&2
    exit 1
  fi

  # Write raw-api-keys: create if it never existed, otherwise update
  if [ "$RAW_SECRET_EXISTS" -eq 0 ]; then
    printf 'Creating %s/raw-api-keys secret...\n' "$PROJECT_NAME"
    if ! aws secretsmanager create-secret \
        --name "${PROJECT_NAME}/raw-api-keys" \
        --region "$AWS_REGION" \
        --secret-string "$raw_json"; then
      printf 'Error: aws secretsmanager create-secret for raw-api-keys failed.\n' >&2
      exit 1
    fi
  else
    printf 'Updating %s/raw-api-keys secret...\n' "$PROJECT_NAME"
    if ! aws secretsmanager put-secret-value \
        --secret-id "${PROJECT_NAME}/raw-api-keys" \
        --region "$AWS_REGION" \
        --secret-string "$raw_json"; then
      printf 'Error: aws secretsmanager put-secret-value for raw-api-keys failed.\n' >&2
      exit 1
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Compute hashes for all three tiers
# ---------------------------------------------------------------------------
HASH_SMALL="$(uv run python -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "$SMALL")"
hs_rc=$?
if [ "$hs_rc" -ne 0 ]; then
  printf 'Error: uv failed to hash small key.\n' >&2
  exit 1
fi

HASH_LARGE="$(uv run python -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "$LARGE")"
hl_rc=$?
if [ "$hl_rc" -ne 0 ]; then
  printf 'Error: uv failed to hash large key.\n' >&2
  exit 1
fi

HASH_ALL="$(uv run python -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "$ALL")"
ha_rc=$?
if [ "$ha_rc" -ne 0 ]; then
  printf 'Error: uv failed to hash all key.\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Construct api-keys JSON via jq
# ---------------------------------------------------------------------------
api_json="$(jq -n \
  --arg hs "$HASH_SMALL" --arg hl "$HASH_LARGE" --arg ha "$HASH_ALL" \
  '{($hs): {tier:"small"}, ($hl): {tier:"large"}, ($ha): {tier:"all"}}')"
jq_rc=$?
if [ "$jq_rc" -ne 0 ]; then
  printf 'Error: jq failed to construct api-keys JSON.\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Write api-keys
# ---------------------------------------------------------------------------
printf 'Writing hash entries to %s/api-keys...\n' "$PROJECT_NAME"
if ! aws secretsmanager put-secret-value \
    --secret-id "$API_KEYS_ARN" \
    --region "$AWS_REGION" \
    --secret-string "$api_json"; then
  printf 'Error: aws secretsmanager put-secret-value for api-keys failed.\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Completion
# ---------------------------------------------------------------------------
printf '\n'
printf 'API keys bootstrapped successfully.\n'
printf '  raw-api-keys: 3 tiers written (small, large, all)\n'
printf '  api-keys:     3 hash entries written\n'
printf '\n'
printf 'Retrieve keys anytime with: sh scripts/print_apikeys.sh\n'
