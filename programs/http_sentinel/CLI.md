# zig-ai - Universal AI Command Line Tool

A production-ready CLI tool for interacting with multiple AI providers from the terminal. Built with Zig 0.16.0 using our high-performance HTTP client with automatic gzip decompression.

## Supported Providers

- **Claude** (Anthropic) - Industry-leading reasoning and coding
- **DeepSeek** - Ultra-affordable (95% cheaper than Claude!)
- **Gemini** (Google) - Fast and capable
- **Grok** (X.AI) - Specialized for code
- **Vertex AI** (Google Cloud) - Enterprise-grade with OAuth2

## Features

✨ **Multiple Modes**
- One-shot queries for quick questions
- Interactive mode for conversations
- Batch processing for CSV files (coming soon)

📊 **Rich Output**
- Token usage tracking
- **Accurate cost calculation** using real-time pricing from `model_costs.csv`
- Per-model pricing for precise cost estimation
- Formatted, readable responses

⚙️ **Highly Configurable**
- Adjustable temperature
- Max tokens control
- Custom system prompts
- Provider switching on-the-fly

🚀 **Production Ready**
- Automatic gzip decompression
- Proper error handling
- Thread-safe HTTP client
- Memory-efficient

## Installation

### Build from Source

```bash
cd zig-http-concurrent
zig build install --prefix ~/.local
```

This installs `zig-ai` to `~/.local/bin/zig-ai`. Make sure `~/.local/bin` is in your PATH:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### System-Wide Installation (requires sudo)

```bash
zig build install --prefix /usr/local
```

This installs to `/usr/local/bin/zig-ai`, making it available system-wide.

## Configuration

### API Keys

Configure API keys using environment variables:

```bash
# Claude (Anthropic)
export ANTHROPIC_API_KEY="sk-ant-..."

# DeepSeek (most affordable!)
export DEEPSEEK_API_KEY="sk-..."

# Gemini (Google)
export GEMINI_API_KEY="..."

# Grok (X.AI)
export XAI_API_KEY="xai-..."

# Vertex AI (Google Cloud) - requires gcloud auth
export VERTEX_PROJECT_ID="your-project-id"
gcloud auth login
gcloud auth application-default login
```

**Tip**: Add these to your `~/.bashrc` or `~/.zshrc` for persistence:

```bash
# Add to ~/.bashrc
export DEEPSEEK_API_KEY="your-key-here"
export GEMINI_API_KEY="your-key-here"
export XAI_API_KEY="your-key-here"
```

### Security Best Practices

**Never commit API keys to git!** Use one of these secure methods:

1. **Environment Variables** (recommended for development)
   ```bash
   export DEEPSEEK_API_KEY="your-key"
   ```

2. **Separate Config File** (recommended for production)
   ```bash
   # Create ~/.config/zig-ai/config
   mkdir -p ~/.config/zig-ai
   echo 'export DEEPSEEK_API_KEY="your-key"' > ~/.config/zig-ai/config
   chmod 600 ~/.config/zig-ai/config

   # Source it in your shell
   source ~/.config/zig-ai/config
   ```

3. **Pass-through from Secret Manager**
   ```bash
   export DEEPSEEK_API_KEY=$(pass show api/deepseek)
   ```

## Usage

### Basic Syntax

```bash
zig-ai [provider] [options] "prompt"
zig-ai --interactive [provider]
zig-ai --batch <csv_file> [options]
zig-ai --list
zig-ai --help
```

### Quick Start Examples

**Simple query:**
```bash
zig-ai deepseek "What is Zig?"
```

**With temperature control:**
```bash
zig-ai claude --temperature 0.5 "Explain async/await"
```

**Interactive mode:**
```bash
zig-ai --interactive gemini
```

**Custom system prompt:**
```bash
zig-ai grok --system "You are a Zig expert" "Best practices for error handling?"
```

**List all providers:**
```bash
zig-ai --list
```

### Command-Line Options

| Option | Short | Description | Example |
|--------|-------|-------------|---------|
| `--help` | `-h` | Show help message | `zig-ai --help` |
| `--list` | `-l` | List available providers | `zig-ai --list` |
| `--interactive` | `-i` | Start interactive mode | `zig-ai -i deepseek` |
| `--temperature` | `-t` | Set temperature (0.0-2.0) | `zig-ai -t 0.7 claude "..."` |
| `--max-tokens` | `-m` | Set max output tokens | `zig-ai -m 4096 deepseek "..."` |
| `--system` | `-s` | Set system prompt | `zig-ai -s "You are helpful" grok "..."` |
| `--no-usage` | | Hide token usage stats | `zig-ai --no-usage deepseek "..."` |
| `--no-cost` | | Hide cost estimates | `zig-ai --no-cost claude "..."` |

### Batch Mode

Batch mode allows you to process multiple prompts concurrently from a CSV file:

```bash
$ zig-ai --batch prompts.csv
```

**CSV Format:**
```csv
provider,prompt,temperature,max_tokens,system_prompt
deepseek,"What is Zig?",1.0,512,
claude,"Explain async/await",0.7,1024,"You are a programming tutor"
gemini,"Write a haiku",1.5,256,
```

**Required columns:** `provider`, `prompt`
**Optional columns:** `temperature`, `max_tokens`, `system_prompt`

**Batch Options:**

| Option | Description | Default |
|--------|-------------|---------|
| `--batch <file>` | Input CSV file | Required |
| `--output <file>` | Output CSV file | `batch_results_{timestamp}.csv` |
| `--concurrency <n>` | Max concurrent requests | 50 |
| `--retry <n>` | Retry attempts per request | 2 |
| `--full-responses` | Save full responses to separate files | false |

**Example Output:**
```csv
id,provider,prompt,response,input_tokens,output_tokens,cost,execution_time_ms,error
1,deepseek,"What is Zig?","Zig is a general-purpose...",11,29,0.000010,1234,
2,claude,"Explain async","Async/await is...",8,156,0.002496,2456,
```

**Advanced Batch Examples:**

```bash
# High concurrency
zig-ai --batch prompts.csv --concurrency 100

# Custom output with full responses
zig-ai --batch prompts.csv --output results/experiment_1.csv --full-responses

# With retries for unstable connections
zig-ai --batch prompts.csv --retry 5 --concurrency 20
```

**Progress Tracking:**
```
🔄 Starting batch processing...
   Requests: 100
   Concurrency: 50
   Retry count: 2

[INFO] Processed 45/100 requests (✅ 42 ❌ 3)...

✨ Batch complete!
   Total time: 12.34s
   Success: 97
   Failed: 3
```

### Interactive Mode

Interactive mode provides a conversation experience with persistent context:

```bash
$ zig-ai --interactive deepseek

╔══════════════════════════════════════════════════════════╗
║  AI Providers CLI - Interactive Mode                    ║
║  Provider: DeepSeek (Ultra-Affordable)                  ║
╚══════════════════════════════════════════════════════════╝

Commands:
  /help     - Show this help
  /clear    - Clear conversation history
  /switch   - Switch provider
  /quit     - Exit

👤 You: What is Zig?

🤖 DeepSeek:
Zig is a general-purpose programming language designed for
robustness, optimality, and clarity...

📊 Tokens: 11 in, 29 out
💰 Estimated cost: $0.000010

👤 You: What makes it different from Rust?

🤖 DeepSeek:
[Response with full conversation context...]

👤 You: /quit

👋 Goodbye!
```

### Practical Use Cases

#### 1. Quick Documentation Lookup
```bash
zig-ai deepseek "How do I use ArrayList in Zig?"
```

#### 2. Code Review
```bash
zig-ai claude --system "You are a code reviewer" "$(cat mycode.zig)"
```

#### 3. Shell Scripting Integration
```bash
#!/bin/bash
# Generate commit messages
DIFF=$(git diff --staged)
MSG=$(zig-ai deepseek "Generate a commit message for: $DIFF")
echo "$MSG"
```

#### 4. Piping from stdin
```bash
cat error.log | zig-ai grok "Analyze these errors and suggest fixes"
```

#### 5. Cost Comparison
```bash
# Test same prompt on different providers
zig-ai deepseek "Explain monads" > deepseek_response.txt
zig-ai claude "Explain monads" > claude_response.txt
```

#### 6. Batch Processing (built-in)
```bash
# Process 100+ prompts concurrently
zig-ai --batch prompts.csv --concurrency 100

# Benchmark multiple providers on same prompts
cat > benchmark.csv << EOF
provider,prompt
deepseek,"Explain monads"
claude,"Explain monads"
gemini,"Explain monads"
grok,"Explain monads"
EOF

zig-ai --batch benchmark.csv --output benchmark_results.csv
```

#### 7. Data Annotation at Scale
```bash
# Create CSV with data to classify
cat > classify.csv << EOF
provider,prompt,temperature
deepseek,"Classify sentiment: I love this product!",0.3
deepseek,"Classify sentiment: This is terrible.",0.3
deepseek,"Classify sentiment: It's okay I guess.",0.3
EOF

zig-ai --batch classify.csv --concurrency 50
```

## Output Format

### Standard Output

```
🤖 DeepSeek (Ultra-Affordable)
💬 Query: What is Zig?

✨ Response:
[AI response here...]

📊 Tokens: 11 in, 29 out
💰 Estimated cost: $0.000010
```

### Quiet Mode (for scripting)

Use `--no-usage` and `--no-cost` to get just the response:

```bash
zig-ai --no-usage --no-cost deepseek "What is Zig?" 2>/dev/null
```

## Provider Comparison

| Provider | Model | Speed | Quality | Cost per 1M Tokens (Input/Output) | Best For |
|----------|-------|-------|---------|-----------------------------------|----------|
| DeepSeek | deepseek-chat | ⚡⚡⚡ | ⭐⭐⭐⭐ | $0.28 / $0.42 | **Most use cases** (ultra-affordable) |
| Claude | claude-sonnet-4-5-20250929 | ⚡⚡ | ⭐⭐⭐⭐⭐ | $3.00 / $15.00 | Complex reasoning, coding |
| Gemini | gemini-2.5-flash | ⚡⚡⚡ | ⭐⭐⭐⭐ | $0.30 / $2.50 | Fast responses, good balance |
| Grok | grok-4-fast-non-reasoning | ⚡⚡ | ⭐⭐⭐⭐ | $0.20 / $0.50 | Code-focused, X.AI integration |
| Vertex | gemini-2.5-pro | ⚡⚡ | ⭐⭐⭐⭐⭐ | $2.50 / $15.00 | Enterprise, OAuth2 auth |

**Cost Examples** (per 1K tokens):
- DeepSeek: ($0.28/1000) input + ($0.42/1000) output = **$0.0007** (cheapest!)
- Grok: ($0.20/1000) input + ($0.50/1000) output = **$0.0007** (tied for cheapest!)
- Gemini Flash: ($0.30/1000) input + ($2.50/1000) output = **$0.0028**
- Claude: ($3.00/1000) input + ($15.00/1000) output = **$0.018**

**Recommendation**: Start with **DeepSeek** or **Grok** for cost-effectiveness, use **Claude** or **Vertex** for complex tasks.

*Note: All costs are automatically calculated from `model_costs.csv` using actual provider pricing.*

## Troubleshooting

### "API key not set" error

```bash
❌ Error: DEEPSEEK_API_KEY environment variable not set

   Set it with:
   export DEEPSEEK_API_KEY=your_api_key_here
```

**Solution**: Set the required environment variable for your chosen provider.

### gcloud authentication error (Vertex AI)

```bash
❌ Error: gcloud authentication failed
```

**Solution**: Run:
```bash
gcloud auth login
gcloud auth application-default login
```

### Connection timeout

**Solution**: Check your internet connection and API status:
```bash
curl -I https://api.deepseek.com
```

### Rate limiting

```bash
❌ Error: RateLimitExceeded
```

**Solution**: Wait a moment and retry. Consider:
- Reducing request frequency
- Upgrading your API plan
- Switching to a different provider temporarily

## Advanced Usage

### Custom Temperature Strategies

```bash
# Creative writing (high temperature)
zig-ai --temperature 1.5 claude "Write a sci-fi story"

# Factual answers (low temperature)
zig-ai --temperature 0.3 deepseek "Explain quantum computing"

# Balanced (default)
zig-ai --temperature 1.0 gemini "Compare React vs Vue"
```

### Automation Scripts

**Generate documentation:**
```bash
#!/bin/bash
for file in src/*.zig; do
    echo "Processing $file..."
    zig-ai deepseek "Generate documentation for: $(cat $file)" > "docs/$(basename $file .zig).md"
done
```

**Code translation:**
```bash
#!/bin/bash
CODE=$(cat input.py)
zig-ai claude --system "You are a code translator" "Convert this Python to Zig: $CODE" > output.zig
```

## Benchmarking

Use the CLI as a benchmarking engine:

```bash
#!/bin/bash
PROMPT="Explain async/await in Zig"

echo "=== Provider Benchmark ==="
for provider in deepseek claude gemini grok; do
    echo "Testing $provider..."
    time zig-ai "$provider" "$PROMPT" > /dev/null
done
```

## Development

### Building from Source

```bash
git clone <repo>
cd zig-http-concurrent
zig build cli -- --help
```

### Running Tests

```bash
# Smoke tests
zig build cli -- --list
zig build cli -- --help

# Integration test
zig build cli -- deepseek "test query"
```

### Project Structure

```
src/
├── main.zig          # Entry point, argument parsing
├── cli.zig           # CLI logic, interactive mode
├── ai/               # AI provider implementations
│   ├── common.zig    # Shared types and utilities
│   ├── claude.zig    # Claude client
│   ├── deepseek.zig  # DeepSeek client
│   ├── gemini.zig    # Gemini client
│   ├── grok.zig      # Grok client
│   └── vertex.zig    # Vertex AI client
└── http_client.zig   # HTTP client with gzip
```

## Roadmap

### V1.0 (Current)
- ✅ Multi-provider support
- ✅ Interactive mode
- ✅ Token usage tracking
- ✅ Cost estimation
- ✅ System installation

### V1.1 (Next)
- ⏳ CSV batch processing
- ⏳ Parallel requests (100+ at once)
- ⏳ JSON output mode
- ⏳ Stdin piping support
- ⏳ Streaming responses

### V2.0 (Future)
- 📋 Configuration file support
- 📋 Response caching
- 📋 Conversation history save/load
- 📋 Markdown output formatting
- 📋 Plugin system for custom providers

## Contributing

This is part of the HTTP Sentinel project. See main README for contribution guidelines.

## License

MIT License - See LICENSE file

## Credits

Built with:
- Zig 0.16.0-dev
- HTTP Sentinel library
- High-performance concurrent HTTP client

---

**Quick Links:**
- [Main Project README](./README.md)
- [AI Providers Documentation](./AI_CLIENTS.md)
- [HTTP Client Documentation](./HTTP_CLIENT.md)
- [Issue Tracker](https://github.com/...)

**Support:**
- For bugs: Open an issue
- For questions: Check documentation
- For features: Open a feature request

**Remember**: DeepSeek is 95% cheaper than Claude! Start there for most tasks. 💰
