# Docker-Based Lambda & Fargate

Comprehensive guide for deploying container-based compute with LocalStack using Docker images.

## Table of Contents
- [Docker-Based Lambda Functions](#docker-based-lambda-functions)
- [ECR Image Management](#ecr-image-management)
- [Fargate Task Orchestration](#fargate-task-orchestration)
- [Lambda-S3 Event Integration](#lambda-s3-event-integration)
- [Networking & DNS Resolution](#networking--dns-resolution)

---

## Docker-Based Lambda Functions

Deploy Lambda functions as OCI container images (up to 10GB) instead of ZIP archives.

### Lambda Runtime Interface Emulator (RIE)

AWS provides base images that include the Runtime Interface Emulator, which translates HTTP requests into Lambda's internal event loop.

**Example Dockerfile (Python):**
```dockerfile
FROM public.ecr.aws/lambda/python:3.9

# Copy application code
COPY app.py ${LAMBDA_TASK_ROOT}
COPY requirements.txt ${LAMBDA_TASK_ROOT}

# Install dependencies
RUN pip install -r requirements.txt

# Set handler
CMD [ "app.handler" ]
```

**Sample Lambda Handler (app.py):**
```python
import json
import boto3
import os

# LocalStack endpoint injection
s3 = boto3.client(
    's3',
    endpoint_url=os.environ.get('AWS_ENDPOINT_URL', 'http://localstack:4566')
)

def handler(event, context):
    """Process S3 event and return result."""
    print(f"Received event: {json.dumps(event)}")
    
    # Extract S3 bucket and key from event
    if 'Records' in event:
        for record in event['Records']:
            bucket = record['s3']['bucket']['name']
            key = record['s3']['object']['key']
            
            print(f"Processing s3://{bucket}/{key}")
            
            # Download and process file
            obj = s3.get_object(Bucket=bucket, Key=key)
            data = obj['Body'].read().decode('utf-8')
            
            print(f"File contents: {data[:100]}...")
    
    return {
        'statusCode': 200,
        'body': json.dumps({'message': 'Processing complete'})
    }
```

### Build and Push to Local ECR

```bash
# Build image
docker build -t my-lambda-processor:latest .

# Tag for LocalStack ECR
docker tag my-lambda-processor:latest \
    localhost.localstack.cloud:4566/lambda-processor:latest

# Authenticate with local ECR
awslocal ecr get-login-password --region us-east-1 | \
    docker login --username AWS --password-stdin localhost:4566

# Push to LocalStack ECR
docker push localhost.localstack.cloud:4566/lambda-processor:latest
```

**Why `localhost.localstack.cloud`?**
- Resolves to `127.0.0.1` on host (allows push from developer machine)
- Resolves to LocalStack container IP when queried via LocalStack's internal DNS (allows pull by Lambda container)

### Create Lambda Function

```bash
awslocal lambda create-function \
    --function-name data-processor \
    --package-type Image \
    --code ImageUri=localhost.localstack.cloud:4566/lambda-processor:latest \
    --role arn:aws:iam::000000000000:role/lambda-ex \
    --timeout 60 \
    --environment Variables="{
        LOG_LEVEL=DEBUG,
        AWS_ENDPOINT_URL=http://localstack:4566
    }"
```

**Critical Environment Variables:**
- `AWS_ENDPOINT_URL=http://localstack:4566`: Lambda container reaches LocalStack via container name (shared Docker network)
- Without this, Lambda SDK calls to S3/DynamoDB would fail (localhost would refer to Lambda container itself)

### Invoke and Monitor

```bash
# Invoke synchronously
awslocal lambda invoke \
    --function-name data-processor \
    --payload '{"test": "data"}' \
    response.json

# View response
cat response.json

# Tail logs in real-time
awslocal logs tail /aws/lambda/data-processor --follow
```

**Container Lifecycle:**
1. `awslocal lambda invoke` sends API request to LocalStack
2. LocalStack instructs Docker daemon to start container (via mounted `/var/run/docker.sock`)
3. Container's RIE starts listening
4. LocalStack sends event payload to RIE
5. Function executes
6. RIE returns result to LocalStack
7. `awslocal` prints result

---

## ECR Image Management

LocalStack includes fully emulated Elastic Container Registry.

### Create Repository

```bash
awslocal ecr create-repository \
    --repository-name lambda-processor \
    --image-scanning-configuration scanOnPush=true
```

**Output includes `repositoryUri`:**
```
localhost:4566/lambda-processor
```

### Authentication Workflow

```bash
# Get authorization token (mocked but follows AWS pattern)
awslocal ecr get-login-password --region us-east-1 | \
    docker login --username AWS --password-stdin localhost:4566
```

**Docker Daemon Configuration:**

If Docker rejects login to `localhost:4566`, configure as insecure registry in `daemon.json`:

```json
{
  "insecure-registries": ["localhost:4566", "localhost.localstack.cloud:4566"]
}
```

Restart Docker after modifying.

### Multi-Image Repository

```bash
# Create multiple repositories
for repo in lambda-processor fargate-backend data-pipeline; do
    awslocal ecr create-repository --repository-name $repo
done

# List repositories
awslocal ecr describe-repositories | jq '.repositories[].repositoryName'
```

### Image Lifecycle Management

```bash
# List images in repository
awslocal ecr list-images --repository-name lambda-processor

# Delete specific image
awslocal ecr batch-delete-image \
    --repository-name lambda-processor \
    --image-ids imageTag=old-version

# Delete repository (force delete with images)
awslocal ecr delete-repository \
    --repository-name lambda-processor \
    --force
```

---

## Fargate Task Orchestration

Emulate serverless container orchestration with ECS Fargate.

### Prerequisites: Cluster and Network

```bash
# Create ECS cluster
awslocal ecs create-cluster --cluster-name default

# Create VPC resources (mocked but required for Fargate)
awslocal ec2 create-vpc --cidr-block 10.0.0.0/16
awslocal ec2 create-subnet --vpc-id <vpc-id> --cidr-block 10.0.1.0/24
awslocal ec2 create-security-group --group-name fargate-sg --description "Fargate security group"
```

### Task Definition with CloudWatch Logging

```bash
awslocal ecs register-task-definition \
    --family fargate-backend \
    --network-mode awsvpc \
    --requires-compatibilities FARGATE \
    --cpu "256" \
    --memory "512" \
    --container-definitions '[{
        "name": "backend-container",
        "image": "localhost.localstack.cloud:4566/lambda-processor:latest",
        "portMappings": [{"containerPort": 80, "protocol": "tcp"}],
        "environment": [
            {"name": "AWS_ENDPOINT_URL", "value": "http://localstack:4566"},
            {"name": "LOG_LEVEL", "value": "DEBUG"}
        ],
        "logConfiguration": {
            "logDriver": "awslogs",
            "options": {
                "awslogs-group": "/ecs/fargate-backend",
                "awslogs-region": "us-east-1",
                "awslogs-stream-prefix": "ecs",
                "awslogs-create-group": "true"
            }
        }
    }]'
```

**Key Configuration:**
- `network-mode awsvpc`: Mandatory for Fargate (allocates ENI in AWS, bridges to Docker network in LocalStack)
- `logDriver: awslogs`: Routes stdout/stderr to CloudWatch Logs
- `awslogs-create-group: true`: Auto-creates log group if missing

### Create Service

```bash
# Get subnet and security group IDs
SUBNET_ID=$(awslocal ec2 describe-subnets --query 'Subnets[0].SubnetId' --output text)
SG_ID=$(awslocal ec2 describe-security-groups --query 'SecurityGroups[0].GroupId' --output text)

# Create service
awslocal ecs create-service \
    --cluster default \
    --service-name backend-service \
    --task-definition fargate-backend \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={
        subnets=[$SUBNET_ID],
        securityGroups=[$SG_ID],
        assignPublicIp=ENABLED
    }"
```

### Monitor Tasks

```bash
# List running tasks
awslocal ecs list-tasks --cluster default

# Describe task
TASK_ARN=$(awslocal ecs list-tasks --cluster default --query 'taskArns[0]' --output text)
awslocal ecs describe-tasks --cluster default --tasks $TASK_ARN

# Tail Fargate logs
awslocal logs tail /ecs/fargate-backend --follow
```

### Stop and Update Service

```bash
# Update service (change desired count)
awslocal ecs update-service \
    --cluster default \
    --service backend-service \
    --desired-count 2

# Stop service (scale to zero)
awslocal ecs update-service \
    --cluster default \
    --service backend-service \
    --desired-count 0

# Delete service
awslocal ecs delete-service \
    --cluster default \
    --service backend-service \
    --force
```

---

## Lambda-S3 Event Integration

Wire S3 object creation events to trigger Lambda functions.

### Setup S3 Bucket

```bash
# Create bucket
awslocal s3 mb s3://raw-data-ingest

# Create logical path structure (S3 "folders" are prefixes)
awslocal s3api put-object \
    --bucket raw-data-ingest \
    --key input/2023/10/ \
    --content-length 0
```

### Configure Event Notification

**Create notification configuration (notification.json):**
```json
{
  "LambdaFunctionConfigurations": [
    {
      "LambdaFunctionArn": "arn:aws:lambda:us-east-1:000000000000:function:data-processor",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            {"Name": "prefix", "Value": "input/"},
            {"Name": "suffix", "Value": ".csv"}
          ]
        }
      }
    }
  ]
}
```

**Apply configuration:**
```bash
awslocal s3api put-bucket-notification-configuration \
    --bucket raw-data-ingest \
    --notification-configuration file://notification.json
```

### Test Event Trigger

```bash
# Upload file (triggers Lambda)
echo "id,name,value" > test-data.csv
echo "1,Alice,100" >> test-data.csv
echo "2,Bob,200" >> test-data.csv

awslocal s3 cp test-data.csv s3://raw-data-ingest/input/2023/10/test-data.csv

# Monitor Lambda invocation
awslocal logs tail /aws/lambda/data-processor --follow
```

**Verify notification:**
```bash
# Check notification configuration
awslocal s3api get-bucket-notification-configuration \
    --bucket raw-data-ingest | jq
```

### Event Types

S3 emits different event types based on upload method:
- `s3:ObjectCreated:Put`: Single-part upload
- `s3:ObjectCreated:CompleteMultipartUpload`: Multi-part upload completion
- `s3:ObjectCreated:*`: Matches all creation events (recommended for testing)

---

## Networking & DNS Resolution

Understanding container-to-container communication is critical for debugging.

### Network Topology

```
┌─────────────────────────────────────────────────┐
│ Host Machine (Developer Workstation)            │
│                                                  │
│  ┌─────────────┐         ┌──────────────────┐  │
│  │   awslocal  │────────▶│  localhost:4566  │  │
│  └─────────────┘         └──────────────────┘  │
│                                   │             │
│                                   ▼             │
│  ┌──────────────────────────────────────────┐  │
│  │      Docker Bridge Network                │  │
│  │                                            │  │
│  │  ┌──────────────┐   ┌─────────────────┐  │  │
│  │  │ LocalStack   │◀──│ Lambda/Fargate  │  │  │
│  │  │ Container    │   │ Containers      │  │  │
│  │  │ (localstack) │   │                 │  │  │
│  │  └──────────────┘   └─────────────────┘  │  │
│  │                                            │  │
│  └──────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

### DNS Resolution Strategies

**From Host (awslocal commands):**
- `localhost:4566` → LocalStack edge port
- `localhost.localstack.cloud:4566` → Resolves to `127.0.0.1`, routes to LocalStack

**From Lambda/Fargate Containers:**
- `localhost:4566` → ❌ FAILS (refers to container itself)
- `localstack:4566` → ✅ Resolves to LocalStack container (via Docker DNS)
- `localhost.localstack.cloud:4566` → ✅ Works if LocalStack DNS forwarding configured

### S3 Endpoint Styles

**Virtual-Hosted Style (recommended):**
```
http://bucket-name.s3.localhost.localstack.cloud:4566/key
```

**Path-Style (fallback for DNS issues):**
```
http://localhost.localstack.cloud:4566/bucket-name/key
```

**SDK Configuration (Python boto3):**
```python
import boto3
import os

# Virtual-hosted style
s3 = boto3.client(
    's3',
    endpoint_url='http://localstack:4566',  # From container
    # endpoint_url='http://localhost:4566',  # From host
)

# Force path-style if DNS issues
s3 = boto3.client(
    's3',
    endpoint_url='http://localstack:4566',
    config=boto3.session.Config(s3={'addressing_style': 'path'})
)
```

### Troubleshooting Connectivity

**Problem: Lambda can't reach S3/DynamoDB**

**Solution 1: Environment Variable**
```bash
awslocal lambda update-function-configuration \
    --function-name data-processor \
    --environment Variables="{AWS_ENDPOINT_URL=http://localstack:4566}"
```

**Solution 2: Verify Docker Network**
```bash
# Check Lambda network
docker network inspect localstack_network | jq '.[0].Containers'

# Ensure LAMBDA_DOCKER_NETWORK set in docker-compose.yml
export LAMBDA_DOCKER_NETWORK=localstack_network
```

**Solution 3: Test DNS Resolution from Container**
```bash
# Enter running Lambda/Fargate container
docker exec -it <container-id> /bin/sh

# Test DNS
nslookup localstack
ping -c 1 localstack

# Test HTTP connectivity
curl http://localstack:4566/_localstack/health
```

### Complete Example: End-to-End Workflow

See [examples/e2e-lambda-fargate-s3.sh](../examples/e2e-lambda-fargate-s3.sh) for a full script that:
1. Builds Docker image
2. Pushes to local ECR
3. Creates Lambda function with S3 trigger
4. Deploys Fargate task
5. Uploads file to S3
6. Monitors Lambda execution logs
7. Verifies Fargate task can access S3
