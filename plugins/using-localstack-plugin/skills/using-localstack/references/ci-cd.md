# CI/CD Patterns

Run LocalStack in CI/CD pipelines for deterministic integration testing.

## General Pattern

1. Start LocalStack as service container
2. Wait for health check
3. Seed resources (IaC or init scripts)
4. Run integration tests
5. Tear down (container/volume discarded)

## GitHub Actions

### Basic Workflow
```yaml
name: Integration Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    
    services:
      localstack:
        image: localstack/localstack:3.0.2
        ports:
          - 4566:4566
        env:
          SERVICES: s3,lambda,dynamodb,sqs
          PERSISTENCE: 1
        options: >-
          --health-cmd "curl -f http://localhost:4566/_localstack/health || exit 1"
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Wait for LocalStack
        run: |
          until curl -f http://localhost:4566/_localstack/health; do
            sleep 2
          done
      
      - name: Install awslocal
        run: pip install awscli-local
      
      - name: Setup Resources
        run: |
          awslocal s3 mb s3://test-bucket
          awslocal dynamodb create-table \
            --table-name test-table \
            --attribute-definitions AttributeName=id,AttributeType=S \
            --key-schema AttributeName=id,KeyType=HASH \
            --billing-mode PAY_PER_REQUEST
      
      - name: Run Tests
        env:
          AWS_ENDPOINT_URL: http://localhost:4566
        run: pytest tests/integration
```

### Pro Version with Auth Token
```yaml
services:
  localstack:
    image: localstack/localstack-pro:3.0.2
    env:
      LOCALSTACK_AUTH_TOKEN: ${{ secrets.LOCALSTACK_AUTH_TOKEN }}
      SERVICES: s3,lambda,dynamodb,eks,rds
```

Store token in GitHub Secrets.

### Cache LocalStack Volume
Speed up subsequent runs by caching persisted state:

```yaml
- name: Cache LocalStack State
  uses: actions/cache@v3
  with:
    path: /tmp/localstack
    key: localstack-${{ hashFiles('**/infrastructure/**') }}

- name: Start LocalStack
  run: |
    docker run -d \
      -p 4566:4566 \
      -e PERSISTENCE=1 \
      -v /tmp/localstack:/var/lib/localstack \
      localstack/localstack:3.0.2
```

## GitLab CI

### .gitlab-ci.yml
```yaml
variables:
  AWS_ENDPOINT_URL: http://localstack:4566
  LOCALSTACK_VERSION: "3.0.2"

services:
  - name: localstack/localstack:${LOCALSTACK_VERSION}
    alias: localstack
    variables:
      SERVICES: s3,lambda,dynamodb

integration_tests:
  stage: test
  image: python:3.11
  before_script:
    - pip install awscli-local pytest boto3
    - until curl -f http://localstack:4566/_localstack/health; do sleep 2; done
  script:
    - awslocal s3 mb s3://test-bucket
    - pytest tests/integration
```

### Pro Version
```yaml
services:
  - name: localstack/localstack-pro:${LOCALSTACK_VERSION}
    alias: localstack
    variables:
      LOCALSTACK_AUTH_TOKEN: ${LOCALSTACK_AUTH_TOKEN}
      SERVICES: s3,lambda,dynamodb,eks
```

Store `LOCALSTACK_AUTH_TOKEN` in GitLab CI/CD Variables (masked).

## CircleCI

### .circleci/config.yml
```yaml
version: 2.1

jobs:
  integration_test:
    docker:
      - image: cimg/python:3.11
      - image: localstack/localstack:3.0.2
        environment:
          SERVICES: s3,lambda,dynamodb
          PERSISTENCE: 1
    
    steps:
      - checkout
      
      - run:
          name: Wait for LocalStack
          command: |
            until curl -f http://localhost:4566/_localstack/health; do
              sleep 2
            done
      
      - run:
          name: Install Dependencies
          command: pip install awscli-local pytest boto3
      
      - run:
          name: Setup Resources
          command: |
            awslocal s3 mb s3://test-bucket
      
      - run:
          name: Run Integration Tests
          environment:
            AWS_ENDPOINT_URL: http://localhost:4566
          command: pytest tests/integration

workflows:
  version: 2
  test:
    jobs:
      - integration_test
```

## Jenkins

### Jenkinsfile
```groovy
pipeline {
  agent any
  
  stages {
    stage('Setup') {
      steps {
        sh 'docker run -d --name localstack -p 4566:4566 -e SERVICES=s3,lambda,dynamodb localstack/localstack:3.0.2'
        sh 'sleep 10'  // Wait for startup
        sh 'until curl -f http://localhost:4566/_localstack/health; do sleep 2; done'
      }
    }
    
    stage('Test') {
      steps {
        sh 'pip install awscli-local'
        sh 'awslocal s3 mb s3://test-bucket'
        sh 'AWS_ENDPOINT_URL=http://localhost:4566 pytest tests/integration'
      }
    }
  }
  
  post {
    always {
      sh 'docker stop localstack || true'
      sh 'docker rm localstack || true'
    }
  }
}
```

## Cloud Pods for Seeded Fixtures (Pro)

Use Cloud Pods to start tests with pre-seeded state:

```yaml
- name: Load Fixture
  run: |
    pip install localstack
    localstack pod load integration-test-fixture

- name: Run Tests
  run: pytest tests/integration
```

**Benefits:**
- Skip resource creation time
- Deterministic test data
- Share fixtures across team

## IaC-Based Seeding

### Terraform
```yaml
- name: Apply Infrastructure
  run: |
    pip install terraform-local
    cd infrastructure
    tflocal init
    tflocal apply -auto-approve

- name: Run Tests
  run: pytest tests/integration
```

### CDK
```yaml
- name: Deploy Stack
  run: |
    npm install -g aws-cdk-local
    cd infrastructure
    cdklocal deploy --require-approval never

- name: Run Tests
  run: pytest tests/integration
```

## Parallel Test Execution

Run multiple test suites against separate LocalStack instances:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        suite: [auth, payments, notifications]
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Start LocalStack
        run: |
          docker run -d \
            --name localstack-${{ matrix.suite }} \
            -p $((4566 + ${{ strategy.job-index }})):4566 \
            -e SERVICES=s3,lambda,dynamodb \
            localstack/localstack:3.0.2
      
      - name: Run ${{ matrix.suite }} Tests
        env:
          AWS_ENDPOINT_URL: http://localhost:$((4566 + ${{ strategy.job-index }}))
        run: pytest tests/${{ matrix.suite }}
```

## Best Practices

1. **Pin version:** Use specific LocalStack image tag (`3.0.2` not `latest`)
2. **Health check:** Always wait for `/health` endpoint before tests
3. **Limit services:** Set `SERVICES` env to only needed services (faster startup)
4. **Persistence:** Enable for faster subsequent runs with cached runtimes
5. **Cleanup:** Tear down containers/volumes after tests (avoid state leaks)
6. **Secrets:** Store Pro auth token in CI secrets, not committed code
7. **Logs:** Capture LocalStack logs on failure for debugging (`docker logs localstack`)

## Example: Full Integration Test Script

```bash
#!/bin/bash
set -e

# Start LocalStack
docker run -d \
  --name localstack \
  -p 4566:4566 \
  -e SERVICES=s3,lambda,dynamodb,sqs \
  -e PERSISTENCE=1 \
  -v /tmp/localstack:/var/lib/localstack \
  localstack/localstack:3.0.2

# Wait for health
until curl -f http://localhost:4566/_localstack/health; do
  echo "Waiting for LocalStack..."
  sleep 2
done

echo "LocalStack ready"

# Apply infrastructure
pip install terraform-local
cd infrastructure
tflocal init
tflocal apply -auto-approve
cd ..

# Run tests
export AWS_ENDPOINT_URL=http://localhost:4566
pytest tests/integration -v

# Capture logs on failure
if [ $? -ne 0 ]; then
  echo "Tests failed. LocalStack logs:"
  docker logs localstack
  exit 1
fi

# Cleanup
docker stop localstack
docker rm localstack
```
