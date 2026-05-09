import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as cr from 'aws-cdk-lib/custom-resources';

export interface SecretsStackProps extends cdk.StackProps {
  /** Logical environment name (e.g., 'prod', 'staging'). */
  envName?: string;
  /** Suffix applied to physical resource names ('' for prod, '-<env>' otherwise). */
  nameSuffix?: string;
}

/**
 * Manages the two API-key secrets used by the dispatcher.
 *
 *  - `gnn-serving/api-keys`     — map of SHA-256(api_key) → {tier, user_id?}
 *  - `gnn-serving/raw-api-keys` — map of tier-name → raw api key string
 *
 * Historically these secrets were created out-of-band via the AWS CLI; only
 * the `gnn-serving/api-keys` placeholder has ever been managed by this stack
 * (with no CDK-side value generation). Existing `small` and `large` entries
 * therefore live in production state that CDK does not own and must not
 * disturb.
 *
 * `gnn-serving/raw-api-keys` is intentionally **shared (unsuffixed) across
 * envs** — it is the single source of truth for raw key material. Every env
 * (prod and ephemeral) imports the same secret by name. Per-env hashed maps
 * (`gnn-serving/api-keys${suffix}`) get seeded with hashes of those shared
 * raw values, so authentication is identical across envs without ever
 * persisting secret material in CDK templates or context.
 *
 * To add the third "all" tier key while keeping prod-redeploys a no-op for
 * the existing tiers, this stack uses an idempotent custom resource that
 * performs a read-modify-write merge on each secret: it leaves any pre-
 * existing entries untouched and only inserts/updates the single `all`
 * entry it owns.
 */
export class SecretsStack extends cdk.Stack {
  public readonly apiKeysSecret: secretsmanager.ISecret;
  public readonly rawApiKeysSecret: secretsmanager.ISecret;

  constructor(scope: Construct, id: string, props?: SecretsStackProps) {
    super(scope, id, props);

    // This stack is now prod-only (gated in `bin/infra.ts`). The api-keys
    // (hash → tier) secret is unsuffixed — there is exactly one across the
    // whole account. Ephemeral envs read it by name in DispatcherStack.
    // RETAIN is preserved so the historical placeholder is never destroyed.
    this.apiKeysSecret = new secretsmanager.Secret(this, 'ApiKeysSecret', {
      secretName: 'gnn-serving/api-keys',
      description: 'API key SHA256 hashes mapped to tier/user metadata',
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // The raw-keys secret has always been managed outside CDK and is shared
    // (unsuffixed) across every env — it is the single source of truth for
    // raw key material. Import it by name so we can grant the merger Lambda
    // read/write access without trying to take ownership of the existing
    // CFN-untracked resource. Note: no `${suffix}` here — every env imports
    // the same `gnn-serving/raw-api-keys`.
    this.rawApiKeysSecret = secretsmanager.Secret.fromSecretNameV2(
      this,
      'RawApiKeysSecret',
      'gnn-serving/raw-api-keys',
    );

    // ------------------------------------------------------------------
    // `all`-tier key merge custom resource
    // ------------------------------------------------------------------
    // The Lambda below is invoked by CFN on Create/Update/Delete and:
    //   - generates a stable raw key the first time it runs (stored in the
    //     raw-api-keys secret under the literal key "all");
    //   - merges its sha256 into the api-keys map under {"tier": "all"};
    //   - leaves all other entries (small/large/etc.) untouched.
    //
    // The merge is keyed by `tierName` (a CR property) so the diff against
    // prod will show a new logical resource and a single new entry per
    // secret, not a wholesale value replacement.
    const tierName = 'all';

    const mergeFn = new lambda.Function(this, 'AllTierKeyMergeFn', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'index.handler',
      timeout: cdk.Duration.seconds(60),
      code: lambda.Code.fromInline(ALL_TIER_MERGE_LAMBDA_SRC),
      description:
        'Idempotently merges the "all"-tier raw API key (and its sha256 hash) into the api-keys / raw-api-keys secrets without touching other entries.',
    });

    mergeFn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: [
          'secretsmanager:GetSecretValue',
          'secretsmanager:PutSecretValue',
          'secretsmanager:DescribeSecret',
        ],
        resources: [
          this.apiKeysSecret.secretArn,
          // imported secret has no exported ARN with version suffix; scope
          // by name pattern instead.
          `arn:aws:secretsmanager:${this.region}:${this.account}:secret:gnn-serving/raw-api-keys-*`,
        ],
      }),
    );

    const provider = new cr.Provider(this, 'AllTierKeyMergeProvider', {
      onEventHandler: mergeFn,
    });

    new cdk.CustomResource(this, 'AllTierKeyMerge', {
      serviceToken: provider.serviceToken,
      resourceType: 'Custom::ApiKeysAllTierMerge',
      properties: {
        ApiKeysSecretArn: this.apiKeysSecret.secretArn,
        RawApiKeysSecretName: 'gnn-serving/raw-api-keys',
        TierName: tierName,
        // Bump this string to force a re-run (e.g. to rotate the key).
        Version: '1',
        // Bumped to trigger OnUpdate on the prod deploy that ships the
        // centralized-lifecycle refactor — restores the `all` raw-key that
        // a non-prod CR's OnDelete previously wiped (worklog 026 #2). The
        // OnUpdate handler is idempotent and re-derives `all` from the
        // existing `small` + `large` raw values.
        Revision: 2,
      },
    });

    // ------------------------------------------------------------------
    // Non-prod-only: seed the per-env hashed-keys map with sha256 of the
    // shared `small`/`large` raw values. Read-only against the shared
    // raw-keys: never generates fresh material; fails fast if a tier is
    // missing in shared raw-keys. Wrapped in `!isProd` so it never appears
    // in the prod synth (preserves the cdk-diff-empty invariant).
    // ------------------------------------------------------------------
    const isProd = (props?.envName ?? 'prod') === 'prod';
    if (!isProd) {
      const seedFn = new lambda.Function(this, 'EphemeralSeedFn', {
        runtime: lambda.Runtime.PYTHON_3_12,
        handler: 'index.handler',
        timeout: cdk.Duration.seconds(60),
        code: lambda.Code.fromInline(EPHEMERAL_SEED_LAMBDA_SRC),
        description:
          'Read-only: seeds the per-env hashed-keys map with sha256(small) and sha256(large) from the shared raw-api-keys secret. Never writes to the shared secret.',
      });

      seedFn.addToRolePolicy(
        new iam.PolicyStatement({
          actions: [
            'secretsmanager:GetSecretValue',
            'secretsmanager:PutSecretValue',
            'secretsmanager:DescribeSecret',
          ],
          resources: [
            this.apiKeysSecret.secretArn,
            `arn:aws:secretsmanager:${this.region}:${this.account}:secret:gnn-serving/raw-api-keys-*`,
          ],
        }),
      );

      const seedProvider = new cr.Provider(this, 'EphemeralSeedProvider', {
        onEventHandler: seedFn,
      });

      for (const tier of ['small', 'large']) {
        new cdk.CustomResource(this, `EphemeralSeed_${tier}`, {
          serviceToken: seedProvider.serviceToken,
          resourceType: 'Custom::ApiKeysEphemeralSeed',
          properties: {
            ApiKeysSecretArn: this.apiKeysSecret.secretArn,
            RawApiKeysSecretName: 'gnn-serving/raw-api-keys',
            TierName: tier,
            Version: '1',
          },
        });
      }
    }

    new cdk.CfnOutput(this, 'ApiKeysSecretArn', {
      value: this.apiKeysSecret.secretArn,
    });
  }
}

const ALL_TIER_MERGE_LAMBDA_SRC = `
"""
OnEvent handler for the Custom::ApiKeysAllTierMerge custom resource.

Invariants (rely on these — do not duplicate-defend):
  - Created exactly once, in SecureGnnSecretsStack on prod (gated in
    bin/infra.ts). Never instantiated for ephemeral envs.
  - Therefore every event this handler sees corresponds to the prod
    stack's lifecycle. There is no per-env multiplicity to reason about.
  - Owns the 'all' tier hash in the prod-managed
    gnn-serving/api-keys secret AND the 'all' raw-key in the shared
    gnn-serving/raw-api-keys secret. No other code path writes either
    of those two specific entries.

The 'all' raw key is deterministically DERIVED from the existing
'small' + 'large' raw keys (sha256 of 'small|large'). This makes
Create/Update fully idempotent — re-running with the same inputs always
produces the same 'all' value, which is what restores the regressed
'all' key (worklog 026 #2) on the next prod deploy.
"""
import json
import hashlib
import boto3
import urllib.request

sm = boto3.client('secretsmanager')


def _send(event, context, status, data=None, physical_id=None, reason=None):
    body = json.dumps({
        'Status': status,
        'Reason': reason or 'See CloudWatch Logs',
        'PhysicalResourceId': physical_id or event.get('PhysicalResourceId') or context.log_stream_name,
        'StackId': event['StackId'],
        'RequestId': event['RequestId'],
        'LogicalResourceId': event['LogicalResourceId'],
        'NoEcho': False,
        'Data': data or {},
    }).encode('utf-8')
    req = urllib.request.Request(
        event['ResponseURL'], data=body, method='PUT',
        headers={'content-type': '', 'content-length': str(len(body))},
    )
    urllib.request.urlopen(req).read()


def _load(secret_id):
    try:
        resp = sm.get_secret_value(SecretId=secret_id)
    except sm.exceptions.ResourceNotFoundException:
        return {}
    txt = resp.get('SecretString') or '{}'
    try:
        val = json.loads(txt)
        return val if isinstance(val, dict) else {}
    except json.JSONDecodeError:
        return {}


def _store(secret_id, data):
    sm.put_secret_value(SecretId=secret_id, SecretString=json.dumps(data))


def _derive_all(raw):
    """Deterministic derivation of the 'all' raw key from small + large.

    Returns None if either prerequisite tier is missing — callers must
    treat that as a hard failure (operator must populate small/large in
    the shared raw-keys secret first).
    """
    small = raw.get('small')
    large = raw.get('large')
    if not small or not large:
        return None
    return hashlib.sha256(f'{small}|{large}'.encode('utf-8')).hexdigest()


def handler(event, context):
    try:
        props = event.get('ResourceProperties', {})
        api_keys_arn = props['ApiKeysSecretArn']
        raw_secret_name = props['RawApiKeysSecretName']
        tier_name = props['TierName']
        request_type = event['RequestType']

        raw = _load(raw_secret_name)
        hashed = _load(api_keys_arn)

        if request_type == 'Create':
            # First-time prod stack deploy: derive 'all' from the existing
            # 'small' + 'large' raw keys, write it to the shared raw-keys
            # secret, hash it, write the hash to the prod api-keys secret.
            key_value = _derive_all(raw)
            if key_value is None:
                _send(event, context, 'FAILED',
                      reason="Cannot derive 'all': shared raw-api-keys is missing 'small' or 'large'. Populate both before deploying.")
                return
            if raw.get(tier_name) != key_value:
                raw[tier_name] = key_value
                _store(raw_secret_name, raw)
            new_hash = hashlib.sha256(key_value.encode('utf-8')).hexdigest()
            cleaned = {h: v for h, v in hashed.items() if not (
                isinstance(v, dict) and v.get('tier') == tier_name and h != new_hash
            )}
            cleaned[new_hash] = {'tier': tier_name}
            if cleaned != hashed:
                _store(api_keys_arn, cleaned)
            _send(event, context, 'SUCCESS',
                  data={'TierName': tier_name},
                  physical_id=f'all-tier-merge-{tier_name}')
            return

        if request_type == 'Update':
            # Re-runs on any CR property change (used here to force restoration
            # after manual incidents — e.g. the worklog 026 #2 wipe). Same
            # outputs as Create — fully idempotent: always re-derive 'all'
            # from 'small' + 'large' and write back if different. Restores
            # the shared 'all' key whenever it has been removed.
            key_value = _derive_all(raw)
            if key_value is None:
                _send(event, context, 'FAILED',
                      reason="Cannot derive 'all': shared raw-api-keys is missing 'small' or 'large'.")
                return
            if raw.get(tier_name) != key_value:
                raw[tier_name] = key_value
                _store(raw_secret_name, raw)
            new_hash = hashlib.sha256(key_value.encode('utf-8')).hexdigest()
            cleaned = {h: v for h, v in hashed.items() if not (
                isinstance(v, dict) and v.get('tier') == tier_name and h != new_hash
            )}
            cleaned[new_hash] = {'tier': tier_name}
            if cleaned != hashed:
                _store(api_keys_arn, cleaned)
            _send(event, context, 'SUCCESS',
                  data={'TierName': tier_name},
                  physical_id=f'all-tier-merge-{tier_name}')
            return

        if request_type == 'Delete':
            # Fires only when the prod SecretsStack itself is being destroyed
            # (rare; the api-keys secret has RemovalPolicy.RETAIN, so deletion
            # is essentially a manual maintainer action). Removes the 'all'
            # tier from both secrets so prod doesn't leave dangling stale
            # state. Ephemeral env teardowns CANNOT reach this branch — that
            # CR isn't created off-prod (gated in bin/infra.ts).
            try:
                if tier_name in raw:
                    raw.pop(tier_name, None)
                    _store(raw_secret_name, raw)
                cleaned = {h: v for h, v in hashed.items() if not (
                    isinstance(v, dict) and v.get('tier') == tier_name
                )}
                if cleaned != hashed:
                    _store(api_keys_arn, cleaned)
            except Exception as e:  # pragma: no cover - defensive
                print(f'cleanup error (ignored): {e}')
            _send(event, context, 'SUCCESS',
                  physical_id=event.get('PhysicalResourceId'))
            return

        # Unknown request types must fail loudly — silent SUCCESS would
        # hide upstream protocol changes.
        raise RuntimeError(f'Unknown request_type: {request_type!r}')
    except Exception as e:
        print(f'merge handler error: {e}')
        _send(event, context, 'FAILED', reason=str(e))
`;

const EPHEMERAL_SEED_LAMBDA_SRC = `
import json, hashlib, boto3, urllib.request
sm = boto3.client('secretsmanager')

def _send(event, context, status, data=None, physical_id=None, reason=None):
    body = json.dumps({
        'Status': status,
        'Reason': reason or 'See CloudWatch Logs',
        'PhysicalResourceId': physical_id or event.get('PhysicalResourceId') or context.log_stream_name,
        'StackId': event['StackId'],
        'RequestId': event['RequestId'],
        'LogicalResourceId': event['LogicalResourceId'],
        'NoEcho': False,
        'Data': data or {},
    }).encode('utf-8')
    req = urllib.request.Request(event['ResponseURL'], data=body, method='PUT',
        headers={'content-type': '', 'content-length': str(len(body))})
    urllib.request.urlopen(req).read()

def _load(secret_id):
    try:
        resp = sm.get_secret_value(SecretId=secret_id)
    except sm.exceptions.ResourceNotFoundException:
        return {}
    txt = resp.get('SecretString') or '{}'
    try:
        v = json.loads(txt)
        return v if isinstance(v, dict) else {}
    except json.JSONDecodeError:
        return {}

def handler(event, context):
    try:
        props = event.get('ResourceProperties', {})
        api_keys_arn = props['ApiKeysSecretArn']
        raw_secret_name = props['RawApiKeysSecretName']
        tier = props['TierName']
        rt = event['RequestType']

        if rt in ('Create', 'Update'):
            raw = _load(raw_secret_name)
            key_value = raw.get(tier)
            if not key_value:
                # READ-ONLY: do not generate; require operator to populate first.
                _send(event, context, 'FAILED',
                      reason=f'Tier {tier!r} missing in shared raw-api-keys; populate it before deploying an ephemeral env.')
                return
            new_hash = hashlib.sha256(key_value.encode('utf-8')).hexdigest()
            hashed = _load(api_keys_arn)
            cleaned = {h: v for h, v in hashed.items()
                       if not (isinstance(v, dict) and v.get('tier') == tier and h != new_hash)}
            cleaned[new_hash] = {'tier': tier}
            if cleaned != hashed:
                sm.put_secret_value(SecretId=api_keys_arn, SecretString=json.dumps(cleaned))
            _send(event, context, 'SUCCESS', data={'TierName': tier},
                  physical_id=f'ephemeral-seed-{tier}')
            return

        if rt == 'Delete':
            try:
                hashed = _load(api_keys_arn)
                cleaned = {h: v for h, v in hashed.items()
                           if not (isinstance(v, dict) and v.get('tier') == tier)}
                if cleaned != hashed:
                    sm.put_secret_value(SecretId=api_keys_arn, SecretString=json.dumps(cleaned))
            except Exception as e:
                print(f'cleanup error (ignored): {e}')
            _send(event, context, 'SUCCESS', physical_id=event.get('PhysicalResourceId'))
            return

        _send(event, context, 'SUCCESS')
    except Exception as e:
        print(f'seed handler error: {e}')
        _send(event, context, 'FAILED', reason=str(e))
`;
