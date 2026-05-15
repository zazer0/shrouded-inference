# First-time setup

**Prereqs:**
- [`uv`](https://github.com/astral-sh/uv) installed (`curl -LsSf https://astral.sh/uv/install.sh | sh`)
- AWS credentials with deployer permissions sourced in your shell

Run once:

```sh
sh scripts/bootstrap_new_deploy_ci.sh <github_owner/repo> <project_name>
```

`project_name` must match `infra/cdk.json` → `context.projectName`. This script:

1. Creates the OIDC deploy role and sets `AWS_DEPLOY_ROLE_ARN` on the GitHub repo.
2. Downloads and uploads model artifacts to S3 (includes a ~115 MB equiformer checkpoint).
3. Generates API keys and stores hashed entries in Secrets Manager. Retrieve them anytime with `sh scripts/print_apikeys.sh`.

All steps are idempotent. To skip the equiformer download (endpoint falls back to degraded mode), run step 2 separately:

```sh
sh scripts/first_time_setup_models.sh --skip-equiformer
```

Then push to `main` to trigger the full CI deploy.

> **AWS role note:** If the OIDC role already exists (e.g. you're re-running after a failed deploy), the bootstrap script is still safe to re-run — it will update the trust policy if needed. If your AWS account requires manual role approval or SCPs restrict role creation, you may need to coordinate with your AWS admin before running.
