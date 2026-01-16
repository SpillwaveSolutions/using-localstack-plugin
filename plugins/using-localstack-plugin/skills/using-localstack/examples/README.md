# Examples and Scripts

Practical examples and helper scripts for common LocalStack workflows.

## Available Examples

### End-to-End Workflows

**[e2e-lambda-fargate-s3.sh](e2e-lambda-fargate-s3.sh)**
Complete workflow demonstrating:
- Docker image build and ECR push
- Lambda function with S3 event trigger
- Fargate task deployment
- CloudWatch Logs monitoring

**Usage:**
```bash
# Ensure LocalStack is running
docker-compose up -d

# Run example
./examples/e2e-lambda-fargate-s3.sh
```

### Helper Scripts

**[ecr-helper.sh](ecr-helper.sh)**
ECR repository and image management utility.

**Commands:**
```bash
# Create repository
./examples/ecr-helper.sh create lambda-processor

# Build and push image
./examples/ecr-helper.sh build-push ./my-app lambda-processor v1.0.0

# List images
./examples/ecr-helper.sh list-images lambda-processor

# Get repository URI
./examples/ecr-helper.sh get-uri lambda-processor

# Delete repository
./examples/ecr-helper.sh delete-repo lambda-processor true
```

### Docker Compose Configuration

**[docker-compose.yml](docker-compose.yml)**
Production-grade LocalStack configuration with:
- Dedicated Docker network for Lambda/Fargate
- Persistent volume mounts
- Health checks
- Environment variable templates

**Usage:**
```bash
# Set auth token
export LOCALSTACK_AUTH_TOKEN=<your-token>

# Start LocalStack
docker-compose up -d

# View logs
docker-compose logs -f localstack

# Stop LocalStack
docker-compose down
```

## Quick Start Examples

### Lambda Function (Docker-based)

**Dockerfile:**
```dockerfile
FROM public.ecr.aws/lambda/python:3.9
COPY app.py ${LAMBDA_TASK_ROOT}
CMD [ "app.handler" ]
```

**app.py:**
```python
import json

def handler(event, context):
    return {
        'statusCode': 200,
        'body': json.dumps({'message': 'Hello from LocalStack!'})
    }
```

**Deploy:**
```bash
# Build and tag
docker build -t my-lambda .
docker tag my-lambda localhost.localstack.cloud:4566/my-lambda:latest

# Push to ECR
awslocal ecr create-repository --repository-name my-lambda
awslocal ecr get-login-password | docker login --username AWS --password-stdin localhost:4566
docker push localhost.localstack.cloud:4566/my-lambda:latest

# Create function
awslocal lambda create-function \
    --function-name my-lambda \
    --package-type Image \
    --code ImageUri=localhost.localstack.cloud:4566/my-lambda:latest \
    --role arn:aws:iam::000000000000:role/lambda-role

# Invoke
awslocal lambda invoke --function-name my-lambda output.json
cat output.json
```

### S3 Event Notification

```bash
# Create bucket
awslocal s3 mb s3://my-bucket

# Create notification config
cat > notification.json << EOF
{
  "LambdaFunctionConfigurations": [{
    "LambdaFunctionArn": "arn:aws:lambda:us-east-1:000000000000:function:my-lambda",
    "Events": ["s3:ObjectCreated:*"]
  }]
}
EOF

# Apply config
awslocal s3api put-bucket-notification-configuration \
    --bucket my-bucket \
    --notification-configuration file://notification.json

# Test trigger
echo "test data" > test.txt
awslocal s3 cp test.txt s3://my-bucket/

# Monitor logs
awslocal logs tail /aws/lambda/my-lambda --follow
```

### Fargate Task

```bash
# Create cluster
awslocal ecs create-cluster --cluster-name default

# Register task definition
awslocal ecs register-task-definition \
    --family my-task \
    --network-mode awsvpc \
    --requires-compatibilities FARGATE \
    --cpu 256 \
    --memory 512 \
    --container-definitions '[{
        "name": "my-container",
        "image": "localhost.localstack.cloud:4566/my-image:latest",
        "environment": [
            {"name": "AWS_ENDPOINT_URL", "value": "http://localstack:4566"}
        ],
        "logConfiguration": {
            "logDriver": "awslogs",
            "options": {
                "awslogs-group": "/ecs/my-task",
                "awslogs-region": "us-east-1",
                "awslogs-stream-prefix": "ecs",
                "awslogs-create-group": "true"
            }
        }
    }]'

# Run task
awslocal ecs run-task \
    --cluster default \
    --task-definition my-task \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[subnet-123],assignPublicIp=ENABLED}"

# Monitor logs
awslocal logs tail /ecs/my-task --follow
```

## Troubleshooting Examples

### Debug Lambda Networking

```bash
# Check Lambda container network
docker ps --filter "name=localstack_lambda_" --format "{{.ID}}: {{.Names}}"

# Inspect Lambda container network
CONTAINER_ID=$(docker ps -q --filter "name=localstack_lambda_" | head -1)
docker inspect $CONTAINER_ID | jq '.[0].NetworkSettings.Networks'

# Test connectivity from Lambda
docker exec $CONTAINER_ID curl http://localstack:4566/_localstack/health
```

### Verify ECR Image Availability

```bash
# Check if image exists in ECR
awslocal ecr describe-images \
    --repository-name my-repo \
    --image-ids imageTag=latest

# Verify image can be pulled
docker pull localhost.localstack.cloud:4566/my-repo:latest
```

### Monitor All CloudWatch Log Groups

```bash
# List all log groups
awslocal logs describe-log-groups --query 'logGroups[].logGroupName' --output text

# Tail multiple log groups
for group in $(awslocal logs describe-log-groups --query 'logGroups[].logGroupName' --output text); do
    echo "=== $group ==="
    awslocal logs tail $group --since 5m
done
```

## Performance Testing Examples

### Lambda Cold Start Measurement

```bash
# Invoke Lambda and measure timing
time awslocal lambda invoke \
    --function-name my-lambda \
    --invocation-type RequestResponse \
    output.json

# Warm invocation (container reused)
time awslocal lambda invoke \
    --function-name my-lambda \
    --invocation-type RequestResponse \
    output.json
```

### S3 Upload Performance

```bash
# Generate test file
dd if=/dev/urandom of=test-1mb.bin bs=1M count=1

# Measure upload time
time awslocal s3 cp test-1mb.bin s3://my-bucket/

# Measure multipart upload (larger file)
dd if=/dev/urandom of=test-100mb.bin bs=1M count=100
time awslocal s3 cp test-100mb.bin s3://my-bucket/
```

## Integration Testing Examples

### Python Integration Test

```python
import boto3
import pytest

@pytest.fixture
def s3_client():
    return boto3.client(
        's3',
        endpoint_url='http://localhost:4566',
        aws_access_key_id='test',
        aws_secret_access_key='test',
        region_name='us-east-1'
    )

def test_s3_upload_download(s3_client):
    bucket = 'test-bucket'
    key = 'test-file.txt'
    content = b'test data'
    
    # Create bucket
    s3_client.create_bucket(Bucket=bucket)
    
    # Upload file
    s3_client.put_object(Bucket=bucket, Key=key, Body=content)
    
    # Download file
    response = s3_client.get_object(Bucket=bucket, Key=key)
    assert response['Body'].read() == content
```

### Node.js Integration Test

```javascript
const AWS = require('aws-sdk');
const assert = require('assert');

const s3 = new AWS.S3({
    endpoint: 'http://localhost:4566',
    s3ForcePathStyle: true,
    accessKeyId: 'test',
    secretAccessKey: 'test',
    region: 'us-east-1'
});

describe('S3 Integration', () => {
    it('should upload and download file', async () => {
        const bucket = 'test-bucket';
        const key = 'test-file.txt';
        const content = 'test data';
        
        // Create bucket
        await s3.createBucket({ Bucket: bucket }).promise();
        
        // Upload file
        await s3.putObject({
            Bucket: bucket,
            Key: key,
            Body: content
        }).promise();
        
        // Download file
        const response = await s3.getObject({
            Bucket: bucket,
            Key: key
        }).promise();
        
        assert.strictEqual(response.Body.toString(), content);
    });
});
```

## Additional Resources

- [Docker-Based Lambda & Fargate Guide](../references/docker-lambda-fargate.md)
- [Service Workflows](../references/services.md)
- [Debugging & Observability](../references/debugging.md)
