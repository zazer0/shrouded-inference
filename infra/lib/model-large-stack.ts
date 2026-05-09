import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as kms from 'aws-cdk-lib/aws-kms';
import { AsyncSagemakerEndpoint } from './constructs/async-sagemaker-endpoint';

interface ModelLargeStackProps extends cdk.StackProps {
  asyncIoBucket: s3.IBucket;
  cmk: kms.IKey;
  envName?: string;
  nameSuffix?: string;
  imageTag: string;
}

export class ModelLargeStack extends cdk.Stack {
  public readonly endpointName: string;

  constructor(scope: Construct, id: string, props: ModelLargeStackProps) {
    super(scope, id, props);

    const projectName = this.node.tryGetContext('projectName') as string ?? 'shrouded-inference';
    const suffix = props.nameSuffix ?? '';
    const endpoint = new AsyncSagemakerEndpoint(this, 'EquiformerEndpoint', {
      modelName: 'equiformer-large',
      instanceType: 'ml.g4dn.xlarge',
      imageUri: `${this.account}.dkr.ecr.${this.region}.amazonaws.com/${projectName}-equiformer-inference${suffix}:${props.imageTag}`,
      modelDataUrl: `s3://${projectName}-model-artifacts-${this.account}${suffix}/equiformer/model-v2.tar.gz`,
      asyncOutputBucket: props.asyncIoBucket,
      cmk: props.cmk,
      maxConcurrentInvocationsPerInstance: 2,
      maxInstanceCount: 1,
      nameSuffix: props.nameSuffix,
      projectName,
    });

    this.endpointName = endpoint.endpointName;

    new cdk.CfnOutput(this, 'LargeEndpointName', {
      value: this.endpointName,
    });
  }
}
