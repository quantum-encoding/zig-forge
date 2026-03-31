#!/bin/bash
# Test the Python cognitive monitor with simulated Claude output

MONITOR_SCRIPT="/home/founder/apps_and_extensions/claude-code-cognitive-monitor/monitor.py"

echo "🧪 Testing Cognitive State Monitor"
echo "=================================="
echo ""
echo "Simulating Claude Code output with cognitive states..."
echo ""

# Simulate Claude output with cognitive states
(
  sleep 0.5
  echo "Synthesizing…"
  sleep 1
  echo "Some normal output here"
  sleep 0.5
  echo "Channelling…"
  sleep 1
  echo "More output"
  sleep 0.5
  echo "Finagling…"
  sleep 1
  echo "Final output"
  sleep 0.5
  echo "Thinking…"
  sleep 0.5
) | python3 "$MONITOR_SCRIPT"

echo ""
echo "=================================="
echo "📊 Checking captured state history:"
echo ""
tail -10 ~/.cache/claude-code-cognitive-monitor/state-history.jsonl
