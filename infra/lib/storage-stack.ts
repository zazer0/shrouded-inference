import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as kms from 'aws-cdk-lib/aws-kms';

export interface StorageStackProps extends cdk.StackProps {
  /** Logical environment name (e.g., 'prod', 'staging'). Defaults to 'prod' upstream. */
  envName?: string;
  /** Suffix applied to physical resource names ('' for prod, '-<env>' otherwise). */
  nameSuffix?: string;
}

export class StorageStack extends cdk.Stack {
  public readonly asyncIoBucket: s3.Bucket;
  public readonly telemetryTable: dynamodb.Table;
  public readonly cmk: kms.Key;

  constructor(scope: Construct, id: string, props?: StorageStackProps) {
    super(scope, id, props);

    const projectName = this.node.tryGetContext('projectName') as string ?? 'shrouded-inference';
    const envName = props?.envName ?? 'prod';
    const suffix = props?.nameSuffix ?? '';
    const isProd = envName === 'prod';

    // Customer-managed KMS key for encrypting customer input at rest across
    // the async-io bucket, the telemetry table, and SageMaker async output.
    // Default key policy gives kms:* only to account root; runtime principals
    // (dispatcher task role, SageMaker execution roles) gain encrypt/decrypt
    // via grantEncryptDecrypt() in downstream stacks. The deploy role MUST
    // never receive kms:Decrypt — that's the privacy property.
    this.cmk = new kms.Key(this, 'CustomerInputCmk', {
      description: `CMK for customer input at rest (env=${envName})`,
      enableKeyRotation: true,
      removalPolicy: isProd ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
      pendingWindow: cdk.Duration.days(7),
      alias: `alias/${projectName}-customer-input${suffix}`,
    });

    this.asyncIoBucket = new s3.Bucket(this, 'AsyncIoBucket', {
      bucketName: `${projectName}-async-io-${this.account}${suffix}`,
      removalPolicy: isProd ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: !isProd,
      encryption: s3.BucketEncryption.KMS,
      encryptionKey: this.cmk,
      bucketKeyEnabled: true,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      lifecycleRules: [
        {
          prefix: 'input/',
          expiration: cdk.Duration.days(1),
          noncurrentVersionExpiration: cdk.Duration.days(1),
        },
        {
          prefix: 'meta/',
          expiration: cdk.Duration.days(1),
          noncurrentVersionExpiration: cdk.Duration.days(1),
        },
        {
          prefix: 'output/',
          expiration: cdk.Duration.days(7),
          noncurrentVersionExpiration: cdk.Duration.days(1),
        },
        {
          prefix: 'failure/',
          expiration: cdk.Duration.days(7),
          noncurrentVersionExpiration: cdk.Duration.days(1),
        },
      ],
    });

    // Versioning suspended: dispatcher uploads are write-once/read-once, versioning
    // was never relied on, and a 1-day expiration only holds if new versions stop
    // being created. S3 buckets can't be unversioned once enabled — Suspended is
    // the permanent terminal state; CDK has no first-class prop for it.
    (this.asyncIoBucket.node.defaultChild as s3.CfnBucket).versioningConfiguration = { status: 'Suspended' };

    new cdk.CfnOutput(this, 'AsyncIoBucketName', {
      value: this.asyncIoBucket.bucketName,
    });
    new cdk.CfnOutput(this, 'AsyncIoBucketArn', {
      value: this.asyncIoBucket.bucketArn,
    });

    // Telemetry table for prediction acceptance/rejection records.
    // GSI lets us query prior pending rows for a given user+input fingerprint
    // so a fresh submission of the same payload can reject earlier ones.
    this.telemetryTable = new dynamodb.Table(this, 'TelemetryTable', {
      partitionKey: { name: 'inference_id', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      encryption: dynamodb.TableEncryption.CUSTOMER_MANAGED,
      encryptionKey: this.cmk,
      removalPolicy: isProd ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
    });
    // Deliberately KEYS_ONLY: this table existed before the duplicate-submit
    // check was introduced, and DynamoDB does not allow widening an existing
    // GSI's projection in-place ("Cannot update GSI's properties other than
    // Provisioned Throughput and Contributor Insights Specification"). Creating
    // a parallel INCLUDE-projected GSI just to avoid an N+1 GetItem isn't worth
    // the operational churn — the duplicate-submit hot path is rare (only fires
    // on an actual duplicate), so the dispatcher reads `verdict` and
    // `inference_status` via per-row GetItem after this Query.
    this.telemetryTable.addGlobalSecondaryIndex({
      indexName: 'byUserAndInput',
      partitionKey: { name: 'gsi1pk', type: dynamodb.AttributeType.STRING }, // "{user_id}#{input_sha256}"
      sortKey: { name: 'created_at', type: dynamodb.AttributeType.STRING },
      projectionType: dynamodb.ProjectionType.KEYS_ONLY,
    });

    new cdk.CfnOutput(this, 'TelemetryTableName', {
      value: this.telemetryTable.tableName,
    });
    new cdk.CfnOutput(this, 'TelemetryTableArn', {
      value: this.telemetryTable.tableArn,
    });
  }
}
