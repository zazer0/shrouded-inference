#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib/core';
import { CoreStack } from '../lib/core-stack';
import { StorageStack } from '../lib/storage-stack';
import { SecretsStack } from '../lib/secrets-stack';
import { ModelSmallStack } from '../lib/model-small-stack';
import { ModelLargeStack } from '../lib/model-large-stack';
import { DispatcherStack } from '../lib/dispatcher-stack';
import { GithubOidcStack } from '../lib/github-oidc-stack';
import { BuildCacheStack } from '../lib/build-cache-stack';

const app = new cdk.App();
const env = {
  account: process.env.CDK_DEFAULT_ACCOUNT,
  region: process.env.CDK_DEFAULT_REGION ?? 'us-west-2',
};

// Multi-env plumbing. `--context env=staging` produces a parallel set of
// stacks suffixed with `-staging`. When unset (or `prod`) the suffix is
// empty and stack IDs / physical names are byte-identical to before, so
// prod redeploys are a no-op.
const envName = app.node.tryGetContext('env') ?? 'prod';
const suffix = envName === 'prod' ? '' : `-${envName}`;

// Image tag for SageMaker Model imageUri. CI passes --context imageTag=${{ github.sha }};
// local dev can export CDK_IMAGE_TAG=$(git rev-parse HEAD) for synth. Falling through to
// 'latest' is a synth-only convenience — production deploy paths must always pass an
// explicit SHA (memory: feedback_cdk_image_tagging.md).
const imageTag = app.node.tryGetContext('imageTag') ?? process.env.CDK_IMAGE_TAG ?? 'latest';

new CoreStack(app, `CoreStack${suffix}`, {
  stackName: `SecureGnnCoreStack${suffix}`,
  env,
  envName,
  nameSuffix: suffix,
});

export const storageStack = new StorageStack(app, `StorageStack${suffix}`, {
  stackName: `SecureGnnStorageStack${suffix}`,
  env,
  envName,
  nameSuffix: suffix,
});

// SecretsStack is prod-only. The api-keys secret + the merger CR are owned
// solely by the prod stack; ephemeral envs import the same `gnn-serving/api-keys`
// secret by name in DispatcherStack. Mirrors the GithubOidcStack prod-only gate
// at the bottom of this file. See worklog 026 for the regressions this fixes.
if (envName === 'prod') {
  new SecretsStack(app, `SecretsStack${suffix}`, {
    stackName: `SecureGnnSecretsStack${suffix}`,
    env,
    envName,
    nameSuffix: suffix,
  });
}

export const modelSmallStack = new ModelSmallStack(app, `ModelSmallStack${suffix}`, {
  stackName: `SecureGnnModelSmallStack${suffix}`,
  env,
  asyncIoBucket: storageStack.asyncIoBucket,
  cmk: storageStack.cmk,
  envName,
  nameSuffix: suffix,
  imageTag,
});

export const modelLargeStack = new ModelLargeStack(app, `ModelLargeStack${suffix}`, {
  stackName: `SecureGnnModelLargeStack${suffix}`,
  env,
  asyncIoBucket: storageStack.asyncIoBucket,
  cmk: storageStack.cmk,
  envName,
  nameSuffix: suffix,
  imageTag,
});

new DispatcherStack(app, `DispatcherStack${suffix}`, {
  stackName: `SecureGnnDispatcherStack${suffix}`,
  env,
  asyncIoBucket: storageStack.asyncIoBucket,
  cmk: storageStack.cmk,
  // Import the prod-managed secret by name (no cross-stack ref). Same name in
  // every env: prod owns the lifecycle, ephemeral envs read-only-share it.
  apiKeysSecretName: 'gnn-serving/api-keys',
  telemetryTable: storageStack.telemetryTable,
  smallEndpointName: modelSmallStack.endpointName,
  largeEndpointName: modelLargeStack.endpointName,
  envName,
  nameSuffix: suffix,
  imageTag,
});

// OIDC provider + role are global singletons keyed on a fixed role name
// (`gnn-serving-github-actions-deploy`). Instantiating per-env would conflict
// on the role; the prod role is reused across ephemeral envs via its widened
// trust pattern.
if (envName === 'prod') {
  new GithubOidcStack(app, `GithubOidcStack${suffix}`, {
    stackName: `SecureGnnGithubOidcStack${suffix}`,
    env,
    envName,
    nameSuffix: suffix,
  });

  new BuildCacheStack(app, 'BuildCacheStack', {
    stackName: 'SecureGnnBuildCacheStack',
    env,
  });
}
