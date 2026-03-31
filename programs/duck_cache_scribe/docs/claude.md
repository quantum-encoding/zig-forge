# Claude Code - Agent Summoning & Eternal Timeline

## Your Enhanced Capabilities

You are Claude Code running on a system with **chronos-stamp** integration and **agent-summon** delegation capabilities. This document explains your new powers and important workflows.

---

## 🔥 Agent Summoning (Delegation to Grok)

### What It Is
You can delegate time-consuming, repetitive, or parallel tasks to **Grok** agents that run asynchronously in isolated crucibles.

### When to Use Agent Summoning

✅ **DELEGATE TO GROK:**
- Tasks that will take 20+ turns
- Repetitive refactoring across many files
- Running long test suites or benchmarks
- Exploratory coding experiments
- Bulk data processing
- Tasks that can run in parallel while you continue working
- When you need to work on multiple things simultaneously

❌ **DON'T DELEGATE:**
- Quick tasks (< 5 turns)
- Tasks requiring user interaction/clarification
- Security-sensitive operations
- Tasks that need your specific reasoning capabilities
- Critical architecture decisions

### How to Summon an Agent

```bash
# Basic syntax
/home/founder/apps_and_extensions/agent-summon/target/release/summon_agent \
  grok \
  "Your detailed task description here" \
  -c /path/to/project/context \
  -t 100

# Example: Delegate refactoring
summon_agent grok \
  "Refactor all database queries to use prepared statements" \
  -c /home/founder/myproject \
  -t 50 &

# Continue working while Grok handles it
# Check result later: cat ~/crucible/grok-*/result.json
```

### Task Description Best Practices

1. **Be Specific**: "Refactor auth to use JWT" not "improve auth"
2. **Include Context**: Mention file locations, patterns, technologies
3. **Set Success Criteria**: "All tests pass" or "Create 10 examples"
4. **Provide Context Path**: Use `-c` flag to give Grok project files

### Finding Results

After delegation:
```bash
# Find the latest crucible
ls -lt ~/crucible/ | head -n 2

# Check result
cat ~/crucible/grok-TIMESTAMP/result.json

# Review git history of changes
cd ~/crucible/grok-TIMESTAMP/workspace
git log --oneline

# See the work
ls -la
```

---

## 🌌 Eternal Agent Logs

### What It Is
Every tool you execute (and every agent summoned) writes to a **centralized eternal timeline** at `~/eternal-agent-logs/`

### Directory Structure
```
~/eternal-agent-logs/
├── daily/
│   ├── 2025-10-24.log    # Today's activity
│   ├── 2025-10-25.log    # Tomorrow's activity
│   └── ...
└── archive/
    ├── 2025-09.tar.gz     # Compressed monthly archives
    └── 2025-10.tar.gz
```

### Log Format
Each line contains:
```
UTC-TIMESTAMP | [CHRONOS] CHRONOS-STAMP | PWD: /workspace/path
```

Example:
```
2025-10-23T23:17:05.039881841Z | [CHRONOS] 2025-10-23T23:17:05.+39392773Z::claude-code::TICK-0000000384::[SESSION-ID]::[/path] → Write | PWD: /home/founder/project
```

### What This Means For You

1. **Full Audit Trail**: Every file you write, edit, or read is logged
2. **Cross-Session Continuity**: See what you did yesterday, last week, last month
3. **Agent Attribution**: Logs show which agent (claude-code, grok-agent, deepseek-code) did what
4. **TICK Counter**: Monotonically increasing timestamp for ordering events
5. **Automatic Archival**: Logs compressed monthly, never deleted

### Querying the Timeline

```bash
# Today's activity
cat ~/eternal-agent-logs/daily/$(date +%Y-%m-%d).log

# Search for specific tool usage
grep "write_file" ~/eternal-agent-logs/daily/*.log

# See all grok-agent activity
grep "grok-agent" ~/eternal-agent-logs/daily/*.log

# Count TICK progression
grep -o "TICK-[0-9]*" ~/eternal-agent-logs/daily/*.log | sort -u
```

---

## 🔀 Auto-Commit with Chronos-Stamp

### How It Works

**Every tool execution automatically creates a git commit with a 4th-dimensional timestamp.**

Example commit message:
```
[CHRONOS] 2025-10-23T23:17:05.+39392773Z::claude-code::TICK-0000000384::[SESSION-ID]::[/home/founder/project] → Write
```

### What This Means

✅ **AUTOMATIC:**
- Git commits created after every Write, Edit, etc.
- Full version history without manual commits
- Chronos-stamp metadata in every commit message

❌ **YOU STILL NEED TO:**
- **Push to remote** when work is complete
- Use proper branching strategy for production

### Pushing Your Work

```bash
# After completing a feature/fix
git push origin branch-name

# For main branch changes (non-production)
git push origin main
```

---

## ⚠️ CRITICAL: Production Branch Workflow

### THE RULE

**NEVER auto-commit to `main` branch on production repositories where `git push = deployment`**

### Why This Matters

Some repositories have CD/CI pipelines where:
- Push to `main` → Automatic deployment to production
- Push to `main` → Published to package registry (npm, PyPI, etc.)
- Push to `main` → Docker build and deploy
- Push to `main` → Live website update

**Auto-committing every tool use would cause chaos!**

### The Safe Workflow

When working on production systems:

1. **Ask First**: "Is this a production repo with auto-deploy?"
2. **Create Pre-Production Branch**:
   ```bash
   git checkout -b pre-prod-FEATURE-NAME
   # or
   git checkout -b dev-YYYY-MM-DD
   ```

3. **Work Normally**: Let auto-commits happen on the branch
4. **When Ready**: User reviews, squashes commits, merges to main
5. **User Pushes to Main**: User controls deployment timing

### Example

```bash
# ❌ BAD - Working directly on main of production repo
git branch
# * main

# ✅ GOOD - Working on pre-production branch
git checkout -b pre-prod-auth-refactor
git branch
# * pre-prod-auth-refactor
#   main

# Work happens, auto-commits pile up
# User reviews when ready:
git log --oneline  # See all chronos commits
git diff main      # Review all changes

# User decides to merge
git checkout main
git merge --squash pre-prod-auth-refactor
git commit -m "Refactor: Implement JWT authentication"
git push  # Deploys to production on user's terms
```

### How to Detect Production Repos

Ask yourself:
1. Does `.github/workflows/` contain deploy steps?
2. Is there a `Dockerfile` with deployment configs?
3. Does `package.json` have `publishConfig`?
4. Is this deployed automatically (Vercel, Netlify, etc.)?

**If YES to any → USE PRE-PRODUCTION BRANCH**

---

## 📊 Workflow Cheatsheet

### Daily Work
```bash
# 1. Check if production repo
ls .github/workflows/  # Check for deploy.yml, etc.

# 2. If production: create branch
git checkout -b pre-prod-$(date +%Y-%m-%d)

# 3. Work normally (auto-commits happen)

# 4. When done: let user review & push
```

### Time-Consuming Task
```bash
# 1. Delegate to Grok
summon_agent grok "Task description" -c /context/path -t 100 &

# 2. Continue with other work

# 3. Check result later
cat ~/crucible/grok-*/result.json
```

### Reviewing Timeline
```bash
# See what you did today
cat ~/eternal-agent-logs/daily/$(date +%Y-%m-%d).log

# See git history
git log --oneline

# Both are linked by TICK numbers in chronos-stamps!
```

---

## 🎯 Best Practices

1. **Communicate Delegation**: Tell user when you're summoning Grok
2. **Branch by Default**: When unsure, create a branch
3. **Push Reminders**: Remind user to push when work is complete
4. **Review Crucibles**: Check Grok's work before integrating
5. **Use Eternal Logs**: Reference timeline for debugging/context
6. **Trust Auto-Commits**: Don't manually commit, let chronos-stamp handle it
7. **Squash for Production**: Recommend squash merges for cleaner history

---

## 🚀 System Overview

```
┌─────────────────┐
│  Claude Code    │ ← You (interactive, reasoning)
│  (Main Agent)   │
└────────┬────────┘
         │
         ├─→ Auto-commits (chronos-stamp) → Git History
         │
         ├─→ Eternal Logs → ~/eternal-agent-logs/daily/
         │
         └─→ Summons → ┌──────────────┐
                       │  Grok Agent  │ ← Delegated tasks
                       │  (Crucible)  │
                       └──────┬───────┘
                              │
                              ├─→ Auto-commits → Crucible Git
                              └─→ Eternal Logs → Same timeline
```

All agents contribute to one unified eternal timeline with chronos-stamp metadata!

---

## 📝 Version

- **Created**: 2025-10-24
- **System**: quantum-encoding-ltd
- **Chronos-Stamp**: Integrated
- **Agent-Summon**: v0.1.0
- **Eternal Logs**: Active

---

Remember: You have the power to summon agents and your work is eternally logged. Use these powers wisely! 🌌
