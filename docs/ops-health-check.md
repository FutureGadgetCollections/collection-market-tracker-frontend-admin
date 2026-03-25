# Ops Health Check Runbook

Use this runbook to verify all scheduled jobs and the API service are healthy.

## Scripts

### Health Check (ops monitoring)

**Ask Claude to run it:**
> "Can you check if the jobs were all successful?"

Claude will execute `scripts/health-check.sh`, interpret the results, and report any failures or warnings — no manual steps required.

```bash
bash scripts/health-check.sh
```

Checks all jobs, GCS/GitHub data files, BQ price data, API service, and schedulers. Exits non-zero on any failure.

### Post-Deploy Validation

After deploying a new version of the API service, run:

```bash
bash scripts/post-deploy-check.sh
```

Verifies the new revision is serving 100% of traffic, `/health` returns 200, config is sane, and all three public read endpoints return non-empty data. Prints a rollback command if anything fails. Completes in ~10 seconds.

> **Project:** `future-gadget-labs-483502`
> **Region:** `us-central1`

---

## What the Script Checks

| # | Check | Tool |
|---|-------|------|
| 1 | Daily data sync — last execution passed | `gcloud run jobs executions list` |
| 2 | GCS data files — all present and within max age | `gcloud storage ls -l` |
| 3 | GitHub data repo — all files present, recent commit | `git log` |
| 4 | Weekly price sync — last execution passed | `gcloud run jobs executions list` |
| 5 | Daily price scraper — ran today and passed | `gcloud run jobs executions list` |
| 6 | BigQuery — yesterday's rows in price history | `bq query` |
| 7 | API service — Ready and `/healthz` returns 200 | `gcloud run services describe` + `curl` |
| 8 | All Cloud Schedulers — ENABLED | `gcloud scheduler jobs describe` |
| 9 | Public frontend — GitHub Pages returns 200 | `curl` |

If any check fails, the script automatically fetches the relevant error logs.

---

## Manual Reference

The sections below document each check in detail for cases where you need to dig deeper than the script output.

> **Prerequisites:**
> ```bash
> gcloud config set project future-gadget-labs-483502
> ```

---

## 1. Daily Data Sync

**Job:** `collection-showcase-data-sync`
**Scheduler:** `collection-showcase-daily-sync` — daily at **03:00 UTC**
**Purpose:** Exports catalog + inventory data from BigQuery to GCS and GitHub.

### 1a. Check job execution

```bash
gcloud run jobs executions list \
  --job=collection-showcase-data-sync \
  --region=us-central1 \
  --limit=3
```

**Pass:** Most recent execution shows `COMPLETE: 1 / 1`.
**Fail:** Marked with `X` or `COMPLETE: 0 / 1`.

If failed, check logs (replace `<execution-name>` with the name from the output above):

```bash
gcloud logging read \
  "resource.type=cloud_run_job AND labels.\"run.googleapis.com/execution_name\"=<execution-name>" \
  --limit=50 \
  --format="value(timestamp,severity,textPayload)" \
  --project=future-gadget-labs-483502
```

### 1b. Verify GCS files are fresh

```bash
gcloud storage ls -l gs://collection-tracker-data/data/
```

**Expected files and acceptable staleness:**

| File | Max Age |
|------|---------|
| `data/sealed-products.json` | 48 h (only changes on catalog edits) |
| `data/single-cards.json` | 48 h |
| `data/set-pull-rates.json` | 48 h |
| `data/products.json` | 48 h |
| `data/transactions.json` | 48 h |
| `data/product-xirr.json` | 48 h |
| `data/portfolio-xirr.json` | 48 h |
| `data/tcgplayer-latest-prices.json` | 8 days (updated weekly) |
| `data/tcgplayer-price-history.json` | 8 days (updated weekly) |

**Pass:** All files present; timestamps within acceptable staleness.
**Fail:** Missing file, or catalog/inventory files not updated in >48 h despite no recent edits.

### 1c. Verify GitHub data repo is fresh

```bash
cd ../collection-market-tracker-data && git log --oneline -5
```

**Expected files in the data repo (`data/` directory):**

| File | Updated by |
|------|-----------|
| `data/sealed-products.json` | API mutation or `collection-showcase-data-sync` |
| `data/single-cards.json` | API mutation or `collection-showcase-data-sync` |
| `data/set-pull-rates.json` | API mutation or `collection-showcase-data-sync` |
| `data/products.json` | Inventory mutation or `collection-showcase-data-sync` |
| `data/transactions.json` | Inventory mutation or `collection-showcase-data-sync` |
| `data/product-xirr.json` | `/sync/xirr` or price sync |
| `data/portfolio-xirr.json` | `/sync/xirr` or price sync |
| `data/tcgplayer-latest-prices.json` | Weekly price sync or `/sync/prices` |
| `data/tcgplayer-price-history.json` | Weekly price sync or `/sync/history` |
| `schema/*.json` | Any of the above |

**Pass:** Recent `chore: sync data <timestamp>` commits present; timestamps consistent with GCS.
**Fail:** No recent commits, or commits older than 24 h with no catalog edits.

---

## 2. Weekly Price Sync

**Job:** `tcgplayer-price-sync`
**Scheduler:** `sync-tcgplayer-prices-weekly` — every **Monday at 10:00 UTC**
**Purpose:** Exports latest prices and full price history from BigQuery to GCS and GitHub.

### 2a. Check job execution

```bash
gcloud run jobs executions list \
  --job=tcgplayer-price-sync \
  --region=us-central1 \
  --limit=5
```

**Pass:** Most recent execution (within the last 8 days) shows `COMPLETE: 1 / 1`.
**Fail:** No recent executions, or marked with `X`.

If failed, check logs:

```bash
gcloud logging read \
  "resource.type=cloud_run_job AND labels.\"run.googleapis.com/execution_name\"=<execution-name>" \
  --limit=50 \
  --format="value(timestamp,severity,textPayload)" \
  --project=future-gadget-labs-483502
```

### 2b. Verify price files on GCS are fresh

```bash
gcloud storage ls -l gs://collection-tracker-data/data/tcgplayer-latest-prices.json
gcloud storage ls -l gs://collection-tracker-data/data/tcgplayer-price-history.json
```

**Pass:** Both files updated within the last 8 days (weekly job runs Mondays).

---

## 3. Daily Price Scraper

**Job:** `tcgplayer-price-scraper`
**Scheduler:** `tcgplayer-price-daily` — daily at **08:00 UTC**
**Purpose:** Scrapes TCGPlayer for market prices; writes to BigQuery `market_data.tcgplayer_price_history`.

### 3a. Check job execution

```bash
gcloud run jobs executions list \
  --job=tcgplayer-price-scraper \
  --region=us-central1 \
  --limit=3
```

**Pass:** Most recent execution shows `COMPLETE: 1 / 1` with a timestamp from today (after 08:00 UTC).
**Fail:** No execution today, marked with `X`, or `COMPLETE: 0 / 1`.

If failed, tail the logs:

```bash
gcloud logging read \
  "resource.type=cloud_run_job AND labels.\"run.googleapis.com/execution_name\"=<execution-name>" \
  --limit=100 \
  --format="value(timestamp,severity,textPayload)" \
  --project=future-gadget-labs-483502
```

Look for:
- `ERROR` or `exit(1)` lines indicating a scrape failure
- Playwright timeout errors
- BigQuery MERGE errors
- Products processed count (should match total catalog products with a `tcgplayer_id`)

### 3b. Verify yesterday's data in BigQuery

Run the following query in the [BigQuery console](https://console.cloud.google.com/bigquery?project=future-gadget-labs-483502):

```sql
-- Row count for yesterday — should match number of products with tcgplayer_id
SELECT
  date,
  COUNT(*) AS rows_written,
  COUNT(CASE WHEN market_price IS NOT NULL THEN 1 END) AS with_market_price
FROM `future-gadget-labs-483502.market_data.tcgplayer_price_history`
WHERE date = DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY)
GROUP BY date;
```

**Pass:** At least one row for yesterday; `rows_written` roughly matches the number of products with `tcgplayer_id` in the catalog.
**Fail:** Zero rows, or significantly fewer rows than expected (partial failure).

To check how many products should have been scraped:

```sql
SELECT
  COUNT(*) AS total_with_tcgplayer_id
FROM (
  SELECT tcgplayer_id FROM `future-gadget-labs-483502.catalog.sealed_products` WHERE tcgplayer_id IS NOT NULL
  UNION ALL
  SELECT tcgplayer_id FROM `future-gadget-labs-483502.catalog.single_cards` WHERE tcgplayer_id IS NOT NULL
);
```

**BigQuery tables and views impacted by this job:**

| Table / View | Type | Impact |
|---|---|---|
| `market_data.tcgplayer_price_history` | Table | Written daily via MERGE on `(tcgplayer_id, date)` |
| `market_data.latest_tcgplayer_prices` | View | Automatically reflects new rows (selects latest per `tcgplayer_id`) |
| `inventory.catalog_products` | View | Read-only by this job (provides `tcgplayer_id` list) |
| `catalog.sealed_products` | Table | Read-only by this job (provides `tcgplayer_id` list) |
| `catalog.single_cards` | Table | Read-only by this job (provides `tcgplayer_id` list) |

---

## 4. API Service Health

**Service:** `collection-market-tracker`
**Purpose:** REST API for CRUD and sync operations; always-on Cloud Run service.

### 4a. Check service status

```bash
gcloud run services describe collection-market-tracker \
  --region=us-central1 \
  --format="table(status.conditions[0].type,status.conditions[0].status,status.url)"
```

**Pass:** `Ready = True`.
**Fail:** `Ready = False` or any other condition.

### 4b. Hit the health endpoint

```bash
curl -s -o /dev/null -w "%{http_code}" \
  https://collection-market-tracker-c2zyiz24hq-uc.a.run.app/health
```

**Pass:** `200`.
**Fail:** Any non-200 response, or connection timeout.

> Note: `/healthz` is intercepted by Cloud Run's serving infrastructure and returns a Google 404 before reaching the app. Use `/health` instead.

### 4c. Check recent error rate (optional)

```bash
gcloud logging read \
  "resource.type=cloud_run_revision AND resource.labels.service_name=collection-market-tracker AND severity>=ERROR" \
  --limit=20 \
  --freshness=1d \
  --format="value(timestamp,severity,textPayload)" \
  --project=future-gadget-labs-483502
```

**Pass:** No errors, or only expected transient errors (e.g. unauthenticated requests).
**Fail:** Repeated 5xx errors, panic messages, or database connection failures.

---

## Quick Reference: All Scheduled Jobs

| Job | Scheduler | Schedule | Cloud Run Job |
|-----|-----------|----------|---------------|
| Daily data sync | `collection-showcase-daily-sync` | Daily 03:00 UTC | `collection-showcase-data-sync` |
| Weekly price sync | `sync-tcgplayer-prices-weekly` | Mondays 10:00 UTC | `tcgplayer-price-sync` |
| Daily price scraper | `tcgplayer-price-daily` | Daily 08:00 UTC | `tcgplayer-price-scraper` |

Check all scheduler jobs at once:

```bash
gcloud scheduler jobs list --location=us-central1 \
  --filter="name:(collection-showcase-daily-sync OR sync-tcgplayer-prices-weekly OR tcgplayer-price-daily)"
```

---

## Suggested Improvements

1. **Add alerting:** Configure Cloud Monitoring alerts on Cloud Run job failure so you're notified without manual checks. Target the `run.googleapis.com/job/completed_task_count` metric filtered by `result=failed`.

2. **Unified status dashboard:** A single BigQuery query or Looker Studio dashboard showing the latest date in `tcgplayer_price_history`, GCS file timestamps, and recent job execution results would let you check everything in one view.

3. **Add a `/healthz` endpoint** to the API if it doesn't exist — makes step 4b scriptable and monitorable.

4. **Backfill check:** After adding new products with `tcgplayer_id`, verify backfill ran by checking for rows in `tcgplayer_price_history` before today's date for those IDs.
