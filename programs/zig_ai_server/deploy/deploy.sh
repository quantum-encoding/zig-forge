#!/bin/bash
# Deploy zig-ai-server to Cloud Run
# Usage: ./deploy/deploy.sh [--region europe-west1]

set -euo pipefail

PROJECT="metatron-cloud-prod-v1"
SERVICE="zig-ai-server"
REGION="${1:-europe-west1}"
IMAGE="gcr.io/${PROJECT}/${SERVICE}"

echo "=== Building Docker image ==="
# Build from repo root (needs both http_sentinel and zig_ai_server)
cd "$(dirname "$0")/../../.."
docker build \
    -f programs/zig_ai_server/Dockerfile \
    -t "${IMAGE}:latest" \
    .

echo "=== Pushing to GCR ==="
docker push "${IMAGE}:latest"

echo "=== Deploying to Cloud Run (${REGION}) ==="
gcloud run deploy "${SERVICE}" \
    --project="${PROJECT}" \
    --region="${REGION}" \
    --image="${IMAGE}:latest" \
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
    --set-env-vars="OPENAI_API_KEY=${OPENAI_API_KEY:-}"

echo "=== Getting service URL ==="
URL=$(gcloud run services describe "${SERVICE}" \
    --project="${PROJECT}" \
    --region="${REGION}" \
    --format="value(status.url)")
echo "Service URL: ${URL}"

echo ""
echo "=== Setting up custom domain ==="
echo "To map api.cosmicduck.dev:"
echo "  gcloud run domain-mappings create --service=${SERVICE} --domain=api.cosmicduck.dev --region=${REGION}"
echo ""
echo "Then in Cloudflare, add a CNAME record:"
echo "  api.cosmicduck.dev → ghs.googlehosted.com"
echo ""
echo "=== Done ==="
echo "Test: curl ${URL}/health"
