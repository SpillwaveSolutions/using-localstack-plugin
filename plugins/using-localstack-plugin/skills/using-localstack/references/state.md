# State & Seeding

Manage persistent state, seed resources, and run parallel environments.

## Persistence

### Enable Persistence
```bash
# Mount volume to persist resources across restarts
export PERSISTENCE=1
export LOCALSTACK_VOLUME_DIR=$PWD/ls_state

localstack start -d
```

Persists:
- S3 buckets and objects
- DynamoDB tables and data
- Lambda functions and layers
- Runtime container caches (faster cold starts)
- Database volumes (RDS/Aurora)

### Docker Volume Mount
```bash
docker run -d \
  -p 4566:4566 \
  -e PERSISTENCE=1 \
  -v $PWD/ls_state:/var/lib/localstack \
  localstack/localstack:3.0.2
```

### Clear State
```bash
# Stop LocalStack
localstack stop

# Remove persisted data
rm -rf ls_state

# Restart fresh
localstack start -d
```

## Cloud Pods (Pro only)

Save/load/share entire LocalStack state snapshots for deterministic reproduction.

### Save Snapshot
```bash
# After setting up resources
localstack pod save my-test-env
```

Captures all resources (S3 buckets, DynamoDB tables, Lambda functions, etc.).

### Load Snapshot
```bash
localstack pod load my-test-env
```

Restores exact state. Useful for:
- Seeded test fixtures
- Team collaboration (share same state)
- CI/CD (deterministic starting point)

### List Snapshots
```bash
localstack pod list
```

### Delete Snapshot
```bash
localstack pod delete my-test-env
```

### Remote Storage (Pro)
Cloud Pods stored remotely and synced across team via LocalStack platform.

## Init Hooks

Seed resources automatically on LocalStack startup using init scripts.

### Setup
```bash
# Create init scripts directory
mkdir -p .localstack/init/ready.d

# Add seed script
cat > .localstack/init/ready.d/01_seed.sh << 'EOF'
#!/bin/bash
awslocal s3 mb s3://seed-bucket
awslocal dynamodb create-table \
  --table-name seed-table \
  --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
EOF

chmod +x .localstack/init/ready.d/01_seed.sh
```

### Mount Init Scripts
```bash
docker run -d \
  -p 4566:4566 \
  -v $PWD/.localstack/init:/etc/localstack/init \
  localstack/localstack:3.0.2
```

Scripts in `ready.d/` execute after LocalStack ready (all services started).

### Advanced: Multi-Stage Init
- `boot.d/` - runs during boot (before services start)
- `ready.d/` - runs after services ready (preferred for resource creation)
- `shutdown.d/` - runs on shutdown

### Example: Seed from IaC
```bash
#!/bin/bash
# .localstack/init/ready.d/02_terraform.sh

cd /etc/localstack/init/terraform
tflocal init
tflocal apply -auto-approve
```

Mount Terraform configs:
```bash
docker run -d \
  -v $PWD/terraform:/etc/localstack/init/terraform \
  -v $PWD/.localstack/init:/etc/localstack/init \
  ...
```

## Parallel Environments

Run multiple isolated LocalStack instances for parallel testing.

### Different Ports
```bash
# Instance 1
LOCALSTACK_HOST=localhost:4566 localstack start -d

# Instance 2 (in separate terminal)
GATEWAY_LISTEN=0.0.0.0:4567 LOCALSTACK_HOST=localhost:4567 localstack start -d
```

Access via different endpoints:
```bash
AWS_ENDPOINT_URL=http://localhost:4566 awslocal s3 ls
AWS_ENDPOINT_URL=http://localhost:4567 awslocal s3 ls
```

### Separate Volumes
```bash
# Test suite A
LOCALSTACK_VOLUME_DIR=/tmp/ls_test_a localstack start -d

# Test suite B
LOCALSTACK_VOLUME_DIR=/tmp/ls_test_b localstack start -d
```

### Randomized Resource Names
Avoid collisions in shared instance:
```bash
# Append random suffix
BUCKET_NAME="test-bucket-$RANDOM"
awslocal s3 mb s3://$BUCKET_NAME
```

### Docker Compose (Multiple Instances)
```yaml
version: '3.8'
services:
  localstack-1:
    image: localstack/localstack:3.0.2
    ports:
      - "4566:4566"
    environment:
      - SERVICES=s3,lambda
      - PERSISTENCE=1
    volumes:
      - ./ls_state_1:/var/lib/localstack
  
  localstack-2:
    image: localstack/localstack:3.0.2
    ports:
      - "4567:4566"  # Map to different host port
    environment:
      - SERVICES=dynamodb,sqs
      - PERSISTENCE=1
    volumes:
      - ./ls_state_2:/var/lib/localstack
```

## State Export/Import (Manual)

### Export Resources (example: S3 and DynamoDB)
```bash
# Export S3 bucket contents
awslocal s3 sync s3://my-bucket ./backup/s3/

# Export DynamoDB table
awslocal dynamodb scan --table-name my-table > backup/dynamodb-table.json
```

### Import Resources
```bash
# Import S3
awslocal s3 mb s3://my-bucket
awslocal s3 sync ./backup/s3/ s3://my-bucket

# Import DynamoDB
jq -c '.Items[]' backup/dynamodb-table.json | while read item; do
  awslocal dynamodb put-item --table-name my-table --item "$item"
done
```

Cloud Pods (Pro) handles this automatically.
