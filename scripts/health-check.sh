#!/usr/bin/env bash
# health-check.sh — Full system health check for collection-market-tracker
# Run directly or ask Claude to execute it to verify all jobs and services.
#
# Usage: bash scripts/health-check.sh
# Requires: gcloud (authenticated), curl, bq (for BQ check)

set -euo pipefail

PROJECT="future-gadget-labs-483502"
REGION="us-central1"
API_URL="https://collection-market-tracker-c2zyiz24hq-uc.a.run.app"
GCS_BUCKET="gs://collection-tracker-data"

# Max acceptable age in seconds for each file type
# Catalog files only update on API mutations — 72h gives a full day of slack
MAX_AGE_CATALOG=$((72 * 3600))   # 72 hours
MAX_AGE_PRICES=$((8 * 86400))    # 8 days (weekly sync)

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "  ${GREEN}PASS${RESET}  $1"; ((PASS++)) || true; }
fail() { echo -e "  ${RED}FAIL${RESET}  $1"; ((FAIL++)) || true; }
warn() { echo -e "  ${YELLOW}WARN${RESET}  $1"; ((WARN++)) || true; }
section() { echo -e "\n${BOLD}$1${RESET}"; }

# Check Cloud Run job execution: pass/warn/fail based on COMPLETE count vs total tasks.
# $1 = job name, $2 = "today" to require same-day run, anything else for any recent run
check_job_execution() {
  local JOB="$1" REQUIRE_TODAY="${2:-}"
  local EXEC_OUT EXEC_NAME EXEC_TIME COMPLETE_COUNT TOTAL_COUNT

  EXEC_OUT=$(gcloud run jobs executions list \
    --job="$JOB" --region="$REGION" --limit=1 \
    --format="csv[no-heading](name,completionTime,status.completedCount,spec.taskCount)" \
    2>/dev/null || true)

  if [[ -z "$EXEC_OUT" ]]; then
    echo "__NOEXEC__"
    return
  fi

  EXEC_NAME=$(echo "$EXEC_OUT" | cut -d',' -f1)
  EXEC_TIME=$(echo "$EXEC_OUT" | cut -d',' -f2)
  COMPLETE_COUNT=$(echo "$EXEC_OUT" | cut -d',' -f3)
  TOTAL_COUNT=$(echo "$EXEC_OUT" | cut -d',' -f4)

  # Job still running — completion time not yet set
  if [[ -z "$EXEC_TIME" ]]; then
    echo "__RUNNING__ $EXEC_NAME"
    return
  fi

  if [[ "$COMPLETE_COUNT" == "$TOTAL_COUNT" && "$TOTAL_COUNT" -ge 1 ]]; then
    echo "__SUCCESS__ $EXEC_NAME ($EXEC_TIME)"
  else
    echo "__FAILED__ $EXEC_NAME ($EXEC_TIME)"
  fi
}

now_epoch() { date +%s; }

gcs_epoch() {
  local ts="$1"
  ts="${ts%Z}"
  ts="${ts/T/ }"
  date -d "$ts UTC" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$ts" +%s 2>/dev/null || echo 0
}

age_str() {
  local secs=$1
  if (( secs < 3600 )); then echo "$((secs / 60))m ago"
  elif (( secs < 86400 )); then echo "$((secs / 3600))h ago"
  else echo "$((secs / 86400))d ago"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Collection Market Tracker — System Health Check${RESET}"
echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Project: $PROJECT"

gcloud config set project "$PROJECT" --quiet 2>/dev/null

# ─────────────────────────────────────────────────────────────────────────────
section "1. Daily Data Sync (collection-showcase-data-sync)"

RESULT=$(check_job_execution "collection-showcase-data-sync")
EXEC_LABEL="${RESULT#* }"
if [[ "$RESULT" == "__NOEXEC__" ]]; then
  fail "No executions found for collection-showcase-data-sync"
elif [[ "$RESULT" == __RUNNING__* ]]; then
  warn "collection-showcase-data-sync is currently running: $EXEC_LABEL"
elif [[ "$RESULT" == __SUCCESS__* ]]; then
  pass "Last execution succeeded: $EXEC_LABEL"
else
  fail "Last execution FAILED: $EXEC_LABEL"
  EXEC_NAME=$(echo "$EXEC_LABEL" | awk '{print $1}')
  echo -e "       Fetching error logs..."
  gcloud logging read \
    "resource.type=cloud_run_job AND labels.\"run.googleapis.com/execution_name\"=${EXEC_NAME}" \
    --limit=10 --format="value(timestamp,textPayload)" \
    --project="$PROJECT" 2>/dev/null | grep -v '^$' | head -10 | sed 's/^/         /'
fi

# ─────────────────────────────────────────────────────────────────────────────
section "2. GCS Data Files (gs://collection-tracker-data/data/)"

NOW=$(now_epoch)
GCS_LS=$(gcloud storage ls -l "${GCS_BUCKET}/data/" 2>/dev/null || true)

# Core files — always expected (FAIL if missing or stale)
declare -A CORE_FILES=(
  ["data/sealed-products.json"]=$MAX_AGE_CATALOG
  ["data/single-cards.json"]=$MAX_AGE_CATALOG
  ["data/set-pull-rates.json"]=$MAX_AGE_CATALOG
  ["data/tcgplayer-latest-prices.json"]=$MAX_AGE_PRICES
  ["data/tcgplayer-price-history.json"]=$MAX_AGE_PRICES
)

for FILE in "${!CORE_FILES[@]}"; do
  MAX="${CORE_FILES[$FILE]}"
  ROW=$(echo "$GCS_LS" | grep "$FILE" || true)
  if [[ -z "$ROW" ]]; then
    fail "$FILE — NOT FOUND in GCS"
    continue
  fi
  TIMESTAMP=$(echo "$ROW" | awk '{print $2}')
  FILE_EPOCH=$(gcs_epoch "$TIMESTAMP")
  AGE=$(( NOW - FILE_EPOCH ))
  AGE_LABEL=$(age_str "$AGE")
  if (( AGE <= MAX )); then
    pass "$FILE — $AGE_LABEL"
  else
    MAX_LABEL=$(age_str "$MAX")
    fail "$FILE — $AGE_LABEL (max allowed: $MAX_LABEL)"
  fi
done

# Inventory files — only present after inventory mutations via the admin UI (WARN if missing)
for FILE in data/products.json data/transactions.json data/product-xirr.json data/portfolio-xirr.json; do
  ROW=$(echo "$GCS_LS" | grep "$FILE" || true)
  if [[ -z "$ROW" ]]; then
    warn "$FILE — not found (expected after first inventory mutation via admin UI)"
  else
    TIMESTAMP=$(echo "$ROW" | awk '{print $2}')
    FILE_EPOCH=$(gcs_epoch "$TIMESTAMP")
    AGE=$(( NOW - FILE_EPOCH ))
    pass "$FILE — $(age_str "$AGE")"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
section "3. GitHub Data Repo (collection-market-tracker-data)"

DATA_REPO="../collection-market-tracker-data"
if [[ -d "$DATA_REPO/.git" ]]; then
  pushd "$DATA_REPO" > /dev/null
  git fetch --quiet origin main 2>/dev/null || true

  LAST_COMMIT_MSG=$(git log -1 --format="%s" origin/main 2>/dev/null)
  LAST_COMMIT_EPOCH=$(git log -1 --format="%ct" origin/main 2>/dev/null)
  AGE=$(( NOW - LAST_COMMIT_EPOCH ))
  AGE_LABEL=$(age_str "$AGE")

  if (( AGE <= MAX_AGE_CATALOG )); then
    pass "Last commit: \"$LAST_COMMIT_MSG\" — $AGE_LABEL"
  else
    warn "Last commit: \"$LAST_COMMIT_MSG\" — $AGE_LABEL (may be stale if no recent edits)"
  fi

  # Core catalog + price files — check against remote tracking branch (no local pull needed)
  for F in sealed-products.json single-cards.json set-pull-rates.json tcgplayer-latest-prices.json; do
    if git show "origin/main:data/$F" > /dev/null 2>&1; then
      pass "data/$F present on GitHub"
    else
      fail "data/$F MISSING from GitHub"
    fi
  done

  # Price history — on GCS but GitHub push has historically been incomplete; WARN not FAIL
  if git show "origin/main:data/tcgplayer-price-history.json" > /dev/null 2>&1; then
    pass "data/tcgplayer-price-history.json present on GitHub"
  else
    warn "data/tcgplayer-price-history.json missing from GitHub (exists on GCS — trigger /sync/history to push)"
  fi

  # Inventory files — only present after first inventory mutations (WARN not FAIL)
  for F in products.json transactions.json product-xirr.json portfolio-xirr.json; do
    if git show "origin/main:data/$F" > /dev/null 2>&1; then
      pass "data/$F present on GitHub"
    else
      warn "data/$F not on GitHub (expected after first inventory mutation via admin UI)"
    fi
  done
  popd > /dev/null
else
  warn "Data repo not found at $DATA_REPO — skipping GitHub checks"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "4. Weekly Price Sync (tcgplayer-price-sync)"

RESULT=$(check_job_execution "tcgplayer-price-sync")
EXEC_LABEL="${RESULT#* }"
if [[ "$RESULT" == "__NOEXEC__" ]]; then
  warn "No executions found for tcgplayer-price-sync (runs Mondays 10:00 UTC)"
elif [[ "$RESULT" == __RUNNING__* ]]; then
  warn "tcgplayer-price-sync is currently running: $EXEC_LABEL"
elif [[ "$RESULT" == __SUCCESS__* ]]; then
  pass "Last execution succeeded: $EXEC_LABEL"
else
  fail "Last execution FAILED: $EXEC_LABEL"
  EXEC_NAME=$(echo "$EXEC_LABEL" | awk '{print $1}')
  echo -e "       Fetching error logs..."
  gcloud logging read \
    "resource.type=cloud_run_job AND labels.\"run.googleapis.com/execution_name\"=${EXEC_NAME}" \
    --limit=10 --format="value(timestamp,textPayload)" \
    --project="$PROJECT" 2>/dev/null | grep -v '^$' | head -10 | sed 's/^/         /'
fi

# ─────────────────────────────────────────────────────────────────────────────
section "5. Daily Price Scraper (tcgplayer-price-scraper)"

RESULT=$(check_job_execution "tcgplayer-price-scraper")
EXEC_LABEL="${RESULT#* }"
TODAY=$(date -u '+%Y-%m-%d')

if [[ "$RESULT" == "__NOEXEC__" ]]; then
  SCHED_EXISTS=$(gcloud scheduler jobs describe tcgplayer-price-daily \
    --location="$REGION" --project="$PROJECT" --format="value(state)" 2>/dev/null || true)
  if [[ "$SCHED_EXISTS" == "ENABLED" ]]; then
    warn "No executions yet — scheduler is configured and will run at next 08:00 UTC"
  else
    fail "No executions found and scheduler tcgplayer-price-daily is missing or disabled"
  fi
elif [[ "$RESULT" == __RUNNING__* ]]; then
  pass "tcgplayer-price-scraper is currently running: $EXEC_LABEL"
elif [[ "$RESULT" == __SUCCESS__* ]]; then
  if [[ "$EXEC_LABEL" == *"$TODAY"* ]]; then
    pass "Ran and succeeded today: $EXEC_LABEL"
  else
    warn "Last run succeeded but NOT today: $EXEC_LABEL — may not have run yet"
  fi
else
  fail "Last execution FAILED: $EXEC_LABEL"
  EXEC_NAME=$(echo "$EXEC_LABEL" | awk '{print $1}')
  echo -e "       Fetching error logs..."
  gcloud logging read \
    "resource.type=cloud_run_job AND labels.\"run.googleapis.com/execution_name\"=${EXEC_NAME}" \
    --limit=15 --format="value(timestamp,textPayload)" \
    --project="$PROJECT" 2>/dev/null | grep -v '^$' | head -15 | sed 's/^/         /'
fi

# ─────────────────────────────────────────────────────────────────────────────
section "6. BigQuery — Yesterday's Price Data"

YESTERDAY=$(date -u -d 'yesterday' '+%Y-%m-%d' 2>/dev/null || date -u -v-1d '+%Y-%m-%d')

if command -v bq &>/dev/null; then
  BQ_RESULT=$(bq --quiet --project_id="$PROJECT" query --nouse_legacy_sql \
    "SELECT COUNT(*) as rows FROM \`${PROJECT}.market_data.tcgplayer_price_history\` WHERE date = '${YESTERDAY}'" \
    2>/dev/null | tail -1 | tr -d ' ' || true)

  if [[ "$BQ_RESULT" =~ ^[0-9]+$ ]]; then
    if (( BQ_RESULT > 0 )); then
      pass "market_data.tcgplayer_price_history has $BQ_RESULT rows for $YESTERDAY"
    else
      fail "market_data.tcgplayer_price_history has 0 rows for $YESTERDAY — price scraper may not have run"
    fi
  else
    warn "Could not parse BQ result ('$BQ_RESULT') — check manually in the BigQuery console"
  fi
else
  warn "bq CLI not available — check manually: SELECT COUNT(*) FROM \`${PROJECT}.market_data.tcgplayer_price_history\` WHERE date = '${YESTERDAY}'"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "7. API Service (collection-market-tracker)"

SVC_OUT=$(gcloud run services describe collection-market-tracker \
  --region="$REGION" \
  --format="csv[no-heading](status.conditions[0].type,status.conditions[0].status)" \
  2>/dev/null)
COND_TYPE=$(echo "$SVC_OUT" | cut -d',' -f1)
COND_STATUS=$(echo "$SVC_OUT" | cut -d',' -f2)

if [[ "$COND_TYPE" == "Ready" && "$COND_STATUS" == "True" ]]; then
  pass "Cloud Run service is Ready"
else
  fail "Cloud Run service is NOT ready ($COND_TYPE=$COND_STATUS)"
fi

# Note: /healthz is intercepted by Cloud Run infrastructure. Use /health.
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${API_URL}/health" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" ]]; then
  pass "/health returned $HTTP_CODE"
else
  fail "/health returned $HTTP_CODE (expected 200)"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "8. Cloud Schedulers"

for JOB in collection-showcase-daily-sync sync-tcgplayer-prices-weekly tcgplayer-price-daily; do
  SCHED_OUT=$(gcloud scheduler jobs describe "$JOB" \
    --location="$REGION" \
    --format="value(state,schedule)" \
    --project="$PROJECT" 2>/dev/null || true)
  if [[ -z "$SCHED_OUT" ]]; then
    fail "Scheduler $JOB — NOT FOUND"
  else
    STATE=$(echo "$SCHED_OUT" | cut -f1)
    SCHED=$(echo "$SCHED_OUT" | cut -f2)
    if [[ "$STATE" == "ENABLED" ]]; then
      pass "Scheduler $JOB — ENABLED ($SCHED)"
    else
      fail "Scheduler $JOB — $STATE"
    fi
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}─────────────────────────────────────────────────────${RESET}"
echo -e "${BOLD}Summary${RESET}"
echo -e "  ${GREEN}PASS${RESET}  $PASS"
echo -e "  ${YELLOW}WARN${RESET}  $WARN"
echo -e "  ${RED}FAIL${RESET}  $FAIL"
echo ""

if (( FAIL > 0 )); then
  echo -e "${RED}Health check FAILED — $FAIL issue(s) require attention.${RESET}"
  exit 1
elif (( WARN > 0 )); then
  echo -e "${YELLOW}Health check passed with $WARN warning(s).${RESET}"
  exit 0
else
  echo -e "${GREEN}All checks passed.${RESET}"
  exit 0
fi
