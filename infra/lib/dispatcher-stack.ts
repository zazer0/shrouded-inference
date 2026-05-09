import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as ecr from 'aws-cdk-lib/aws-ecr';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as kms from 'aws-cdk-lib/aws-kms';

interface DispatcherStackProps extends cdk.StackProps {
  asyncIoBucket: s3.IBucket;
  /**
   * Customer-managed KMS key shared by async-io bucket, telemetry table, and
   * SageMaker async output. The dispatcher task role needs encrypt/decrypt
   * to read/write KMS-encrypted objects in those resources.
   */
  cmk: kms.IKey;
  /**
   * Name (NOT ARN) of the secret holding the SHA256(api-key) → tier map.
   * Resolved internally via `Secret.fromSecretNameV2`. Same name in every env
   * (`gnn-serving/api-keys`); prod owns the lifecycle in `SecretsStack`.
   */
  apiKeysSecretName: string;
  telemetryTable: dynamodb.ITable;
  smallEndpointName: string;
  largeEndpointName: string;
  /**
   * Git SHA of the deploying commit. Injected into the dispatcher container
   * via task-def env (NOT a docker build-arg) so the image stays content-only
   * and truly cacheable; `/healthz` echoes this at runtime.
   */
  imageTag: string;
  /** Logical environment name (e.g., 'prod', 'staging'). Defaults to 'prod'. */
  envName?: string;
  /** Suffix applied to physical resource names ('' for prod, '-<env>' otherwise). */
  nameSuffix?: string;
}

export class DispatcherStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: DispatcherStackProps) {
    super(scope, id, props);

    // Import the api-keys secret by name. Prod's SecretsStack owns it;
    // ephemeral envs share the exact same secret so dispatcher auth is
    // identical across envs without per-env secret churn.
    const apiKeysSecret = secretsmanager.Secret.fromSecretNameV2(
      this,
      'ApiKeysSecret',
      props.apiKeysSecretName,
    );

    // --- VPC (default) ---
    const vpc = ec2.Vpc.fromLookup(this, 'DefaultVpc', { isDefault: true });

    // --- ECS Cluster ---
    const cluster = new ecs.Cluster(this, 'Cluster', { vpc });

    // --- Task Definition ---
    const taskDef = new ecs.FargateTaskDefinition(this, 'TaskDef', {
      cpu: 256,
      memoryLimitMiB: 512,
    });

    taskDef.taskRole.addToPrincipalPolicy(
      new iam.PolicyStatement({
        actions: ['sagemaker:InvokeEndpointAsync'],
        resources: ['*'],
      }),
    );

    // Allow the dispatcher to resolve the running model version of each tier
    // at request time. DescribeEndpoint is scoped to the small + large
    // endpoint ARNs; DescribeEndpointConfig and DescribeModel target derived
    // resources whose names are not known at stack-synthesis time, so they
    // use Resource: '*' (read-only describe APIs, low blast radius).
    taskDef.taskRole.addToPrincipalPolicy(
      new iam.PolicyStatement({
        actions: ['sagemaker:DescribeEndpoint'],
        resources: [
          `arn:aws:sagemaker:${this.region}:${this.account}:endpoint/${props.smallEndpointName}`,
          `arn:aws:sagemaker:${this.region}:${this.account}:endpoint/${props.largeEndpointName}`,
        ],
      }),
    );
    taskDef.taskRole.addToPrincipalPolicy(
      new iam.PolicyStatement({
        actions: ['sagemaker:DescribeEndpointConfig', 'sagemaker:DescribeModel'],
        // EndpointConfig and Model names are derived from CFN at deploy time
        // and not stable for ARN-scoping; the actions are read-only metadata.
        resources: ['*'],
      }),
    );

    props.asyncIoBucket.grantReadWrite(taskDef.taskRole);
    // Customer input flows through the async-io bucket, the telemetry table,
    // and SageMaker's KMS-encrypted async output — all using the shared CMK.
    // The task role is the only operator-side principal granted decrypt.
    props.cmk.grantEncryptDecrypt(taskDef.taskRole);
    apiKeysSecret.grantRead(taskDef.taskRole);
    props.telemetryTable.grantReadWriteData(taskDef.taskRole);

    // --- Container ---
    const dispatcherRepo = ecr.Repository.fromRepositoryName(
      this,
      'DispatcherRepo',
      `dispatcher${props.nameSuffix ?? ''}`,
    );

    taskDef.addContainer('dispatcher', {
      image: ecs.ContainerImage.fromEcrRepository(dispatcherRepo, props.imageTag),
      portMappings: [{ containerPort: 8000 }],
      environment: {
        SMALL_ENDPOINT_NAME: props.smallEndpointName,
        LARGE_ENDPOINT_NAME: props.largeEndpointName,
        SECRET_ARN: apiKeysSecret.secretArn,
        ASYNC_IO_BUCKET: props.asyncIoBucket.bucketName,
        TELEMETRY_TABLE_NAME: props.telemetryTable.tableName,
        ENV_NAME: props.envName ?? 'prod',
        GIT_SHA: props.imageTag,
      },
      logging: ecs.LogDrivers.awsLogs({ streamPrefix: 'dispatcher' }),
    });

    // --- ALB ---
    const alb = new elbv2.ApplicationLoadBalancer(this, 'ALB', {
      vpc,
      internetFacing: true,
    });

    const listener = alb.addListener('HttpListener', { port: 80 });

    // --- Fargate Service ---
    const service = new ecs.FargateService(this, 'Service', {
      cluster,
      taskDefinition: taskDef,
      desiredCount: 1,
      assignPublicIp: true,
    });

    listener.addTargets('DispatcherTarget', {
      port: 8000,
      targets: [service],
      healthCheck: {
        path: '/healthz',
        interval: cdk.Duration.seconds(30),
        healthyThresholdCount: 2,
        unhealthyThresholdCount: 3,
      },
    });

    // --- CloudFront (HTTPS via default *.cloudfront.net cert) ---
    const distribution = new cloudfront.Distribution(this, 'Cdn', {
      defaultBehavior: {
        origin: new origins.LoadBalancerV2Origin(alb, {
          protocolPolicy: cloudfront.OriginProtocolPolicy.HTTP_ONLY,
        }),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
        // FastAPI is dynamic — disable caching so /healthz, /v1/predict, and
        // telemetry POSTs always hit origin.
        cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
        originRequestPolicy: cloudfront.OriginRequestPolicy.ALL_VIEWER,
      },
      comment: `gnn-dispatcher-${props.envName ?? 'prod'}`,
    });

    // --- Outputs ---
    new cdk.CfnOutput(this, 'AlbDnsName', {
      value: alb.loadBalancerDnsName,
      description: 'ALB DNS for the dispatcher service',
    });
    new cdk.CfnOutput(this, 'CdnDomain', {
      value: `https://${distribution.domainName}`,
      description: 'CloudFront HTTPS URL fronting the ALB',
    });
  }
}
