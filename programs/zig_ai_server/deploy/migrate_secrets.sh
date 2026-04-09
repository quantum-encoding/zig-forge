#!/bin/bash
# One-time migration: move API keys from env vars to GCP Secret Manager.
#
# Run this ONCE with admin credentials (not the qai-local-dev SA, which
# doesn't have Secret Manager permissions):
#
#   gcloud auth login              # use your admin account
#   ./deploy/migrate_secrets.sh
#
# After running, the deploy script will use --set-secrets instead of
# --set-env-vars. Secrets can be rotated without redeploying.
#
# Prerequisites (one-time setup):
# 1. Enable Secret Manager API:
#      gcloud services enable secretmanager.googleapis.com --project=metatron-cloud-prod-v1
# 2. Grant the Cloud Run runtime SA access to secrets:
#      gcloud projects add-iam-policy-binding metatron-cloud-prod-v1 \
#        --member="serviceAccount:967904281608-compute@developer.gserviceaccount.com" \
#        --role="roles/secretmanager.secretAccessor"

set -euo pipefail

PROJECT="metatron-cloud-prod-v1"

# Read values from local env (same source deploy.sh currently uses)
declare -A SECRETS=(
  [qai-bootstrap-key]="${QAI_BOOTSTRAP_KEY:-}"
  [anthropic-api-key]="${ANTHROPIC_API_KEY:-}"
  [deepseek-api-key]="${DEEPSEEK_API_KEY:-}"
  [gemini-api-key]="${GEMINI_API_KEY:-}"
  [xai-api-key]="${XAI_API_KEY:-}"
  [openai-api-key]="${OPENAI_API_KEY:-}"
)

echo "╔══════════════════════════════════════╗"
echo "║  Secret Manager migration           ║"
echo "╚══════════════════════════════════════╝"
echo ""

# Verify each env var is set
missing=()
for name in "${!SECRETS[@]}"; do
  if [ -z "${SECRETS[$name]}" ]; then
    missing+=("$name")
  fi
done

if [ ${#missing[@]} -gt 0 ]; then
  echo "✗ Missing env vars:"
  for m in "${missing[@]}"; do
    echo "    $m"
  done
  echo ""
  echo "Set all required env vars before running this script."
  exit 1
fi

# Check Secret Manager API is enabled
if ! gcloud services list --enabled --project="$PROJECT" --filter="name:secretmanager.googleapis.com" --format="value(name)" | grep -q secretmanager; then
  echo "→ Enabling Secret Manager API..."
  gcloud services enable secretmanager.googleapis.com --project="$PROJECT"
fi

# Create or update each secret
for secret_name in "${!SECRETS[@]}"; do
  value="${SECRETS[$secret_name]}"
  echo "→ $secret_name"

  if gcloud secrets describe "$secret_name" --project="$PROJECT" > /dev/null 2>&1; then
    # Secret exists — add a new version
    echo "$value" | gcloud secrets versions add "$secret_name" \
      --project="$PROJECT" \
      --data-file=- > /dev/null
    echo "  ✓ updated (new version)"
  else
    # Create new secret
    echo "$value" | gcloud secrets create "$secret_name" \
      --project="$PROJECT" \
      --replication-policy="automatic" \
      --data-file=- > /dev/null
    echo "  ✓ created"
  fi
done

# Grant Cloud Run runtime SA access
SA="967904281608-compute@developer.gserviceaccount.com"
echo ""
echo "→ Granting $SA access to secrets..."
for secret_name in "${!SECRETS[@]}"; do
  gcloud secrets add-iam-policy-binding "$secret_name" \
    --project="$PROJECT" \
    --member="serviceAccount:$SA" \
    --role="roles/secretmanager.secretAccessor" \
    --condition=None \
    --quiet > /dev/null 2>&1 || true
done
echo "✓ IAM bindings updated"

echo ""
echo "══════════════════════════════════════"
echo "✓ Secret Manager migration complete"
echo ""
echo "Next steps:"
echo "  1. Redeploy with: ./deploy/deploy.sh"
echo "  2. The deploy script now uses --set-secrets instead of --set-env-vars"
echo "  3. To rotate a secret: echo 'new-value' | gcloud secrets versions add <name> --project=$PROJECT --data-file=-"
echo "══════════════════════════════════════"
