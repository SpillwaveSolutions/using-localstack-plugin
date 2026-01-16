# Setup & Configuration

## Requirements
- Docker: Allocate RAM based on workload
  - 4 GB minimum: core services (S3, Lambda, DynamoDB, API Gateway, SQS, SNS)
  - 12-16 GB: Pro features with MSK/RDS (broker and database containers)
  - 16-32 GB: EKS/EMR multi-node clusters
- Python 3.7+
- Fast SSD with 10-30 GB free disk (service runtimes, DB volumes, cached images)
- Apple Silicon (M1/M2/M3) supported via multi-arch images

## Installation

### Recommended: pipx (cross-platform, isolated)
```bash
pipx install localstack
```

### Alternative: Homebrew (macOS only)
```bash
brew install localstack/tap/localstack-cli
```

Simpler on Apple Silicon but macOS-only.

## Start Commands

### Community Edition
```bash
localstack start -d
```

### Pro Edition
```bash
# Set auth token (get from https://app.localstack.cloud)
export LOCALSTACK_AUTH_TOKEN=<your-token>

# Start with pinned version for reproducibility
localstack start -d --version 3.0.2
```

### Docker Direct (Pro with custom config)
```bash
docker run -d \
  -p 4566:4566 \
  -e LOCALSTACK_AUTH_TOKEN=<token> \
  -e SERVICES=s3,lambda,dynamodb,sqs,sns,eventbridge \
  -e PERSISTENCE=1 \
  -v $PWD/ls_state:/var/lib/localstack \
  localstack/localstack-pro:3.0.2
```

## Port Configuration
- **Edge port 4566:** All service APIs route through this (S3, Lambda, DynamoDB, etc.)
- **Service ports 4510-4559:** Direct engine access for RDS/Elasticsearch/OpenSearch when bypassing edge proxy
- **Conflict resolution:** Set `EXTERNAL_SERVICE_PORTS_START=4600` if ports conflict with existing services

## Performance Tuning

### Service Scope (reduce startup time and memory)
```bash
export SERVICES=s3,lambda,dynamodb,sqs,sns
localstack start -d
```

### Persistence (cache runtimes and DB state)
```bash
export PERSISTENCE=1
export LOCALSTACK_VOLUME_DIR=$PWD/ls_state
localstack start -d
```

Keeps Lambda runtime containers, DynamoDB tables, S3 buckets across restarts.

### Eager Service Loading (pre-warm for faster first request)
```bash
export EAGER_SERVICE_LOADING=1
```

Starts all service providers immediately rather than on-demand.

### Lambda Runtime Tuning
```bash
# Keep warm containers alive for 600 seconds (reduces cold starts)
export LAMBDA_KEEPALIVE_MS=600000

# Attach debugger to Lambda containers
export LAMBDA_DOCKER_FLAGS="-p 9229:9229"
```

### Logging Verbosity
```bash
# Standard debug output
export DEBUG=1

# Deep trace for service internals
export LS_LOG=trace
```

## Platform-Specific Notes

### Windows (WSL2 required)
- Run LocalStack inside WSL2 for best performance
- Use WSL2 or named Docker volumes (avoid slow NTFS bind mounts)

### macOS (Apple Silicon)
- Multi-arch images automatically select ARM64 variants
- Homebrew CLI handles architecture transparently

### Linux
- Standard Docker setup works without modifications
- Consider allocating swap if RAM-constrained

## Endpoints & DNS

### Primary CLI Tool
```bash
# awslocal wraps AWS CLI with endpoint preset
awslocal s3 ls
```

### Manual Endpoint Override
```bash
AWS_ENDPOINT_URL=http://localhost:4566 aws s3 ls
```

### DNS Helper (service-style hostnames)
```bash
# *.localhost.localstack.cloud resolves to 127.0.0.1
curl http://s3.localhost.localstack.cloud:4566
```

Prefer endpoint injection or DNS in app code; avoid hardcoding `localhost:4566`.

## IAM Configuration (Pro)

### Default: Allow-All (Community/Pro)
No IAM enforcement by default. All requests succeed regardless of credentials.

### Enforce IAM (Pro only)
```bash
export ENFORCE_IAM=1
```

Real policy evaluation; requests fail if IAM policies deny access.

### Soft Mode (Pro only)
```bash
export IAM_SOFT_MODE=1
```

Logs IAM violations without blocking requests. Use to discover needed permissions.

### Policy Stream (Pro only)
Emits minimal IAM statements required for observed API calls. Use to generate least-privilege policies.
