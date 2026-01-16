# Using LocalStack Plugin

LocalStack developer toolkit plugin to stand up, test, and debug AWS-native systems locally with LocalStack Community/Pro. Includes explicit commands/agents plus the `using-localstack` skill.

## Install

Clone to your skills/plugins location:
```
git clone https://github.com/SpillwaveSolutions/using-localstack-plugin.git
```

## Structure
```
using-localstack-plugin/
├── .claude-plugin/marketplace.json
├── plugins/using-localstack-plugin/
│   ├── skills/using-localstack/SKILL.md
│   ├── commands/
│   │   ├── awslocal-smoke.md
│   │   └── localstack-ci-plan.md
│   └── agents/
│       ├── localstack-keyword-watcher.md
│       └── localstack-ci-signal.md
├── docs/README.md
└── .gitignore
```

## Commands
- `/awslocal-smoke` — Run a LocalStack smoke check (S3, DynamoDB, Lambda) to verify health and connectivity.
- `/localstack-ci-plan` — Generate a CI-ready LocalStack plan (services, env vars, image pin, persistence).

## Agents
- `localstack-keyword-watcher` — Triggers when LocalStack/awslocal/tflocal/cdklocal is mentioned; offers setup or troubleshooting steps.
- `localstack-ci-signal` — Triggers when CI/pipeline tooling is mentioned with LocalStack; offers CI config and test guidance.

## Skill
- `using-localstack` — Full practitioner guide covering installation, awslocal, service workflows, IaC, debugging, persistence, and sharp edges.

## License
MIT © Richard Hightower
