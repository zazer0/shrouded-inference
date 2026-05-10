# [priv] shrouded-inference

A security-focused ML model deployment: with near-zero-cost when idle, and fully anonymized metrics to improve the model(s) - without compromising customers' IP.

Simplified User Story Architecture:
<p align="center">
  <img src="./docs/data-boundary.svg" alt="Architecture" width="100%" />
</p>

Full Architecture and rationale: [docs/arch-decisions.md](docs/arch-decisions.md).

## Notable design choices

- **All inputs encrypted with Customer Managed Keys, unreadable to the AWS deployer** — admin access returns ciphertext; raw payloads auto-deleted within 24 hours.
- **API keys unrecoverable from a breach** — only SHA-256 hashes stored, raw values never leave Secrets Manager.
- **No long-lived AWS credentials** — short-lived OIDC tokens, trust pinned to one branch on one repo.
- **Near-zero idle cost** — both model endpoints scale to zero; ~$25/month floor.
- **Feedback without labeling overhead** — binary approve/regenerate verdict, keyed by hashed user + payload.

## Iteration-speed choices

- **Infra regressions caught before main** — every PR gets a throwaway copy of the full stack, torn down on close.
- **New model tier in a five-line diff** — both endpoints share one reusable `AsyncSagemakerEndpoint` construct.
- **Prod redeploys cut from ~50 min to ~3** — content-addressed ECR tags, retagged from the PR's already-built image.
- **Env teardowns are true no-ops on shared state** — secrets lifecycle owned by prod, other envs inherit by name.
- **`/healthz` reports the deployed commit, images stay cacheable** — SHA injected at deploy time, not baked at build.

## Threat model

In scope:

- Customer IP — never persisted in raw form
- API auth — keys stored as fingerprints
- Deploy credentials — short-lived, branch-pinned, no static keys
- Blast radius — per-tier IAM scoping, name-based secret imports
- Audit — every request logged at ALB, dispatcher, SageMaker, and CloudTrail layers
- Cost ceiling — scale-to-zero on both endpoints
- Operator visibility — admin access reads ciphertext, not customer data; key access is logged
- PR-env blast radius — each ephemeral environment has its own separate encryption key

## First-time setup / repo rename recovery

The GitHub Actions OIDC deploy role (`<project_name>-github-actions-deploy`) trust policy is
sourced dynamically from `GITHUB_REPOSITORY` at CDK synth time. CI keeps it in sync via
`cdk deploy --all` on every push to `main`. However, CI cannot self-heal for:

1. **First-time setup** — the OIDC role doesn't exist yet.
2. **After a GitHub repo rename** — the existing trust policy is stale before the next CI run can fix it.

**Prereq:** [`uv`](https://github.com/astral-sh/uv) must be installed (`curl -LsSf https://astral.sh/uv/install.sh | sh`).

Run once, with deployer AWS creds sourced:

```sh
sh scripts/bootstrap_new_deploy_ci.sh <github_owner/repo> <project_name>
```

`project_name` must match `infra/cdk.json` → `context.projectName`. The script autonomously:

1. Deploys the OIDC stack and sets `AWS_DEPLOY_ROLE_ARN` on the GitHub repo.
2. Seeds model artifacts — downloads the EquiformerV2 checkpoint via `uv` + fairchem, repacks it,
   and uploads both `graphsage/model-v2.tar.gz` and `equiformer/model-v2.tar.gz` into the project S3 bucket.
3. Bootstraps API keys — generates fresh `small` and `large` tier keys, stores them in
   `${project_name}/raw-api-keys`, and writes hashed entries into `${project_name}/api-keys`.
   Retrieve keys anytime with `sh scripts/print_apikeys.sh`.

All steps are idempotent; re-running is safe.

To skip the ~115 MB equiformer download (endpoint falls back to degraded mode):

```sh
sh scripts/bootstrap_new_deploy_ci.sh <github_owner/repo> <project_name>
# — then, separately —
sh scripts/first_time_setup_models.sh --skip-equiformer
```

Once complete, push to `main` to trigger the full CI deploy of all stacks.

---
