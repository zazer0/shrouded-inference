import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import * as ecr from 'aws-cdk-lib/aws-ecr';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as s3deploy from 'aws-cdk-lib/aws-s3-deployment';

export interface CoreStackProps extends cdk.StackProps {
  /** Logical environment name (e.g., 'prod', 'staging'). */
  envName?: string;
  /** Suffix applied to physical resource names ('' for prod). */
  nameSuffix?: string;
}

export class CoreStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: CoreStackProps) {
    super(scope, id, props);

    const projectName = this.node.tryGetContext('projectName') as string ?? 'shrouded-inference';
    const envName = props?.envName ?? 'prod';
    const suffix = props?.nameSuffix ?? '';
    const isProd = envName === 'prod';

    // --------------- ECR Repositories ---------------

    const repoNames = [`${projectName}-dispatcher`, `${projectName}-graphsage-inference`, `${projectName}-equiformer-inference`];
    const repos: ecr.Repository[] = [];

    for (const name of repoNames) {
      const repo = new ecr.Repository(this, `${name}-repo`, {
        repositoryName: `${name}${suffix}`,
        removalPolicy: isProd ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
        emptyOnDelete: !isProd,
        lifecycleRules: [
          {
            maxImageCount: 10,
            tagStatus: ecr.TagStatus.ANY,
            description: `Keep last 10 images for ${name}`,
          },
        ],
      });
      repos.push(repo);
    }

    // --------------- S3 Bucket ---------------

    const modelArtifactsBucket = new s3.Bucket(this, 'ModelArtifactsBucket', {
      bucketName: `${projectName}-model-artifacts-${this.account}${suffix}`,
      removalPolicy: isProd ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: !isProd,
      versioned: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
    });

    // --------------- Seed Model Artifacts (non-prod only) ---------------
    // Per-env model-artifacts seeding (multi-env split):
    //   - Graphsage (~845 KB) is committed to the repo and seeded via
    //     CDK BucketDeployment so its provenance lives with the code.
    //   - Equiformer (~115 MB) exceeds GitHub's 100 MB per-file limit;
    //     it's seeded from the prod bucket by the deploy workflow's
    //     "Seed equiformer artifact" step (.github/workflows/deploy.yml)
    //     before `cdk deploy --all`.
    // Prod's equiformer artifact is uploaded out-of-band (file exceeds git's 100 MB limit); the gate
    // ensures CDK does not touch it.
    if (!isProd) {
      new s3deploy.BucketDeployment(this, 'GraphsageArtifacts', {
        sources: [s3deploy.Source.asset('../model-artifacts/graphsage')],
        destinationBucket: modelArtifactsBucket,
        destinationKeyPrefix: 'graphsage',
        prune: false,
      });
    }

    // --------------- CloudFormation Outputs ---------------

    for (let i = 0; i < repoNames.length; i++) {
      new cdk.CfnOutput(this, `${repoNames[i]}-repo-uri`, {
        value: repos[i].repositoryUri,
        description: `ECR repository URI for ${repoNames[i]}`,
      });
    }

    new cdk.CfnOutput(this, 'ModelArtifactsBucketName', {
      value: modelArtifactsBucket.bucketName,
      description: 'S3 bucket for GNN model artifacts',
    });
  }
}
