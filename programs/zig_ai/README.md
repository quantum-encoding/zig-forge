# zig-ai

Universal AI command-line tool and library written in Zig. Supports text generation, structured output, web search, deep research, image generation and editing, video generation, music generation, text-to-speech, speech-to-text, batch processing, and autonomous agent mode across multiple providers.

## Features

- **Text Generation**: Claude, DeepSeek, Gemini, Grok, OpenAI, Vertex AI
- **Vision (Multimodal)**: Send images (local files or HTTPS URLs) for analysis with Claude, Gemini, Grok, OpenAI, Vertex
- **Structured Output**: JSON schema-based responses from all text providers, 12 built-in templates
- **Web Search**: Gemini google_search grounding with citations (seconds)
- **Grok Search**: xAI Web Search and X/Twitter Search via Responses API with server-side tool usage tracking
- **Deep Research**: Gemini Interactions API autonomous research agent (5-20 minutes)
- **Agent Mode**: Autonomous task execution with 17 tools and security sandboxing
- **Server-Side Tools (Grok)**: web_search, x_search, code_interpreter — auto-executed by xAI alongside client-side function tools, with citations
- **Remote MCP Tools (Grok)**: Connect Grok to external MCP servers for server-side tool execution
- **Collections Search (Grok)**: Search uploaded document collections (PDFs, CSVs, text) via file_search tool
- **File Attachments (Grok)**: Upload and attach files to chat for automatic document search via attachment_search tool
- **Citations (Grok)**: Automatic source URLs from server-side tools, optional inline citations with positional data
- **Image Generation**: DALL-E 2/3, GPT-Image, Grok-2-Image, Imagen, Gemini + 40 prompt templates
- **Image Editing**: GPT-Image 1.5 and Grok Imagine Image — style transfer, virtual try-on, sketch rendering, background removal
- **Image Batch**: CSV-driven batch generation with retry, resume, and result export
- **Video Generation**: OpenAI Sora 2, Google Veo 3.1, xAI Grok Imagine Video
- **Batch API**: Multi-provider async batch processing (Anthropic, Gemini, OpenAI, xAI) — 50% cost discount, up to 100K requests
- **Music Generation**: Google Lyria 2 (batch and realtime streaming)
- **Gemini Live**: Real-time WebSocket streaming with Gemini (text + audio, tool calling, context compression)
- **Voice Agent**: xAI Grok Realtime voice conversations (text-to-audio, tool calling)
- **Text-to-Speech**: OpenAI TTS, Google Gemini TTS
- **Speech-to-Text**: OpenAI Whisper
- **Text Templates**: 16 parameterized prompt templates across 6 categories
- **FFI Library**: C-compatible shared/static library for embedding in any language

## Installation

```bash
zig build
./zig-out/bin/zig-ai --help
```

## Environment Variables

```bash
# Text/Structured/Agent providers
export ANTHROPIC_API_KEY=...      # Claude
export DEEPSEEK_API_KEY=...       # DeepSeek
export GEMINI_API_KEY=...         # Gemini (also used for Research, Imagen, Veo, TTS)
export GOOGLE_GENAI_API_KEY=...   # Fallback for GEMINI_API_KEY
export XAI_API_KEY=...            # Grok
export OPENAI_API_KEY=...         # OpenAI (GPT-5.2, DALL-E, TTS, STT, Sora)
export VERTEX_PROJECT_ID=...      # Vertex AI

# Music (requires gcloud auth)
gcloud auth login
gcloud config set project YOUR_PROJECT
```

## Usage

### Text Generation

```bash
# One-shot query
zig-ai claude "What is quantum computing?"
zig-ai deepseek "Explain Zig's comptime"
zig-ai gemini "Write a haiku about programming"

# Interactive mode
zig-ai --interactive gemini

# With options
zig-ai claude "Be creative" --temperature 1.5 --max-tokens 500
```

### xAI Server-Side Tools and Citations (Grok)

When using the Grok provider, you can enable xAI server-side tools that are auto-executed by xAI's infrastructure. These work on both text generation (`grok` command) and agent mode. Citations are returned automatically when server-side tools are used.

```bash
# Enable web search (Grok searches the web before answering)
zig-ai grok "What happened in tech news today?" --web-search

# Enable X/Twitter search
zig-ai grok "What are people saying about Zig?" --x-search

# Enable code interpreter (Grok can execute code)
zig-ai grok "Calculate the fibonacci sequence to 100" --code-interpreter

# Combine multiple server-side tools
zig-ai grok "Research and analyze recent AI benchmarks" --web-search --code-interpreter

# Request inline citations (structured positional data)
zig-ai grok "Latest Zig release features" --web-search --include inline_citations

# Request search sources metadata
zig-ai grok "DPDK performance" --web-search --include web_search_call.action.sources

# Multiple include values
zig-ai grok "topic" --web-search --include inline_citations --include web_search_call.action.sources
```

**Server-side tools:**

| Flag | Tool | Description |
|------|------|-------------|
| `--web-search` | `web_search` | Grok searches the web before responding |
| `--x-search` | `x_search` | Grok searches X/Twitter posts |
| `--code-interpreter` | `code_interpreter` | Grok can execute Python code |

**Citations:** When server-side tools are used, Grok automatically returns:
- **Source URLs**: Listed under the response as `Sources (N):` with numbered URLs
- **Inline citations** (with `--include inline_citations`): Structured annotations with `url`, `title`, `start_index`, `end_index` for precise attribution

**Environment:** Requires `XAI_API_KEY`. Server-side tools are Grok-only.

### Remote MCP Tools (Grok)

Connect Grok to external MCP (Model Context Protocol) servers. MCP tools are server-side — xAI connects to the MCP server and executes tools on your behalf.

```bash
# Connect to an MCP server
zig-ai grok "Get my calendar events" --mcp https://mcp.example.com/calendar

# With authentication
zig-ai grok "List tasks" --mcp https://mcp.example.com/tasks --mcp-auth "Bearer sk-..."

# With label (for display/logging)
zig-ai grok "Search docs" --mcp https://mcp.example.com/docs --mcp-label "Documentation"

# Multiple MCP servers
zig-ai grok "Cross-reference data" \
  --mcp https://mcp.example.com/crm --mcp-label "CRM" \
  --mcp https://mcp.example.com/analytics --mcp-label "Analytics"

# Agent mode with MCP tools
zig-ai agent "Analyze project status" --sandbox . \
  --mcp https://mcp.example.com/jira --mcp-auth "Bearer token"
```

**Options:**

| Flag | Description |
|------|-------------|
| `--mcp <url>` | MCP server URL (repeatable for multi-server) |
| `--mcp-label <label>` | Display label for the preceding `--mcp` server |
| `--mcp-auth <token>` | Authorization header for the preceding `--mcp` server |

**Note:** `--mcp-label` and `--mcp-auth` modify the most recently specified `--mcp` entry. Specify them immediately after each `--mcp` URL.

**Environment:** Requires `XAI_API_KEY`. MCP tools are Grok-only (xAI Responses API).

### Collections Search (Grok)

Search through uploaded document collections using xAI's `file_search` server-side tool. Grok autonomously searches your documents and synthesizes information with citations. Useful for RAG workflows, financial analysis, legal document review, and enterprise knowledge bases.

Collections are created and managed via the xAI console (console.x.ai) or xAI SDK. The CLI references collections by their IDs.

```bash
# Search a single collection
zig-ai grok "Analyze Q4 revenue trends" --collection col_abc123

# Search multiple collections
zig-ai grok "Compare filings across years" --collection col_2023 --collection col_2024

# Combined with other server-side tools
zig-ai grok "Research and cross-reference with our docs" \
  --collection col_abc123 --web-search --code-interpreter

# Custom max results
zig-ai grok "Find all mentions of revenue" --collection col_abc123 --collection-max-results 20

# Agent mode with collection search
zig-ai agent "Summarize key findings" --sandbox . --collection col_abc123

# Combined with inline citations
zig-ai grok "Cite sources for revenue data" --collection col_abc123 --include inline_citations
```

**Options:**

| Flag | Description |
|------|-------------|
| `--collection <id>` | Collection ID to search (repeatable for multi-collection) |
| `--collection-max-results <n>` | Max results per search (default: 10) |

**Citations:** Collections citations use the `collections://` URI format:
```
collections://collection_id/files/file_id
```

**Environment:** Requires `XAI_API_KEY`. Collections search is Grok-only (xAI Responses API).

### File Attachments (Grok)

Upload files and attach them to chat conversations. Grok automatically activates the `attachment_search` server-side tool to search and reason over your documents.

**File management:**

```bash
# Upload a file (returns file ID)
zig-ai file upload report.pdf

# List uploaded files
zig-ai file list

# Delete a file
zig-ai file delete file-abc123
```

**Chat with files:**

```bash
# Auto-upload and attach a file (uploads, then queries)
zig-ai "What was the total revenue?" --file report.pdf -p grok

# Attach multiple files
zig-ai "Compare these reports" --file q3.pdf --file q4.pdf -p grok

# Use a pre-uploaded file ID
zig-ai "Summarize findings" --file-id file-abc123 -p grok

# Agent mode with file attachment
zig-ai agent "Analyze this data" --sandbox . --file-id file-abc123

# Combine with other tools
zig-ai "Analyze and visualize" --file data.csv -p grok --code-interpreter
```

**Options:**

| Flag | Description |
|------|-------------|
| `--file <path>` / `-F` | Upload and attach a file (repeatable) |
| `--file-id <id>` | Attach a pre-uploaded file ID (repeatable) |

**Supported formats:** .txt, .md, .py, .js, .csv, .json, .pdf, and more (max 48 MB per file).

**How it works:** When files are attached, xAI automatically enables the `attachment_search` server-side tool. Grok autonomously searches your documents, performs multiple queries if needed, and synthesizes a comprehensive answer. File context persists across conversation turns.

**Environment:** Requires `XAI_API_KEY`. File attachments are Grok-only (xAI Responses API).

### Text Templates

16 pre-engineered prompt templates with parameterization that shape AI responses for specific tasks.

```bash
# Apply a template
zig-ai claude -T joke-code "recursion"
zig-ai gemini -T code-review -P language=zig -P focus=security "my_code.zig"
zig-ai grok -T storyteller -P genre=sci-fi "a world where AI writes all code"

# List all templates
zig-ai --text-templates

# Template with custom params
zig-ai claude -T tutor -P subject=physics -P level=college "explain quantum entanglement"
zig-ai openai -T executive-summary -P audience=board "Q4 revenue increased 23%..."
```

**Available templates (16):**

| Category | Templates |
|----------|-----------|
| Coding | `joke-code`, `code-review`, `rubber-duck` |
| Creative | `storyteller`, `poet`, `worldbuilder` |
| Professional | `email-pro`, `executive-summary`, `tweet` |
| Education | `tutor`, `eli5`, `socratic` |
| Analysis | `data-analyst`, `debate` |
| Entertainment | `dungeon-master`, `roast` |

Each template defines parameters with defaults. Missing parameters use the template-defined defaults automatically. Use `-P key=value` to override.

### Vision (Multimodal Input)

Send images to AI models for analysis. Supports local files (PNG, JPEG, GIF, WebP, BMP) and HTTPS URLs.

```bash
# Local files
zig-ai gemini "What's in this image?" --image photo.png
zig-ai claude "Compare these two diagrams" --image diagram1.png --image diagram2.png

# HTTPS URLs (all providers)
zig-ai grok "Describe this image" --image https://example.com/photo.jpg
zig-ai claude "What's happening here?" -I https://upload.wikimedia.org/image.png

# Mix local files and URLs
zig-ai openai "Compare" --image local.png --image https://example.com/remote.jpg

# With other options
zig-ai openai "Extract text from this screenshot" --image screen.png --max-tokens 1000
```

**Vision-capable providers:**
- Claude (Anthropic) — URLs via `source.type:"url"`, base64 via `source.type:"base64"`
- Gemini (Google) — URLs via `file_data.file_uri`, base64 via `inline_data`
- OpenAI (GPT-5.2) — URLs via `image_url.url`
- Grok (xAI) — URLs via `image_url.url`
- Vertex AI

**Note:** DeepSeek does not support vision input.

### Research (Web Search and Deep Research)

Two research modes powered by Gemini APIs for real-time information retrieval.

**Web Search** uses `generateContent` with google_search grounding. The model autonomously searches the web and returns grounded results with citations. Fast (seconds).

**Deep Research** uses the Gemini Interactions API with an autonomous research agent that searches, reads, and synthesizes a comprehensive report. Takes 5-20 minutes.

```bash
# Web search (default, fast)
zig-ai research "What are the latest developments in quantum computing?"

# Deep research (comprehensive, 5-20 minutes)
zig-ai research "Comprehensive analysis of Zig vs Rust for systems programming" --deep

# Save report to file
zig-ai research "DPDK performance tuning techniques" -o report.md

# JSON output (content + sources + usage)
zig-ai research "Latest AI news" --json

# Model override
zig-ai research "complex topic" -m gemini-3.1-pro-preview

# Thinking level control
zig-ai research "topic" -T high        # More reasoning
zig-ai research "quick fact" -T off     # Minimal thinking

# Deep research with custom agent
zig-ai research "topic" --deep --agent deep-research-2.0

# System prompt
zig-ai research "topic" --system "Focus on performance benchmarks"
```

**Thinking levels** map to the correct API parameter based on model family:

| Level | Gemini 3 Flash | Gemini 3 Pro | Gemini 2.5 |
|-------|---------------|-------------|------------|
| `off` | minimal | low | budget=0 |
| `low` (default) | low | low | budget=1024 |
| `medium` | medium | low* | budget=8192 |
| `high` | high | high | budget=dynamic |

*Gemini 3 Pro only supports "low" and "high"; unsupported levels fall back to "low".

**Options:**

| Flag | Description |
|------|-------------|
| `--deep`, `-D` | Use deep research mode (default: web search) |
| `--model`, `-m` | Model override (default: gemini-2.5-flash) |
| `--agent`, `-A` | Deep research agent name override |
| `--output`, `-o` | Save report to file |
| `--thinking`, `-T` | Thinking level: off, low, medium, high |
| `--system`, `-s` | System instruction |
| `--max-tokens` | Maximum output tokens (default: 65536) |
| `--no-sources` | Hide source URLs |
| `--json` | Output as JSON (content + sources + usage) |

**Environment:** Requires `GEMINI_API_KEY` (or `GOOGLE_GENAI_API_KEY` as fallback).

### Grok Search (Web Search + X Search)

Search the web and X/Twitter via xAI's Responses API with server-side tool execution. The model autonomously uses web_search or x_search tools, returning results with source citations and server-side tool usage billing.

```bash
# Web search (default)
zig-ai search "What are the latest developments in Zig?"

# X/Twitter search
zig-ai search -X "AI news today"
zig-ai search --x "Grok updates" --allow-handle xai --from 2026-01-01

# With filters
zig-ai search "DPDK performance" --allow-domain dpdk.org --allow-domain ziglang.org
zig-ai search -X "Zig programming" --exclude-handle bots

# Save to file / JSON output
zig-ai search "topic" -o report.md
zig-ai search "topic" --json

# Model override and system prompt
zig-ai search "topic" -m grok-4-1-fast-non-reasoning -s "Be concise"

# Limit server-side agentic loop turns
zig-ai search "complex research topic" --max-turns 5

# Media understanding
zig-ai search "topic" --image-understanding
zig-ai search -X "viral video" --video-understanding
```

**Options:**

| Flag | Description |
|------|-------------|
| `--x, -X` | X/Twitter search mode (default: web search) |
| `--model, -m` | Model override (default: grok-4-1-fast-reasoning) |
| `--system, -s` | System instruction |
| `--output, -o` | Save result to file |
| `--max-tokens` | Maximum output tokens (default: 65536) |
| `--max-turns` | Limit server-side agentic loop turns |
| `--no-sources` | Hide source URLs |
| `--json` | JSON output (content + sources + usage + tool_usage) |
| `--allow-domain` | Constrain to domain (repeatable, web search) |
| `--exclude-domain` | Exclude domain (repeatable, web search) |
| `--allow-handle` | Constrain to X handle (repeatable, X search) |
| `--exclude-handle` | Exclude X handle (repeatable, X search) |
| `--from` | Start date YYYY-MM-DD (X search) |
| `--to` | End date YYYY-MM-DD (X search) |
| `--image-understanding` | Enable image analysis in results |
| `--video-understanding` | Enable video analysis (X search only) |

**Output includes:**
- Response content with inline citations
- Source URLs with titles
- Token usage (input, output, reasoning, cached)
- Server-side tool usage breakdown (web search calls, X search calls, code execution, image/video analysis, collections search, MCP)
- Estimated cost

**Environment:** Requires `XAI_API_KEY`.

### Structured Output

Generate JSON responses that conform to a predefined schema. Schemas can be loaded from config files or use the 12 built-in templates.

```bash
# Generate structured output (default: Gemini)
zig-ai structured "Meeting: John and Jane, Monday 2pm, discuss Q1 goals" --schema meeting

# Use different providers
zig-ai structured "Extract event info" -s calendar -p openai
zig-ai structured "Parse invoice" -s invoice -p claude
zig-ai structured "Analyze sentiment" -s sentiment -p grok
zig-ai structured "Summarize article" -s summary -p deepseek

# Save to file
zig-ai structured "Meeting notes..." -s meeting -o output.json

# With system prompt
zig-ai structured "Raw text..." -s meeting --system "Be thorough"

# Show raw API response (debugging)
zig-ai structured "..." -s meeting --raw

# Use built-in templates (include schema + system prompt)
zig-ai structured -T sentiment "This product is amazing but overpriced"
zig-ai structured -T invoice -P currency=EUR "3 licenses @ $50 each"
zig-ai structured -T code-review -P language=zig -P focus=security "fn main() { ... }"

# List built-in templates
zig-ai struct-templates
```

**Built-in structured templates (12):**

| Category | Templates |
|----------|-----------|
| Business | `product-listing`, `meeting-notes`, `invoice`, `resume-parse` |
| Analysis | `sentiment`, `entity-extraction`, `classification` |
| Coding | `code-review`, `api-spec` |
| Creative | `recipe` |
| Education | `lesson-plan`, `quiz` |

Each template bundles a JSON schema and parameterized system prompt. Use `-P key=value` to customize (e.g., `-P granularity=detailed`, `-P difficulty=hard`).

**Schema management:**

```bash
# List available schemas
zig-ai schemas list

# Show schema details
zig-ai schemas show meeting

# Show schema directories
zig-ai schemas path
```

**Schema directories (in priority order):**
1. `~/.config/zig_ai/schemas/` - User schemas (higher priority)
2. `./config/schemas/` - Project schemas

See [Writing Schemas](#writing-schemas-for-structured-output) for schema format details.

### Agent Mode

Agent mode enables autonomous task execution with security sandboxing and tool calling across all 4 providers (Claude, Gemini, Grok, OpenAI). The AI can read/write files, search code, execute commands, and manage processes within a restricted environment. Session cost is displayed after each task.

```bash
# Run a task with sandbox
zig-ai agent "Refactor main.zig for better error handling" --sandbox ./my-project

# Use a named agent config
zig-ai agent "Add unit tests" --config code-assistant

# Interactive mode
zig-ai agent --interactive --sandbox .

# With xAI server-side tools (Grok provider)
zig-ai agent "Research and implement a cache" --config grok-agent --web-search
zig-ai agent "Find API docs and write a client" --sandbox . --web-search --x-search

# With MCP tools (Grok provider)
zig-ai agent "Sync project tasks" --sandbox . --mcp https://mcp.example.com/jira

# With code interpreter
zig-ai agent "Analyze this CSV data" --sandbox . --code-interpreter

# List available agent configs
zig-ai agent list

# Show agent config details
zig-ai agent show code-assistant

# Create a new agent config
zig-ai agent init my-agent --sandbox ./project
```

**Multi-turn state preservation:** When using Grok with server-side tools, the agent automatically chains requests via `previous_response_id`. This preserves server-side tool state (web search results, code interpreter sessions, MCP connections) across turns without resending the full conversation. Storage is auto-enabled when server-side or MCP tools are present.

**Available tools (17):**

| Tool | Tier | Description |
|------|------|-------------|
| `read_file` | auto | Read file contents (with offset/limit) |
| `write_file` | confirm | Create or modify files in writable paths |
| `list_files` | auto | List directory contents (recursive, max depth) |
| `search_files` | auto | Grep-like content search with file pattern filter |
| `grep` | auto | Search text patterns with context lines, case options |
| `cat` | auto | Concatenate/display files with line numbering |
| `wc` | auto | Count lines, words, bytes, characters |
| `find` | auto | Find files by name pattern, type, size |
| `execute_command` | varies | Run shell commands (allowlisted, per-command tiers) |
| `confirm_action` | auto | Request human confirmation for risky operations |
| `trash_file` | confirm | Move file to trash (recoverable delete) |
| `rm` | confirm | Remove files/directories with safety caps |
| `cp` | confirm | Copy files with overwrite protection |
| `mv` | confirm | Move/rename files and directories |
| `mkdir` | confirm | Create directories (with parents flag) |
| `touch` | confirm | Create empty files or update timestamps |
| `kill_process` | auto | Send signals to agent-spawned processes only |

**Permission tiers:**

Every tool call is resolved to a permission tier before execution:

| Tier | Behavior |
|------|----------|
| `auto` | Runs immediately, no confirmation needed |
| `confirm` | User prompted with `[y/N]` before execution |
| `askpass` | User must type `"yes"` (for sudo, chown, chgrp) |
| `blocked` | Hard rejection, structured error returned to AI |

External commands (via `execute_command`) have per-command tier resolution with subcommand rules. For example, `git status` can be auto while `git push` requires confirmation.

The `kill_process` tool has a built-in conditional safety check: it only allows killing PIDs that the agent itself spawned via `execute_command`. Untracked PIDs are rejected.

**Security features:**

- **Path sandboxing**: All file operations restricted to sandbox root
- **Permission tiers**: 4-tier system (auto/confirm/askpass/blocked) for all tools
- **Deny-by-default commands**: Only explicitly allowed commands can run
- **Banned patterns**: Secondary safety net blocks dangerous command patterns
- **Process table**: Tracks all spawned processes for safe kill_process
- **Process group killing**: Timeout kills entire process tree, not just shell
- **Command normalization**: Prevents bypass attempts (`rm -rf` = `rm -r -f`)
- **Runaway detection**: Stops agent if same tool called >3 times consecutively

**Output convention:**

Agents write generated artifacts to `{sandbox_root}/output/`. This directory is created automatically when the agent starts and is included in the default writable paths.

**Agent configuration:**

Agent configs are stored in `~/.config/zig_ai/agents/` as JSON files:

```json
{
  "agent_name": "code-assistant",
  "description": "AI coding assistant with sandbox access",
  "provider": {
    "name": "claude",
    "model": "claude-sonnet-4-5-20250929",
    "max_tokens": 32768,
    "max_turns": 50
  },
  "sandbox": {
    "root": ".",
    "writable_paths": [".", "./output"],
    "allow_network": false
  },
  "tools": {
    "enabled": ["read_file", "write_file", "list_files", "search_files",
                "execute_command", "confirm_action", "trash_file", "grep",
                "cat", "wc", "find", "rm", "cp", "mv", "mkdir", "touch",
                "kill_process"],
    "execute_command": {
      "allowed_commands": ["ls", "cat", "grep", "find", "wc", "head", "tail", "diff"],
      "banned_patterns": ["rm -rf /", "sudo *", "chmod -R 777"],
      "timeout_ms": 30000,
      "max_output_bytes": 65536,
      "kill_process_group": true
    },
    "permissions": {
      "auto": ["grep", "cat", "wc", "find", "read_file", "list_files", "search_files"],
      "confirm": ["write_file", "trash_file", "rm", "cp", "mv", "mkdir", "touch"]
    },
    "external_commands": {
      "auto": ["npm", "node", "zig", "cargo", "python", "git", "make"],
      "confirm": ["curl", "wget", "pip", "brew"],
      "blocked": ["docker", "systemctl", "reboot", "shutdown"]
    }
  },
  "limits": {
    "max_file_size_bytes": 1048576,
    "max_files_per_operation": 100
  },
  "system_prompt": "You are a helpful coding assistant. Write generated files to the output/ directory."
}
```

**Configuration fields:**

| Field | Description |
|-------|-------------|
| `provider.name` | AI provider: `claude`, `openai`, `gemini`, `grok` |
| `provider.max_tokens` | Max tokens per response (default: 32768) |
| `provider.max_turns` | Max agentic turns before stopping (default: 50) |
| `sandbox.root` | Root directory for all file operations |
| `sandbox.writable_paths` | Paths where writes are allowed |
| `tools.enabled` | List of enabled tools (17 available) |
| `tools.permissions.auto` | Native tools that run without confirmation |
| `tools.permissions.confirm` | Native tools that require `[y/N]` |
| `tools.external_commands.auto` | Shell commands that run without confirmation |
| `tools.external_commands.blocked` | Shell commands that are always rejected |
| `tools.execute_command.allowed_commands` | Allowlisted executables |
| `tools.execute_command.banned_patterns` | Patterns that are always blocked |
| `limits.max_file_size_bytes` | Max file size for read/write |

### Text-to-Speech (TTS)

```bash
# OpenAI TTS
zig-ai tts-openai "Hello, this is a test" -o speech.mp3
zig-ai tts-openai "Welcome!" --voice nova --model gpt-4o-mini-tts

# Google Gemini TTS
zig-ai tts-google "Hello from Gemini" -o speech.wav
zig-ai tts-google "Welcome!" --voice puck

# Multi-speaker (Google)
zig-ai tts-google "Alice: Hi! Bob: Hello!" --voice kore --speaker2 "Bob" --voice2 charon

# List voices
zig-ai tts-openai --list-voices
zig-ai tts-google --list-voices
```

### Speech-to-Text (STT)

```bash
# Transcribe audio
zig-ai stt-openai audio.mp3
zig-ai stt-openai recording.wav -o transcript.txt

# With options
zig-ai stt-openai audio.mp3 --language en --format json

# Translate to English
zig-ai stt-openai foreign_audio.mp3 --translate
```

### Image Generation

```bash
# DALL-E 3
zig-ai dalle3 "a cosmic duck floating in space"

# Grok-2-Image
zig-ai grok-image "quantum computer visualization" -n 2

# Imagen (Google)
zig-ai imagen "photorealistic sunset over mountains"

# Gemini Flash
zig-ai gemini-image "abstract art in neon colors"

# With prompt template
zig-ai dalle3 -t cyberpunk "a neon city street"
zig-ai imagen -t product "a luxury watch on marble"
zig-ai gemini-image -t anime "a warrior princess"

# Options
zig-ai dalle3 "prompt" -n 4 -s 1024x1024 -q hd
```

**Image prompt templates (40+):**

| Category | Templates |
|----------|-----------|
| Photography | `photo`, `portrait`, `landscape`, `macro`, `product`, `food`, `architecture`, `fashion` |
| Digital Art | `anime`, `comic`, `watercolor`, `digital-art` |
| Cinematic | `cinematic`, `noir` |
| Themed | `cyberpunk`, `steampunk`, `fantasy`, `surreal`, `retro80s`, `solarpunk`, `sci-fi`, `cosmic-duck` |
| Business | `corporate`, `marketing`, `social` |
| Construction | `painting`, `kitchen`, `bathroom`, `flooring`, `roofing`, `terrace` |
| Artistic | `abstract`, `minimalist`, `infographic`, `ui-mockup`, `comic-strip`, `collectible` |

### Image Editing

Edit existing images using GPT-Image 1.5 (OpenAI) or Grok Imagine Image (xAI). Supports templates for common workflows.

```bash
# Basic edit (default: OpenAI GPT-Image 1.5)
zig-ai edit photo.png "make the sky dramatic and stormy"

# Use Grok provider
zig-ai edit photo.png "add snow to the scene" --provider grok

# With templates (OpenAI)
zig-ai edit photo.png "make it winter" -t weather-change --fidelity high
zig-ai edit person.png shirt.png "dress in this outfit" -t try-on
zig-ai edit product.png "clean product shot" -t bg-remove --transparent
zig-ai edit sketch.png "render this" -t sketch-render -n 4
zig-ai edit room.png "remove the plant" -t object-remove
```

**Options:**

| Flag | Description |
|------|-------------|
| `-p, --provider` | `openai` (default) or `grok` |
| `-n, --count` | Number of output images (default: 1) |
| `-s, --size` | Output size (1024x1024, 1024x1536, 1536x1024) |
| `-q, --quality` | Quality (auto, low, medium, high) |
| `--fidelity` | Input fidelity: low or high (OpenAI only) |
| `--transparent` | Transparent background (OpenAI only) |
| `-t, --template` | Apply edit template |
| `-o, --output` | Custom output path |

**Edit templates:** `style-transfer`, `try-on`, `sketch-render`, `bg-remove`, `weather-change`, `object-remove`

**Provider notes:**
- **OpenAI GPT-Image 1.5**: Supports 1-16 input images, multipart upload, all templates and quality/fidelity options. Requires `OPENAI_API_KEY`.
- **Grok Imagine Image**: Single input image, JSON API with base64 data URI encoding. Requires `XAI_API_KEY`.

### Image Batch Processing

Process CSV files of image generation prompts with retry logic, rate limiting, and result tracking.

```bash
# Basic batch
zig-ai image-batch prompts.csv -p dalle3

# With options
zig-ai image-batch prompts.csv -p gpt-image -s 1024x1024 -q hd --fast --transparent

# Apply template to all rows
zig-ai image-batch prompts.csv --template cyberpunk -p gemini-image

# Rate limiting and retry
zig-ai image-batch prompts.csv -p dalle3 --delay 2000 --retry 3

# Output control
zig-ai image-batch prompts.csv -p imagen -o ./output/ --results results.csv

# Resume from row 50
zig-ai image-batch prompts.csv -p dalle3 --start-from 50

# Dry run (validate CSV without generating)
zig-ai image-batch prompts.csv --dry-run
```

**CSV format:** Columns for `prompt`, `provider`, `size`, `quality`, `style`, `aspect_ratio`, `count` per row. Only `prompt` is required; other columns override CLI defaults.

**Options:**

| Flag | Description |
|------|-------------|
| `-p, --provider` | Image provider (dalle3, gpt-image, grok-image, imagen, gemini-image) |
| `-s, --size` | Default image size (e.g., 1024x1024) |
| `-q, --quality` | Quality (auto/standard/hd/high/medium/low) |
| `-t, --template` | Apply media template to all rows |
| `-n, --count` | Images per prompt (default: 1) |
| `--fast` | Shortcut for --quality=low |
| `--transparent` | Shortcut for --background=transparent |
| `-d, --delay` | Delay between requests in ms (default: 2000) |
| `-r, --retry` | Retry failed requests (default: 2) |
| `-o, --output-dir` | Output directory for images |
| `--results` | Write results to CSV |
| `--dry-run` | Validate CSV without generating |
| `--start-from` | Resume from row N |

### Video Generation

Generate videos using OpenAI Sora 2, Google Veo 3.1, or xAI Grok Imagine Video. Video providers use async APIs — the CLI submits a render job and polls until completion.

```bash
# OpenAI Sora 2
zig-ai sora "a cat playing piano" -d 10

# Google Veo 3.1
zig-ai veo "drone flying over mountains" -d 8 -r 1080p

# xAI Grok Imagine Video
zig-ai grok-video "a sunset over the ocean with gentle waves" -d 6
```

**Options:**

| Flag | Description |
|------|-------------|
| `-d, --duration` | Duration in seconds (default varies by provider) |
| `-r, --resolution` | Resolution: 720p, 1080p |
| `-a, --aspect-ratio` | Aspect ratio: 16:9, 9:16 |
| `-m, --model` | Model variant (e.g., sora-2, sora-2-pro, grok-imagine-video) |
| `-o, --output` | Custom output path |

**Provider details:**

| Provider | Command | Model | Duration | Requires |
|----------|---------|-------|----------|----------|
| OpenAI Sora 2 | `sora` | sora-2 | 4-20s | OPENAI_API_KEY |
| Google Veo 3.1 | `veo` | veo-3.1 | 4-8s | GEMINI_API_KEY |
| xAI Grok Imagine Video | `grok-video` | grok-imagine-video | 4-6s | XAI_API_KEY |

### Music Generation

```bash
# Google Lyria 2
zig-ai lyria "ambient space soundscape with gentle pads"

# Lyria realtime (instant clips)
zig-ai lyria-realtime "short jazzy piano riff"

# Options
-d, --duration    Duration in seconds (default: 30)
--bpm             Target beats per minute
--seed            Seed for reproducible generation
--negative        Negative prompt (things to avoid)
```

### Voice Agent

Real-time voice conversations with xAI Grok via the Realtime WebSocket API. Send text, receive audio + text responses with tool calling support. Five distinct voices available.

```bash
# One-shot
zig-ai voice "Hello, how are you?"
zig-ai voice "Count to five" --no-audio
zig-ai voice "Tell me a joke" -v rex -o joke.wav

# Interactive REPL
zig-ai voice --interactive -v eve
zig-ai voice -i -s "Be concise and witty"

# Options
zig-ai voice "Explain quantum computing" -v leo -f pcm16 -r 24000
```

**Options:**

| Flag | Description |
|------|-------------|
| `-v, --voice` | Voice: `ara` (default), `rex`, `sal`, `eve`, `leo` |
| `-s, --instructions` | System prompt / persona instructions |
| `-f, --format` | Audio format: `pcm16` (default), `pcmu`, `pcma` |
| `-r, --sample-rate` | Sample rate: 8000-48000 (default: 24000) |
| `-o, --output` | Output WAV path (default: voice_response.wav) |
| `--no-audio` | Transcript only, skip audio output |
| `-i, --interactive` | Interactive REPL conversation mode |

**Voices:**

| Voice | Style |
|-------|-------|
| `ara` | Warm and conversational (default) |
| `rex` | Energetic and bold |
| `sal` | Calm and measured |
| `eve` | Friendly and expressive |
| `leo` | Deep and authoritative |

**Interactive mode** maintains a persistent WebSocket session for multi-turn conversations. Audio is saved as `voice_turn_N.wav` per turn. Exit with Ctrl+D.

**Environment:** Requires `XAI_API_KEY`.

### Gemini Live (Real-time WebSocket Streaming)

Real-time streaming conversations with Google Gemini via WebSocket. Supports text and audio modalities, voice selection, tool calling, context compression for unlimited sessions, and thinking mode.

```bash
# One-shot text query
zig-ai live "Hello, how are you?"
zig-ai live "Explain quantum computing" --no-audio

# Audio response with voice
zig-ai live "Tell me a story" --modality audio -v puck -o story.wav

# Interactive REPL (multi-turn conversation)
zig-ai live --interactive
zig-ai live -i --context-compression

# With Google Search grounding
zig-ai live "What's the latest on Zig?" --google-search

# With thinking mode
zig-ai live "Think step by step about this problem" --thinking 1024

# Transcription of audio output
zig-ai live "Sing a song" --modality audio --transcription

# Custom model
zig-ai live "Hello" --model gemini-2.5-flash-native-audio-preview-12-2025
```

**Options:**

| Flag | Description |
|------|-------------|
| `--modality <MODE>` | Response modality: `text` (default), `audio` |
| `-v, --voice <VOICE>` | Voice: `kore` (default), `charon`, `fenrir`, `aoede`, `puck`, `leda`, `orus`, `zephyr` |
| `-s, --system <TEXT>` | System instruction |
| `--model <MODEL>` | Model name (default: gemini-live-2.5-flash-preview) |
| `-t, --temperature <F>` | Temperature 0.0-2.0 (default: 1.0) |
| `-o, --output <PATH>` | Output WAV path (default: live_response.wav) |
| `--no-audio` | Text only, skip audio output |
| `-i, --interactive` | Interactive REPL conversation mode |
| `--context-compression` | Sliding window for unlimited session duration |
| `--transcription` | Enable output audio transcription |
| `--google-search` | Enable Google Search grounding |
| `--thinking <N>` | Enable thinking with token budget |

**Models:**

| Model | Description |
|-------|-------------|
| `gemini-live-2.5-flash-preview` | Text + VAD (default) |
| `gemini-2.5-flash-native-audio-preview-12-2025` | Native audio output |

**Voices:**

| Voice | Style |
|-------|-------|
| `kore` | Firm and authoritative (default) |
| `charon` | Warm and calm |
| `fenrir` | Excitable and energetic |
| `aoede` | Bright and upbeat |
| `puck` | Lively and playful |
| `leda` | Youthful and clear |
| `orus` | Firm and informative |
| `zephyr` | Breezy and conversational |

**Interactive mode** maintains a persistent WebSocket session for multi-turn conversations. Audio is saved as `live_turn_N.wav` per turn. Exit with Ctrl+D.

**Environment:** Requires `GEMINI_API_KEY` (or `GOOGLE_GENAI_API_KEY` as fallback).

### Batch API

Multi-provider async batch processing for text and image generation. Submit up to 100,000 requests at 50% cost discount via provider-native batch APIs.

**Supported providers:** Anthropic, Gemini, OpenAI, xAI

```bash
# Submit a text batch (all-in-one: create + poll + download)
zig-ai batch-api submit prompts.csv --provider anthropic --model claude-opus-4-6
zig-ai batch-api submit prompts.csv -p gemini -o results.jsonl
zig-ai batch-api submit prompts.csv -p openai --model gpt-4.1
zig-ai batch-api submit prompts.csv -p xai

# Image batch (OpenAI only)
zig-ai batch-api submit images.csv -p openai --model gpt-image-1

# Step-by-step workflow
zig-ai batch-api create prompts.csv -p anthropic     # Create batch
zig-ai batch-api status msgbatch_abc123               # Check progress
zig-ai batch-api results msgbatch_abc123 -o out.jsonl # Download results
zig-ai batch-api cancel msgbatch_abc123               # Cancel if needed

# List recent batches
zig-ai batch-api list -p openai

# Auto-detect provider from batch ID format
zig-ai batch-api status batch_xyz123     # → OpenAI
zig-ai batch-api status batches/xyz      # → Gemini
zig-ai batch-api status msgbatch_xyz     # → Anthropic
```

**CSV format (text):**

```csv
prompt,model,max_tokens,temperature,system_prompt,custom_id
"What is AI?",claude-opus-4-6,1000,0.7,"You are helpful",id-1
"Explain Zig",,2000,,,id-2
```

Only the `prompt` column is required. Other columns override CLI defaults.

**CSV format (images, OpenAI only):**

```csv
prompt,size,quality,n,custom_id
"A sunset over mountains",1024x1024,hd,1,img-1
"Geometric patterns",1024x1536,standard,2,img-2
```

**Commands:**

| Command | Description |
|---------|-------------|
| `create <csv>` | Create a batch from CSV file |
| `submit <csv>` | Create + poll + download results (all-in-one) |
| `status <id>` | Check batch processing status |
| `results <id>` | Download batch results (JSONL or CSV) |
| `cancel <id>` | Cancel an in-progress batch |
| `list` | List recent batches |

**Options:**

| Flag | Description |
|------|-------------|
| `-p, --provider` | Provider: `anthropic`, `gemini`, `openai`, `xai` |
| `-m, --model` | Model override (each provider has a sensible default) |
| `-o, --output` | Output file path for results |
| `--format` | Output format: `jsonl` (default) or `csv` |

**Batch pricing (50% discount applied automatically):**

| Provider | Models | Batch Price (per MTok in/out) |
|----------|--------|-------------------------------|
| Anthropic | Haiku 4.5, Sonnet 4.5, Opus 4.6 | $0.50/$2.50, $1.50/$7.50, $2.50/$12.50 |
| Gemini | Flash 2.5/3, Pro 2.5/3 | $0.15/$1.25, $1.25/$7.50 |
| OpenAI | GPT-4.1 Mini, GPT-4.1 | $0.20/$0.40, $1.00/$2.00 |
| xAI | Grok 4.1 Fast | $2.50/$5.00 |

## Writing Schemas for Structured Output

Schemas are JSON files with `name`, `description`, and `schema` fields. The schema follows JSON Schema format.

### Basic Schema Format

```json
{
  "name": "meeting",
  "description": "Extract meeting details from text",
  "schema": {
    "type": "object",
    "properties": {
      "title": {
        "type": "string",
        "description": "Meeting title"
      },
      "date": {
        "type": "string",
        "description": "Meeting date"
      },
      "attendees": {
        "type": "array",
        "items": { "type": "string" },
        "description": "List of attendees"
      }
    },
    "required": ["title", "date", "attendees"],
    "additionalProperties": false
  }
}
```

### Provider-Specific Requirements

Different providers have different requirements for schemas:

#### OpenAI (Strict Mode)
- **All properties must be required** - OpenAI's strict mode requires every property in the schema to be listed in the `required` array
- Uses `/v1/responses` API with `text.format.type: "json_schema"`

```json
{
  "name": "example",
  "schema": {
    "type": "object",
    "properties": {
      "field1": { "type": "string" },
      "field2": { "type": "number" }
    },
    "required": ["field1", "field2"],
    "additionalProperties": false
  }
}
```

#### Claude (Anthropic)
- Full JSON Schema support
- Optional fields allowed

#### Gemini (Google)
- Full JSON Schema support via `responseJsonSchema`
- Optional fields allowed
- Nested objects supported

#### Grok (xAI)
- OpenAI-compatible format with `response_format.json_schema`
- Similar requirements to OpenAI

#### DeepSeek
- **No strict schema enforcement** - Uses JSON mode with schema included in prompt
- Schema is sent as instructions, not enforced
- Works best with clear, simple schemas

### Schema Examples

**Invoice extraction:**
```json
{
  "name": "invoice",
  "description": "Extract invoice information",
  "schema": {
    "type": "object",
    "properties": {
      "invoice_number": { "type": "string" },
      "date": { "type": "string" },
      "vendor": { "type": "string" },
      "total": { "type": "number" },
      "currency": { "type": "string" },
      "line_items": {
        "type": "array",
        "items": {
          "type": "object",
          "properties": {
            "description": { "type": "string" },
            "quantity": { "type": "number" },
            "unit_price": { "type": "number" }
          },
          "required": ["description", "quantity", "unit_price"],
          "additionalProperties": false
        }
      }
    },
    "required": ["invoice_number", "date", "vendor", "total", "currency", "line_items"],
    "additionalProperties": false
  }
}
```

**Sentiment analysis:**
```json
{
  "name": "sentiment",
  "description": "Analyze text sentiment",
  "schema": {
    "type": "object",
    "properties": {
      "sentiment": {
        "type": "string",
        "enum": ["positive", "negative", "neutral"]
      },
      "confidence": { "type": "number" },
      "keywords": {
        "type": "array",
        "items": { "type": "string" }
      }
    },
    "required": ["sentiment", "confidence", "keywords"],
    "additionalProperties": false
  }
}
```

### Best Practices

1. **Use `additionalProperties: false`** - Prevents models from adding extra fields
2. **Provide descriptions** - Helps models understand field purposes
3. **Keep schemas simple** - Deeply nested schemas may cause issues with some providers
4. **Test across providers** - Verify your schema works with all providers you need
5. **Use enums for constrained values** - When a field has specific allowed values

## Library Integration

### Shared Library (C/Rust/Tauri)

```bash
zig build -Dlib          # Build shared library (libzig_ai.dylib / .so)
zig build -Dlib -Dstatic # Build static library
```

The C header is at `include/zig_ai.h`. It exposes text AI, image/video/music generation, TTS/STT, file management, batch processing, research, structured output, voice agent, and agent mode.

### FFI Functions

**Text AI:**

| Function | Description |
|----------|-------------|
| `zig_ai_text_session_create` | Create a conversation session with config |
| `zig_ai_text_session_destroy` | Destroy session and free resources |
| `zig_ai_text_send` | Send message in session, get response |
| `zig_ai_text_send_ex` | Extended send with images, files, collections, server tools |
| `zig_ai_text_clear_history` | Clear conversation history |
| `zig_ai_text_query` | One-shot text query (no session) |
| `zig_ai_text_calculate_cost` | Calculate cost for token usage |
| `zig_ai_text_default_model` | Get default model for a provider |
| `zig_ai_text_provider_available` | Check if a provider's API key is set |
| `zig_ai_text_response_free` | Free response strings |
| `zig_ai_string_free` | Free a CString allocated by the library |

**Structured Output:**

| Function | Description |
|----------|-------------|
| `zig_ai_structured_generate` | Generate structured JSON from prompt + schema |
| `zig_ai_structured_list_templates` | List all built-in templates as JSON |
| `zig_ai_structured_get_template` | Get single template with schema |
| `zig_ai_structured_response_free` | Free structured response |

**Research:**

| Function | Description |
|----------|-------------|
| `zig_ai_research_web_search` | Web search with google_search grounding |
| `zig_ai_research_deep_start` | Start deep research (returns interaction ID) |
| `zig_ai_research_deep_poll` | Poll deep research once (non-blocking) |
| `zig_ai_research_response_free` | Free research response |

Deep research FFI is split into `start`/`poll` so the caller controls the polling loop (important for UI apps that need to update progress).

**Agent:**

| Function | Description |
|----------|-------------|
| `zig_ai_agent_create` | Create agent from flat config struct |
| `zig_ai_agent_destroy` | Destroy agent and free resources |
| `zig_ai_agent_set_callback` | Set event callback with userdata pointer |
| `zig_ai_agent_run` | Run task (blocking), writes result to out param |
| `zig_ai_agent_result_free` | Free result strings |

**Image/Video/Music:**

| Function | Description |
|----------|-------------|
| `zig_ai_image_generate` | Generate image from prompt |
| `zig_ai_image_edit` | Edit image (style transfer, try-on, etc.) |
| `zig_ai_video_generate` | Generate video from prompt |
| `zig_ai_music_generate` | Generate music from prompt |
| `zig_ai_lyria_session_create` | Create realtime Lyria streaming session |
| `zig_ai_lyria_connect` | Connect to Lyria RealTime API |
| `zig_ai_lyria_set_prompts` | Set weighted DJ-style prompts |
| `zig_ai_lyria_play/pause/stop` | Playback control |
| `zig_ai_lyria_get_audio_chunk` | Read audio data from stream |

**Voice Agent:**

| Function | Description |
|----------|-------------|
| `zig_ai_voice_session_create` | Create voice agent session |
| `zig_ai_voice_session_destroy` | Destroy voice agent session |
| `zig_ai_voice_connect` | Connect to xAI Realtime API |
| `zig_ai_voice_send_text` | Send text and get response |
| `zig_ai_voice_send_tool_result` | Send tool result, get next response |
| `zig_ai_voice_get_state` | Get current session state |
| `zig_ai_voice_is_connected` | Check if session is connected |
| `zig_ai_voice_close` | Close the connection |
| `zig_ai_voice_response_free` | Free a voice response |

**Gemini Live (Real-time WebSocket):**

| Function | Description |
|----------|-------------|
| `zig_ai_live_session_create` | Create Gemini Live session |
| `zig_ai_live_session_destroy` | Destroy session |
| `zig_ai_live_connect` | Connect with config (model, modality, voice) |
| `zig_ai_live_send_text` | Send text and get response |
| `zig_ai_live_send_tool_response` | Send tool result, get next response |
| `zig_ai_live_get_state` | Get session state |
| `zig_ai_live_is_connected` | Check if connected |
| `zig_ai_live_close` | Close connection |
| `zig_ai_live_response_free` | Free response (text, audio, tool calls) |
| `zig_ai_live_pcm_to_wav` | Convert raw PCM to WAV (24kHz 16-bit mono) |

**Batch Processing:**

| Function | Description |
|----------|-------------|
| `zig_ai_batch_create` | Create batch executor from request array |
| `zig_ai_batch_create_from_csv` | Create batch executor from CSV file |
| `zig_ai_batch_execute` | Execute all requests |
| `zig_ai_batch_get_results` | Get results after execution |
| `zig_ai_batch_write_results` | Write results to CSV |
| `zig_ai_batch_destroy` | Destroy executor |

**Text-to-Speech (TTS):**

| Function | Description |
|----------|-------------|
| `zig_ai_tts_openai` | Generate speech with OpenAI TTS (gpt-4o-mini-tts) |
| `zig_ai_tts_google` | Generate speech with Google Cloud TTS |
| `zig_ai_tts_response_free` | Free TTS response (audio data + strings) |

**Speech-to-Text (STT):**

| Function | Description |
|----------|-------------|
| `zig_ai_stt_openai` | Transcribe/translate audio with OpenAI Whisper |
| `zig_ai_stt_response_free` | Free STT response strings |

**File Management (xAI):**

| Function | Description |
|----------|-------------|
| `zig_ai_file_upload` | Upload a file for Grok file_search (48 MB limit) |
| `zig_ai_file_list` | List all uploaded files (returns JSON) |
| `zig_ai_file_delete` | Delete an uploaded file by ID |
| `zig_ai_file_response_free` | Free file response strings |

**Memory model:** C owns input strings (Zig copies on entry). Zig owns output strings (C calls `_free()`). Events are valid only during callback -- copy if needed.

### Agent FFI Example

```c
#include "zig_ai.h"

void on_event(const ZigAiAgentEvent* event, void* userdata) {
    if (event->type == ZIG_AI_EVENT_TOOL_COMPLETE) {
        printf("[%s] %s (%lums)\n",
            event->tool_success ? "ok" : "err",
            event->tool_name.ptr,
            event->duration_ms);
    }
}

int main() {
    ZigAiAgentConfig config = {
        .provider = { .ptr = "claude", .len = 6 },
        .sandbox_root = { .ptr = "/tmp/sandbox", .len = 12 },
        .max_tokens = 0,  // default
        .max_turns = 0,   // default
        .temperature = -1, // default
    };

    ZigAiAgentSession* agent = zig_ai_agent_create(&config);
    zig_ai_agent_set_callback(agent, on_event, NULL);

    ZigAiAgentResult result;
    ZigAiString task = { .ptr = "List all files", .len = 14 };
    zig_ai_agent_run(agent, task, &result);

    printf("Response: %.*s\n", (int)result.final_response.len, result.final_response.ptr);
    printf("Turns: %u, Tools: %u, Tokens: %u/%u\n",
        result.turns_used, result.tool_calls_made,
        result.input_tokens, result.output_tokens);

    zig_ai_agent_result_free(&result);
    zig_ai_agent_destroy(agent);
}
```

### Using as a Zig Dependency

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_ai = .{
        .path = "../zig_ai",  // or use URL
    },
    .http_sentinel = .{
        .path = "../http_sentinel",
    },
},
```

In your `build.zig`:

```zig
const zig_ai = b.dependency("zig_ai", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zig-ai", zig_ai.module("zig-ai"));
```

### Structured Output API

```zig
const std = @import("std");
const structured = @import("zig-ai").structured;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load schemas
    var loader = structured.SchemaLoader.init(allocator);
    defer loader.deinit();
    try loader.loadAll();

    // Get schema
    const schema = loader.get("meeting") orelse return error.SchemaNotFound;

    // Get API key
    const api_key = std.mem.span(std.c.getenv("GEMINI_API_KEY") orelse return error.NoApiKey);

    // Build request
    const request = structured.StructuredRequest{
        .prompt = "Meeting: John and Jane, Monday 2pm",
        .schema = schema,
        .provider = .gemini,
        .model = null,  // Use default
        .system_prompt = null,
        .max_tokens = 4096,
    };

    // Generate
    var response = try structured.generate(allocator, api_key, request);
    defer response.deinit();

    // Use the JSON output
    std.debug.print("Result: {s}\n", .{response.json_output});

    if (response.usage) |usage| {
        std.debug.print("Tokens: {d} in, {d} out\n", .{usage.input_tokens, usage.output_tokens});
    }
}
```

### Direct Provider Access

```zig
const providers = @import("zig-ai").structured.providers;
const types = @import("zig-ai").structured.types;

// Use a specific provider directly
var response = try providers.gemini.generate(allocator, api_key, request);
defer response.deinit();
```

### Creating Schemas Programmatically

```zig
const types = @import("zig-ai").structured.types;

// Create schema in code (must manage memory)
var schema = types.Schema{
    .name = try allocator.dupe(u8, "my_schema"),
    .description = try allocator.dupe(u8, "My custom schema"),
    .schema_json = try allocator.dupe(u8,
        \\{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}
    ),
    .allocator = allocator,
};
defer schema.deinit();
```

### Error Handling

```zig
const response = structured.generate(allocator, api_key, request) catch |err| {
    switch (err) {
        types.StructuredError.InvalidApiKey => // Handle auth error
        types.StructuredError.RateLimitExceeded => // Handle rate limit
        types.StructuredError.InvalidRequest => // Handle bad request
        types.StructuredError.InvalidResponse => // Handle parse error
        types.StructuredError.RefusalError => // Model refused
        types.StructuredError.MaxTokensExceeded => // Response truncated
        else => // Other error
    }
};
```

## Output Storage

Generated media is saved to:
- **Local**: Current working directory
- **Central store**: `~/media_store/{type}/{provider}/{job-id}/`

Each job includes:
- The generated media file
- `metadata.json` with prompt, model, processing time, etc.

## Provider Commands

| Command | Provider | Required Key | Features |
|---------|----------|--------------|----------|
| `research` | Google Gemini | GEMINI_API_KEY | Web Search, Deep Research |
| `search` | xAI Grok | XAI_API_KEY | Web Search, X Search |
| `agent` | Any text provider | Provider-specific | Autonomous tasks, Tools |
| `claude` | Anthropic Claude | ANTHROPIC_API_KEY | Text, Vision, Structured |
| `deepseek` | DeepSeek | DEEPSEEK_API_KEY | Text, Structured* |
| `gemini` | Google Gemini | GEMINI_API_KEY | Text, Vision, Structured, TTS |
| `grok` | xAI Grok | XAI_API_KEY | Text, Vision, Structured, Search, Image, Edit, Video |
| `openai` | OpenAI | OPENAI_API_KEY | Text, Vision, Structured, TTS, STT |
| `vertex` | Google Vertex | VERTEX_PROJECT_ID | Text, Vision |
| `dalle3` | OpenAI DALL-E 3 | OPENAI_API_KEY | Image |
| `dalle2` | OpenAI DALL-E 2 | OPENAI_API_KEY | Image |
| `gpt-image` | OpenAI GPT-Image | OPENAI_API_KEY | Image, Edit |
| `grok-image` | xAI Grok-2-Image | XAI_API_KEY | Image |
| `edit` | OpenAI / xAI | OPENAI_API_KEY or XAI_API_KEY | Image Edit |
| `imagen` | Google Imagen | GEMINI_API_KEY | Image |
| `gemini-image` | Gemini Flash | GEMINI_API_KEY | Image |
| `image-batch` | Any image provider | Provider-specific | Batch Image |
| `batch-api` | Anthropic/Gemini/OpenAI/xAI | Provider-specific | Batch Text/Image |
| `sora` | OpenAI Sora 2 | OPENAI_API_KEY | Video |
| `veo` | Google Veo 3.1 | GEMINI_API_KEY | Video |
| `grok-video` | xAI Grok Imagine Video | XAI_API_KEY | Video |
| `lyria` | Google Lyria 2 | gcloud auth | Music |
| `lyria-realtime` | Lyria instant | gcloud auth | Music (streaming) |
| `live` | Google Gemini Live | GEMINI_API_KEY | Real-time streaming, Voice |
| `voice` | xAI Grok Realtime | XAI_API_KEY | Voice Agent |
| `tts-openai` | OpenAI TTS | OPENAI_API_KEY | Speech |
| `tts-google` | Google TTS | GEMINI_API_KEY | Speech |
| `stt-openai` | OpenAI Whisper | OPENAI_API_KEY | Transcription |

*DeepSeek structured output uses JSON mode with schema in prompt (not strict enforcement)

## Default Models

| Provider | Default Model |
|----------|---------------|
| OpenAI | gpt-5.2 |
| Claude | claude-sonnet-4-5-20250929 |
| Gemini | gemini-3-flash-preview |
| Grok | grok-4-1-fast-non-reasoning (Responses API) |
| DeepSeek | deepseek-chat |

### Available Grok Models

**Language models** (per million tokens):

| Model | Input/Output | Context | Notes |
|-------|-------------|---------|-------|
| `grok-4-1-fast-non-reasoning` | $0.20/$0.50 | 2M | Default. Fast, no reasoning trace |
| `grok-4-1-fast-reasoning` | $0.20/$0.50 | 2M | Reasoning trace in streaming mode |
| `grok-code-fast-1` | $0.20/$1.50 | 256K | Agentic coding, native tool calling, interleaved reasoning |
| `grok-4-fast-non-reasoning` | $0.20/$0.50 | 2M | Previous generation fast model |
| `grok-4-fast-reasoning` | $0.20/$0.50 | 2M | Previous generation reasoning model |
| `grok-4-0709` | $3.00/$15.00 | 256K | Full Grok 4. Reasoning-only (no non-reasoning mode) |

**Image generation models** (per image):

| Model | Output Price | Notes |
|-------|-------------|-------|
| `grok-imagine-image-pro` | $0.07/image | High quality, 1K/2K resolution, $0.002/image input |
| `grok-imagine-image` | $0.02/image | Standard quality, 300 rpm |

**Video generation models** (per second):

| Model | Output Price | Notes |
|-------|-------------|-------|
| `grok-imagine-video` | $0.05/sec | 60 rpm |

**Server-side tool costs** (per 1K calls):

| Tool | Cost | Tool name |
|------|------|-----------|
| Web Search | $5 | `web_search` |
| X Search | $5 | `x_search` |
| Code Execution | $5 | `code_execution` / `code_interpreter` |
| File Attachments | $10 | `attachment_search` |
| Collections Search | $2.50 | `collections_search` / `file_search` |
| Remote MCP Tools | Token-based | Set by MCP server |

### grok-code-fast-1 Tips

`grok-code-fast-1` is a lightweight reasoning model optimized for agentic coding with native tool calling. Designed for tool-heavy workflows, not one-shot Q&A (use Grok 4 models for that).

**For CLI usage:**
- Provide specific context: reference exact files and paths rather than vague descriptions
- Set explicit goals: detailed prompts with concrete requirements outperform vague ones
- Iterate rapidly: the model's speed and low cost make rapid refinement the best strategy
- Use with agent mode: `zig-ai agent "task" --config grok-agent` — the model excels at multi-step tool-calling tasks

**For API integration:**
- Use native tool calling (not XML-based), which the model was specifically designed for
- Give detailed system prompts describing tasks, expectations, and edge cases
- Use XML tags or Markdown headings to structure context in the initial user prompt
- Avoid modifying prompt history between turns to maximize cache hits (major speed contributor)
- Reasoning traces are exposed via `reasoning_content` in streaming mode only

### Grok 4 Notes

`grok-4-0709` is a reasoning model with no non-reasoning mode. Unlike grok-4-1-fast, it does **not** support `presencePenalty`, `frequencyPenalty`, `stop`, or `reasoning_effort` parameters.

### Batch API Pricing

The xAI Batch API provides **50% off** all token costs (input, output, cached, reasoning). Requests are processed asynchronously, typically within 24 hours. Use `zig-ai batch` for batch operations. Image and video models are not supported in batch mode.

## Dependencies

- [http_sentinel](../http_sentinel) - HTTP client library

## License

MIT
