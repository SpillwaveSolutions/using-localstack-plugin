# Debugging & Observability

Troubleshoot failures, inspect logs, inject failures, and trace event flows.

## Container Logs

### View LocalStack Logs
```bash
# Tail logs
docker logs -f localstack

# Last 100 lines
docker logs localstack --tail 100

# Filter for errors
docker logs localstack | grep -i error

# Service-specific logs
docker logs localstack | grep -i "s3\|lambda\|dynamodb"
```

### Verbose Logging
```bash
# Standard debug output
export DEBUG=1
localstack start -d

# Deep trace (service internals, API requests/responses)
export LS_LOG=trace
localstack start -d
```

## CloudWatch Logs (LocalStack)

### Tail Lambda Logs
```bash
# Most recent logs
awslocal logs tail /aws/lambda/my-function

# Follow logs in real-time
awslocal logs tail /aws/lambda/my-function --follow

# Filter by time range
awslocal logs tail /aws/lambda/my-function --since 10m
```

### Create Log Groups Manually
```bash
awslocal logs create-log-group --log-group-name /custom/app
awslocal logs put-log-events \
  --log-group-name /custom/app \
  --log-stream-name stream1 \
  --log-events timestamp=$(date +%s)000,message="Test log"
```

## Health Checks

### Service Health Endpoint
```bash
curl http://localhost:4566/_localstack/health | jq
```

**Response:**
```json
{
  "services": {
    "s3": "available",
    "lambda": "running",
    "dynamodb": "available"
  },
  "version": "3.0.2"
}
```

**Status values:**
- `available`: Service provider loaded and ready
- `running`: Service active with resources
- `error`: Service failed to start

### Check Specific Service
```bash
curl http://localhost:4566/_localstack/health | jq '.services.s3'
```

## Failure Injection

Test resilience by injecting failures into specific services.

### DynamoDB Error Injection
```bash
# 10% failure rate for DynamoDB operations
export DYNAMODB_ERROR_PROBABILITY=0.1
localstack start -d
```

Operations randomly fail with `InternalServerError`. Use to test retry logic.

### Kinesis Latency Injection
```bash
# Add 500ms latency to Kinesis operations
export KINESIS_LATENCY=500
localstack start -d
```

### Custom Error Injection (Pro)
Use Chaos Engineering extensions to inject failures into any service.

## Networking Troubleshooting

### Lambda → LocalStack Communication

**Problem:** Lambda can't reach other services (S3, DynamoDB, etc.)

**Solution 1: Use LocalStack internal DNS**
```python
# In Lambda code
import boto3
s3 = boto3.client('s3', endpoint_url='http://localhost.localstack.cloud:4566')
```

**Solution 2: Set LAMBDA_DOCKER_NETWORK**
```bash
# Lambda containers join same network as LocalStack
export LAMBDA_DOCKER_NETWORK=bridge
localstack start -d
```

**Verify network:**
```bash
docker network inspect bridge | jq '.[0].Containers'
```

### Container → LocalStack from Docker Compose

If your app runs in Docker Compose and needs to reach LocalStack:

```yaml
version: '3.8'
services:
  app:
    image: my-app
    environment:
      AWS_ENDPOINT_URL: http://localstack:4566
    networks:
      - localstack-network
  
  localstack:
    image: localstack/localstack:3.0.2
    ports:
      - "4566:4566"
    networks:
      - localstack-network

networks:
  localstack-network:
```

### Host → LocalStack
From host machine, always use `http://localhost:4566`.

### Port Conflicts

**Problem:** Port 4566 already in use

**Solution: Shift external ports**
```bash
export EXTERNAL_SERVICE_PORTS_START=4600
localstack start -d
```

Access via `http://localhost:4600`.

## Event Tracing (Pro)

### EventBridge Event Studio
Visual debugger for event-driven flows. Traces events through EventBridge rules, Lambda invocations, and targets.

Access via LocalStack Web UI (Pro).

### Stack Insights
Visualizes service calls and dependencies. Shows which services interact and call graphs.

### IAM Policy Stream
Logs all IAM policy evaluations. Use to discover missing permissions:

```bash
export IAM_SOFT_MODE=1  # Log violations without blocking
export ENFORCE_IAM=1
localstack start -d

# Perform operations
awslocal s3 ls

# Check logs for needed IAM statements
docker logs localstack | grep -i "iam policy"
```

## Common Issues

### Issue: Lambda Timeout
**Symptom:** Lambda function times out or doesn't respond

**Debug:**
```bash
# Check Lambda logs
awslocal logs tail /aws/lambda/my-function

# Increase timeout
awslocal lambda update-function-configuration \
  --function-name my-function \
  --timeout 300

# Verify network connectivity (if calling other services)
export LAMBDA_DOCKER_NETWORK=bridge
```

### Issue: S3 Bucket Not Found
**Symptom:** `NoSuchBucket` error immediately after creation

**Debug:**
```bash
# Verify bucket exists
awslocal s3 ls

# Check S3 service health
curl http://localhost:4566/_localstack/health | jq '.services.s3'

# Recreate bucket
awslocal s3 mb s3://my-bucket

# Verify with explicit endpoint
awslocal s3 ls --endpoint-url http://localhost:4566
```

### Issue: DynamoDB Table Not Active
**Symptom:** `ResourceNotFoundException` or table status not `ACTIVE`

**Debug:**
```bash
# Check table status
awslocal dynamodb describe-table --table-name my-table | jq .Table.TableStatus

# Wait for ACTIVE (may take a few seconds)
while [ "$(awslocal dynamodb describe-table --table-name my-table | jq -r .Table.TableStatus)" != "ACTIVE" ]; do
  sleep 1
done

# Check DynamoDB service health
curl http://localhost:4566/_localstack/health | jq '.services.dynamodb'
```

### Issue: API Gateway 404
**Symptom:** API Gateway endpoint returns 404

**Debug:**
```bash
# Verify deployment exists
awslocal apigateway get-deployments --rest-api-id $API_ID

# Check stage name
awslocal apigateway get-stages --rest-api-id $API_ID

# Ensure correct URL format
# http://localhost:4566/restapis/{api-id}/{stage}/_user_request_/{path}
curl http://localhost:4566/restapis/$API_ID/dev/_user_request_/test
```

### Issue: EventBridge Rule Not Triggering
**Symptom:** Events sent but Lambda not invoked

**Debug:**
```bash
# Verify rule exists and is enabled
awslocal events list-rules --event-bus-name my-bus

# Check rule has targets
awslocal events list-targets-by-rule --rule my-rule --event-bus-name my-bus

# Send test event and check Lambda logs immediately
awslocal events put-events --entries '[{"Source": "test", "DetailType": "test", "Detail": "{}"}]'
awslocal logs tail /aws/lambda/my-handler --follow

# Verify event pattern matches
# Event pattern must match Source, DetailType, and Detail structure
```

## Performance Profiling

### Check Resource Usage
```bash
# Docker stats
docker stats localstack

# Memory usage
docker stats localstack --no-stream --format "{{.MemUsage}}"

# CPU usage
docker stats localstack --no-stream --format "{{.CPUPerc}}"
```

### Identify Slow Operations
```bash
# Enable trace logging
export LS_LOG=trace
localstack start -d

# Operations logged with timing
docker logs localstack | grep -i "duration\|elapsed"
```

## Diagnostic Info Dump

Collect diagnostic info for bug reports:

```bash
# LocalStack version
localstack --version

# Service health
curl http://localhost:4566/_localstack/health

# Container info
docker inspect localstack | jq '.[0].Config.Env'

# Recent logs
docker logs localstack --tail 200

# System info
docker info | grep -E "CPUs|Total Memory"
```
