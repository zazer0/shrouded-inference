# WebUI Usage

## Running the WebUI yourself

The WebUI is served same-origin from the dispatcher's ALB.

Look up the current ALB DNS from the CloudFormation output:

```bash
ALB=$(aws cloudformation describe-stacks \
  --stack-name SecureGnnDispatcherStack \
  --query 'Stacks[0].Outputs[?OutputKey==`AlbDnsName`].OutputValue' \
  --output text)
echo "http://$ALB/"
```

Just open that URL in a browser — the static index.html is mounted at `/` by FastAPI (`app.mount("/", StaticFiles(...))` in `dispatcher/app/main.py`).

## Getting API keys

> **Note:** The secret name is controlled by `context.projectName` in `infra/cdk.json`
> (e.g., `shrouded-inference/raw-api-keys`).

Keys live in AWS Secrets Manager under `<project_name>/raw-api-keys`. With direnv loaded:

eval "$(direnv export bash)"

```sh
sh scripts/print_apikeys.sh
```

The secret is a JSON blob with .small and .large fields containing the raw keys. The dispatcher checks the hashed version against `<project_name>/api-keys` (hash→tier mapping).

## Using the UI

1. Paste the key into the API key field (persists to localStorage under gnn_api_key).
2. Pick small or large in the tier dropdown — the payload textarea auto-fills with a tier-appropriate sample (small: {"node_indices":[0,1,2,3]}; large: CO/Cu(111) ASE-style dict).
3. Click **Run inference**. A result card appears and the UI polls `/v1/predict/{id}` every 2s.
   Badge meanings (status × verdict, fused — see `pickBadgeKey` in `dispatcher/app/static/index.html`):
   - 🟡 pending — still running on SageMaker.
   - ⚪ awaiting verdict — completed; no user action yet. Approve / Regenerate buttons enabled.
   - 🟢 approved — user clicked **Approve**.
   - 🔴 rejected — user clicked **Regenerate**, or another submit with the same payload superseded this row.
   - 🔴 failed — terminal error (failed inferences never get a verdict).
4. Once the card reads ⚪ awaiting verdict, two buttons appear:
   - **Approve** → `POST /v1/predict/{id}/approve`; flips the badge to 🟢.
   - **Regenerate** → re-POSTs `/v1/predict` with the *same payload*. Server hashes the payload and flips the prior row to `verdict=rejected` automatically (implicit-reject rule). A new card appears for the fresh inference.

### Persistence & multi-tab

- Cards are persisted in `localStorage` under `gnn_cards` (cap 50, FIFO). A page refresh rehydrates every card and re-attaches polling for any non-terminal ones.
- Each visible card soft-polls its verdict every ~5s while completed+pending, so a rejection triggered in another tab (or by another submit of the same payload) surfaces here within ~5s.
- For an approve-via-curl fallback, see the **Telemetry & Acceptance** section in `README.md`.

### Cold-start expectations

- Small (m5.large): ~3–7 min from scale-from-zero
- Large (g4dn.xlarge): ~5–10 min cold-start; warm requests are seconds

If small endpoint is fully cold and the browser polling exceeds your patience, you can verify directly: `curl -H "X-Api-Key: $KEY" "http://$ALB/v1/predict/$ID"` (with `$ALB` set from the describe-stacks command above).

