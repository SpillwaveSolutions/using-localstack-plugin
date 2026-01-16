# IaC Deployment

Deploy infrastructure as code against LocalStack using Terraform, CDK, or CloudFormation.

## Terraform with tflocal

### Installation
```bash
pip install terraform-local
```

`tflocal` wraps Terraform CLI and presets AWS provider endpoints to `http://localhost:4566`.

### Basic Usage
```bash
# Initialize (downloads providers)
tflocal init

# Plan
tflocal plan

# Apply
tflocal apply

# Destroy
tflocal destroy
```

### Provider Configuration

**Option 1: Use tflocal (recommended)**
```hcl
# provider.tf - standard AWS provider
provider "aws" {
  region = "us-east-1"
}

# tflocal automatically sets endpoints
```

**Option 2: Manual endpoint override**
```hcl
provider "aws" {
  region = "us-east-1"
  
  endpoints {
    s3             = "http://localhost:4566"
    lambda         = "http://localhost:4566"
    dynamodb       = "http://localhost:4566"
    apigateway     = "http://localhost:4566"
    # Add other services as needed
  }
  
  # Use any credentials (not validated in LocalStack Community)
  access_key = "test"
  secret_key = "test"
  
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}
```

### State Backend (optional: use LocalStack S3)
```hcl
terraform {
  backend "s3" {
    bucket         = "terraform-state"
    key            = "state/terraform.tfstate"
    region         = "us-east-1"
    endpoint       = "http://localhost:4566"
    
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    force_path_style            = true
  }
}
```

Create backend bucket first:
```bash
awslocal s3 mb s3://terraform-state
```

### Reproducibility Best Practices
- Pin LocalStack image version: `--version 3.0.2`
- Pin Terraform provider versions in `required_providers`
- Use AWS provider v4 if v5 schema issues arise (check LocalStack docs for compatibility)

### Example: S3 + Lambda
```hcl
resource "aws_s3_bucket" "uploads" {
  bucket = "my-uploads"
}

resource "aws_lambda_function" "processor" {
  filename      = "lambda.zip"
  function_name = "upload-processor"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.handler"
  runtime       = "python3.11"
}

resource "aws_s3_bucket_notification" "upload_trigger" {
  bucket = aws_s3_bucket.uploads.id
  
  lambda_function {
    lambda_function_arn = aws_lambda_function.processor.arn
    events              = ["s3:ObjectCreated:*"]
  }
}
```

## AWS CDK with cdklocal

### Installation
```bash
npm install -g aws-cdk-local aws-cdk
```

`cdklocal` wraps CDK CLI and configures LocalStack endpoints.

### Bootstrap
```bash
# One-time setup (creates staging bucket in LocalStack S3)
cdklocal bootstrap
```

### Deploy Stack
```bash
# Synthesize CloudFormation template
cdklocal synth

# Deploy
cdklocal deploy

# Destroy
cdklocal destroy
```

### Stack Definition Example (TypeScript)
```typescript
import * as cdk from 'aws-cdk-lib';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as s3n from 'aws-cdk-lib/aws-s3-notifications';

export class MyStack extends cdk.Stack {
  constructor(scope: cdk.App, id: string, props?: cdk.StackProps) {
    super(scope, id, props);
    
    const bucket = new s3.Bucket(this, 'UploadBucket');
    
    const handler = new lambda.Function(this, 'Processor', {
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda'),
    });
    
    bucket.addEventNotification(
      s3.EventType.OBJECT_CREATED,
      new s3n.LambdaDestination(handler)
    );
  }
}
```

### Context and Lookups
CDK may attempt AWS API lookups (VPCs, hosted zones, etc.). If failing:
- Supply values via `cdk.json` context
- Use `CDK_DEFAULT_ACCOUNT=000000000000` and `CDK_DEFAULT_REGION=us-east-1`

## CloudFormation Direct

### Deploy Template
```bash
# Create stack
awslocal cloudformation create-stack \
  --stack-name my-stack \
  --template-body file://template.yaml \
  --parameters ParameterKey=BucketName,ParameterValue=my-bucket

# Check status
awslocal cloudformation describe-stacks --stack-name my-stack

# View events (useful for debugging failures)
awslocal cloudformation describe-stack-events --stack-name my-stack

# Update stack
awslocal cloudformation update-stack \
  --stack-name my-stack \
  --template-body file://template-v2.yaml

# Delete stack
awslocal cloudformation delete-stack --stack-name my-stack
```

### Change Sets (preview changes)
```bash
# Create change set
awslocal cloudformation create-change-set \
  --stack-name my-stack \
  --change-set-name my-changes \
  --template-body file://template-v2.yaml

# Review changes
awslocal cloudformation describe-change-set \
  --stack-name my-stack \
  --change-set-name my-changes

# Execute
awslocal cloudformation execute-change-set \
  --stack-name my-stack \
  --change-set-name my-changes
```

### Custom Resources
Lambda-backed custom resources generally work. LocalStack executes Lambda and processes custom resource responses.

### Example Template (YAML)
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Resources:
  UploadBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: my-uploads
      NotificationConfiguration:
        LambdaConfigurations:
          - Event: s3:ObjectCreated:*
            Function: !GetAtt ProcessorFunction.Arn
  
  ProcessorFunction:
    Type: AWS::Lambda::Function
    Properties:
      FunctionName: upload-processor
      Runtime: python3.11
      Handler: index.handler
      Code:
        ZipFile: |
          def handler(event, context):
              print(event)
              return {'statusCode': 200}
      Role: !GetAtt LambdaRole.Arn
  
  LambdaRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: lambda.amazonaws.com
            Action: sts:AssumeRole
```

## Troubleshooting IaC Deployments

### Terraform Issues
- **Provider version mismatch:** Pin AWS provider to v4 if v5 causes schema issues
- **State locking errors:** Check S3 backend bucket exists: `awslocal s3 ls s3://terraform-state`
- **Resource creation fails:** Check LocalStack logs: `docker logs localstack | grep ERROR`

### CDK Issues
- **Bootstrap fails:** Verify LocalStack is running and S3 service is available
- **Lookup failures:** Supply context values in `cdk.json` or use env vars for account/region
- **Asset upload errors:** Check CDK staging bucket exists in LocalStack S3

### CloudFormation Issues
- **Stack stuck in CREATE_IN_PROGRESS:** Check stack events for specific resource failure
- **Custom resource timeout:** Verify Lambda handler returns proper CloudFormation response format
- **Resource not found:** Ensure dependent resources created first (check DependsOn attribute)
