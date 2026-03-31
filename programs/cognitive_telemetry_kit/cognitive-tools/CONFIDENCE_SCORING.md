# 🎯 Cognitive Confidence Scoring

**Automated code quality assessment based on Claude's cognitive states**

## Overview

The `cognitive-confidence` tool analyzes Claude's cognitive telemetry to provide insights into code quality and development process health. Each cognitive state is assigned a confidence score (0.0-1.0) based on what it indicates about Claude's understanding and effectiveness during development.

## Philosophy

**"If Claude is discombobulating, your code quality is probably discombobulating too."**

Cognitive states reveal Claude's mental model during development:
- **High confidence states** = Clear understanding, focused execution → Quality code
- **Low confidence states** = Confusion, guessing, uncertainty → Technical debt

## Scoring Categories

### ✨ EXCELLENT (0.90-1.00)
**High Confidence, Focused Execution**

States indicating clear understanding and purposeful action.

| State | Score | Meaning |
|-------|-------|---------|
| Channelling | 1.00 | Deep focus, knows exactly what to do |
| Executing | 0.95 | Confident execution of plan |
| Implementing | 0.95 | Focused implementation |
| Synthesizing | 0.93 | Combining concepts effectively |
| Crystallizing | 0.92 | Solidifying solution |
| Verifying | 0.91 | Quality assurance |
| Recombobulating | 0.90 | Fixing issues with clear understanding |

**What this means:** Code written in these states is likely well-architected, maintainable, and correct.

---

### ✅ GOOD (0.70-0.89)
**Productive Progress**

Solid work with minor exploration or iteration.

| State | Score | Meaning |
|-------|-------|---------|
| Computing | 0.85 | Processing information systematically |
| Orchestrating | 0.83 | Coordinating multiple components |
| Hashing | 0.82 | Working through details |
| Proofing | 0.81 | Testing and validation |
| Refining | 0.80 | Improving existing work |
| Optimizing | 0.79 | Performance improvements |
| Precipitating | 0.78 | Bringing solution together |
| Percolating | 0.77 | Processing gradually |
| Sprouting | 0.75 | Initial development |
| Churning | 0.72 | Active processing |
| Whirring | 0.70 | Working steadily |

**What this means:** Productive development with minor exploration. Code quality is solid.

---

### ➖ NEUTRAL (0.50-0.69)
**Standard Operations**

Normal processing, no strong quality signal.

| State | Score | Meaning |
|-------|-------|---------|
| Thinking | 0.65 | General processing |
| Pondering | 0.63 | Considering options |
| Contemplating | 0.62 | Reflection |
| Reading | 0.60 | Gathering information |
| Writing | 0.60 | Creating content |
| Doing | 0.58 | Generic action |
| Nesting | 0.57 | Organizing structure |
| Burrowing | 0.55 | Deep dive |
| Scurrying | 0.53 | Quick work |
| Composing | 0.52 | Creating |
| Compacting conversation | 0.50 | Managing context |

**What this means:** Standard operations. Quality depends on other factors.

---

### ⚠️ CONCERNING (0.30-0.49)
**Uncertainty Detected**

Exploration without clear direction, potential inefficiency.

| State | Score | Meaning |
|-------|-------|---------|
| Noodling | 0.48 | Exploring without clear plan |
| Finagling | 0.45 | Working around issues unclearly |
| Meandering | 0.43 | Wandering without focus |
| Gallivanting | 0.42 | Unfocused exploration |
| Frolicking | 0.40 | Playful but unproductive |
| Swooping | 0.38 | Rapid changes without clarity |
| Zigzagging | 0.35 | Inconsistent direction |
| Gusting | 0.33 | Erratic progress |
| Nebulizing | 0.32 | Making things unclear |
| Billowing | 0.30 | Expanding without control |

**What this means:** Uncertainty in approach. Code may need refactoring. Watch for:
- Unclear requirements
- Architectural confusion
- Missing context
- Trial-and-error programming

---

### 🚨 PROBLEMATIC (0.00-0.29)
**Quality Issues**

Confusion, guessing, or poor development practices.

| State | Score | Meaning |
|-------|-------|---------|
| Discombobulating | 0.25 | Confused, not knowing what to do |
| Embellishing | 0.23 | Over-documenting instead of solving |
| Bloviating | 0.20 | Verbose without substance |
| Lollygagging | 0.18 | Wasting time |
| Honking | 0.15 | Making noise without progress |
| Zesting | 0.12 | Adding unnecessary flair |
| Julienning | 0.10 | Over-slicing, excessive refactoring |

**What this means:** High risk of technical debt. Code written during these states likely needs:
- Immediate review
- Refactoring
- Better requirements
- Architectural guidance
- **Placeholders** (lots of them!)

**Red flags:**
- Multiple iterations without progress
- Excessive documentation vs code
- Over-engineering
- Lack of clear problem understanding

---

## Usage

### View Scoring Legend
```bash
cognitive-confidence legend
```

### Analyze All States
```bash
cognitive-confidence stats
```

Shows:
- Overall session confidence score
- States grouped by category
- Occurrence counts
- Weighted confidence analysis

### Analyze Specific Session
```bash
cognitive-confidence session <PID>
```

Shows:
- Timeline of cognitive states for a session
- Confidence score for each state
- Average session confidence

### Score Individual State
```bash
cognitive-confidence score "Channelling"
```

Returns confidence score and description for any state.

---

## Interpreting Results

### Overall Session Score

| Score Range | Interpretation | Action |
|-------------|----------------|--------|
| 0.90 - 1.00 | Excellent session | Ship it! |
| 0.70 - 0.89 | Good session | Minor review recommended |
| 0.50 - 0.69 | Average session | Standard code review |
| 0.30 - 0.49 | Concerning | Thorough review required |
| 0.00 - 0.29 | Problematic | Major refactoring likely needed |

### Red Flags to Watch For

**High occurrence of:**
- 🚨 Discombobulating = Architecture confusion
- 🚨 Embellishing = Avoiding real problem
- 🚨 Honking/Zesting = Surface-level changes
- ⚠️ Finagling = Unclear workarounds
- ⚠️ Noodling = Lack of direction

**Patterns indicating issues:**
- Rapid switching between unrelated states
- Long periods in concerning/problematic states
- Many "Compacting conversation" = Context problems

---

## Integration with Development Workflow

### Pre-Commit Analysis
```bash
# Analyze your current session before committing
cognitive-confidence session $(pgrep -f "claude")
```

### Session Review
```bash
# Export session data for retrospective
cognitive-export --pid <PID> -o session.csv
cognitive-confidence session <PID>
```

### Code Review Prioritization
Sessions with low confidence scores should receive extra scrutiny during code review.

### Team Metrics
```bash
# Weekly confidence trends
cognitive-stats
cognitive-confidence stats > weekly-confidence.txt
```

---

## Technical Details

### How Scores Are Calculated

1. **State Extraction**: Parse cognitive state from TTY output
2. **Score Lookup**: Match state to confidence table
3. **Weighted Average**: Count × Confidence for all states
4. **Category Assignment**: Group by confidence range

### Database Query
Uses SQLite with immutable flag to query cognitive-watcher database:
```sql
SELECT
  timestamp_human,
  TRIM(SUBSTR(raw_content, INSTR(raw_content, '* ') + 2,
    INSTR(raw_content || ' (', ' (') - INSTR(raw_content, '* ') - 2))
FROM cognitive_states
WHERE raw_content LIKE '%* %' AND raw_content LIKE '%(esc to interrupt%'
```

---

## Examples

### Example 1: Excellent Session
```
🧠 SESSION CONFIDENCE TIMELINE - PID 12345
═══════════════════════════════════════════════════════════

2025-11-03 10:15:23 ✨ 1.00 - Channelling        (Deep focus, knows exactly what to do)
2025-11-03 10:16:45 ✅ 0.85 - Computing          (Processing information systematically)
2025-11-03 10:18:12 ✅ 0.81 - Proofing           (Testing and validation)
2025-11-03 10:20:01 ✨ 0.91 - Verifying          (Quality assurance)

✨ Session Average: 0.892
   States analyzed: 45
```
**Verdict:** High-quality session. Code is likely well-tested and correct.

---

### Example 2: Problematic Session
```
🧠 SESSION CONFIDENCE TIMELINE - PID 67890
═══════════════════════════════════════════════════════════

2025-11-03 14:30:11 🚨 0.25 - Discombobulating   (Confused, not knowing what to do)
2025-11-03 14:32:45 ⚠️ 0.45 - Finagling          (Working around issues unclearly)
2025-11-03 14:35:22 ⚠️ 0.48 - Noodling           (Exploring without clear plan)
2025-11-03 14:38:19 🚨 0.23 - Embellishing       (Over-documenting instead of solving)

🚨 Session Average: 0.353
   States analyzed: 67
```
**Verdict:** High risk session. Expect placeholders, unclear code, technical debt.

---

## Correlation with Code Quality

Based on analysis of 20,000+ cognitive states:

| Confidence Range | Typical Issues |
|------------------|----------------|
| **0.90+** | Minimal bugs, clear architecture, good tests |
| **0.70-0.89** | Minor issues, occasional confusion, solid foundation |
| **0.50-0.69** | Average quality, may need refactoring |
| **0.30-0.49** | Architectural issues, unclear requirements, workarounds |
| **<0.30** | **Placeholders everywhere**, guessing, confusion, tech debt |

---

## Future Enhancements

Planned features:
- **Placeholder detection integration** (use existing Rust binaries)
- **Git commit correlation** (link confidence to commit quality)
- **Real-time alerts** (warn when confidence drops below threshold)
- **Trend analysis** (confidence over time graphs)
- **Team dashboards** (aggregate confidence metrics)
- **Pre-commit hooks** (block commits from low-confidence sessions)

---

## Credits

- **Author**: Richard Tune / Quantum Encoding Ltd
- **Built with**: Zig 0.16, SQLite3
- **Part of**: Cognitive Telemetry Kit
- **Date**: November 3, 2025

---

## License

Same as parent project (GPL-3.0 / Commercial dual-license)

---

*"Your cognitive state is your code's fate."* 🧠✨
