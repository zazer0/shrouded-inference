import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import * as ecr from 'aws-cdk-lib/aws-ecr';

export class BuildCacheStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const cacheRepo = new ecr.Repository(this, 'equiformer-cache-repo', {
      repositoryName: 'equiformer-cache',
      imageTagMutability: ecr.TagMutability.MUTABLE,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    new cdk.CfnOutput(this, 'EquiformerCacheRepoUri', {
      value: cacheRepo.repositoryUri,
      description: 'ECR repository URI for buildx layer cache',
    });
  }
}
