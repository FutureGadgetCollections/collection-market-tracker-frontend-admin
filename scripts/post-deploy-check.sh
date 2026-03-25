#!/usr/bin/env bash
# post-deploy-check.sh — Fast smoke test after deploying collection-market-tracker
# Verifies the new revision is live, the API responds, and key read endpoints work.
#
# Usage: bash scripts/post-deploy-check.sh
# Requires: gcloud (authenticated), curl
#
# Exits 0 on pass, 1 on any failure.

set -euo pipefail

PROJECT="future-gadget-labs-483502"
REGION="us-central1"
SERVICE="collection-market-tracker"
API_URL="https://collection-market-tracker-c2zyiz24hq-uc.a.run.app"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}PASS${RESET}  $1"; ((PASS++)) || true; }
fail() { echo -e "  ${RED}FAIL${RESET}  $1"; ((FAIL++)) || true; }

echo -e "\n${BOLD}Post-Deploy Smoke Test — ${SERVICE}${RESET}"
echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

gcloud config set project "$PROJECT" --quiet 2>/dev/null

# ── 1. Cloud Run revision is ready and serving 100% traffic ──────────────────
echo -e "\n${BOLD}1. Revision status${RESET}"

SVC_JSON=$(gcloud run services describe "$SERVICE" \
  --region="$REGION" --project="$PROJECT" \
  --format="json(status.conditions,status.traffic,status.observedGeneration,spec.template.metadata.name)" \
  2>/dev/null)

READY_STATUS=$(echo "$SVC_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for c in d.get('status', {}).get('conditions', []):
    if c.get('type') == 'Ready':
        print(c.get('status', ''))
        break
" 2>/dev/null || true)

if [[ "$READY_STATUS" == "True" ]]; then
  pass "Service is Ready"
else
  fail "Service is NOT Ready (status=$READY_STATUS)"
fi

REVISION=$(gcloud run services describe "$SERVICE" \
  --region="$REGION" --project="$PROJECT" \
  --format="value(status.traffic[0].revisionName)" 2>/dev/null)
TRAFFIC_PCT=$(gcloud run services describe "$SERVICE" \
  --region="$REGION" --project="$PROJECT" \
  --format="value(status.traffic[0].percent)" 2>/dev/null)

if [[ "$TRAFFIC_PCT" == "100" ]]; then
  pass "Revision $REVISION is serving 100% of traffic"
else
  fail "Traffic split unexpected: $REVISION at ${TRAFFIC_PCT}%"
fi

# ── 2. Health endpoint ────────────────────────────────────────────────────────
echo -e "\n${BOLD}2. Health endpoint${RESET}"

HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${API_URL}/health" 2>/dev/null || echo "000")
if [[ "$HTTP" == "200" ]]; then
  pass "GET /health → $HTTP"
else
  fail "GET /health → $HTTP (expected 200)"
fi

# ── 3. Info endpoint returns expected config ──────────────────────────────────
echo -e "\n${BOLD}3. Config sanity (/info)${RESET}"

INFO=$(curl -s --max-time 10 "${API_URL}/info" 2>/dev/null || true)
for KEY in bq_project catalog_dataset gcs_bucket; do
  if echo "$INFO" | grep -q "\"$KEY\""; then
    pass "/info contains $KEY"
  else
    fail "/info missing $KEY (got: $INFO)"
  fi
done

# ── 4. Public read endpoints return 200 and non-empty JSON arrays ─────────────
echo -e "\n${BOLD}4. Public read endpoints${RESET}"

for ENDPOINT in /sealed-products /single-cards /set-pull-rates; do
  RESPONSE=$(curl -s --max-time 15 "${API_URL}${ENDPOINT}" 2>/dev/null || true)
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "${API_URL}${ENDPOINT}" 2>/dev/null || echo "000")

  if [[ "$HTTP" != "200" ]]; then
    fail "GET $ENDPOINT → $HTTP (expected 200)"
    continue
  fi

  # Check it's a non-empty JSON array
  COUNT=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo "0")
  if (( COUNT > 0 )); then
    pass "GET $ENDPOINT → 200 ($COUNT records)"
  else
    fail "GET $ENDPOINT → 200 but returned empty array or invalid JSON"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}─────────────────────────────────────────────────────${RESET}"
echo -e "${BOLD}Summary${RESET}"
echo -e "  ${GREEN}PASS${RESET}  $PASS"
echo -e "  ${RED}FAIL${RESET}  $FAIL"
echo ""

if (( FAIL > 0 )); then
  echo -e "${RED}Post-deploy check FAILED — $FAIL issue(s). Consider rolling back.${RESET}"
  echo -e "  Roll back: gcloud run services update-traffic $SERVICE --to-revisions=PREV_REVISION=100 --region=$REGION"
  exit 1
else
  echo -e "${GREEN}All checks passed — deploy looks good.${RESET}"
  exit 0
fi
