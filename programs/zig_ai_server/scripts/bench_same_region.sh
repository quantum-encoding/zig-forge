#!/bin/bash
# Benchmark: Go vs Zig from the SAME region as Cloud Run (europe-west1)
# Eliminates network latency so we measure pure server overhead.
#
# Usage:
#   # Option 1: Run from Cloud Shell (close but not same DC)
#   ./scripts/bench_same_region.sh
#
#   # Option 2: Spin up a temp VM in europe-west1 (same DC as Cloud Run)
#   ./scripts/bench_same_region.sh --vm
#
#   # Option 3: Just generate the script to paste into Cloud Shell
#   ./scripts/bench_same_region.sh --print

set -euo pipefail

PROJECT="metatron-cloud-prod-v1"
REGION="europe-west1"
ZONE="europe-west1-b"
VM_NAME="bench-runner-tmp"

GO_URL="https://quantum-ai-api-3wmmugkfzq-ew.a.run.app"
ZIG_URL="https://zig-ai-server-3wmmugkfzq-ew.a.run.app"

# ── The actual benchmark script (runs on the remote machine) ────
BENCH_SCRIPT='#!/bin/bash
set -euo pipefail

GO_URL="https://quantum-ai-api-3wmmugkfzq-ew.a.run.app"
ZIG_URL="https://zig-ai-server-3wmmugkfzq-ew.a.run.app"
GO_KEY="__GO_KEY__"
ZIG_KEY="__ZIG_KEY__"

# Get identity token for Cloud Run IAM
ID_TOKEN=$(curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=${ZIG_URL}" 2>/dev/null || \
  gcloud auth print-identity-token --audiences="${ZIG_URL}" 2>/dev/null || echo "")

N_LATENCY=100
N_CHAT=20
N_THROUGHPUT_SEC=15
CONCURRENCIES="1 5 10 20 50"

percentile() {
  local p=$1; shift
  local sorted=$(printf "%s\n" "$@" | sort -n)
  local count=$(echo "$sorted" | wc -l | tr -d " ")
  local idx=$(echo "scale=0; ($count - 1) * $p / 100" | bc)
  echo "$sorted" | sed -n "$((idx + 1))p"
}

mean() {
  local sum=0 count=0
  for v in "$@"; do
    sum=$(echo "$sum + $v" | bc -l)
    count=$((count + 1))
  done
  echo "scale=3; $sum / $count" | bc -l
}

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Same-Region Benchmark: Go vs Zig (europe-west1)           ║"
echo "║  Measuring pure server overhead — no transatlantic network  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Phase 1: Health (no auth, minimal work) ─────────────────────
echo "Phase 1: Health endpoint ($N_LATENCY requests each)..."
go_times=() zig_times=()

for i in $(seq 1 $N_LATENCY); do
  t=$(curl -s -o /dev/null -w "%{time_total}" "$GO_URL/health" 2>/dev/null)
  go_times+=("$t")
done
for i in $(seq 1 $N_LATENCY); do
  t=$(curl -s -o /dev/null -w "%{time_total}" "$ZIG_URL/health" 2>/dev/null)
  zig_times+=("$t")
done

go_p50=$(percentile 50 "${go_times[@]}")
go_p95=$(percentile 95 "${go_times[@]}")
go_p99=$(percentile 99 "${go_times[@]}")
zig_p50=$(percentile 50 "${zig_times[@]}")
zig_p95=$(percentile 95 "${zig_times[@]}")
zig_p99=$(percentile 99 "${zig_times[@]}")

echo "  Health:     Go P50=${go_p50}s  P95=${go_p95}s  P99=${go_p99}s"
echo "              Zig P50=${zig_p50}s  P95=${zig_p95}s  P99=${zig_p99}s"

# ── Phase 2: Models (authenticated, JSON serialization) ─────────
echo ""
echo "Phase 2: Models endpoint ($N_LATENCY requests each)..."
go_times=() zig_times=()

for i in $(seq 1 $N_LATENCY); do
  t=$(curl -s -o /dev/null -w "%{time_total}" \
    -H "Authorization: Bearer $GO_KEY" "$GO_URL/qai/v1/models" 2>/dev/null)
  go_times+=("$t")
done
for i in $(seq 1 $N_LATENCY); do
  t=$(curl -s -o /dev/null -w "%{time_total}" \
    -H "Authorization: Bearer $ID_TOKEN" \
    -H "X-API-Key: $ZIG_KEY" "$ZIG_URL/qai/v1/models" 2>/dev/null)
  zig_times+=("$t")
done

go_m_p50=$(percentile 50 "${go_times[@]}")
go_m_p95=$(percentile 95 "${go_times[@]}")
zig_m_p50=$(percentile 50 "${zig_times[@]}")
zig_m_p95=$(percentile 95 "${zig_times[@]}")

echo "  Models:     Go P50=${go_m_p50}s  P95=${go_m_p95}s"
echo "              Zig P50=${zig_m_p50}s  P95=${zig_m_p95}s"

# ── Phase 3: Chat non-streaming (provider latency included) ─────
echo ""
echo "Phase 3: Chat non-streaming ($N_CHAT requests each, deepseek-chat)..."
CHAT_BODY="{\"model\":\"deepseek-chat\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: pong\"}],\"max_tokens\":10,\"temperature\":0}"
go_times=() zig_times=()

for i in $(seq 1 $N_CHAT); do
  t=$(curl -s -o /dev/null -w "%{time_total}" -X POST \
    -H "Authorization: Bearer $GO_KEY" \
    -H "Content-Type: application/json" \
    -d "$CHAT_BODY" "$GO_URL/qai/v1/chat" 2>/dev/null)
  go_times+=("$t")
done
for i in $(seq 1 $N_CHAT); do
  t=$(curl -s -o /dev/null -w "%{time_total}" -X POST \
    -H "Authorization: Bearer $ID_TOKEN" \
    -H "X-API-Key: $ZIG_KEY" \
    -H "Content-Type: application/json" \
    -d "$CHAT_BODY" "$ZIG_URL/qai/v1/chat" 2>/dev/null)
  zig_times+=("$t")
done

go_c_p50=$(percentile 50 "${go_times[@]}")
go_c_p95=$(percentile 95 "${go_times[@]}")
go_c_p99=$(percentile 99 "${go_times[@]}")
zig_c_p50=$(percentile 50 "${zig_times[@]}")
zig_c_p95=$(percentile 95 "${zig_times[@]}")
zig_c_p99=$(percentile 99 "${zig_times[@]}")

echo "  Chat:       Go P50=${go_c_p50}s  P95=${go_c_p95}s  P99=${go_c_p99}s"
echo "              Zig P50=${zig_c_p50}s  P95=${zig_c_p95}s  P99=${zig_c_p99}s"

# ── Phase 4: Throughput (health, concurrent) ────────────────────
echo ""
echo "Phase 4: Throughput (${N_THROUGHPUT_SEC}s window, health endpoint)..."

for c in $CONCURRENCIES; do
  # Go
  go_count=0
  go_start=$(date +%s%N)
  for worker in $(seq 1 $c); do
    (
      end=$(($(date +%s) + N_THROUGHPUT_SEC))
      count=0
      while [ $(date +%s) -lt $end ]; do
        curl -s -o /dev/null "$GO_URL/health" 2>/dev/null && count=$((count + 1))
      done
      echo $count
    ) &
  done
  go_results=$(wait; echo "")
  # Simpler approach: use xargs
  go_count=$(seq 1 $c | xargs -P $c -I{} sh -c "
    end=\$((SECONDS + $N_THROUGHPUT_SEC)); count=0
    while [ \$SECONDS -lt \$end ]; do
      curl -s -o /dev/null $GO_URL/health 2>/dev/null && count=\$((count + 1))
    done
    echo \$count
  " | paste -sd+ | bc)
  go_rps=$(echo "scale=1; $go_count / $N_THROUGHPUT_SEC" | bc)

  # Zig
  zig_count=$(seq 1 $c | xargs -P $c -I{} sh -c "
    end=\$((SECONDS + $N_THROUGHPUT_SEC)); count=0
    while [ \$SECONDS -lt \$end ]; do
      curl -s -o /dev/null $ZIG_URL/health 2>/dev/null && count=\$((count + 1))
    done
    echo \$count
  " | paste -sd+ | bc)
  zig_rps=$(echo "scale=1; $zig_count / $N_THROUGHPUT_SEC" | bc)

  echo "  c=$c: Go=${go_rps} rps  Zig=${zig_rps} rps"
done

# ── Summary ─────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  RESULTS (same-region, pure server overhead)"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "  Latency (seconds):"
echo "                       Go P50     Zig P50"
echo "  Health              ${go_p50}     ${zig_p50}"
echo "  Models (authed)     ${go_m_p50}     ${zig_m_p50}"
echo "  Chat (P50)          ${go_c_p50}     ${zig_c_p50}"
echo "  Chat (P99)          ${go_c_p99}     ${zig_c_p99}"
echo ""
echo "  Infrastructure:"
echo "  Go:  2 vCPU, 512Mi"
echo "  Zig: 1 vCPU, 512Mi"
echo ""
echo "  Note: Health/Models measure server overhead only."
echo "  Chat includes DeepSeek provider latency (constant for both)."
echo "══════════════════════════════════════════════════════════════"
'

# ── Mode selection ──────────────────────────────────────────────

MODE="${1:-local}"

if [ "$MODE" = "--print" ]; then
  # Just print the script for pasting into Cloud Shell
  echo "# Paste this into Cloud Shell or a europe-west1 VM:"
  echo "$BENCH_SCRIPT" | \
    sed "s|__GO_KEY__|${QAI_API_KEY:-PASTE_YOUR_GO_KEY}|g" | \
    sed "s|__ZIG_KEY__|${ZIG_API_KEY:-PASTE_YOUR_ZIG_KEY}|g"
  exit 0
fi

if [ "$MODE" = "--vm" ]; then
  echo "→ Creating temporary VM in $ZONE..."

  # Create a small VM
  gcloud compute instances create "$VM_NAME" \
    --project="$PROJECT" \
    --zone="$ZONE" \
    --machine-type=e2-medium \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --scopes=cloud-platform \
    --quiet 2>&1 | tail -2

  echo "→ Waiting for VM to be ready..."
  sleep 15

  # Upload and run the benchmark
  SCRIPT_FILE=$(mktemp)
  echo "$BENCH_SCRIPT" | \
    sed "s|__GO_KEY__|${QAI_API_KEY:-}|g" | \
    sed "s|__ZIG_KEY__|qai_k_claudetest_a4eba07117597770961a4606b9ce8127|g" > "$SCRIPT_FILE"
  chmod +x "$SCRIPT_FILE"

  echo "→ Uploading benchmark script..."
  gcloud compute scp "$SCRIPT_FILE" "${VM_NAME}:/tmp/bench.sh" \
    --project="$PROJECT" --zone="$ZONE" --quiet 2>/dev/null

  echo "→ Running benchmark on VM in $ZONE..."
  echo ""
  gcloud compute ssh "$VM_NAME" \
    --project="$PROJECT" --zone="$ZONE" \
    --command="bash /tmp/bench.sh" 2>/dev/null

  echo ""
  echo "→ Cleaning up VM..."
  gcloud compute instances delete "$VM_NAME" \
    --project="$PROJECT" --zone="$ZONE" --quiet 2>/dev/null

  rm -f "$SCRIPT_FILE"
  echo "✓ VM deleted"
  exit 0
fi

# Default: run locally (from Spain)
echo "Running benchmark from local machine (includes network latency)..."
echo "For same-region results, use: $0 --vm"
echo ""
BENCH_SCRIPT_FINAL=$(echo "$BENCH_SCRIPT" | \
  sed "s|__GO_KEY__|${QAI_API_KEY:-}|g" | \
  sed "s|__ZIG_KEY__|qai_k_claudetest_a4eba07117597770961a4606b9ce8127|g")
eval "$BENCH_SCRIPT_FINAL"
