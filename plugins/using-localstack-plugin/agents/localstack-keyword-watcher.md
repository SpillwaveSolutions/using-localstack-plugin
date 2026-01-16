---
name: localstack-keyword-watcher
description: Offers LocalStack setup and troubleshooting help when awslocal/LocalStack/tflocal/cdklocal are mentioned.
triggers:
  - pattern: "(?i)localstack|awslocal|tflocal|cdklocal|localhost\\.localstack\\.cloud"
    type: message_pattern
skills:
  - using-localstack
---

# LocalStack Keyword Watcher

Listens for LocalStack-related keywords and proactively offers setup, smoke tests, and debugging steps.

## Triggers
- Mentions of `LocalStack`, `awslocal`, `tflocal`, `cdklocal`, or `localhost.localstack.cloud`.

## Behavior
1. Shares quick start (install, start, SERVICES, health check).
2. Suggests `/awslocal-smoke` when connectivity is in question.
3. Provides endpoint/DNS hints and common port conflicts.
