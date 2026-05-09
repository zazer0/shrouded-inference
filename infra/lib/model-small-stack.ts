import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as kms from 'aws-cdk-lib/aws-kms';
import { AsyncSagemakerEndpoint } from './constructs/async-sagemaker-endpoint';

interface ModelSmallStackProps extends cdk.StackProps {
  asyncIoBucket: s3.IBucket;
  cmk: kms.IKey;
  envName?: string;
  nameSuffix?: string;
  imageTag: string;
}

export class ModelSmallStack extends cdk.Stack {
  public readonly endpointName: string;

  constructor(scope: Construct, id: string, props: ModelSmallStackProps) {
    super(scope, id, props);

    const projectName = this.node.tryGetContext('projectName') as string ?? 'shrouded-inference';
    const suffix = props.nameSuffix ?? '';
    const endpoint = new AsyncSagemakerEndpoint(this, 'GraphSageEndpoint', {
      modelName: 'graphsage-small',
      instanceType: 'ml.m5.large',
      imageUri: `${this.account}.dkr.ecr.${this.region}.amazonaws.com/${projectName}-graphsage-inference${suffix}:${props.imageTag}`,
      modelDataUrl: `s3://${projectName}-model-artifacts-${this.account}${suffix}/graphsage/model-v2.tar.gz`,
      asyncOutputBucket: props.asyncIoBucket,
      cmk: props.cmk,
      maxConcurrentInvocationsPerInstance: 4,
      maxInstanceCount: 1,
      nameSuffix: props.nameSuffix,
      projectName,
    });

    this.endpointName = endpoint.endpointName;

    new cdk.CfnOutput(this, 'SmallEndpointName', {
      value: this.endpointName,
    });
  }
}
