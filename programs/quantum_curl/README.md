# Quantum Curl

**High-Velocity Command-Driven Router for Microservice Orchestration**

Quantum Curl is not a curl clone. It is a strategic weapon designed for the orchestration and stress-testing of complex microservice architectures.

## Core Architecture

The genius lies in the decoupling of the **Battle Plan** (the JSONL manifest) from the **Execution Engine** (the high-concurrency Zig runtime). This allows you to define complex, multi-stage, multi-service operations as a simple, declarative data file, and then unleash the full, zero-contention power of the `http_sentinel` engine to execute that plan with breathtaking speed and efficiency.

```
┌────────────────────────────────────────────────────────────────┐
│                     QUANTUM CURL ARCHITECTURE                  │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│   ┌─────────────┐    ┌──────────────────────────────────────┐  │
│   │ Battle Plan │    │         Execution Engine             │  │
│   │   (JSONL)   │───▶│  ┌────────────────────────────────┐  │  │
│   │             │    │  │     Thread Pool (N workers)    │  │  │
│   │ {"id":"1"}  │    │  │  ┌─────┐ ┌─────┐ ┌─────┐       │  │  │
│   │ {"id":"2"}  │    │  │  │ W1  │ │ W2  │ │ WN  │       │  │  │
│   │ {"id":"3"}  │    │  │  │ HC  │ │ HC  │ │ HC  │       │  │  │
│   │    ...      │    │  │  └──┬──┘ └──┬──┘ └──┬──┘       │  │  │
│   └─────────────┘    │  │     │       │       │          │  │  │
│                      │  │     ▼       ▼       ▼          │  │  │
│                      │  │  ┌─────────────────────────┐   │  │  │
│                      │  │  │   Target Services       │   │  │  │
│                      │  │  │ (Microservice Mesh)     │   │  │  │
│                      │  │  └─────────────────────────┘   │  │  │
│                      │  └────────────────────────────────┘  │  │
│                      │                                      │  │
│                      │  HC = HttpClient (per-worker)        │  │
│                      │  Zero contention via isolation       │  │
│                      └──────────────────────────────────────┘  │
│                                        │                       │
│                                        ▼                       │
│                         ┌──────────────────────────┐           │
│                         │   Telemetry Stream       │           │
│                         │      (JSONL out)         │           │
│                         │                          │           │
│                         │ {"id":"1","status":200}  │           │
│                         │ {"id":"2","status":500}  │           │
│                         │ {"id":"3","status":200}  │           │
│                         └──────────────────────────┘           │
└────────────────────────────────────────────────────────────────┘
```

## Performance Characteristics

### Sustained Benchmark Results (60 seconds)

| Concurrency | Total Requests | Throughput | Success Rate | Avg Latency |
|-------------|----------------|------------|--------------|-------------|
| 100 workers | 2,892,251 | 48,202 req/sec | 100.0% | 2.07 ms |
| 200 workers | 2,810,481 | 46,836 req/sec | 100.0% | 4.27 ms |

### Key Metrics

| Metric | Value | Notes |
|--------|-------|-------|
| Sustained Throughput | ~48K req/sec | Consistent over 60+ seconds |
| Success Rate | 100% | Zero failures under load |
| Latency (100 concurrent) | ~2ms avg | Min: 0ms, Max: 21ms |
| Latency (200 concurrent) | ~4ms avg | Min: 0ms, Max: 41ms |
| Concurrency Model | Thread-per-request | Zero contention |
| Memory Pattern | Client-per-worker | No shared state, no leaks |

## Strategic Applications

### 1. Service Mesh Router

A decentralized, high-velocity conductor for inter-service communication:

```jsonl
{"id":"auth-check","method":"GET","url":"http://auth-service:8080/validate","headers":{"Authorization":"Bearer token"}}
{"id":"user-data","method":"GET","url":"http://user-service:8080/profile/123"}
{"id":"metrics-push","method":"POST","url":"http://metrics-service:8080/ingest","body":"{\"event\":\"login\"}"}
```

### 2. Resilience-Forging Tool

Native retry and backoff logic imposes discipline on unstable or "flaky" services:

```jsonl
{"id":"flaky-api","method":"GET","url":"http://unreliable-service:8080/data","max_retries":5}
{"id":"critical-write","method":"POST","url":"http://database-api:8080/write","body":"{}","max_retries":10}
```

### 3. Stress-Testing Weapon

Controlled, overwhelming force projection to find precise breaking points:

```bash
# Generate 10,000 requests and fire at 200 concurrent
./generate-load.sh 10000 | quantum-curl --concurrency 200
```

### 4. API Test Suite Executor

Batch execution of comprehensive test suites with full telemetry:

```bash
quantum-curl --file api-test-suite.jsonl --concurrency 50 > results.jsonl
```

## Installation

### From Source

```bash
# Build quantum-curl
cd programs/quantum_curl
zig build

# Binary available at zig-out/bin/quantum-curl
```

### From Monorepo Root

```bash
zig build quantum_curl
# Binary at zig-out/bin/quantum-curl
```

## Usage

### Basic Usage

```bash
# Process requests from file
quantum-curl --file battle-plan.jsonl

# Process from stdin (pipeline mode)
cat requests.jsonl | quantum-curl

# Single request via echo
echo '{"id":"1","method":"GET","url":"https://httpbin.org/get"}' | quantum-curl
```

### Concurrency Control

```bash
# Default: 50 concurrent requests
quantum-curl --file requests.jsonl

# High-concurrency stress test
quantum-curl --file stress-test.jsonl --concurrency 200

# Conservative mode for rate-limited APIs
quantum-curl --file api-calls.jsonl --concurrency 5
```

### Pipeline Patterns

```bash
# Generate requests dynamically
seq 1 1000 | while read i; do
  echo "{\"id\":\"req-$i\",\"method\":\"GET\",\"url\":\"http://target:8080/item/$i\"}"
done | quantum-curl --concurrency 100

# Filter and retry failed requests
quantum-curl --file requests.jsonl | jq -c 'select(.status != 200)' | quantum-curl
```

## Input Format: The Command Protocol

Each line is an independent request manifest in JSON format:

```jsonl
{"id":"unique-id","method":"GET","url":"https://api.example.com/resource"}
{"id":"post-req","method":"POST","url":"https://api.example.com/create","headers":{"Content-Type":"application/json"},"body":"{\"name\":\"test\"}"}
{"id":"retry-req","method":"GET","url":"https://flaky.example.com/data","max_retries":5,"timeout_ms":10000}
```

### Request Manifest Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique identifier for request tracking |
| `method` | string | Yes | HTTP method: GET, POST, PUT, PATCH, DELETE |
| `url` | string | Yes | Full URL including scheme |
| `headers` | object | No | Key-value pairs for HTTP headers |
| `body` | string | No | Request body (for POST, PUT, PATCH) |
| `timeout_ms` | number | No | Request timeout in milliseconds |
| `max_retries` | number | No | Override default retry count |

## Output Format: Telemetry Stream

Each response is a JSONL record with full telemetry:

```jsonl
{"id":"unique-id","status":200,"latency_ms":45,"retry_count":0,"body":"..."}
{"id":"failed-req","status":0,"latency_ms":3001,"retry_count":3,"error":"Connection timed out"}
```

### Response Manifest Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Request ID for correlation |
| `status` | number | HTTP status code (0 if failed before response) |
| `latency_ms` | number | Wall-clock time in milliseconds |
| `retry_count` | number | Number of retry attempts (0 = first try succeeded) |
| `body` | string | Response body (truncated to 1000 chars) |
| `error` | string | Error message if request failed |

## Examples

### Service Health Check Suite

```jsonl
{"id":"auth-health","method":"GET","url":"http://auth:8080/health"}
{"id":"user-health","method":"GET","url":"http://user:8080/health"}
{"id":"order-health","method":"GET","url":"http://order:8080/health"}
{"id":"payment-health","method":"GET","url":"http://payment:8080/health"}
{"id":"notification-health","method":"GET","url":"http://notification:8080/health"}
```

### API Integration Tests

```jsonl
{"id":"create-user","method":"POST","url":"http://api:8080/users","headers":{"Content-Type":"application/json"},"body":"{\"name\":\"test\",\"email\":\"test@example.com\"}"}
{"id":"get-user","method":"GET","url":"http://api:8080/users/1"}
{"id":"update-user","method":"PUT","url":"http://api:8080/users/1","headers":{"Content-Type":"application/json"},"body":"{\"name\":\"updated\"}"}
{"id":"delete-user","method":"DELETE","url":"http://api:8080/users/1"}
```

### Load Test Configuration

```jsonl
{"id":"load-1","method":"GET","url":"http://target:8080/endpoint","max_retries":0}
{"id":"load-2","method":"GET","url":"http://target:8080/endpoint","max_retries":0}
{"id":"load-3","method":"GET","url":"http://target:8080/endpoint","max_retries":0}
... (repeat for desired load)
```

## Architecture Details

### Dependency on http_sentinel

Quantum Curl is architecturally dependent on `http_sentinel` as its core HTTP client library. This relationship provides:

- **HttpClient**: Thread-safe, high-performance HTTP client
- **Automatic GZIP decompression**: Transparent handling of compressed responses
- **Connection management**: Proper resource lifecycle handling

### Thread Model

```
Main Thread
    │
    ├── Parse JSONL input
    │
    ├── For each batch (up to max_concurrency):
    │       │
    │       ├── Spawn Worker Thread 1 ─── HttpClient ─── Target
    │       ├── Spawn Worker Thread 2 ─── HttpClient ─── Target
    │       ├── Spawn Worker Thread N ─── HttpClient ─── Target
    │       │
    │       └── Join all threads (wait for batch completion)
    │
    └── Stream JSONL output (mutex-protected)
```

### Retry Logic

Failed requests are automatically retried with exponential backoff:

- Base delay: 100ms
- Backoff formula: `100ms * 2^attempt`
- Example: 100ms, 200ms, 400ms, 800ms, 1600ms...

## Real-World Testing: CRG Direct SvelteKit

The `examples/` directory includes battle-tested JSONL files for the [CRG Direct](https://crg-direct-sveltekit--quantum-encoding-v3.europe-west4.hosted.app/) production SvelteKit deployment.

### Route Coverage Test

Hits every public route once to verify zero 404s after a deployment:

```bash
quantum-curl --file examples/crg-route-test.jsonl --concurrency 10
```

**56 endpoints** tested — public pages, service pages, auth flows, sitemap, and a deliberate 404 control. Pipe through `jq` to flag failures:

```bash
quantum-curl --file examples/crg-route-test.jsonl --concurrency 10 \
  | jq -c 'select(.status >= 400 and .id != "route-056-expect-404")'
```

If that outputs nothing, the deploy is clean.

### Stress Test

Hammers the homepage with concurrent requests to check cold-start and throughput:

```bash
quantum-curl --file examples/crg-stress-test.jsonl --concurrency 50
```

### Example Results (europe-west4, Cloud Run)

| Test | Routes | 200 OK | Redirects | 404 | 500 | Avg Latency |
|------|--------|--------|-----------|-----|-----|-------------|
| Route coverage | 56 | 52 | 3 (auth redirects) | 1 (expected) | 0 | ~350ms |
| Stress test | 50 | 50 | 0 | 0 | 0 | varies |

## Integration with CI/CD

### GitHub Actions Example

```yaml
- name: API Integration Tests
  run: |
    quantum-curl --file tests/api-suite.jsonl --concurrency 20 > results.jsonl
    # Verify all requests succeeded
    if jq -e 'select(.status != 200)' results.jsonl > /dev/null; then
      echo "Some requests failed!"
      jq 'select(.status != 200)' results.jsonl
      exit 1
    fi
```

### Docker Integration

```dockerfile
FROM alpine:latest
COPY zig-out/bin/quantum-curl /usr/local/bin/
ENTRYPOINT ["quantum-curl"]
```

## Benchmarking

Quantum Curl includes a comprehensive benchmark suite for performance validation:

```bash
# Build benchmark tools
zig build

# Start the echo server (in terminal 1)
./zig-out/bin/bench-echo-server 8888

# Run quick benchmark (in terminal 2)
./zig-out/bin/bench-quantum-curl

# Run sustained 60-second benchmark
./zig-out/bin/sustained-bench --duration 60 --concurrency 100

# Run high-concurrency stress test
./zig-out/bin/sustained-bench --duration 60 --concurrency 200
```

### Benchmark Tools

| Tool | Purpose |
|------|---------|
| `bench-echo-server` | Minimal HTTP server for controlled benchmarking |
| `bench-quantum-curl` | Quick statistical benchmark with regression detection |
| `sustained-bench` | Long-running performance validation |

## Requirements

- **Zig Version**: 0.16.0+
- **Dependency**: http_sentinel (included via monorepo)
- **Platform**: Linux, macOS, Windows

## License

MIT License - See LICENSE file for details.

```
Copyright 2025 QUANTUM ENCODING LTD
Website: https://quantumencoding.io
Contact: rich@quantumencoding.io
```
