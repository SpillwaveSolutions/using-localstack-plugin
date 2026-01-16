#!/bin/bash
# End-to-End Example: Docker-based Lambda triggered by S3, with Fargate accessing results
# 
# This script demonstrates a complete workflow:
# 1. Build and push Docker image to local ECR
# 2. Create Lambda function that processes S3 uploads
# 3. Configure S3 event notification to trigger Lambda
# 4. Deploy Fargate task that reads processed results
# 5. Upload test file to S3
# 6. Monitor Lambda execution and Fargate logs

set -e  # Exit on error

echo "=== LocalStack End-to-End Example ==="
echo "Prerequisites: LocalStack running via docker-compose up -d"
echo ""

# Configuration
ECR_REPO="data-processor"
LAMBDA_FUNCTION="data-processor"
S3_BUCKET="raw-data-ingest"
FARGATE_FAMILY="result-reader"
CLUSTER_NAME="default"
SERVICE_NAME="result-reader-service"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Wait for LocalStack to be ready
log_info "Waiting for LocalStack to be ready..."
until curl -sf http://localhost:4566/_localstack/health > /dev/null; do
    log_warn "Waiting for LocalStack..."
    sleep 2
done
log_info "LocalStack is ready!"

# Step 1: Create and push Docker image
log_info "Step 1: Building Docker image for Lambda/Fargate"

mkdir -p ./build
cat > ./build/app.py << 'EOF'
import json
import boto3
import os

s3 = boto3.client(
    's3',
    endpoint_url=os.environ.get('AWS_ENDPOINT_URL', 'http://localstack:4566')
)

def handler(event, context):
    """Process S3 event and write result."""
    print(f"Received event: {json.dumps(event)}")
    
    if 'Records' in event:
        for record in event['Records']:
            bucket = record['s3']['bucket']['name']
            key = record['s3']['object']['key']
            
            print(f"Processing s3://{bucket}/{key}")
            
            # Read input file
            obj = s3.get_object(Bucket=bucket, Key=key)
            data = obj['Body'].read().decode('utf-8')
            lines = data.strip().split('\n')
            
            print(f"File has {len(lines)} lines")
            
            # Write processed result
            result_key = key.replace('input/', 'output/').replace('.csv', '.processed.txt')
            result_data = f"Processed {len(lines)} lines from {key}\n"
            result_data += f"First line: {lines[0] if lines else 'N/A'}\n"
            
            s3.put_object(
                Bucket=bucket,
                Key=result_key,
                Body=result_data.encode('utf-8')
            )
            
            print(f"Wrote result to s3://{bucket}/{result_key}")
    
    return {
        'statusCode': 200,
        'body': json.dumps({'message': 'Processing complete'})
    }
EOF

cat > ./build/requirements.txt << EOF
boto3>=1.26.0
EOF

cat > ./build/Dockerfile << EOF
FROM public.ecr.aws/lambda/python:3.9
COPY app.py \${LAMBDA_TASK_ROOT}
COPY requirements.txt \${LAMBDA_TASK_ROOT}
RUN pip install -r requirements.txt
CMD [ "app.handler" ]
EOF

docker build -t ${ECR_REPO}:latest ./build
log_info "Docker image built successfully"

# Step 2: Create ECR repository and push
log_info "Step 2: Creating ECR repository and pushing image"

awslocal ecr create-repository --repository-name ${ECR_REPO} 2>/dev/null || true

# Authenticate with ECR
awslocal ecr get-login-password --region us-east-1 | \
    docker login --username AWS --password-stdin localhost:4566 2>/dev/null || true

# Tag and push
docker tag ${ECR_REPO}:latest localhost.localstack.cloud:4566/${ECR_REPO}:latest
docker push localhost.localstack.cloud:4566/${ECR_REPO}:latest

log_info "Image pushed to local ECR"

# Step 3: Create S3 bucket
log_info "Step 3: Creating S3 bucket"

awslocal s3 mb s3://${S3_BUCKET} 2>/dev/null || true
awslocal s3api put-object --bucket ${S3_BUCKET} --key input/ --content-length 0
awslocal s3api put-object --bucket ${S3_BUCKET} --key output/ --content-length 0

log_info "S3 bucket created with input/ and output/ prefixes"

# Step 4: Create Lambda function
log_info "Step 4: Creating Lambda function"

awslocal lambda create-function \
    --function-name ${LAMBDA_FUNCTION} \
    --package-type Image \
    --code ImageUri=localhost.localstack.cloud:4566/${ECR_REPO}:latest \
    --role arn:aws:iam::000000000000:role/lambda-ex \
    --timeout 60 \
    --environment Variables="{
        LOG_LEVEL=DEBUG,
        AWS_ENDPOINT_URL=http://localstack:4566
    }" 2>/dev/null || log_warn "Lambda function already exists"

log_info "Lambda function created"

# Step 5: Configure S3 event notification
log_info "Step 5: Configuring S3 event notification"

cat > /tmp/notification.json << EOF
{
  "LambdaFunctionConfigurations": [
    {
      "LambdaFunctionArn": "arn:aws:lambda:us-east-1:000000000000:function:${LAMBDA_FUNCTION}",
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
EOF

awslocal s3api put-bucket-notification-configuration \
    --bucket ${S3_BUCKET} \
    --notification-configuration file:///tmp/notification.json

log_info "S3 event notification configured"

# Step 6: Create Fargate task definition
log_info "Step 6: Creating Fargate task definition"

awslocal ecs create-cluster --cluster-name ${CLUSTER_NAME} 2>/dev/null || true

# Create VPC resources (mocked)
VPC_ID=$(awslocal ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text 2>/dev/null || echo "vpc-123")
SUBNET_ID=$(awslocal ec2 create-subnet --vpc-id ${VPC_ID} --cidr-block 10.0.1.0/24 --query 'Subnet.SubnetId' --output text 2>/dev/null || echo "subnet-123")
SG_ID=$(awslocal ec2 create-security-group --group-name fargate-sg --description "Fargate SG" --query 'GroupId' --output text 2>/dev/null || echo "sg-123")

# Register task definition
cat > /tmp/fargate-task.json << EOF
{
  "family": "${FARGATE_FAMILY}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "containerDefinitions": [{
    "name": "reader-container",
    "image": "localhost.localstack.cloud:4566/${ECR_REPO}:latest",
    "entryPoint": ["/bin/sh"],
    "command": ["-c", "while true; do aws s3 ls s3://${S3_BUCKET}/output/ --endpoint-url=http://localstack:4566 --no-verify-ssl; sleep 30; done"],
    "environment": [
      {"name": "AWS_ENDPOINT_URL", "value": "http://localstack:4566"},
      {"name": "AWS_DEFAULT_REGION", "value": "us-east-1"},
      {"name": "AWS_ACCESS_KEY_ID", "value": "test"},
      {"name": "AWS_SECRET_ACCESS_KEY", "value": "test"}
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/${FARGATE_FAMILY}",
        "awslogs-region": "us-east-1",
        "awslogs-stream-prefix": "ecs",
        "awslogs-create-group": "true"
      }
    }
  }]
}
EOF

awslocal ecs register-task-definition --cli-input-json file:///tmp/fargate-task.json 2>/dev/null || true

log_info "Fargate task definition registered"

# Step 7: Upload test file to S3 (triggers Lambda)
log_info "Step 7: Uploading test file to S3"

cat > /tmp/test-data.csv << EOF
id,name,value
1,Alice,100
2,Bob,200
3,Charlie,300
4,Diana,400
5,Eve,500
EOF

awslocal s3 cp /tmp/test-data.csv s3://${S3_BUCKET}/input/test-data.csv

log_info "File uploaded. Lambda should be triggered automatically."

# Step 8: Monitor Lambda execution
log_info "Step 8: Monitoring Lambda logs (10 seconds)"

sleep 2
awslocal logs tail /aws/lambda/${LAMBDA_FUNCTION} --since 1m || log_warn "No Lambda logs yet"

# Verify output file exists
log_info "Verifying output file was created"
sleep 2
awslocal s3 ls s3://${S3_BUCKET}/output/

# Step 9: Start Fargate service
log_info "Step 9: Starting Fargate service"

awslocal ecs create-service \
    --cluster ${CLUSTER_NAME} \
    --service-name ${SERVICE_NAME} \
    --task-definition ${FARGATE_FAMILY} \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={
        subnets=[${SUBNET_ID}],
        securityGroups=[${SG_ID}],
        assignPublicIp=ENABLED
    }" 2>/dev/null || log_warn "Fargate service already exists"

log_info "Fargate service started"

# Step 10: Monitor Fargate logs
log_info "Step 10: Monitoring Fargate logs (10 seconds)"

sleep 5
awslocal logs tail /ecs/${FARGATE_FAMILY} --since 1m || log_warn "No Fargate logs yet"

# Summary
echo ""
echo "=== Summary ==="
log_info "✓ Docker image built and pushed to ECR"
log_info "✓ Lambda function created and triggered by S3"
log_info "✓ S3 bucket created with input/output prefixes"
log_info "✓ Fargate service deployed and monitoring output"
echo ""
echo "Next steps:"
echo "  - Monitor Lambda: awslocal logs tail /aws/lambda/${LAMBDA_FUNCTION} --follow"
echo "  - Monitor Fargate: awslocal logs tail /ecs/${FARGATE_FAMILY} --follow"
echo "  - List output files: awslocal s3 ls s3://${S3_BUCKET}/output/"
echo "  - Upload more files: awslocal s3 cp <file> s3://${S3_BUCKET}/input/"
echo ""
echo "Cleanup:"
echo "  - Stop Fargate: awslocal ecs update-service --cluster ${CLUSTER_NAME} --service ${SERVICE_NAME} --desired-count 0"
echo "  - Delete function: awslocal lambda delete-function --function-name ${LAMBDA_FUNCTION}"
echo "  - Delete bucket: awslocal s3 rb s3://${S3_BUCKET} --force"
echo ""

log_info "Example complete!"
