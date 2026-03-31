# Cognitive State Capture - Final Solution

## The Problem
Status lines weren't being captured because the watcher used keyword-based filtering that couldn't handle all possible states (e.g., "Verifying" wasn't in the keyword list).

## The Solution
1. **Watcher**: Capture ALL TTY output from Claude - no filtering
2. **Script**: Intelligently extract status lines using pattern matching

## How It Works

### Watcher (cognitive-watcher-v2.c)
- Captures all TTY writes from Claude process
- Saves everything to database
- No keyword filtering - just raw capture

### Script (get-cognitive-state)
- Queries database for recent entries
- Filters out tool execution patterns (Bash, Read, Write, Edit)
- Looks for lines starting with `>` or `*` (status line markers)
- Extracts text between marker and `(` - this is the cognitive state

### Status Line Format
```
> [COGNITIVE STATE] (esc to interrupt...)
* [COGNITIVE STATE] (esc to interrupt...)
```

Examples:
- `> Verifying git commits (esc to interrupt...)`
- `* Testing chronos-stamp (esc to interrupt...)`
- `> Writing documentation (esc to interrupt...)`

## Scalability
This approach works for ANY cognitive state without hardcoding keywords. It's based on the UI pattern, not content matching.
