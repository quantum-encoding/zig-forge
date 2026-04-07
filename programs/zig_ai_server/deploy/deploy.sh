#!/bin/bash
# Deploy zig-ai-server to Cloud Run.
#
# Usage:
#   ./deploy/deploy.sh           # async build, poll, deploy
#   ./deploy/deploy.sh --quick   # deploy latest image (skip build)
#   ./deploy/deploy.sh --dry-run # build only, don't deploy
#   ./deploy/deploy.sh --status  # check last build status

set -euo pipefail

PROJECT="metatron-cloud-prod-v1"
REGION="europe-west1"
SERVICE="zig-ai-server"
IMAGE="gcr.io/${PROJECT}/${SERVICE}:latest"
BUILD_ID_FILE="/tmp/zig-ai-server-build-id"
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

QUICK=false
DRY_RUN=false
STATUS_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=true ;;
    --dry-run) DRY_RUN=true ;;
    --status) STATUS_ONLY=true ;;
  esac
done

# ── Status check ──
if [ "$STATUS_ONLY" = true ]; then
  if [ -f "$BUILD_ID_FILE" ]; then
    BUILD_ID=$(cat "$BUILD_ID_FILE")
    STATUS=$(gcloud builds describe "$BUILD_ID" --project="$PROJECT" --format="value(status)" 2>/dev/null || echo "UNKNOWN")
    echo "Build $BUILD_ID: $STATUS"
  else
    echo "No pending build."
  fi
  exit 0
fi

echo "╔══════════════════════════════════════╗"
echo "║  zig-ai-server deploy               ║"
echo "╚══════════════════════════════════════╝"
echo ""

# 0. Local build check (fast, catches errors before cloud build).
echo "→ Local build check..."
cd "${REPO_ROOT}/programs/zig_ai_server"
if ! zig build 2>&1; then
  echo "✗ Local build failed. Fix errors before deploying."
  exit 1
fi
echo "✓ Local build OK"
cd "$REPO_ROOT"

if [ "$QUICK" = false ]; then
  # 1. Create minimal build context (don't upload the whole monorepo).
  echo ""
  echo "→ Creating build context..."
  BUILD_CTX=$(mktemp -d)
  trap "rm -rf ${BUILD_CTX}" EXIT

  mkdir -p "${BUILD_CTX}/programs/http_sentinel"
  mkdir -p "${BUILD_CTX}/programs/zig_ai_server"
  mkdir -p "${BUILD_CTX}/programs/gcp_auth"

  cp -r "${REPO_ROOT}/programs/http_sentinel/src" "${BUILD_CTX}/programs/http_sentinel/src"
  cp "${REPO_ROOT}/programs/http_sentinel/build.zig" "${BUILD_CTX}/programs/http_sentinel/"
  cp "${REPO_ROOT}/programs/http_sentinel/build.zig.zon" "${BUILD_CTX}/programs/http_sentinel/"

  cp -r "${REPO_ROOT}/programs/gcp_auth/src" "${BUILD_CTX}/programs/gcp_auth/src"
  cp "${REPO_ROOT}/programs/gcp_auth/build.zig" "${BUILD_CTX}/programs/gcp_auth/"
  cp "${REPO_ROOT}/programs/gcp_auth/build.zig.zon" "${BUILD_CTX}/programs/gcp_auth/"

  cp -r "${REPO_ROOT}/programs/zig_ai_server/src" "${BUILD_CTX}/programs/zig_ai_server/src"
  cp -r "${REPO_ROOT}/programs/zig_ai_server/data" "${BUILD_CTX}/programs/zig_ai_server/data"
  cp "${REPO_ROOT}/programs/zig_ai_server/build.zig" "${BUILD_CTX}/programs/zig_ai_server/"
  cp "${REPO_ROOT}/programs/zig_ai_server/build.zig.zon" "${BUILD_CTX}/programs/zig_ai_server/"

  cp "${REPO_ROOT}/programs/zig_ai_server/Dockerfile" "${BUILD_CTX}/"

  CTX_SIZE=$(du -sh "${BUILD_CTX}" | awk '{print $1}')
  CTX_FILES=$(find "${BUILD_CTX}" -type f | wc -l | tr -d ' ')
  echo "✓ Context: ${CTX_SIZE}, ${CTX_FILES} files"

  # 2. Submit cloud build asynchronously.
  echo ""
  echo "→ Submitting Cloud Build..."
  SUBMIT_OUTPUT=$(gcloud builds submit "${BUILD_CTX}" \
    --tag "$IMAGE" \
    --project="$PROJECT" \
    --machine-type=E2_HIGHCPU_8 \
    --timeout=600s \
    --async \
    --quiet 2>&1)

  BUILD_ID=$(echo "$SUBMIT_OUTPUT" | grep -oE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' | head -1)

  if [ -z "$BUILD_ID" ]; then
    echo "✗ Failed to submit build:"
    echo "$SUBMIT_OUTPUT" | tail -5
    exit 1
  fi

  echo "$BUILD_ID" > "$BUILD_ID_FILE"
  echo "✓ Build submitted: $BUILD_ID"

  # 3. Poll for completion.
  echo "→ Waiting for build..."
  POLL_INTERVAL=15
  MAX_POLLS=40  # 10 minutes
  for i in $(seq 1 $MAX_POLLS); do
    sleep $POLL_INTERVAL
    STATUS=$(gcloud builds describe "$BUILD_ID" --project="$PROJECT" --format="value(status)" 2>/dev/null || echo "UNKNOWN")

    case "$STATUS" in
      SUCCESS)
        echo ""
        echo "✓ Cloud Build succeeded (${i}x${POLL_INTERVAL}s)"
        rm -f "$BUILD_ID_FILE"
        break
        ;;
      FAILURE|INTERNAL_ERROR|TIMEOUT|CANCELLED)
        echo ""
        echo "✗ Cloud Build $STATUS"
        gcloud builds log "$BUILD_ID" --project="$PROJECT" 2>/dev/null | tail -15
        rm -f "$BUILD_ID_FILE"
        exit 1
        ;;
      QUEUED|WORKING)
        printf "\r  [%02d/%02d] %s..." "$i" "$MAX_POLLS" "$STATUS"
        ;;
      *)
        printf "\r  [%02d/%02d] %s..." "$i" "$MAX_POLLS" "$STATUS"
        ;;
    esac
  done

  if [ -f "$BUILD_ID_FILE" ]; then
    echo ""
    echo "⚠ Build still running after $((MAX_POLLS * POLL_INTERVAL))s"
    echo "  Check: ./deploy/deploy.sh --status"
    exit 1
  fi
fi

if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "→ Dry run — skipping deploy"
  exit 0
fi

# 4. Deploy to Cloud Run.
echo ""
echo "→ Deploying to Cloud Run..."
DEPLOY_OUTPUT=$(gcloud run deploy "$SERVICE" \
  --image "$IMAGE" \
  --region "$REGION" \
  --project "$PROJECT" \
  --platform=managed \
  --allow-unauthenticated \
  --port=8080 \
  --cpu=1 \
  --memory=512Mi \
  --min-instances=0 \
  --max-instances=10 \
  --concurrency=80 \
  --timeout=300s \
  --set-env-vars="QAI_BOOTSTRAP_KEY=${QAI_BOOTSTRAP_KEY:-}" \
  --set-env-vars="ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}" \
  --set-env-vars="DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY:-}" \
  --set-env-vars="GEMINI_API_KEY=${GEMINI_API_KEY:-}" \
  --set-env-vars="XAI_API_KEY=${XAI_API_KEY:-}" \
  --set-env-vars="OPENAI_API_KEY=${OPENAI_API_KEY:-}" \
  --quiet 2>&1)

DEPLOY_STATUS=$?
if [ $DEPLOY_STATUS -ne 0 ]; then
  echo "✗ Deploy failed:"
  echo "$DEPLOY_OUTPUT" | tail -10
  exit 1
fi

REVISION=$(echo "$DEPLOY_OUTPUT" | grep -o 'zig-ai-server-[0-9]*-[a-z]*' | head -1)
echo "✓ Deployed: ${REVISION:-latest}"

# 5. Health check.
echo ""
URL=$(gcloud run services describe "$SERVICE" \
  --project="$PROJECT" \
  --region="$REGION" \
  --format="value(status.url)" 2>/dev/null)

echo "→ Health check ($URL)..."
sleep 5
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "${URL}/health" 2>/dev/null)
if [ "$HEALTH" = "200" ]; then
  echo "✓ Health OK (200)"
else
  echo "⚠ Health check returned $HEALTH (may still be cold-starting)"
fi

# 6. Done.
echo ""
echo "══════════════════════════════════════"
echo "✓ Deploy complete"
echo "  Service: ${URL}"
echo "  Domain: https://api.cosmicduck.dev"
echo "  Revision: ${REVISION:-latest}"
echo ""
echo "  Custom domain (one-time):"
echo "    gcloud run domain-mappings create --service=${SERVICE} --domain=api.cosmicduck.dev --region=${REGION} --project=${PROJECT}"
echo "    Then CNAME api.cosmicduck.dev → ghs.googlehosted.com in Cloudflare"
echo "══════════════════════════════════════"
