import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as sagemaker from 'aws-cdk-lib/aws-sagemaker';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as appscaling from 'aws-cdk-lib/aws-applicationautoscaling';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as kms from 'aws-cdk-lib/aws-kms';

export interface AsyncSagemakerEndpointProps {
  modelName: string;
  instanceType: string;
  imageUri: string;
  modelDataUrl: string;
  asyncOutputBucket: s3.IBucket;
  maxConcurrentInvocationsPerInstance?: number;
  maxInstanceCount: number;
  /**
   * Suffix applied to model / endpoint-config / endpoint physical names.
   * Empty string for prod (preserves current names byte-for-byte); set to
   * '-<env>' for non-prod deployments.
   */
  nameSuffix?: string;
  /**
   * Customer-managed KMS key used for encrypting async-inference output and
   * granted to the SageMaker execution role. Provided by StorageStack so all
   * customer-input-bearing resources share a single key.
   */
  cmk: kms.IKey;
  /**
   * Optional project name used as a physical-name prefix for the endpoint.
   * Forks/renames pass this in from the consuming stack so the endpoint name
   * tracks the single source of truth in `cdk.json`.
   */
  projectName?: string;
}

export class AsyncSagemakerEndpoint extends Construct {
  public readonly endpointName: string;

  constructor(scope: Construct, id: string, props: AsyncSagemakerEndpointProps) {
    super(scope, id);

    // --- Execution Role ---
    const executionRole = new iam.Role(this, 'ExecutionRole', {
      assumedBy: new iam.ServicePrincipal('sagemaker.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSageMakerFullAccess'),
      ],
    });

    // Read model artifacts from the bucket in modelDataUrl (s3://bucket-name/key)
    const modelBucketName = props.modelDataUrl.replace('s3://', '').split('/')[0];
    executionRole.addToPolicy(new iam.PolicyStatement({
      actions: ['s3:GetObject'],
      resources: [`arn:aws:s3:::${modelBucketName}/*`],
    }));

    // Write async output to async-io bucket
    props.asyncOutputBucket.grantReadWrite(executionRole);
    // Allow the execution role to encrypt/decrypt with the shared CMK so it
    // can write KMS-encrypted output objects and read KMS-encrypted inputs.
    props.cmk.grantEncryptDecrypt(executionRole);

    const nameSuffix = props.nameSuffix ?? '';
    const suffixedModelName = `${props.modelName}${nameSuffix}`;

    // --- SageMaker Model ---
    // NOTE: modelName intentionally omitted so CDK auto-generates a unique
    // physical name. CFN AWS::SageMaker::Model is replace-only on imageUri
    // changes, and a fixed name causes "AlreadyExists" 400s on replacement.
    const model = new sagemaker.CfnModel(this, 'Model', {
      executionRoleArn: executionRole.roleArn,
      primaryContainer: {
        image: props.imageUri,
        modelDataUrl: props.modelDataUrl,
      },
    });

    // Ensure the IAM policy with S3 permissions is created before the Model,
    // otherwise SageMaker validation fails because the role lacks s3:GetObject.
    const defaultPolicy = executionRole.node.findChild('DefaultPolicy') as iam.Policy;
    model.node.addDependency(defaultPolicy);

    // --- Endpoint Config ---
    // NOTE: endpointConfigName also omitted (same replacement collision risk
    // when productionVariants[].modelName changes due to auto-generated model
    // name above).
    const endpointConfig = new sagemaker.CfnEndpointConfig(this, 'EndpointConfig', {
      productionVariants: [
        {
          modelName: model.attrModelName,
          variantName: 'AllTraffic',
          initialInstanceCount: 1,
          instanceType: props.instanceType,
        },
      ],
      asyncInferenceConfig: {
        outputConfig: {
          s3OutputPath: `s3://${props.asyncOutputBucket.bucketName}/output/`,
          s3FailurePath: `s3://${props.asyncOutputBucket.bucketName}/failure/`,
          kmsKeyId: props.cmk.keyArn,
        },
        clientConfig: {
          maxConcurrentInvocationsPerInstance:
            props.maxConcurrentInvocationsPerInstance ?? 4,
        },
      },
    });
    endpointConfig.addDependency(model);

    // --- Endpoint ---
    // Endpoint name kept stable — dispatcher references it via stack output.
    const endpointName = props.projectName ? `${props.projectName}-${suffixedModelName}-endpoint` : `${suffixedModelName}-endpoint`;
    const endpoint = new sagemaker.CfnEndpoint(this, 'Endpoint', {
      endpointName,
      endpointConfigName: endpointConfig.attrEndpointConfigName,
    });
    endpoint.addDependency(endpointConfig);
    this.endpointName = endpointName;

    // --- Auto Scaling ---
    const scalableTarget = new appscaling.ScalableTarget(this, 'ScalableTarget', {
      serviceNamespace: appscaling.ServiceNamespace.SAGEMAKER,
      resourceId: `endpoint/${endpointName}/variant/AllTraffic`,
      scalableDimension: 'sagemaker:variant:DesiredInstanceCount',
      minCapacity: 0,
      maxCapacity: props.maxInstanceCount,
    });
    scalableTarget.node.addDependency(endpoint);

    scalableTarget.scaleToTrackMetric('BacklogTracking', {
      targetValue: 2,
      customMetric: new cloudwatch.Metric({
        namespace: 'AWS/SageMaker',
        metricName: 'ApproximateBacklogSizePerInstance',
        dimensionsMap: {
          EndpointName: endpointName,
        },
        statistic: 'Average',
      }),
    });
    // Step scaling: scale from 0 -> 1 when there is a backlog with no capacity.
    // Required because target tracking alone cannot scale from zero.
    scalableTarget.scaleOnMetric('ScaleFromZero', {
      metric: new cloudwatch.Metric({
        namespace: 'AWS/SageMaker',
        metricName: 'HasBacklogWithoutCapacity',
        dimensionsMap: { EndpointName: endpointName },
        statistic: 'Maximum',
        period: cdk.Duration.minutes(1),
      }),
      scalingSteps: [
        { upper: 0, change: 0 },
        { lower: 1, change: +1 },
      ],
      adjustmentType: appscaling.AdjustmentType.CHANGE_IN_CAPACITY,
      cooldown: cdk.Duration.seconds(180),
      evaluationPeriods: 1,
    });
  }
}
