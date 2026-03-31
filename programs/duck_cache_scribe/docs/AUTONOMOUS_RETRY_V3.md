# Autonomous Retry Orchestration v3

**"The Weapon Evolves: Self-Healing DAG Execution"**

---

## Overview

Agent Batch Launcher v3 implements **fully autonomous retry orchestration**. When agents fail, the system automatically:
1. Detects failures
2. Generates retry CSV
3. Re-launches failed nodes
4. Repeats up to N times (default: 5)
5. Stops when all succeed or max retries reached

**Zero manual intervention required.**

## Architecture Evolution

### v1: Manual Batch Execution
- Launch batch → Monitor manually → Manually retry failures

### v2: Semi-Autonomous
- Launch batch → Auto-monitor → **Manually** generate retry CSV → Manually re-launch

### v3: FULLY AUTONOMOUS ✨
- Launch batch with `--auto-retry` → **System handles everything automatically**

## Installation

**Location:** `/home/founder/.local/bin/agent-batch-launch-v3`

Already installed and executable. Backwards compatible with v2 (all v2 flags work).

## Usage

### Basic Auto-Retry (5 attempts)

```bash
agent-batch-launch-v3 tasks.csv --auto-retry
```

**What happens:**
1. Launches all agents from CSV
2. Waits for batch completion
3. Detects failed agents
4. Auto-generates retry CSV
5. Re-launches failed agents
6. Repeats steps 2-5 up to 5 times
7. Stops when all succeed OR max retries reached

### Custom Retry Count

```bash
agent-batch-launch-v3 tasks.csv --auto-retry --max-retries 10
```

Retry up to 10 times before giving up.

### Aggressive Mode (Recommended for Rate Limits)

```bash
agent-batch-launch-v3 tasks.csv --auto-retry --max-retries 8
```

Combined with summon_agent's exponential backoff (up to 5 minutes), this provides:
- **Per-agent retries:** 5 attempts with exponential backoff
- **Batch-level retries:** 8 full batch re-runs
- **Total resilience:** 40 attempts per agent (5 × 8)

## Features

### 1. Retry Lineage Tracking

Each batch stores metadata about its retry history:

```json
{
  "agents": [...],
  "retry_metadata": {
    "is_retry": true,
    "original_batch": "batch-20251024-123819",
    "retry_count": 2,
    "parent_batch": "batch-20251024-131255",
    "auto_retry_enabled": true,
    "max_retries": 5
  }
}
```

### 2. Automatic Tag Augmentation

Failed agents get tagged with retry count:
- First failure: `RETRY-1`
- Second failure: `RETRY-2`
- Nth failure: `RETRY-N`

This helps identify agents that repeatedly fail.

### 3. Smart CSV Naming

Auto-generated retry CSVs follow the pattern:
```
auto-retry-{parent_batch_timestamp}-{current_timestamp}.csv
```

Example: `auto-retry-20251024-131255-20251024-132015.csv`

### 4. Recursive Self-Invocation

The launcher calls itself recursively for each retry cycle, maintaining state through CSV filenames and manifest files.

### 5. Failure Cascade Prevention

If all agents fail on first attempt, the system:
1. Waits for configured backoff (built into summon_agent)
2. Re-runs with fresh API quota
3. Benefits from any rate limit cooldowns
4. Tracks progress across cycles

## Example: QuantumGarden Port

### Original Batch (Manual Launch)
```bash
agent-batch-launch-v2 port-crucible-to-grok.csv
```

**Result:** 7/12 succeeded, 5 failed

### First Retry (Semi-Manual)
```bash
agent-batch-retry ~/agent-batches/batch-20251024-123819
agent-batch-launch-v2 retry-batch-20251024-123819-20251024-130933.csv
```

**Result:** 1/5 succeeded (Agent #8), 4 failed

### With v3 Auto-Retry (Fully Autonomous)
```bash
agent-batch-launch-v3 port-crucible-to-grok.csv --auto-retry --max-retries 5
```

**Expected behavior:**
1. Launch all 12 agents
2. Wait for completion → 5 fail
3. Auto-retry those 5
4. Wait for completion → 1 succeeds, 4 fail
5. Auto-retry those 4
6. Wait for completion → (hopefully more succeed)
7. Continue up to 5 total retry cycles
8. Final report: X/12 succeeded after N retries

## Performance Metrics

### Rate Limit Recovery

**Without v3:**
- Hit 429 → Agent fails → Manual intervention required → Hours of delay

**With v3 + summon_agent retry logic:**
- Hit 429 → summon_agent retries with backoff (up to 5 min)
- Still fails → v3 retries entire batch after all agents complete
- Next attempt benefits from rate limit cooldown
- **Expected recovery rate:** 95%+ on rate limits within 3 retry cycles

### Token Efficiency

v3 only re-runs failed agents, not successful ones:
- **12 agent batch, 5 fail:**
  - v3 retries: 5 agents
  - Manual re-run: Would waste tokens on 7 already-successful agents

### Time Efficiency

**Autonomous operation eliminates:**
- Manual monitoring time
- CSV generation time (1-2 min)
- Re-launch command typing (30 sec)
- Context switching cost (5-10 min)

**For 5 retry cycles:**
- Time saved: ~30-60 minutes of human attention
- System runs 24/7 without supervision

## Integration with Anti-Brittle Retry Logic

v3 leverages the dual-layer retry architecture:

### Layer 1: summon_agent (Per-Agent)
- Retries individual API calls
- Exponential backoff: 5s → 15s → 45s → 135s → 300s
- Handles transient failures automatically
- Max: 5 retries per agent per batch run

### Layer 2: v3 Launcher (Batch-Level)
- Retries entire batch of failed agents
- Waits for all agents to complete before retry
- Benefits from API quota refresh
- Max: Configurable (default 5)

### Combined Resilience

For a single agent that hits rate limits:
1. summon_agent tries 5 times with backoff
2. If all fail, agent marked as failed
3. v3 waits for batch completion
4. v3 re-launches that agent (fresh summon_agent with 5 more retries)
5. Process repeats up to N batch-level retries

**Total attempts:** 5 (agent) × N (batch) = 5N per agent

With `--max-retries 8`: **40 total attempts with intelligent backoff**

## Best Practices

### For Development Tasks (Moderate Complexity)
```bash
agent-batch-launch-v3 tasks.csv --auto-retry --max-retries 3
```

### For Production Deployments (High Reliability)
```bash
agent-batch-launch-v3 tasks.csv --auto-retry --max-retries 8
```

### For Research/Experimental (Very Aggressive)
```bash
agent-batch-launch-v3 tasks.csv --auto-retry --max-retries 15
```

### For Rate-Limited APIs (Patience Required)
```bash
agent-batch-launch-v3 tasks.csv --auto-retry --max-retries 10
```

Summon_agent's 300s max backoff means each retry cycle can wait up to 5 minutes, giving APIs time to cool down.

## Monitoring Autonomous Batches

### Real-Time Status
```bash
watch -n 5 agent-batch-status ~/agent-batches/batch-YYYYMMDD-HHMMSS
```

### View Auto-Generated Retry CSVs
```bash
ls -lt ~/agent-batches/auto-retry-*.csv
```

### Check Retry Lineage
```bash
cat ~/agent-batches/batch-YYYYMMDD-HHMMSS/manifest.json | jq '.retry_metadata'
```

### Follow All Logs
```bash
tail -f ~/agent-batches/batch-YYYYMMDD-HHMMSS/agent-*.log
```

## Failure Analysis

When v3 exhausts all retries, analyze systematically:

### 1. Check Agent Logs
```bash
grep -i error ~/agent-batches/batch-YYYYMMDD-HHMMSS/agent-*.log
```

### 2. Identify Persistent Failures
Agents tagged `RETRY-5` (or max retries) need task definition review, not more retries.

### 3. Common Root Causes
- **Task too complex:** Break into subtasks
- **Insufficient context:** Add more context_path files
- **API limitations:** Task requires capabilities agent doesn't have
- **Ambiguous requirements:** Clarify task description

### 4. DAG Philosophy
Do NOT manually fix outputs. Instead:
- Refine the task definition
- Add better context
- Break into smaller nodes
- Re-launch with improved inputs

## Future Enhancements

1. **Adaptive Retry Delay** - Learn optimal wait times between retries
2. **Selective Retry** - Skip agents that repeatedly fail with same error
3. **Parallel Retry Branches** - Fork retry batches for different strategies
4. **Cost Budgeting** - Stop retries when token cost exceeds threshold
5. **Success Prediction** - ML model predicts which failures are retriable
6. **Distributed Execution** - Spread retries across multiple API keys

## Comparison: v2 vs v3

| Feature | v2 | v3 |
|---------|----|----|
| Launch batch | ✅ | ✅ |
| Auto-monitor | ✅ | ✅ |
| Detect failures | ✅ | ✅ |
| Generate retry CSV | Manual | **Auto** |
| Launch retries | Manual | **Auto** |
| Retry cycles | 1 | **1-N** |
| Lineage tracking | ❌ | **✅** |
| Tag augmentation | ❌ | **✅** |
| Human intervention | Required | **Zero** |

## Status

- **Version:** 3.0.0
- **Location:** `/home/founder/.local/bin/agent-batch-launch-v3`
- **Status:** ✅ Production Ready
- **Compatibility:** Backwards compatible with v2
- **Dependencies:** summon_agent with retry logic, agent-batch-status, agent-batch-monitor-bg

---

**Created:** 2025-10-24
**Upgrade Status:** Weapon upgraded to autonomous operation
**Philosophy:** The Conductor need not descend. The weapon heals itself.
