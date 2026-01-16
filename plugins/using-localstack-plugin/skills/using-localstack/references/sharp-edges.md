# Sharp Edges & Limits

LocalStack aims for high fidelity with AWS, but gaps remain. This guide covers known limits, gotchas, and AWS parity differences.

## Not Production

**LocalStack is for development and testing only.** Do not use for production workloads.

### Missing Production Features
- **Multi-AZ:** Single-region emulation, no AZ redundancy
- **Global tables:** DynamoDB global tables not supported
- **Cross-region replication:** S3/RDS cross-region replication unavailable
- **Managed service edge cases:** Simplified behavior for complex managed service interactions
- **Scale/performance parity:** Latency and throughput differ from AWS

### Validation Still Required
Always validate in real AWS before production:
- IAM policy edge cases
- Service quotas and limits
- Scale and performance characteristics
- Regional service availability
- Managed service upgrade behavior

## IAM Enforcement

### Community Edition
Default: **allow-all**. IAM policies not enforced. Any credentials work.

### Pro Edition
- `ENFORCE_IAM=1`: Real policy evaluation (requests can fail if denied)
- `IAM_SOFT_MODE=1`: Logs violations without blocking (discover needed permissions)
- **Custom trust policies:** May be simplified; complex trust relationships might not match AWS behavior exactly

**Recommendation:** Test IAM in real AWS sandbox for production-critical policies.

## Service-Specific Limits

### Lambda
- **Runtimes:** Supported via Docker images; custom runtimes may require additional config
- **Cold start timing:** Differs from AWS (faster or slower depending on host resources)
- **Concurrency:** No hard limit, but constrained by Docker host resources
- **VPC:** Lambda VPC networking simplified (no ENI management delays)

### DynamoDB
- **Global tables:** Not supported
- **Backups/restores:** Simplified (no point-in-time recovery)
- **Auto-scaling:** Billing mode works but scaling behavior differs
- **DAX:** DynamoDB Accelerator not available

### S3
- **Cross-region replication:** Not supported
- **Transfer acceleration:** Stub only (no actual acceleration)
- **Glacier storage classes:** Simulated (no actual archival delay)
- **Bucket policies with complex conditions:** May not fully match AWS evaluation logic

### RDS/Aurora (Pro)
- **Snapshots:** Simplified (no automated backups or cross-region snapshots)
- **Read replicas:** Limited support
- **Failover:** No multi-AZ failover simulation
- **Performance Insights:** Not available

### EKS (Pro)
- **Control plane:** Simulated (uses k3d, not real EKS control plane)
- **Managed node groups:** Simplified node management
- **Fargate:** EKS + Fargate not fully supported
- **ALB Ingress Controller:** May require manual setup

### MSK (Pro)
- **Multi-broker clusters:** Simplified topology (fewer brokers than AWS)
- **Tiered storage:** Not supported
- **MSK Connect:** Limited support

### Step Functions (Pro)
- **Service integrations:** Most supported, but some advanced integrations may be stubbed
- **Express workflows:** Supported, but execution semantics may differ slightly
- **Activity workers:** Supported but timing/polling behavior may vary

### EventBridge
- **Schema registry:** Supported, but auto-discovery limited
- **Event Replay:** Not available
- **Cross-region event buses:** Not supported

### API Gateway
- **Throttling:** Not enforced (no rate limiting)
- **Usage plans/API keys:** Accepted but not enforced
- **Custom domain names:** Simplified (no real DNS or certificate validation)

## Custom Resources (CloudFormation)

Lambda-backed custom resources generally work, but:
- **Async operations:** Long-running custom resources may timeout if not handled properly
- **External lookups:** Custom resources querying real AWS will fail unless given real credentials

## Terraform Provider Compatibility

- **AWS Provider v5:** May encounter schema issues; prefer v4 if problems arise
- **State locking:** Works with LocalStack S3 backend, but DynamoDB locking simplified
- **Data sources:** Lookups for existing resources work only within LocalStack scope

## CDK Limitations

- **Context lookups:** May fail for VPC/hosted zone lookups; supply via `cdk.json` context
- **Cross-stack references:** Work within LocalStack but differ from AWS (no CloudFormation exports across accounts)
- **Bootstrap:** Uses LocalStack S3 for staging bucket (not real AWS)

## Networking Gotchas

### Lambda → LocalStack
Lambdas run in Docker containers. Must use internal DNS or bridge network:
```bash
export LAMBDA_DOCKER_NETWORK=bridge
```

Or use `localhost.localstack.cloud` in Lambda code.

### Host → LocalStack
Always `http://localhost:4566` from host machine.

### Container → LocalStack
Use service name (`localstack`) if in Docker Compose network, or container IP.

## Port Conflicts

If port 4566 conflicts:
```bash
export EXTERNAL_SERVICE_PORTS_START=4600
```

Or map Docker port differently:
```bash
docker run -p 4567:4566 ...
```

## Performance Expectations

- **Faster:** No network latency to AWS regions; single-box simplicity
- **Slower:** Some operations slower due to Docker overhead and emulation
- **Resource-bound:** Heavy workloads (EKS, MSK, RDS) require substantial RAM (16-32 GB)

## Debugging Differences

- **Logs:** Centralized in Docker logs (no separate CloudWatch log groups unless created)
- **Metrics:** No CloudWatch metrics by default (custom metrics need manual push)
- **Traces:** No X-Ray tracing (use EventBridge Event Studio for event tracing in Pro)

## Edge Cases to Watch

1. **ARN formats:** LocalStack uses account ID `000000000000` and region `us-east-1` by default
2. **Timestamps:** May differ slightly from AWS (clock skew issues rare but possible)
3. **Error messages:** Error responses may not exactly match AWS format
4. **Pagination:** Some list APIs may not paginate identically to AWS
5. **Eventual consistency:** DynamoDB eventually consistent reads may be immediately consistent in LocalStack

## When to Escalate to Real AWS

Test in real AWS if:
- Complex IAM policies with conditions/tags
- Service interactions involving multiple regions
- Performance/scale validation (load testing)
- Managed service upgrade paths (e.g., RDS minor version upgrades)
- Advanced networking (VPC peering, Transit Gateway)

## Known Issues & Workarounds

### Issue: S3 Event Notifications Delayed
**Workaround:** Poll or add explicit delay; event delivery timing differs from AWS

### Issue: Lambda Cold Starts Inconsistent
**Workaround:** Use `LAMBDA_KEEPALIVE_MS` to tune warm container retention

### Issue: DynamoDB Streams Latency
**Workaround:** Expect faster delivery than AWS; adjust batch windows if testing backpressure

### Issue: API Gateway CORS Not Applied
**Workaround:** Verify OPTIONS method explicitly defined; CORS headers may need manual mock integration

### Issue: CloudFormation Stack Delete Fails
**Workaround:** Check for resource dependencies; delete manually via awslocal then delete stack

## Reporting Issues

If you encounter bugs or unexpected behavior:
1. Check LocalStack version (`localstack --version`)
2. Review service documentation: https://docs.localstack.cloud/aws/services/
3. Search GitHub issues: https://github.com/localstack/localstack/issues
4. Provide minimal reproduction (IaC template or awslocal commands)
5. Include LocalStack logs (`docker logs localstack`)

## Staying Updated

- **Release notes:** https://docs.localstack.cloud/references/changelog/
- **Service coverage:** https://docs.localstack.cloud/aws/feature-coverage/
- **Blog:** https://blog.localstack.cloud/

## Final Reminder

LocalStack is a powerful tool for local development and deterministic CI/CD, but it's not a perfect AWS replica. Always validate critical workflows in real AWS before production deployment.
