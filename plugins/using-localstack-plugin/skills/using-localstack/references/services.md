# Service Workflows

Detailed patterns for core AWS services in LocalStack.

## S3 (Community/Pro)

### Basic Operations
```bash
# Create bucket (use valid AWS bucket naming)
awslocal s3 mb s3://my-bucket

# Upload object
awslocal s3 cp file.txt s3://my-bucket/

# List objects
awslocal s3 ls s3://my-bucket/

# Download object
awslocal s3 cp s3://my-bucket/file.txt downloaded.txt
```

### Event Notifications
S3 → Lambda, SNS, or SQS supported:
```bash
# Create Lambda function first
awslocal lambda create-function ...

# Configure S3 notification
awslocal s3api put-bucket-notification-configuration \
  --bucket my-bucket \
  --notification-configuration '{
    "LambdaFunctionConfigurations": [{
      "LambdaFunctionArn": "arn:aws:lambda:us-east-1:000000000000:function:my-handler",
      "Events": ["s3:ObjectCreated:*"]
    }]
  }'
```

**Verify:** Upload test object; check Lambda logs: `awslocal logs tail /aws/lambda/my-handler`

### Persistence
Mount volume to keep buckets/objects across restarts:
```bash
export PERSISTENCE=1
export LOCALSTACK_VOLUME_DIR=$PWD/ls_state
```

## DynamoDB (Community/Pro)

### Table Management
```bash
# Create table
awslocal dynamodb create-table \
  --table-name users \
  --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

# Verify status
awslocal dynamodb describe-table --table-name users | jq .Table.TableStatus
# Should return "ACTIVE"

# Put item
awslocal dynamodb put-item \
  --table-name users \
  --item '{"id": {"S": "123"}, "name": {"S": "Alice"}}'

# Query
awslocal dynamodb scan --table-name users
```

### Global Secondary Indexes (GSI)
```bash
awslocal dynamodb update-table \
  --table-name users \
  --attribute-definitions AttributeName=email,AttributeType=S \
  --global-secondary-index-updates '[{
    "Create": {
      "IndexName": "email-index",
      "KeySchema": [{"AttributeName": "email", "KeyType": "HASH"}],
      "Projection": {"ProjectionType": "ALL"}
    }
  }]'
```

### DynamoDB Streams → Lambda
```bash
# Enable streams
awslocal dynamodb update-table \
  --table-name users \
  --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES

# Get stream ARN
STREAM_ARN=$(awslocal dynamodb describe-table --table-name users | jq -r .Table.LatestStreamArn)

# Create event source mapping
awslocal lambda create-event-source-mapping \
  --function-name my-stream-handler \
  --event-source-arn $STREAM_ARN \
  --starting-position LATEST
```

### Advanced Config
```bash
# Error injection for testing resilience
export DYNAMODB_ERROR_PROBABILITY=0.1  # 10% failure rate

# Enable TTL deletion (default off)
export DYNAMODB_REMOVE_EXPIRED_ITEMS=1
```

## Lambda (Community/Pro)

### Multi-Runtime Support
Supported runtimes via Docker: Python, Node.js, Java, Go, .NET, Ruby, custom runtimes.

### Create Function
```bash
# Package code
zip function.zip handler.py

# Create function
awslocal lambda create-function \
  --function-name my-function \
  --runtime python3.11 \
  --role arn:aws:iam::000000000000:role/lambda-role \
  --handler handler.main \
  --zip-file fileb://function.zip \
  --environment Variables={KEY=value}

# Invoke
awslocal lambda invoke \
  --function-name my-function \
  --payload '{"input": "data"}' \
  output.json

# Check logs
awslocal logs tail /aws/lambda/my-function
```

### Event Source Mappings
Supported triggers: S3, SQS, SNS, Kinesis, DynamoDB Streams, EventBridge.

**SQS trigger:**
```bash
awslocal lambda create-event-source-mapping \
  --function-name my-function \
  --event-source-arn arn:aws:sqs:us-east-1:000000000000:my-queue \
  --batch-size 10
```

### Debugging
```bash
# Attach debugger port
export LAMBDA_DOCKER_FLAGS="-p 9229:9229"

# Use LAMBDA_DOCKER_NETWORK to share network with other containers
export LAMBDA_DOCKER_NETWORK=localstack_network
```

## API Gateway (Community/Pro)

### REST API with Lambda Proxy
```bash
# Create REST API
API_ID=$(awslocal apigateway create-rest-api --name my-api | jq -r .id)

# Get root resource
ROOT_ID=$(awslocal apigateway get-resources --rest-api-id $API_ID | jq -r '.items[0].id')

# Create method
awslocal apigateway put-method \
  --rest-api-id $API_ID \
  --resource-id $ROOT_ID \
  --http-method GET \
  --authorization-type NONE

# Integrate with Lambda
awslocal apigateway put-integration \
  --rest-api-id $API_ID \
  --resource-id $ROOT_ID \
  --http-method GET \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:000000000000:function:my-function/invocations

# Deploy
awslocal apigateway create-deployment \
  --rest-api-id $API_ID \
  --stage-name dev

# Test
curl http://localhost:4566/restapis/$API_ID/dev/_user_request_/
```

### HTTP API (simpler, faster)
```bash
awslocal apigatewayv2 create-api \
  --name my-http-api \
  --protocol-type HTTP \
  --target arn:aws:lambda:us-east-1:000000000000:function:my-function
```

## EventBridge (Community/Pro)

### Custom Event Bus
```bash
# Create custom bus
awslocal events create-event-bus --name my-bus

# Create rule
awslocal events put-rule \
  --name my-rule \
  --event-bus-name my-bus \
  --event-pattern '{"source": ["my.app"], "detail-type": ["order.placed"]}'

# Target Lambda
awslocal events put-targets \
  --rule my-rule \
  --event-bus-name my-bus \
  --targets Id=1,Arn=arn:aws:lambda:us-east-1:000000000000:function:my-handler

# Send test event
awslocal events put-events \
  --entries '[{
    "Source": "my.app",
    "DetailType": "order.placed",
    "Detail": "{\"orderId\": \"123\"}",
    "EventBusName": "my-bus"
  }]'

# Verify Lambda invocation
awslocal logs tail /aws/lambda/my-handler
```

### Scheduled Rules
```bash
# Run Lambda every 5 minutes
awslocal events put-rule \
  --name scheduled-task \
  --schedule-expression "rate(5 minutes)"

awslocal events put-targets \
  --rule scheduled-task \
  --targets Id=1,Arn=arn:aws:lambda:us-east-1:000000000000:function:my-task
```

## Kinesis & MSK (Community: Kinesis only; Pro: MSK)

### Kinesis Data Streams
```bash
# Create stream
awslocal kinesis create-stream --stream-name my-stream --shard-count 1

# Put record
awslocal kinesis put-record \
  --stream-name my-stream \
  --partition-key key1 \
  --data "SGVsbG8gV29ybGQ="

# Lambda trigger
awslocal lambda create-event-source-mapping \
  --function-name my-stream-processor \
  --event-source-arn arn:aws:kinesis:us-east-1:000000000000:stream/my-stream \
  --starting-position LATEST
```

### MSK (Pro only)
```bash
# Create MSK cluster (uses embedded Kafka)
awslocal kafka create-cluster \
  --cluster-name my-cluster \
  --broker-node-group-info '{"InstanceType": "kafka.m5.large", "ClientSubnets": ["subnet-123"]}'

# Get bootstrap brokers
awslocal kafka get-bootstrap-brokers --cluster-arn <cluster-arn>
```

## EKS (Pro only)

### Create Cluster (uses k3d internally)
```bash
awslocal eks create-cluster \
  --name my-cluster \
  --role-arn arn:aws:iam::000000000000:role/eks-role \
  --resources-vpc-config subnetIds=subnet-123,subnet-456

# Update kubeconfig
awslocal eks update-kubeconfig --name my-cluster

# Verify
kubectl get nodes
```

## RDS/Aurora (Pro only)

### PostgreSQL
```bash
# Create DB instance (spawns real Postgres container)
awslocal rds create-db-instance \
  --db-instance-identifier my-postgres \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --master-username admin \
  --master-user-password secret123 \
  --allocated-storage 20

# Get endpoint
ENDPOINT=$(awslocal rds describe-db-instances --db-instance-identifier my-postgres | jq -r '.DBInstances[0].Endpoint.Address')

# Connect
psql -h $ENDPOINT -U admin -d postgres
```

### MySQL/MariaDB
```bash
awslocal rds create-db-instance \
  --db-instance-identifier my-mysql \
  --engine mysql \
  --master-username root \
  --master-user-password secret123 \
  --allocated-storage 20
```

## CloudWatch Logs (Community/Pro)

### Log Group & Stream Management
```bash
# Create log group manually
awslocal logs create-log-group --log-group-name /custom/application

# List all log groups
awslocal logs describe-log-groups | jq '.logGroups[].logGroupName'

# List streams in a log group
awslocal logs describe-log-streams \
  --log-group-name /aws/lambda/my-function | jq '.logStreams[].logStreamName'

# Delete old log group
awslocal logs delete-log-group --log-group-name /custom/old-app
```

### Tailing Logs (Live Tail)
```bash
# Tail Lambda logs (follows new entries in real-time)
awslocal logs tail /aws/lambda/data-processor --follow

# Tail with timestamp filter (last 10 minutes)
awslocal logs tail /aws/lambda/data-processor \
  --since 10m \
  --follow

# Tail specific number of lines
awslocal logs tail /aws/lambda/data-processor --follow --max-items 50
```

**Live Tail vs Regular Tail:**
- `--follow`: Real-time streaming (like `tail -f`), waits for new log events
- Without `--follow`: Retrieves existing logs up to current time, then exits

### Log Filtering
```bash
# Filter logs by pattern
awslocal logs filter-log-events \
  --log-group-name /aws/lambda/data-processor \
  --filter-pattern "ERROR"

# Filter with time range (Unix timestamps)
awslocal logs filter-log-events \
  --log-group-name /aws/lambda/data-processor \
  --start-time 1609459200000 \
  --end-time 1609545600000 \
  --filter-pattern "timeout"

# JSON-based filtering (extracts structured logs)
awslocal logs filter-log-events \
  --log-group-name /aws/lambda/data-processor \
  --filter-pattern '{ $.statusCode = 500 }'
```

### Multi-Log-Group Monitoring
```bash
# Tail multiple Lambda functions simultaneously (separate terminals)
awslocal logs tail /aws/lambda/function-a --follow &
awslocal logs tail /aws/lambda/function-b --follow &
wait

# Or use shell script for parallel tailing
for func in function-a function-b function-c; do
  awslocal logs tail /aws/lambda/$func --follow | sed "s/^/[$func] /" &
done
wait
```

### Automatic Log Group Creation
Lambda and Fargate can auto-create log groups when properly configured:

**Lambda:** Automatically creates `/aws/lambda/<function-name>` on first invocation.

**Fargate Task Definition:**
```json
{
  "logConfiguration": {
    "logDriver": "awslogs",
    "options": {
      "awslogs-group": "/ecs/fargate-backend",
      "awslogs-region": "us-east-1",
      "awslogs-stream-prefix": "ecs",
      "awslogs-create-group": "true"
    }
  }
}
```

**Verify:** Check logs immediately after task starts:
```bash
awslocal logs tail /ecs/fargate-backend --follow
```

### Debugging Tips
```bash
# Check if log group exists before tailing
awslocal logs describe-log-groups \
  --log-group-name-prefix /aws/lambda/my-function

# If empty, function hasn't been invoked yet or logging is misconfigured

# Force Lambda invocation to generate logs
awslocal lambda invoke \
  --function-name my-function \
  --payload '{"test": true}' \
  /tmp/response.json

# Then tail logs
awslocal logs tail /aws/lambda/my-function
```

### Retention Policies
```bash
# Set retention period (days: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653)
awslocal logs put-retention-policy \
  --log-group-name /aws/lambda/data-processor \
  --retention-in-days 7

# Remove retention (logs never expire)
awslocal logs delete-retention-policy \
  --log-group-name /aws/lambda/data-processor
```

---

## Step Functions (Pro only)

### Standard Workflow
```bash
# Create state machine
awslocal stepfunctions create-state-machine \
  --name my-workflow \
  --definition file://state-machine.json \
  --role-arn arn:aws:iam::000000000000:role/sf-role

# Start execution
awslocal stepfunctions start-execution \
  --state-machine-arn arn:aws:states:us-east-1:000000000000:stateMachine:my-workflow \
  --input '{"orderId": "123"}'

# Check status
awslocal stepfunctions describe-execution --execution-arn <execution-arn>
```

### TestState for Unit Testing
```bash
# Test individual state without full workflow
awslocal stepfunctions test-state \
  --definition file://single-state.json \
  --role-arn arn:aws:iam::000000000000:role/sf-role \
  --input '{"key": "value"}'
```
