#!/bin/sh
# first_time_setup_models.sh — Seed SageMaker model artifacts into this project's S3 bucket.
#
# Usage:
#   first_time_setup_models.sh [<aws_region>]
#   first_time_setup_models.sh --skip-equiformer [<aws_region>]
#
#   <aws_region>        Optional, default us-west-2
#   --skip-equiformer   Upload graphsage only; equiformer endpoint runs in
#                       degraded mode (graceful fallback built into inference.py)
#
# Environment variables (optional — set by bootstrap_new_deploy_ci.sh):
#   BOOTSTRAP_GITHUB_REPO    — owner/repo, e.g. zazer0/temp-shrouded-inference
#   BOOTSTRAP_PROJECT_NAME   — project name already written to cdk.json, e.g. shrouded-inference
#
# If those env vars are not set, the script derives them itself.

# ---------------------------------------------------------------------------
# Resolve REPO_ROOT relative to this script's location
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
SKIP_EQUIFORMER=0
AWS_REGION="us-west-2"

if [ "$1" = "--skip-equiformer" ]; then
  SKIP_EQUIFORMER=1
  shift
fi

if [ "$#" -ge 1 ]; then
  AWS_REGION="$1"
fi

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
# Derive GITHUB_REPO
# ---------------------------------------------------------------------------
if [ -n "$BOOTSTRAP_GITHUB_REPO" ]; then
  GITHUB_REPO="$BOOTSTRAP_GITHUB_REPO"
else
  GITHUB_REPO=""

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

  # 3) Give up — require the user to pass BOOTSTRAP_GITHUB_REPO.
  if [ -z "$GITHUB_REPO" ]; then
    printf 'Error: could not auto-detect <github_owner/repo>.\n' >&2
    printf '       Tried: .git/config (origin remote), then "gh repo view".\n' >&2
    printf '       Set BOOTSTRAP_GITHUB_REPO=<owner>/<repo> and re-run.\n' >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Resolve AWS account and bucket name
# ---------------------------------------------------------------------------
printf 'Resolving AWS account...\n'
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

BUCKET="${PROJECT_NAME}-model-artifacts-${ACCOUNT}"

printf 'Project:  %s\n' "$PROJECT_NAME"
printf 'Account:  %s\n' "$ACCOUNT"
printf 'Region:   %s\n' "$AWS_REGION"
printf 'Bucket:   %s\n' "$BUCKET"
printf '\n'

# ---------------------------------------------------------------------------
# Bucket self-heal: deploy CoreStack if bucket does not exist
# ---------------------------------------------------------------------------
aws s3api head-bucket --bucket "$BUCKET" --region "$AWS_REGION"
bucket_rc=$?
if [ "$bucket_rc" -ne 0 ]; then
  printf 'Bucket %s not found. Deploying CoreStack to create it...\n' "$BUCKET"
  cd "$REPO_ROOT/infra" || exit 1
  if ! npx cdk deploy CoreStack \
    --context githubRepo="$GITHUB_REPO" \
    --context projectName="$PROJECT_NAME" \
    --require-approval never; then
    printf 'Error: CoreStack deploy failed. Cannot proceed.\n' >&2
    exit 1
  fi
  cd "$REPO_ROOT" || exit 1
fi

# ---------------------------------------------------------------------------
# GraphSAGE upload (always)
# ---------------------------------------------------------------------------
printf 'Processing graphsage artifact...\n'

gs_src="$REPO_ROOT/model-artifacts/graphsage/model-v2.tar.gz"
gs_key="graphsage/model-v2.tar.gz"

if [ ! -f "$gs_src" ]; then
  printf 'Error: local file not found: %s\n' "$gs_src" >&2
  exit 1
fi

gs_local_size="$(wc -c < "$gs_src")"

gs_head_out="$(aws s3api head-object --bucket "$BUCKET" --key "$gs_key" --region "$AWS_REGION" --output json)"
gs_head_rc=$?

if [ "$gs_head_rc" -eq 0 ]; then
  gs_remote_size="$(printf '%s' "$gs_head_out" | jq -r '.ContentLength')"
  if [ "$gs_remote_size" = "$gs_local_size" ]; then
    printf 'graphsage already up to date, skipping.\n'
  else
    printf 'graphsage size mismatch (local=%s remote=%s), re-uploading...\n' "$gs_local_size" "$gs_remote_size"
    if ! aws s3 cp "$gs_src" "s3://${BUCKET}/${gs_key}"; then
      printf 'Error: graphsage upload failed.\n' >&2
      exit 1
    fi
    aws s3api head-object --bucket "$BUCKET" --key "$gs_key" --region "$AWS_REGION"
    gs_verify_rc=$?
    if [ "$gs_verify_rc" -ne 0 ]; then
      printf 'Error: graphsage upload verification failed.\n' >&2
      exit 1
    fi
    printf 'graphsage uploaded and verified.\n'
  fi
else
  printf 'Uploading graphsage...\n'
  if ! aws s3 cp "$gs_src" "s3://${BUCKET}/${gs_key}"; then
    printf 'Error: graphsage upload failed.\n' >&2
    exit 1
  fi
  aws s3api head-object --bucket "$BUCKET" --key "$gs_key" --region "$AWS_REGION"
  gs_verify_rc=$?
  if [ "$gs_verify_rc" -ne 0 ]; then
    printf 'Error: graphsage upload verification failed.\n' >&2
    exit 1
  fi
  printf 'graphsage uploaded and verified.\n'
fi

# ---------------------------------------------------------------------------
# Equiformer setup (skipped if --skip-equiformer)
# ---------------------------------------------------------------------------
if [ "$SKIP_EQUIFORMER" -eq 1 ]; then
  printf '\nSkipping equiformer (--skip-equiformer set).\n'
else
  printf '\nProcessing equiformer artifact...\n'

  # E1 — uv check
  if ! command -v uv >/dev/null; then
    printf 'Error: uv is required but not found.\n' >&2
    printf 'Install: curl -LsSf https://astral.sh/uv/install.sh | sh\n' >&2
    exit 1
  fi

  # E2 — venv (idempotent)
  VENV="$REPO_ROOT/.venv-equiformer-setup"
  "$VENV/bin/python" -c 'import fairchem'
  venv_rc=$?
  if [ "$venv_rc" -ne 0 ]; then
    printf 'Creating venv and installing fairchem dependencies...\n'
    if ! uv venv "$VENV" --python 3.11; then
      printf 'Error: uv venv creation failed.\n' >&2
      exit 1
    fi
    if ! uv pip install --python "$VENV/bin/python" -r "$REPO_ROOT/models/equiformer/requirements.txt"; then
      printf 'Error: pip install failed.\n' >&2
      exit 1
    fi
  else
    printf 'fairchem already installed in %s, skipping venv setup.\n' "$VENV"
  fi

  # E3 — download checkpoint (idempotent)
  checkpoint="$REPO_ROOT/model_artifacts/equiformer/checkpoint.pt"
  if [ -s "$checkpoint" ]; then
    printf 'Checkpoint already present, skipping download.\n'
  else
    printf 'Downloading equiformer checkpoint via fairchem registry...\n'
    if ! "$VENV/bin/python" "$REPO_ROOT/scripts/download_equiformer.py"; then
      printf 'Error: equiformer checkpoint download failed.\n' >&2
      exit 1
    fi
    if [ ! -s "$checkpoint" ]; then
      printf 'Error: checkpoint not found after download: %s\n' "$checkpoint" >&2
      exit 1
    fi
    printf 'Checkpoint downloaded.\n'
  fi

  # E4 — repack tarball (idempotent)
  tarball="$REPO_ROOT/model_artifacts/equiformer/model-v2.tar.gz"
  if [ -s "$tarball" ]; then
    printf 'equiformer tarball already exists, skipping repack.\n'
  else
    printf 'Repacking equiformer tarball...\n'
    tmpdir="$(mktemp -d)"
    cp "$checkpoint" "$tmpdir/checkpoint.pt"
    mkdir "$tmpdir/code"
    cp "$REPO_ROOT/models/equiformer/inference.py" "$tmpdir/code/inference.py"
    if ! tar czf "$tarball" -C "$tmpdir" checkpoint.pt code; then
      rm -rf "$tmpdir"
      printf 'Error: tar repack failed.\n' >&2
      exit 1
    fi
    rm -rf "$tmpdir"
    printf 'equiformer tarball created.\n'
  fi

  # E5 — upload equiformer (idempotent)
  eq_key="equiformer/model-v2.tar.gz"
  eq_local_size="$(wc -c < "$tarball")"

  eq_head_out="$(aws s3api head-object --bucket "$BUCKET" --key "$eq_key" --region "$AWS_REGION" --output json)"
  eq_head_rc=$?

  if [ "$eq_head_rc" -eq 0 ]; then
    eq_remote_size="$(printf '%s' "$eq_head_out" | jq -r '.ContentLength')"
    if [ "$eq_remote_size" = "$eq_local_size" ]; then
      printf 'equiformer already up to date, skipping upload.\n'
    else
      printf 'equiformer size mismatch (local=%s remote=%s), re-uploading...\n' "$eq_local_size" "$eq_remote_size"
      if ! aws s3 cp "$tarball" "s3://${BUCKET}/${eq_key}"; then
        printf 'Error: equiformer upload failed.\n' >&2
        exit 1
      fi
      aws s3api head-object --bucket "$BUCKET" --key "$eq_key" --region "$AWS_REGION"
      eq_verify_rc=$?
      if [ "$eq_verify_rc" -ne 0 ]; then
        printf 'Error: equiformer upload verification failed.\n' >&2
        exit 1
      fi
      printf 'equiformer uploaded and verified.\n'
    fi
  else
    printf 'Uploading equiformer...\n'
    if ! aws s3 cp "$tarball" "s3://${BUCKET}/${eq_key}"; then
      printf 'Error: equiformer upload failed.\n' >&2
      exit 1
    fi
    aws s3api head-object --bucket "$BUCKET" --key "$eq_key" --region "$AWS_REGION"
    eq_verify_rc=$?
    if [ "$eq_verify_rc" -ne 0 ]; then
      printf 'Error: equiformer upload verification failed.\n' >&2
      exit 1
    fi
    printf 'equiformer uploaded and verified.\n'
  fi
fi

# ---------------------------------------------------------------------------
# Completion
# ---------------------------------------------------------------------------
printf '\nModel artifact seeding complete.\n'
printf '\n'
printf '  Bucket:    s3://%s\n' "$BUCKET"
printf '  graphsage: s3://%s/graphsage/model-v2.tar.gz\n' "$BUCKET"
if [ "$SKIP_EQUIFORMER" -ne 1 ]; then
  printf '  equiformer: s3://%s/equiformer/model-v2.tar.gz\n' "$BUCKET"
fi
printf '\n'
printf 'Next: trigger CI on your GitHub repo to deploy the Model stacks.\n'
