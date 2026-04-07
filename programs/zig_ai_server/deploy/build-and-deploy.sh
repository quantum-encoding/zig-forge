#!/bin/bash
# Build and deploy zig-ai-server to Cloud Run
# Extracts only required files into a temp context to avoid uploading the monorepo.
#
# Usage: ./deploy/build-and-deploy.sh [--region europe-west1]

set -euo pipefail

PROJECT="metatron-cloud-prod-v1"
SERVICE="zig-ai-server"
REGION="${1:-europe-west1}"
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

echo "=== Creating minimal build context ==="
BUILD_CTX=$(mktemp -d)
trap "rm -rf ${BUILD_CTX}" EXIT

# Copy only what the Dockerfile needs
mkdir -p "${BUILD_CTX}/programs/http_sentinel"
mkdir -p "${BUILD_CTX}/programs/zig_ai_server"
mkdir -p "${BUILD_CTX}/programs/gcp_auth"

# http_sentinel (dependency)
cp -r "${REPO_ROOT}/programs/http_sentinel/src" "${BUILD_CTX}/programs/http_sentinel/src"
cp "${REPO_ROOT}/programs/http_sentinel/build.zig" "${BUILD_CTX}/programs/http_sentinel/"
cp "${REPO_ROOT}/programs/http_sentinel/build.zig.zon" "${BUILD_CTX}/programs/http_sentinel/"

# gcp_auth (dependency)
cp -r "${REPO_ROOT}/programs/gcp_auth/src" "${BUILD_CTX}/programs/gcp_auth/src"
cp "${REPO_ROOT}/programs/gcp_auth/build.zig" "${BUILD_CTX}/programs/gcp_auth/"
cp "${REPO_ROOT}/programs/gcp_auth/build.zig.zon" "${BUILD_CTX}/programs/gcp_auth/"

# zig_ai_server
cp -r "${REPO_ROOT}/programs/zig_ai_server/src" "${BUILD_CTX}/programs/zig_ai_server/src"
cp -r "${REPO_ROOT}/programs/zig_ai_server/data" "${BUILD_CTX}/programs/zig_ai_server/data"
cp "${REPO_ROOT}/programs/zig_ai_server/build.zig" "${BUILD_CTX}/programs/zig_ai_server/"
cp "${REPO_ROOT}/programs/zig_ai_server/build.zig.zon" "${BUILD_CTX}/programs/zig_ai_server/"

# Dockerfile
cp "${REPO_ROOT}/programs/zig_ai_server/Dockerfile" "${BUILD_CTX}/"

echo "Build context: $(du -sh ${BUILD_CTX} | awk '{print $1}')"
echo "Files: $(find ${BUILD_CTX} -type f | wc -l | tr -d ' ')"

echo "=== Submitting to Cloud Build ==="
gcloud builds submit "${BUILD_CTX}" \
    --project="${PROJECT}" \
    --tag="gcr.io/${PROJECT}/${SERVICE}:latest" \
    --timeout=600s \
    --machine-type=E2_HIGHCPU_8

echo "=== Deploying to Cloud Run ==="
gcloud run deploy "${SERVICE}" \
    --project="${PROJECT}" \
    --region="${REGION}" \
    --image="gcr.io/${PROJECT}/${SERVICE}:latest" \
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

URL=$(gcloud run services describe "${SERVICE}" \
    --project="${PROJECT}" \
    --region="${REGION}" \
    --format="value(status.url)")

echo ""
echo "=== Deployed ==="
echo "URL: ${URL}"
echo "Health: curl ${URL}/health"
echo ""
echo "Custom domain setup:"
echo "  gcloud run domain-mappings create --service=${SERVICE} --domain=api.cosmicduck.dev --region=${REGION} --project=${PROJECT}"
echo "  Then CNAME api.cosmicduck.dev → ghs.googlehosted.com in Cloudflare"
