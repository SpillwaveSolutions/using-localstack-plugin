# Docker Desktop Troubleshooting

Diagnostic flowchart and remediation manual for running LocalStack on Docker Desktop (macOS, Windows WSL2, Linux).

## Table of Contents
- [Diagnostic Triage](#diagnostic-triage)
- [Networking & Connectivity](#networking--connectivity)
- [Compute (Lambda & Fargate) Failures](#compute-lambda--fargate-failures)
- [Persistence & Storage Issues](#persistence--storage-issues)
- [IAM & Security](#iam--security)
- [Performance & Resource Tuning](#performance--resource-tuning)
- [Common Tooling Friction](#common-tooling-friction)

---

## Diagnostic Triage

Before applying fixes, establish the ground truth of the environment.

### Health & Connectivity Check

**Command:**
```bash
curl -s http://localhost:4566/_localstack/health | jq
```

**Healthy Response:**
```json
{
  "services": {
    "s3": "running",
    "lambda": "available",
    "dynamodb": "running"
  }
}
```

**Failure Modes:**
- **Connection Refused:** LocalStack container is not running or port 4566 is blocked/bound by another process
- **Service "available" but not "running":** The service is lazy-loaded (default). It will start on the first request.

**Verify container is running:**
```bash
docker ps | grep localstack
```

### Enable Verbose Logging

Standard logs often hide the root cause of 500 errors.

**Update docker-compose.yml:**
```yaml
environment:
  - DEBUG=1                    # Detailed debug logs for most services
  - LS_LOG=trace               # Protocol-level tracing (headers, payloads)
```

**Analyze logs:**
```bash
docker logs -f localstack-main
```

**Look for:**
- `AccessDenied` - IAM enforcement issues
- `DockerConnectionError` - Docker socket mount problems
- Java stack traces - DynamoDB/OpenSearch/Kinesis issues

---

## Networking & Connectivity

Networking is the single most common failure point due to the "Host vs. Container" boundary.

### Problem: "Connection Refused" from Lambda/Fargate to S3/DynamoDB

**Symptom:** Application code running inside Lambda or Fargate crashes with `Connection refused` when calling S3/DynamoDB.

**Root Cause:** Code is trying to hit `localhost:4566`. Inside the container, `localhost` refers to the container itself, not the LocalStack gateway.

**Solution 1: DNS Magic (Recommended)**
```bash
# In Lambda/Fargate environment variables
export AWS_ENDPOINT_URL=http://localstack:4566
# OR
export AWS_ENDPOINT_URL=http://localhost.localstack.cloud:4566
```

LocalStack's internal DNS resolves `localhost.localstack.cloud` to the correct container IP from within the Docker network.

**Solution 2: Network Configuration**

Ensure your `docker-compose.yml` defines a specific bridge network:

```yaml
services:
  localstack:
    environment:
      - LAMBDA_DOCKER_NETWORK=my_stack_network  # MUST match your network name
    networks:
      - my_stack_network

networks:
  my_stack_network:
    name: my_stack_network
```

**Verify network:**
```bash
docker network inspect my_stack_network | jq '.[0].Containers'
```

### Problem: S3 Bucket "Not Found" or Domain Resolution Errors

**Symptom:** `Could not resolve host: my-bucket.s3.localhost.localstack.cloud`

**Root Cause:** Virtual-hosted style requests (`bucket.s3...`) require DNS wildcard resolution.

**Solution 1: Verify DNS Resolution**
```bash
# On host machine
nslookup localhost.localstack.cloud
# Should resolve to 127.0.0.1

# Test with dig
dig localhost.localstack.cloud
```

**Solution 2: Force Path-Style Addressing**

Corporate VPNs often block local DNS resolution. Use path-style addressing to bypass DNS reliance.

**Python (boto3):**
```python
import boto3

s3 = boto3.client(
    's3',
    endpoint_url='http://localhost:4566',
    config=boto3.session.Config(s3={'addressing_style': 'path'})
)
```

**AWS CLI:**
```bash
aws s3 ls s3://my-bucket \
  --endpoint-url=http://localhost:4566 \
  --region us-east-1 \
  --no-verify-ssl
```

**Solution 3: Update /etc/hosts (macOS/Linux)**
```bash
# Add to /etc/hosts
echo "127.0.0.1 localhost.localstack.cloud" | sudo tee -a /etc/hosts
echo "127.0.0.1 *.localhost.localstack.cloud" | sudo tee -a /etc/hosts
```

### Problem: Port 4566 Conflicts

**Symptom:** Docker fails to start with `Bind for 0.0.0.0:4566 failed: port is already allocated`.

**Root Cause:** A zombie LocalStack process or another service is holding the port.

**Solution:**

**macOS/Linux:**
```bash
# Identify process
lsof -i :4566

# Kill process
kill -9 <PID>
```

**Windows:**
```powershell
# Identify process
netstat -ano | findstr :4566

# Kill process
taskkill /PID <PID> /F
```

**Verify port is free:**
```bash
# Should return nothing
lsof -i :4566
```

**Alternative: Change LocalStack port**
```yaml
services:
  localstack:
    ports:
      - "4567:4566"  # Map to different host port
    environment:
      - EDGE_PORT=4566  # Internal port stays 4566
```

---

## Compute (Lambda & Fargate) Failures

### Problem: Lambda Functions Stuck in "Pending"

**Symptom:** `awslocal lambda create-function` succeeds, but invocations hang or return errors; logs show "Pending" state indefinitely.

**Root Cause:** LocalStack cannot talk to the host Docker daemon to spawn the Lambda container.

**Solution 1: Mount Docker Socket**

Ensure `/var/run/docker.sock` is mounted in your compose file:

```yaml
services:
  localstack:
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock"
```

**Verify mount:**
```bash
docker exec -it localstack-main ls -l /var/run/docker.sock
# Should show: srw-rw---- 1 root docker 0 ...
```

**Solution 2: Permissions (Linux)**

The user inside the container must have permissions to read the socket:

```yaml
services:
  localstack:
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock"
    user: root  # Or add user to docker group
```

**Verify Docker access from within container:**
```bash
docker exec -it localstack-main docker ps
# Should list running containers
```

**Solution 3: Alternative Docker Socket Paths (macOS Docker Desktop)**

Docker Desktop for Mac uses a different socket path:

```yaml
volumes:
  - "/var/run/docker.sock.raw:/var/run/docker.sock"  # Try this if standard path fails
```

### Problem: Architecture Mismatch ("Exec Format Error")

**Symptom:** Lambda fails immediately with `exec user process caused: exec format error`.

**Root Cause:** Running an `x86_64` Lambda binary/layer on Apple Silicon (M1/M2/M3) host, or vice-versa.

**Solution 1: Build for Correct Architecture**

```bash
# Check your host architecture
uname -m
# arm64 = Apple Silicon
# x86_64 = Intel/AMD

# Build Lambda package for arm64
docker build --platform linux/arm64 -t my-lambda:latest .

# Or for x86_64
docker build --platform linux/amd64 -t my-lambda:latest .
```

**Solution 2: Force Lambda Architecture**

```bash
awslocal lambda create-function \
  --function-name my-func \
  --architectures arm64 \
  --runtime python3.11 \
  --role arn:aws:iam::000000000000:role/lambda-role \
  --handler index.handler \
  --zip-file fileb://function.zip
```

**Solution 3: Use LAMBDA_DOCKER_FLAGS (Advanced)**

```yaml
environment:
  - LAMBDA_DOCKER_FLAGS=--platform linux/arm64
```

**Verify Lambda architecture:**
```bash
awslocal lambda get-function --function-name my-func | jq .Configuration.Architectures
```

### Problem: Fargate Tasks Failing to Pull Images

**Symptom:** ECS task stays in `PROVISIONING` then stops. Docker logs show `manifest unknown` or connection errors to ECR.

**Root Cause:** The LocalStack container cannot resolve the ECR endpoint or the image tag is incorrect.

**Solution 1: Correct Image Tagging**

Ensure you tagged the image with `localhost.localstack.cloud:4566` before pushing:

```bash
# Build image
docker build -t my-fargate-app:latest .

# Tag for LocalStack ECR
docker tag my-fargate-app:latest \
  localhost.localstack.cloud:4566/my-repo:latest

# Push to LocalStack ECR
docker push localhost.localstack.cloud:4566/my-repo:latest
```

**Verify image in ECR:**
```bash
awslocal ecr describe-images --repository-name my-repo
```

**Solution 2: Network Configuration**

The Fargate container needs outbound access. If using `awsvpc` mode, ensure proper network configuration:

```bash
# Get subnet and security group IDs
SUBNET_ID=$(awslocal ec2 describe-subnets --query 'Subnets[0].SubnetId' --output text)
SG_ID=$(awslocal ec2 describe-security-groups --query 'SecurityGroups[0].GroupId' --output text)

# Create service with network config
awslocal ecs create-service \
  --cluster default \
  --service-name my-service \
  --task-definition my-task \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={
    subnets=[$SUBNET_ID],
    securityGroups=[$SG_ID],
    assignPublicIp=ENABLED
  }"
```

**Solution 3: Check Task Stopped Reason**

```bash
TASK_ARN=$(awslocal ecs list-tasks --cluster default --query 'taskArns[0]' --output text)
awslocal ecs describe-tasks --cluster default --tasks $TASK_ARN | \
  jq '.tasks[0].stoppedReason'
```

---

## Persistence & Storage Issues

### Problem: "Data Disappears on Restart"

**Symptom:** Buckets and tables created in a previous session are gone.

**Root Cause:** Persistence is disabled by default in Community (and some Pro configs).

**Solution 1: Enable Persistence (Pro Feature)**

```yaml
environment:
  - PERSISTENCE=1
  - LOCALSTACK_AUTH_TOKEN=${LOCALSTACK_AUTH_TOKEN}
volumes:
  - "./volume:/var/lib/localstack"
```

**Verify persistence:**
```bash
# Create a bucket
awslocal s3 mb s3://test-persistence

# Restart LocalStack
docker-compose restart

# Check if bucket still exists
awslocal s3 ls
# Should show test-persistence
```

**Solution 2: Use Cloud Pods (Pro Feature)**

```bash
# Save state
awslocal pod save my-state

# Restore state later
awslocal pod load my-state
```

**Solution 3: Export/Import Resources**

```bash
# Export DynamoDB table
awslocal dynamodb scan --table-name users > users_backup.json

# Restore later
cat users_backup.json | jq -r '.Items[]' | while read item; do
  awslocal dynamodb put-item --table-name users --item "$item"
done
```

### Problem: File Sharing / Volume Mount Denied

**Symptom:** Docker logs show errors mounting `/tmp/...` or user code directories.

**Root Cause:** Docker Desktop (especially on macOS) does not have file sharing enabled for the directory you are trying to mount.

**Solution: Enable File Sharing**

**macOS Docker Desktop:**
1. Open Docker Desktop
2. Settings → Resources → File Sharing
3. Add your project's parent directory
4. Click "Apply & Restart"

**Verify mount:**
```bash
docker exec -it localstack-main ls -la /var/lib/localstack
# Should show your volume contents
```

**Alternative: Use Named Volumes**

```yaml
volumes:
  - localstack_data:/var/lib/localstack

volumes:
  localstack_data:
    driver: local
```

### Problem: Corrupted State (The "Crash Loop")

**Symptom:** LocalStack crashes immediately on startup while "Loading state".

**Root Cause:** Incompatible or corrupted serialized data in the volume (common after upgrading LocalStack versions).

**Solution (The Nuclear Option):**

```bash
# Stop the container
docker-compose down

# Delete the volume data
rm -rf ./volume/state  # Or wherever your volume points

# Verify volume is empty
ls -la ./volume

# Restart
docker-compose up -d

# Check logs
docker logs -f localstack-main
```

**Alternative: Use Fresh Volume**

```yaml
volumes:
  - "./volume_fresh:/var/lib/localstack"  # Different path
```

---

## IAM & Security

### Problem: "Access Denied" when it works on AWS

**Symptom:** `Enforce IAM` is enabled, and requests fail locally.

**Root Cause:** AWS IAM is complex; LocalStack's enforcement is strict. Policies often rely on implicit behaviors not present locally or specific ARN format mismatches.

**Solution 1: Soft Mode (Recommended for Development)**

```yaml
environment:
  - IAM_SOFT_MODE=1  # Logs permission errors as warnings but allows requests
```

**This confirms if it's a policy issue vs. a system error.**

**Verify:**
```bash
# Should now succeed with warning in logs
awslocal s3 ls s3://my-bucket

# Check logs for IAM warnings
docker logs localstack-main 2>&1 | grep IAM
```

**Solution 2: Use IAM Policy Stream (Pro Feature)**

Enable IAM Policy Stream to see exactly which permission is missing:

```yaml
environment:
  - IAM_POLICY_STREAM=1
```

Visit LocalStack Web App → IAM Policy Stream to see real-time permission checks and generate fixes.

**Solution 3: Fix ARN Formats**

LocalStack uses specific ARN formats:

```json
{
  "Effect": "Allow",
  "Action": "s3:GetObject",
  "Resource": "arn:aws:s3:::my-bucket/*"
}
```

**Verify ARN format:**
```bash
awslocal s3api get-bucket-location --bucket my-bucket | jq
# Should return bucket ARN
```

### Problem: ECR Authentication Failures

**Symptom:** `docker login` fails against LocalStack.

**Root Cause:** Docker client expects strict HTTPS or valid certs.

**Solution 1: Use awslocal Helper**

```bash
awslocal ecr get-login-password | \
  docker login --username AWS --password-stdin localhost.localstack.cloud:4566
```

**Solution 2: Configure Insecure Registry**

Edit Docker daemon config (`~/.docker/daemon.json` or Docker Desktop Settings → Docker Engine):

```json
{
  "insecure-registries": [
    "localhost:4566",
    "localhost.localstack.cloud:4566"
  ]
}
```

**Restart Docker Desktop after modifying.**

**Verify login:**
```bash
docker info | grep "Insecure Registries"
# Should list localhost:4566
```

---

## Performance & Resource Tuning

### Problem: Java Services Crashing (OOM)

**Symptom:** DynamoDB, OpenSearch, or Kinesis silently fail; Docker stats show high RAM usage.

**Root Cause:** These services run on the Java Virtual Machine (JVM) inside the container and can exhaust allocated heap memory.

**Solution 1: Increase Heap Size**

```yaml
environment:
  - DYNAMODB_HEAP_SIZE=1G      # Default: 256m
  - OPENSEARCH_JAVA_OPTS=-Xms1g -Xmx2g
  - KINESIS_HEAP_SIZE=512m
```

**Solution 2: Allocate More Docker Resources**

**Docker Desktop Settings:**
- Memory: At least 4GB (8GB+ recommended for Big Data stacks)
- CPUs: At least 2 cores (4+ recommended)

**Verify Docker resources:**
```bash
docker info | grep -E 'CPUs|Total Memory'
```

**Solution 3: Monitor Resource Usage**

```bash
# Watch container resource usage
docker stats localstack-main

# Check Java heap usage
docker exec -it localstack-main jps -lv | grep DynamoDB
```

### Problem: Slow Startup

**Symptom:** First request to a service takes 5-10 seconds.

**Root Cause:** Lazy loading (services start only when hit).

**Solution 1: Eager Service Loading**

```yaml
environment:
  - EAGER_SERVICE_LOADING=1  # Forces boot-up of all services at container start
```

**Trade-off:** Makes startup slower (30-60 seconds), but runtime faster.

**Solution 2: Preload Specific Services**

```yaml
environment:
  - SERVICES=s3,dynamodb,lambda  # Only load required services
```

**Verify startup time:**
```bash
time docker-compose up -d
# Check how long LocalStack takes to become healthy
```

**Solution 3: Use Persistence**

With persistence enabled, subsequent startups are faster as state is reloaded from disk.

---

## Common Tooling Friction

### Problem: Terraform Provider v5 Errors

**Symptom:** Terraform fails with generic 500 errors or schema validation errors.

**Root Cause:** Breaking changes in the official AWS Provider v5 vs LocalStack's emulation of those new APIs.

**Solution 1: Pin Provider Version**

```hcl
# versions.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"  # Pin to v4.x
    }
  }
}
```

**Solution 2: Use Latest LocalStack Image**

```yaml
services:
  localstack:
    image: localstack/localstack:latest  # Or specific version like 3.0
```

**Solution 3: Enable Terraform Compatibility Mode (Pro)**

```yaml
environment:
  - PROVIDER_OVERRIDE_TERRAFORM=1
```

**Verify Terraform version:**
```bash
terraform version
# Terraform v1.x.x
# Provider registry.terraform.io/hashicorp/aws v4.x.x
```

### Problem: CloudWatch Logs Tailing Hangs

**Symptom:** `awslocal logs tail ... --follow` produces no output.

**Root Cause:** Buffering issues or polling intervals.

**Solution 1: Update awscli-local**

```bash
# Check version
pip show awscli-local

# Update to latest (requires 0.19+)
pip install --upgrade awscli-local
```

**Solution 2: Use Direct Endpoint Override**

```bash
aws --endpoint-url=http://localhost:4566 \
  logs tail /aws/lambda/my-func --follow
```

**Solution 3: Use Alternative Tools**

```bash
# Use LocalStack logs directly
docker logs -f localstack-main | grep "my-func"

# Or use AWS CLI v2 with profile
aws logs tail /aws/lambda/my-func --follow --profile localstack
```

**Verify log group exists:**
```bash
awslocal logs describe-log-groups | jq '.logGroups[].logGroupName'
```

### Problem: CDK Bootstrap Fails

**Symptom:** `cdklocal bootstrap` fails with S3 or CloudFormation errors.

**Root Cause:** CDK expects specific AWS behaviors that LocalStack emulates differently.

**Solution 1: Use cdklocal Wrapper**

```bash
# Install cdklocal
npm install -g aws-cdk-local

# Bootstrap with cdklocal
cdklocal bootstrap
```

**Solution 2: Manual Bootstrap**

```bash
# Create CDK staging bucket manually
awslocal s3 mb s3://cdk-hnb659fds-assets-000000000000-us-east-1

# Deploy with CDK
cdklocal deploy
```

**Solution 3: Use CDK v1 (Legacy)**

CDK v2 has more strict requirements. Consider using CDK v1 for local development:

```bash
npm install -g aws-cdk@1.x
```

**Verify CDK version:**
```bash
cdk --version
```

---

## Quick Reference: Common Commands

### Health Checks
```bash
# Overall health
curl http://localhost:4566/_localstack/health | jq

# Service-specific health
curl http://localhost:4566/_localstack/health | jq '.services.s3'

# Container status
docker ps | grep localstack
docker logs -f localstack-main
```

### Networking Verification
```bash
# DNS resolution
nslookup localhost.localstack.cloud

# Port availability
lsof -i :4566

# Network inspection
docker network inspect localstack_network | jq
```

### Resource Monitoring
```bash
# Container stats
docker stats localstack-main

# Docker Desktop resources
docker info | grep -E 'CPUs|Total Memory'

# Disk usage
docker system df
```

### Cleanup
```bash
# Stop and remove containers
docker-compose down

# Remove volumes
docker-compose down -v

# Remove all LocalStack data
rm -rf ./volume

# Prune Docker resources
docker system prune -a --volumes
```
