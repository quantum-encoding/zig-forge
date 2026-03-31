# CSV Batch Processing Feature Design

## Overview

Add batch processing capability to the `zig-ai` CLI tool for processing 100+ prompts concurrently with different AI providers per request.

## Use Cases

1. **Benchmarking**: Compare responses from multiple providers for the same prompts
2. **Bulk Processing**: Process large datasets with AI assistance
3. **A/B Testing**: Test different prompts with different providers
4. **Data Annotation**: Label/classify large datasets using AI
5. **Quality Assurance**: Run test suites against multiple AI models

## CSV Format

### Input CSV Structure

```csv
provider,prompt,temperature,max_tokens,system_prompt
deepseek,"What is Zig?",1.0,512,
claude,"Explain async/await",0.7,1024,"You are a programming tutor"
gemini,"Write a haiku about code",1.5,256,
grok,"Fix this bug: ...",0.3,2048,"You are a debugging expert"
deepseek,"Translate to Spanish: Hello",1.0,256,
```

**Required Fields**:
- `provider`: One of `claude`, `deepseek`, `gemini`, `grok`, `vertex`
- `prompt`: The prompt text (quoted if contains commas)

**Optional Fields**:
- `temperature`: Override default (default: 1.0)
- `max_tokens`: Override default (default: 4096)
- `system_prompt`: Custom system prompt (default: none)

### Output CSV Structure

```csv
id,provider,prompt,response,input_tokens,output_tokens,cost,execution_time_ms,error
1,deepseek,"What is Zig?","Zig is a general-purpose...",11,29,0.000010,1234,
2,claude,"Explain async/await","Async/await is a pattern...",8,156,0.002496,2456,
3,gemini,"Write a haiku","Code flows like water...",7,23,0.000023,987,
4,grok,"Fix this bug","The issue is...",45,123,0.001520,3456,
5,deepseek,"Translate","Hola",5,3,0.000002,456,
```

**Output Fields**:
- `id`: Sequential request ID
- `provider`: Provider used
- `prompt`: Original prompt (truncated if long)
- `response`: AI response (truncated if long, full response in separate file)
- `input_tokens`: Tokens in prompt
- `output_tokens`: Tokens in response
- `cost`: Estimated cost in USD
- `execution_time_ms`: Time to complete request
- `error`: Error message if request failed (empty if successful)

## CLI Interface

### Command Syntax

```bash
zig-ai --batch <input.csv> [options]
```

### Options

- `--batch <file>`: Input CSV file path (required)
- `--output <file>`: Output CSV file path (default: `batch_results_{timestamp}.csv`)
- `--concurrency <n>`: Max concurrent requests (default: 50, max: 200)
- `--full-responses`: Save full responses to separate directory
- `--continue-on-error`: Continue processing if individual requests fail (default: true)
- `--retry <n>`: Number of retries for failed requests (default: 2)
- `--timeout <ms>`: Per-request timeout in milliseconds (default: 120000)
- `--progress`: Show progress bar (default: true)

### Examples

**Basic batch processing:**
```bash
zig-ai --batch prompts.csv
```

**High concurrency with full responses:**
```bash
zig-ai --batch prompts.csv --concurrency 100 --full-responses
```

**Custom output location:**
```bash
zig-ai --batch prompts.csv --output results/experiment_1.csv
```

**With retries and progress:**
```bash
zig-ai --batch prompts.csv --retry 3 --progress
```

## Architecture

### Components

1. **CSV Parser** (`src/batch/csv_parser.zig`)
   - Parse input CSV with proper quote handling
   - Validate required fields
   - Build BatchRequest structures

2. **Batch Executor** (`src/batch/executor.zig`)
   - Manage concurrent request pool
   - Track in-flight requests
   - Handle retries and timeouts
   - Aggregate results

3. **Progress Tracker** (`src/batch/progress.zig`)
   - Real-time progress display
   - Statistics (success/failure counts)
   - ETA calculation
   - Rate limiting display

4. **Result Writer** (`src/batch/writer.zig`)
   - Write results to CSV incrementally
   - Handle full response output
   - Flush on signal (SIGINT/SIGTERM)

### Data Structures

```zig
pub const BatchRequest = struct {
    id: u32,
    provider: Provider,
    prompt: []const u8,
    temperature: f32 = 1.0,
    max_tokens: u32 = 4096,
    system_prompt: ?[]const u8 = null,

    allocator: std.mem.Allocator,
};

pub const BatchResult = struct {
    id: u32,
    provider: Provider,
    prompt: []const u8,
    response: ?[]const u8,
    input_tokens: u32,
    output_tokens: u32,
    cost: f64,
    execution_time_ms: u64,
    error_message: ?[]const u8,

    allocator: std.mem.Allocator,
};

pub const BatchConfig = struct {
    input_file: []const u8,
    output_file: []const u8,
    concurrency: u32 = 50,
    full_responses: bool = false,
    continue_on_error: bool = true,
    retry_count: u32 = 2,
    timeout_ms: u64 = 120000,
    show_progress: bool = true,
};
```

### Concurrency Model

Use Zig's thread pool pattern:

```zig
pub const BatchExecutor = struct {
    pool: std.Thread.Pool,
    requests: []BatchRequest,
    results: std.ArrayList(BatchResult),
    semaphore: std.Thread.Semaphore,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, concurrency: u32) !BatchExecutor;
    pub fn execute(self: *BatchExecutor, config: BatchConfig) !void;
};
```

**Execution Flow**:
1. Parse CSV into `BatchRequest` array
2. Initialize thread pool with concurrency limit
3. Spawn worker threads, each:
   - Acquire semaphore slot
   - Execute request using appropriate AI client
   - Write result (with mutex)
   - Release semaphore slot
4. Wait for all threads to complete
5. Write final results to CSV

### Error Handling

**Request-Level Errors**:
- Network failures → retry with exponential backoff
- Rate limiting → sleep and retry
- Invalid API key → fail immediately (don't retry)
- Timeout → mark as error and continue

**Batch-Level Errors**:
- Invalid CSV format → fail with clear error message
- Missing API keys → warn but continue with available providers
- Disk full → flush buffers and fail gracefully

### Progress Display

```
🔄 Processing batch: prompts.csv
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 45/100 (45%)

✅ Completed: 42   ❌ Failed: 3   ⏳ In Progress: 5   ⏰ Pending: 50

💰 Total Cost: $0.15   ⚡ Rate: 12 req/s   ⏱️  ETA: 8s

Providers: Claude: 12 | DeepSeek: 18 | Gemini: 10 | Grok: 2
```

## Implementation Plan

### Phase 1: Core Batch Processing
1. CSV parser with validation
2. Basic batch executor (sequential first)
3. Result writer
4. Simple progress output

### Phase 2: Concurrency
1. Thread pool integration
2. Semaphore-based concurrency control
3. Mutex-protected result writing
4. Request retry logic

### Phase 3: Advanced Features
1. Progress bar with statistics
2. Full response output to separate files
3. Graceful shutdown (SIGINT handling)
4. Resume from partial completion

### Phase 4: Optimization
1. Connection pooling per provider
2. Adaptive concurrency based on response times
3. Memory-efficient streaming for large batches
4. Result caching for duplicate prompts

## Testing Strategy

1. **Unit Tests**:
   - CSV parser with various formats
   - BatchRequest/BatchResult serialization
   - Error handling for invalid inputs

2. **Integration Tests**:
   - Small batch (10 requests) across all providers
   - Error recovery and retry logic
   - Progress tracking accuracy

3. **Load Tests**:
   - 100+ concurrent requests
   - Memory usage profiling
   - Rate limit handling

4. **Smoke Tests**:
   - `zig-ai --batch test.csv` with 5 simple prompts
   - Verify output CSV format
   - Check error handling

## Performance Targets

- **Throughput**: 50 requests/second at concurrency=50
- **Memory**: <500MB for 1000 requests in flight
- **Latency**: <200ms overhead per request (excluding API time)
- **Error Rate**: <1% for transient network errors (with retries)

## Security Considerations

1. **API Keys**: Use environment variables, never store in CSV
2. **File Permissions**: Set output files to 600 (user-only)
3. **Input Validation**: Sanitize all CSV inputs
4. **Resource Limits**: Cap concurrency to prevent DoS of APIs

## Future Enhancements

1. **Streaming Responses**: Support SSE for long-running prompts
2. **Smart Routing**: Auto-select best provider based on prompt type
3. **Cost Optimization**: Use cheapest provider that meets quality threshold
4. **Result Analysis**: Built-in comparison and diff tools
5. **JSON Input/Output**: Support JSON in addition to CSV
6. **Web UI**: Simple web interface for batch management

## References

- User mentioned "summon_agent program using the agent-batch binary"
- Existing CLI implementation in `src/cli.zig` and `src/main.zig`
- Thread-safe HTTP client in `src/http_client.zig`
- AI provider clients in `src/ai/*.zig`

## Timeline

- **Week 1**: Phase 1 (Core batch processing)
- **Week 2**: Phase 2 (Concurrency)
- **Week 3**: Phase 3 (Advanced features)
- **Week 4**: Phase 4 (Optimization) + Testing
