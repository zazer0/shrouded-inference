import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import * as iam from 'aws-cdk-lib/aws-iam';

export interface GithubOidcStackProps extends cdk.StackProps {
  /** Logical environment name (e.g., 'prod', 'staging'). */
  envName?: string;
  /** Suffix applied to physical resource names ('' for prod). */
  nameSuffix?: string;
}

export class GithubOidcStack extends cdk.Stack {
  public readonly deployRoleArn: string;

  constructor(scope: Construct, id: string, props?: GithubOidcStackProps) {
    super(scope, id, props);

    const githubRepo =
      process.env.GITHUB_REPOSITORY ??
      (this.node.tryGetContext('githubRepo') as string | undefined);

    if (!githubRepo || !/^[\w.-]+\/[\w.-]+$/.test(githubRepo)) {
      throw new Error(
        'GithubOidcStack: could not resolve <owner>/<repo>. ' +
        'GITHUB_REPOSITORY is auto-set in GitHub Actions. ' +
        'For a local cdk deploy (first-time setup or post-rename recovery), ' +
        'pass --context githubRepo=<owner>/<repo>. ' +
        'Refusing to synth a trust policy against an unknown repo.',
      );
    }

    const oidcProvider = new iam.OpenIdConnectProvider(this, 'GithubOidcProvider', {
      url: 'https://token.actions.githubusercontent.com',
      clientIds: ['sts.amazonaws.com'],
      thumbprints: ['6938fd4d98bab03faadb97b34396831e3780aea1'],
    });

    const deployRole = new iam.Role(this, 'GithubActionsDeployRole', {
      roleName: 'gnn-serving-github-actions-deploy',
      assumedBy: new iam.FederatedPrincipal(
        oidcProvider.openIdConnectProviderArn,
        {
          StringEquals: {
            'token.actions.githubusercontent.com:aud': 'sts.amazonaws.com',
          },
          StringLike: {
            'token.actions.githubusercontent.com:sub': [
              `repo:${githubRepo}:ref:refs/heads/main`,
              `repo:${githubRepo}:pull_request`,
            ],
          },
        },
        'sts:AssumeRoleWithWebIdentity',
      ),
      maxSessionDuration: cdk.Duration.hours(1),
    });

    deployRole.addManagedPolicy(
      iam.ManagedPolicy.fromAwsManagedPolicyName('AdministratorAccess'),
    );

    this.deployRoleArn = deployRole.roleArn;

    new cdk.CfnOutput(this, 'DeployRoleArn', {
      value: deployRole.roleArn,
      description: 'ARN of the GitHub Actions deploy role — add as GitHub secret AWS_DEPLOY_ROLE_ARN',
    });
  }
}
