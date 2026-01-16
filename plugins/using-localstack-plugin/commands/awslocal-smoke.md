---
name: awslocal-smoke
description: Run a LocalStack smoke check (S3 bucket, DynamoDB table, Lambda invoke) to verify the stack is healthy.
parameters:
  - name: services
    description: Comma list of services to test (s3,dynamodb,lambda); default runs all.
    required: false
  - name: cleanup
    description: Delete created test resources after the check (default true).
    required: false
    default: true
skills:
  - using-localstack
---

# awslocal Smoke Check

Runs a fast health check against LocalStack using `awslocal` to validate API connectivity and basic flows.

## Usage

```
/awslocal-smoke
/awslocal-smoke --services s3,dynamodb
/awslocal-smoke --cleanup false
```

## What It Does
1. Ensures LocalStack is reachable on `http://localhost:4566`.
2. (S3) Creates a temp bucket, uploads a test object, lists it.
3. (DynamoDB) Creates a temp table, writes/reads a test item.
4. (Lambda) (If enabled) Invokes a simple function or echoes a payload.
5. Cleans up test resources if `cleanup` is true.

Use this before running integration suites or after upgrading LocalStack images.
