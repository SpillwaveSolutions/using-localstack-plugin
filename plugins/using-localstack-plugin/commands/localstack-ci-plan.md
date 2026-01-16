---
name: localstack-ci-plan
description: Generate a CI-ready LocalStack plan (services, env vars, image pin, persistence) for tflocal/cdklocal pipelines.
parameters:
  - name: services
    description: Comma list of services to start (default: s3,lambda,dynamodb,cloudformation,sqs,sns).
    required: false
  - name: persistence
    description: Enable persistence across CI steps (true/false, default false).
    required: false
    default: false
  - name: version
    description: Pin LocalStack image tag (e.g., 3.8.0; default latest).
    required: false
skills:
  - using-localstack
---

# LocalStack CI Plan

Produces a ready-to-apply CI recipe for running LocalStack in pipelines (GitHub Actions/Jenkins/GitLab), including env vars, image pinning, and volume mounts for deterministic tests.

## Usage

```
/localstack-ci-plan
/localstack-ci-plan --services s3,lambda,dynamodb --persistence true --version 3.8.0
```

## What It Does
1. Recommends a `localstack/localstack` (or `-pro`) image tag and core env vars.
2. Suggests `SERVICES` set, volume mounts (`/var/lib/localstack`), and health checks.
3. Outputs tflocal/cdklocal/awslocal wiring and example job steps.
4. Highlights snapshot/persistence guidance and cleanup strategy.
