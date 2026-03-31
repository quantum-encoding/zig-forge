# API Testing Suite with quantum-curl

Complete guide for testing pre-production API deployments using quantum-curl.

## Quick Start

```bash
# 1. Make scripts executable
chmod +x examples/run-api-tests.sh examples/validate-results.sh

# 2. Edit your test suite
nano examples/api-test-suite.jsonl

# 3. Run tests against staging
./examples/run-api-tests.sh staging

# 4. Run with detailed output
./examples/run-api-tests.sh staging --verbose

# 5. Validate specific assertions
./examples/validate-results.sh test-results/latest.jsonl
```

## Test Suite Format

Each line in `api-test-suite.jsonl` is a JSON request manifest:

```json
{
  "id": "unique-test-id",
  "method": "GET|POST|PUT|DELETE|PATCH",
  "url": "https://api.staging.example.com/endpoint",
  "headers": {
    "Authorization": "Bearer token-here",
    "Content-Type": "application/json"
  },
  "body": "{\"key\":\"value\"}",
  "max_retries": 3
}
```

## Environment Configuration

Edit `run-api-tests.sh` to add your environments:

```bash
declare -A ENVS=(
    ["local"]="http://localhost:3000"
    ["dev"]="https://api.dev.yourcompany.com"
    ["staging"]="https://api.staging.yourcompany.com"
    ["production"]="https://api.yourcompany.com"
)
```

## Example Test Scenarios

### 1. Health Check Suite
```jsonl
{"id":"api-health","method":"GET","url":"https://api.staging.example.com/health"}
{"id":"db-health","method":"GET","url":"https://api.staging.example.com/health/database"}
{"id":"cache-health","method":"GET","url":"https://api.staging.example.com/health/cache"}
```

### 2. Authentication Flow
```jsonl
{"id":"register","method":"POST","url":"https://api.staging.example.com/auth/register","body":"{\"email\":\"test@test.com\",\"password\":\"test123\"}"}
{"id":"login","method":"POST","url":"https://api.staging.example.com/auth/login","body":"{\"email\":\"test@test.com\",\"password\":\"test123\"}"}
{"id":"refresh","method":"POST","url":"https://api.staging.example.com/auth/refresh","headers":{"Authorization":"Bearer __TOKEN__"}}
```

### 3. CRUD Operations
```jsonl
{"id":"create","method":"POST","url":"https://api.staging.example.com/api/items","body":"{\"name\":\"Test Item\"}"}
{"id":"read","method":"GET","url":"https://api.staging.example.com/api/items/1"}
{"id":"update","method":"PUT","url":"https://api.staging.example.com/api/items/1","body":"{\"name\":\"Updated\"}"}
{"id":"delete","method":"DELETE","url":"https://api.staging.example.com/api/items/1"}
```

## Interpreting Results

### Success Output
```
═══════════════════════════════════════════════════════════════
Test Results
═══════════════════════════════════════════════════════════════

✓ Success: 15/15
✗ Failed:  0/15
⚡ Avg Latency: 234ms

✓ health-check       [200]  45ms
✓ login-valid        [200] 123ms
✓ users-list         [200] 234ms
```

### Failure Output
```
✗ login-invalid      [401]  89ms
✗ not-found          [404]  23ms
✓ unauthorized       [403]  12ms
✗ timeout-test       [0]  5000ms (retried 3x)
  Error: Connection timeout
```

## CI/CD Integration

### GitHub Actions
Copy `examples/ci-api-tests.yml` to `.github/workflows/api-tests.yml`

**Required Secrets:**
- `STAGING_API_URL` - Staging base URL
- `STAGING_API_TOKEN` - Staging auth token
- `DEV_API_URL` - Dev base URL
- `DEV_API_TOKEN` - Dev auth token

### GitLab CI
```yaml
api-tests:
  stage: test
  image: ubuntu:latest
  script:
    - wget https://releases.example.com/quantum-curl
    - chmod +x quantum-curl
    - ./examples/run-api-tests.sh staging
  artifacts:
    paths:
      - test-results/
    when: always
```

## Advanced Usage

### Custom Assertions
```bash
# Check specific response content
jq -r 'select(.id=="health-check") | .body' results.jsonl | \
  grep -q '"status":"healthy"' && echo "✓ Health OK"

# Performance validation
LATENCY=$(jq -r 'select(.id=="critical-endpoint") | .latency_ms' results.jsonl)
if [ "$LATENCY" -lt 100 ]; then
  echo "✓ Performance OK: ${LATENCY}ms"
fi
```

### Parameterized Tests
```bash
# Generate dynamic test suite
for user_id in {1..100}; do
  echo "{\"id\":\"user-$user_id\",\"method\":\"GET\",\"url\":\"https://api.example.com/users/$user_id\"}"
done | ./quantum-curl --concurrency 50
```

### Load Testing
```bash
# Stress test with 1000 concurrent requests
for i in {1..1000}; do
  echo "{\"id\":\"load-$i\",\"method\":\"GET\",\"url\":\"https://api.example.com/endpoint\"}"
done | ./quantum-curl --concurrency 100 > load-test-results.jsonl

# Analyze latency distribution
jq -r '.latency_ms' load-test-results.jsonl | \
  awk '{sum+=$1; sumsq+=$1*$1} END {
    printf "Avg: %.0fms, StdDev: %.0fms\n",
    sum/NR, sqrt(sumsq/NR - (sum/NR)^2)
  }'
```

## Best Practices

1. **Idempotent Tests** - Design tests that can run multiple times
2. **Independent Tests** - Don't rely on test execution order
3. **Cleanup** - Delete test data after validation
4. **Environment Isolation** - Use separate test accounts per environment
5. **Version Control** - Commit test suites alongside code
6. **Monitor Performance** - Track latency trends over time
7. **Retry Logic** - Use `max_retries` for flaky endpoints

## Troubleshooting

### High Latency
```bash
# Reduce concurrency
./quantum-curl --file tests.jsonl --concurrency 10

# Check network
ping api.staging.example.com
```

### Failed Requests
```bash
# View error details
jq 'select(.error_message != null)' results.jsonl

# Check retry counts
jq 'select(.retry_count > 0) | {id, retries: .retry_count}' results.jsonl
```

### Rate Limiting
Quantum-curl has built-in rate limiting (200 req/min default). If you hit API rate limits:

1. Reduce concurrency: `--concurrency 5`
2. Add delays in test suite
3. Split tests into multiple runs
4. Contact your API team for higher limits

## Example: Full Pre-Production Validation

```bash
#!/bin/bash
# Complete validation script

echo "🔍 Starting pre-production validation..."

# 1. Health checks (fast fail)
./examples/run-api-tests.sh staging | grep -q "health-check.*200" || {
  echo "❌ Health check failed - aborting"
  exit 1
}

# 2. Critical path tests
./examples/run-api-tests.sh staging

# 3. Validate specific assertions
./examples/validate-results.sh test-results/latest.jsonl

# 4. Performance benchmarks
AVG_LATENCY=$(jq -s 'map(.latency_ms) | add / length' test-results/latest.jsonl)
if (( $(echo "$AVG_LATENCY > 500" | bc -l) )); then
  echo "⚠️  Performance degradation detected: ${AVG_LATENCY}ms"
  exit 1
fi

echo "✅ All pre-production validations passed!"
```

## Next Steps

- Add more test scenarios to `api-test-suite.jsonl`
- Customize validation rules in `validate-results.sh`
- Integrate into your CI/CD pipeline
- Set up monitoring dashboards with test metrics
- Create separate test suites for smoke/regression/load tests
