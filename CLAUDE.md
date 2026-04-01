# collection-market-tracker-frontend-admin

## Project Overview

Hugo-based admin frontend for the **Collection Market Tracker** — tracks TCG market prices and listings. Deployed to GitHub Pages; reads static JSON from the data repo and writes via the backend API.

## Multi-Repo Setup

Run `./setup.sh` after cloning this repo to clone all sibling repos to the correct local paths.

## All Repositories

| Repo | GitHub | Local Path | Purpose |
|------|--------|-----------|---------|
| Frontend admin (this repo) | `FutureGadgetCollections/collection-market-tracker-frontend-admin` | `../collection-market-tracker-frontend-admin` | Hugo admin UI — CRUD via backend API |
| **Public frontend** | `FutureGadgetCollections/collection-market-tracker-frontend` | `../collection-market-tracker-frontend` | Hugo public site — read-only; sealed products, single cards, pull rates; no auth |
| Backend (Go / Cloud Run) | `FutureGadgetCollections/collection-market-tracker-backend` | `../collection-market-tracker-backend` | API microservice + scheduled Cloud Run jobs |
| Data files (static JSON) | `FutureGadgetCollections/collection-market-tracker-data` | `../collection-market-tracker-data` | JSON published by backend; read by frontends |
| Showcase frontend (public) | `FutureGadgetCollections/collection-showcase-frontend` | `../collection-showcase-frontend` | Public-facing Hugo site; read-only, no auth |
| **EV Simulator** | `FutureGadgetCollections/collection-market-tracker-ev-simulator` | `../collection-market-tracker-ev-simulator` | Hugo public site — pack EV calculator + pack opening simulator; no auth |

## GCP Infrastructure

| Resource | Details |
|----------|---------|
| GCP Project | `future-gadget-labs-483502` |
| Cloud Run service (API) | `collection-market-tracker` — `us-central1` |
| Cloud Run job (price scraper) | `tcgplayer-price-scraper` — `us-central1` — daily at 08:00 UTC via Cloud Scheduler |
| Cloud Run job (set metrics) | `set-market-metrics` — `us-central1` — Monday 12:00 UTC via Cloud Scheduler; `scripts/set_market_metrics/` |
| Cloud Run job (data sync) | `collection-showcase-data-sync` — `us-central1` (planned, not yet configured) |
| GCS bucket | `collection-tracker-data` |
| BigQuery | Project `future-gadget-labs-483502` — datasets: `catalog` (reference), `market_data` (price history + ML features) |
| Firebase project | `collection-showcase-auth` (Google sign-in; config goes in `.env`, never committed) |
| Artifact Registry | `us-central1-docker.pkg.dev/future-gadget-labs-483502/tcg-collection/` |

## Architecture

- **Framework:** [Hugo](https://gohugo.io/) — static site generator with Go templates
- **Theme:** Custom theme (`themes/admin/`) — Bootstrap 5 layout
- **Auth:** Firebase Authentication — Google sign-in; ID token attached to all backend requests
- **Backend communication:** `api()` helper in `static/js/api.js` handles token attachment automatically
- **Data reads:** Static JSON from GitHub Raw (`collection-market-tracker-data`) with GCS fallback, via `static/js/data-loader.js`
- **Deployment:** GitHub Pages via GitHub Actions (`.github/workflows/deploy.yml`)

## Backend Architecture (collection-market-tracker-backend)

The backend has three distinct concerns:

1. **API microservice** — Cloud Run service (`collection-market-tracker`): handles REST endpoints for CRUD operations on BigQuery `catalog` dataset, triggers GCS and GitHub data file updates after mutations.
2. **TCGPlayer price scraper** — Cloud Run job (`tcgplayer-price-scraper`): Python + Playwright job in `scripts/tcgplayer_prices/`. Scrapes market price, avg daily sold, listed median, and sellers from TCGPlayer. Writes to `market_data.tcgplayer_price_history` via MERGE on `(tcgplayer_id, date)`. Runs daily at 08:00 UTC via Cloud Scheduler. Two modes: `--daily` (snapshot for all products) and `--backfill` (full annual history for new products — run manually after adding `tcgplayer_id`s to catalog).
3. **Set market metrics job** — Cloud Run job (`set-market-metrics`): Python job in `scripts/set_market_metrics/`. Reads single card prices from `tcgplayer_price_history` and pull rates from `set_pull_rates`, computes `set_market_value` (sum of all singles prices) and `pack_ev` (expected pack value from pull rates × avg rarity prices). Writes to `market_data.set_market_metrics` via MERGE on `(game, set_code, snapshot_date)`. Two modes: `MODE=weekly` (default, latest date only) and `MODE=backfill` (all dates not yet in the table — run manually to populate history). Runs Monday 12:00 UTC. Deploy: `scripts/deploy-set-metrics-job.sh`.
4. **Data sync job** — Cloud Run job (`collection-showcase-data-sync`): planned but not yet configured.

## BigQuery Tables

### market_data dataset

| Table | Grain | Purpose |
|-------|-------|---------|
| `tcgplayer_price_history` | `(tcgplayer_id, date)` | Raw daily TCGPlayer scrape — market price, avg daily sold, listed median, sellers |
| `set_market_metrics` | `(game, set_code, snapshot_date)` | Weekly set-level metrics computed from single card prices + pull rates. `set_market_value` = sum of all singles prices; `pack_ev` = expected value of a single pack. Updated Monday 12:00 UTC by `set-market-metrics` job. Feeds `set_market_value`/`pack_expected_value` columns in `ml_price_features_sealed`. |
| `pricecharting_price_history` | `(game, set_code, product_type, date)` | Historical prices from PriceCharting. Partitioned by `date`, clustered by `(game, set_code)`. Columns: `market_price`. Planned: `sell_through_rate`. Raw source — consumed by `ml_price_features_sealed`. |
| `ml_price_features_sealed` | `(game, set_code, product_type, snapshot_date)` | ML feature table for sealed price prediction. Partitioned by `snapshot_date`, clustered by `(game, set_code)`. See ML section below. |
| `price_history` | — | Legacy placeholder — empty, not used. |
| `latest_tcgplayer_prices` | — | Latest TCGPlayer prices view/table. |

### catalog dataset

| Table | Purpose |
|-------|---------|
| `sealed_products` | Sealed product catalog — PK `(game, set_code, product_type)` |
| `single_cards` | Single card catalog — PK `(game, set_code, card_number)` |
| `set_pull_rates` | Pull rate data — PK `(set_code, rarity)` |

### Pull rate coverage & pack construction

| Game | Sets covered | Pack structure | Script |
|------|-------------|----------------|--------|
| Riftbound | rb01–rb03 | 14 cards: 7C + 3UC + 2 rare+ foil + 1 foil wildcard + 1 token | `scripts/catalog/bulk_insert_pack_construction.py` |
| One Piece | op01–op14 (Main Series) | 12 cards: 7C + 3UC + 1 DON!! + 1 hit slot (R/SR/SEC) | same |
| Pokemon | sv01–sv10 + sub-sets (SV era) | 10 cards: 4C + 3UC + 2 reverse holo + 1 holo | same |
| Pokemon | swsh01–swsh12 + sub-sets (SWSH era) | 10 cards: 5C + 3UC + 1 reverse holo + 1 holo | same |
| One Piece | eb01–eb03, prb01–prb02 | different structure — not yet researched | — |
| Pokemon | older eras (XY, SM, DP, Base, etc.) | vary significantly per era — not yet added | — |

Hard-rarity pull rates (double_rare and above for Pokemon; epic/alt_art/etc for Riftbound) are handled by `bulk_insert_pokemon_pull_rates.py` and manual Riftbound imports. `bulk_insert_pack_construction.py` handles C/UC/base-slot rates only.

**One Piece set names (op01–op14):**
op01 Romance Dawn · op02 Paramount War · op03 Pillars of Strength · op04 Kingdoms of Intrigue · op05 Awakening of the New Era · op06 Wings of the Captain · op07 500 Years in the Future · op08 Two Legends · op09 Emperors in the New World · op10 Royal Bloodline · op11 A Fist of Divine Speed · op12 Master and Student Bonds · op13 Carrying on His Will · op14 The Azure Sea's Seven

## ML Feature Table: ml_price_features_sealed

Target variables: `log_return_1yr` = `log(price_1yr / market_price)`, same for 2yr. Train only on rows where label is not NULL (records older than 1yr/2yr respectively).

| Column group | Columns |
|---|---|
| Identity | `snapshot_date`, `game`, `set_code`, `product_type` |
| Time | `month` (1–12), `release_age_days` |
| Core signals | `market_price`, `avg_daily_sold`*, `listed_median`*, `seller_count`* |
| Lag features | `price_7d/30d/90d/180d/365d_ago`, `pct_change_7d/30d/90d` |
| Set-level | `set_market_value`, `pack_expected_value` |
| Pull rates | `pull_rarity_1_p50` … `pull_rarity_4_p50` (rarest → most common) |
| Labels | `price_1yr`, `price_2yr`, `log_return_1yr`, `log_return_2yr` |

\* NULL for data predating the project

**Jobs feeding this table:**
1. Daily scraper — appends core signals
2. Feature computation job — fills lag columns, `release_age_days`, `month`; joins `set_market_metrics` to populate `set_market_value` and `pack_expected_value`
3. Label backfill job — daily, fills `price_1yr`/`log_return_1yr` for rows exactly 365d old; same for 730d
4. Pull rate sync — updates `pull_rarity_*` columns on demand

**TODO:** `ml_price_features_singles` — separate ML table for individual cards; adds `card_number`, `rarity`, `card_pct_of_set_value`. Singles price scraper should run **weekly** (not daily).

## Open TODOs

### Precon deck support (deferred)
EV simulator JS + HTML tab structure complete. Remaining:

1. **Populate first deck lists** — create a JSON file per precon and run `bulk_insert_precon_deck_lists.py`. Format:
   ```json
   {"game":"pokemon","set_code":"sv01","product_type":"battle-deck-koraidon",
    "cards":[{"card_number":"001","quantity":4}, ...]}
   ```

### PriceCharting historical data pipeline (IN PROGRESS — next session pick up at Step 4)

Goal: populate `market_data.pricecharting_price_history` with monthly sealed product price history so `set_market_metrics` can be backfilled beyond TCGPlayer's 1-year window.

Source: `FutureGadgetResearch/set-value-tracking-backend` — audited, scraper is in Go at `internal/pricecharting/pricecharting.go`. Parses `VGPC.chart_data` JS from PriceCharting HTML, returns `[]MonthlyPrice{SnapshotDate, PriceUSD}` (one entry per month, closest to the 15th). Handles 429/403 rate limiting with retry.

Target table: `market_data.pricecharting_price_history` — grain `(game, set_code, product_type, date)`, column `market_price`. Already defined in CLAUDE.md BQ tables section.

**Step 1 — Populate `pricecharting_url` in `catalog.sealed_products` ✅ DONE**
- All Pokemon + Riftbound URLs were already populated in BQ (verified 2026-03-30)
- Script `scripts/catalog/update_pricecharting_urls.py` exists for future URL updates

**Step 2 — Build `pricecharting-scraper` Cloud Run job ✅ DONE**
- `scripts/pricecharting_scraper/pricecharting_scraper.py` — Go scraper logic ported to Python
- Deployed as Cloud Run job `pricecharting-scraper` in `us-central1`
- Scheduled monthly: `pricecharting-scraper-monthly` — 16th of each month 06:00 UTC
- Deploy script: `scripts/deploy-pricecharting-scraper-job.sh`

**Step 3 — Run backfill ✅ DONE**
- `MODE=backfill` executed 2026-03-31; scraped 378 products into `pricecharting_price_history`

**Step 4 — Deploy and run `set-market-metrics` (NEXT)**
- `set_market_metrics` BQ table doesn't exist yet — job creates it on first MERGE
- `compute_set_metrics.py` is ready in `scripts/set_market_metrics/` — just needs deploying
- Run `./scripts/deploy-set-metrics-job.sh` then trigger `MODE=backfill`
- Then enable weekly Cloud Scheduler

**Step 5 — One Piece eb/prb pack structure**
- Extra boosters (eb01–eb03) and premium boosters (prb01–prb02) have different pack construction; needs research before adding pull rates.

**Step 6 — Pokemon older eras pull rates**
- XY, Sun & Moon, Diamond & Pearl, Base Set era all have different pack structures; add separately once needed.

### EV simulator (collection-market-tracker-ev-simulator)
- CLAUDE.md created; precon-deck-lists.json data format documented there


## Data Flow

```
BigQuery (source of truth)
  ├── API (on mutation) ──► GCS bucket ──┐
  ├── API (on mutation) ──► data repo  ──┤──► frontends (GitHub Raw first, GCS fallback)
  └── Cron job (daily)  ──► GCS + data repo (same as above)

Frontend data source priority: GitHub Raw ► GCS ► API (user-selectable via refresh buttons)
```

## Sections

| Section | Content Dir | Layout | Data File | API Path |
|---------|------------|--------|-----------|----------|
| Sealed Products | `content/sealed-products/` | `themes/admin/layouts/sealed-products/list.html` | `data/sealed-products.json` | `/sealed-products` |
| Single Cards | `content/single-cards/` | `themes/admin/layouts/single-cards/list.html` | `data/single-cards.json` | `/single-cards` |
| Set Pull Rates | `content/set-pull-rates/` | `themes/admin/layouts/set-pull-rates/list.html` | `data/set-pull-rates.json` | `/set-pull-rates` |

## Key Files

| Path | Purpose |
|------|---------|
| `hugo.toml` | Hugo config — title, description, params defaults |
| `themes/admin/layouts/` | Hugo templates (baseof, list, index) |
| `themes/admin/layouts/partials/` | head, navbar, footer, scripts partials |
| `static/js/firebase-init.js` | Firebase app init, `authSignOut()`, `isEmailAllowed()`, auth state listener |
| `static/js/api.js` | Authenticated `api(method, path, body)` helper + `qs()` query builder |
| `static/js/app.js` | Global `showToast()` and `triggerSync()` utilities |
| `static/js/data-loader.js` | `loadJsonData(filename)` — GitHub-first, GCS-fallback data fetching |
| `static/css/app.css` | Minimal style overrides on top of Bootstrap 5 |
| `.env.example` | Template for all environment variables |

## Auth Flow

1. User signs in via Firebase Auth (Google sign-in).
2. Firebase issues an ID token.
3. Frontend attaches the token as `Authorization: Bearer <token>` on all backend requests.
4. Backend validates the token via Firebase Admin SDK.
5. Access further restricted to `ALLOWED_EMAILS` whitelist, enforced on both frontend and backend.

## Development Notes

- Hugo config lives in `hugo.toml`
- Firebase config goes in `.env` — never commit this file
- Environment variables are injected as `HUGO_PARAMS_*` and map to `.Site.Params.*` in templates
- The `split .Site.Params.allowed.emails ","` pattern in `head.html` converts the comma-separated email string to a JS array
- Data loads default to GitHub Raw; use the refresh button group (GitHub / GCS / API) to switch sources
- Data files live under `data/` in the data repo (e.g. `data/sealed-products.json`), not the root
- Data files are JSON arrays — the backend syncer (`queryJSON`) marshals BQ rows as `[]map[string]bigquery.Value`
- Composite PKs: sealed-products `(game, set_code, product_type)`, single-cards `(game, set_code, card_number)`, set-pull-rates `(set_code, rarity)`
- URL segments for composite PKs are `encodeURIComponent`-encoded by the frontend
- To add a new section: create `content/<section>/_index.md`, add a nav link in `navbar.html`, and create `themes/admin/layouts/<section>/list.html`
