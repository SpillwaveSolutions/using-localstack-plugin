---
name: localstack-ci-signal
description: Detects CI/pipeline mentions with LocalStack and offers a deterministic setup recipe.
triggers:
  - pattern: "(?i)(CI|pipeline|GitHub Actions|Jenkins|GitLab).*(LocalStack|awslocal)"
    type: message_pattern
skills:
  - using-localstack
---

# LocalStack CI Signal

Activates when CI or pipeline topics intersect with LocalStack to propose a CI-ready configuration.

## Behavior
1. Recommends image tag pinning, SERVICES, and env vars.
2. Suggests volume mounts for persistence and health checks.
3. Points to `/localstack-ci-plan` for a tailored job template.
