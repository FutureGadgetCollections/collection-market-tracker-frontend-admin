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
| Docker Hub | `philwin/collection-market-tracker`, `philwin/tcgplayer-price-scraper`, `philwin/set-market-metrics`, `philwin/pricecharting-scraper`, `philwin/tcgplayer-price-sync` |

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
| `graded_price_history` | `(pricecharting_url, date)` | Monthly graded card prices from PriceCharting. Partitioned by `date`, clustered by `(game, set_code)`. Columns: ungraded_price, grade_7/8/9/9.5_price, psa_10_price. Scraped by `scripts/pricecharting_scraper/graded_price_scraper.py`. |
| `ev_set_history` | `(game, set_code, product_type, snapshot_date)` | Weekly EV snapshots per set/product. Partitioned by `snapshot_date`, clustered by `(game, set_code)`. Per-rarity avg prices (sifted $0.25), pack EV (gross/TCGPlayer 13.25%/Manapool 7.9%), box EV, value ratio, card coverage. Populated by `ev-history` Cloud Run job (`scripts/ev_history/`). Weekly mode: latest date. Backfill mode: all missing dates. |
| `price_history` | — | Legacy placeholder — empty, not used. |
| `latest_tcgplayer_prices` | — | View: latest row per `tcgplayer_id` from `tcgplayer_price_history`. |
| `ev_card_prices` | — | View: `single_cards` LEFT JOIN `latest_tcgplayer_prices` on `tcgplayer_id`. Columns: game, set_code, card_number, name, rarity, treatment, collector_only, market_price, avg_daily_sold, listed_median, sellers, price_date. |
| `ev_set_summary` | — | View: aggregated card prices by `(game, set_code, rarity, treatment, collector_only)`. Columns: card_count, priced_count, avg_price, avg_price_sifted_025, total_price, total_price_sifted_025. |

### catalog dataset

| Table | Purpose |
|-------|---------|
| `sealed_products` | Sealed product catalog — PK `(game, set_code, product_type)` |
| `single_cards` | Single card catalog — PK `(game, set_code, card_number)`. Columns include `treatment` (base, borderless, showcase, extended_art, neon_ink, raised_foil, source_material, token) and `collector_only` (bool — TRUE for collector-booster-exclusive cards). |
| `set_pull_rates` | Pull rate data — PK `(set_code, rarity)` |
| `pack_slots` | Per-slot probability distributions for booster products — PK `(game, set_code, product_type, slot_index)`. Columns: `slot_name`, `is_foil`, `p_common/uncommon/rare/mythic/special` (sum to ~1.0 per slot), `card_pool`, `notes`. Used for EV calculation and pack opening simulation. Populated by `scripts/catalog/create_pack_slots_table.py`. |

### Pull rate coverage & pack construction

| Game | Sets covered | Pack structure | Script |
|------|-------------|----------------|--------|
| Riftbound | rb01–rb03 | 14 cards: 7C + 3UC + 2 rare+ foil + 1 foil wildcard + 1 token | `scripts/catalog/bulk_insert_pack_construction.py` |
| One Piece | op01–op14 (Main Series) | 12 cards: 7C + 3UC + 1 DON!! + 1 hit slot (R/SR/SEC) | same |
| Pokemon | sv01–sv10 + sub-sets (SV era) | 10 cards: 4C + 3UC + 2 reverse holo + 1 holo | same |
| Pokemon | swsh01–swsh12 + sub-sets (SWSH era) | 10 cards: 5C + 3UC + 1 reverse holo + 1 holo | same |
| MTG | tla (Avatar: The Last Airbender) | 14 cards: 6C + 3UC + 1 wildcard + 1 R/M + 1 foil + 1 land + 1 token | same (aggregated) + `create_pack_slots_table.py` (per-slot) |
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

## MTG TLA Set Details (Avatar: The Last Airbender)

| Field | Value |
|-------|-------|
| Set code | `tla` |
| Game | `mtg` |
| Era | `Universes Beyond` |
| Release date | 2025-11-21 |
| Base set size | 286 cards: 96 commons (81 draftable), 110 uncommons, 60 rares, 20 mythics |
| Products | play-booster-box (30 packs, TCGPlayer 648643), collector-booster-box (12, 648650), jumpstart-booster-box (24, 648679) |
| Pull rates source | magic.wizards.com/en/news/feature/collecting-avatar-the-last-airbender |
| Single cards | Fetch via `fetch_single_cards.py` with TCGPlayer magic/avatar-the-last-airbender URL; game slug "magic" maps to our "mtg" — script will prompt for set_code, enter `tla` |

**Play Booster slot breakdown (14 cards — 13 game cards + 1 token):**

| Slot | Name | C | U | R | M | Special | Foil | Pool |
|------|------|---|---|---|---|---------|------|------|
| 1–6 | common_1–6 | 96.2% | — | — | — | 3.85% (source material) | No | 81 draftable commons |
| 7–9 | uncommon_1–3 | — | 96.4% | — | — | 3.6% (scene cards) | No | 110 uncommons |
| 10 | wildcard | 4.2% | 74.1% | 16.7% | 2.6% | 2.4% | No | all main set |
| 11 | rare_mythic | — | — | 80% | 12.6% | 7.4% (booster fun) | No | main rares/mythics |
| 12 | foil | 53.9% | 36.7% | 6.7% | 1.2% | 1.5% | Yes | all main set |
| 13 | land | — | — | — | — | 100% | No | land pool |

**Aggregated pull rates per play booster** (stored in `set_pull_rates`):
- common: ~6.35 | uncommon: ~4.00 | rare: ~1.034 | mythic: ~0.164

Per-slot data in `catalog.pack_slots` — query via MCP `catalog_pack_slots(game='mtg', set_code='tla')`.

## Open TODOs

### Graded card market tracking (TODO)

Goal: track graded card prices and gem rates over time for PSA and CGC grading companies.

**Data to track (monthly grain):**
- PSA 10 price, PSA 9 price, PSA 10 gem rate
- CGC 10 price, CGC 10 gem rate
- CGC Pristine 10 price, CGC Pristine 10 rate

**Gem rate tracking:** Need to track gem rate changes over time as grading populations grow. Monthly snapshots.

**BQ table design (TODO):**
- `market_data.graded_prices` — grain: `(tcgplayer_id, grade, grading_company, snapshot_date)`. Columns: `price`, `population`, `gem_rate`.
- Or: `market_data.graded_card_history` — grain: `(game, set_code, card_number, grading_company, grade, snapshot_date)`.

**Data sources:**
- PriceCharting links already exist for Pokemon, One Piece, Riftbound sealed products — can retrieve PSA 9, PSA 10, CGC 10, CGC Pristine 10 prices from PriceCharting product pages.
- PSA/CGC population reports for gem rates.

**Steps:**
1. Design BQ table schema
2. Build scraper for graded prices from PriceCharting (extend existing `pricecharting_scraper.py`)
3. Build scraper for gem rates from PSA/CGC population reports
4. Add graded price columns to admin frontend card views
5. Add gem rate tracking and historical charts

### Sentiment / market focus analysis (TODO)

Goal: track market sentiment and community focus across TCG sets to identify which sets are gaining or losing interest.

**Potential signals:**
- TCGPlayer avg_daily_sold trends (already scraped)
- TCGPlayer seller count trends (already scraped)
- Price velocity (rate of price change over 7d/30d/90d)
- Social media mentions / Reddit activity
- YouTube box opening frequency

**Steps:**
1. Define sentiment metrics from existing data (price velocity, volume trends)
2. Build a sentiment dashboard on the admin panel
3. (Optional) Add external data sources (Reddit API, YouTube API)

### Investigate One Piece rare_leader and hit_slot EV (TODO)

The slot 11 (rare_leader) and slot 12 (hit_slot) EV calculations for One Piece sets still look off. Need to investigate:
- Are the per-slot note percentages being parsed correctly?
- Is the `weightedSpecialAvg` function weighting leader/SR/SEC correctly for OP?
- Compare against known box break data to validate
- Check if leader cards are being double-counted (slot 11 leader rate + slot 12 leader rate)

### Self-hosted PostgreSQL database (TODO)

Goal: host a PostgreSQL instance on Proxmox as the primary DB for frontends, with BQ as source of truth and backup.

- BQ is source of truth; PG is synced on every BQ write (dual-write from Go API)
- Tables to mirror: `catalog.sealed_products`, `catalog.single_cards`, `catalog.set_pull_rates`, `catalog.pack_slots`, `market_data.tcgplayer_price_history`, `market_data.pricecharting_price_history`, `market_data.set_market_metrics`
- ML tables (`ml_price_features_sealed`) stay in BQ only
- Go API queries PG primarily; Cloud Run fallback still hits BQ
- PG schema should match BQ grain/column names exactly for easy sync
- Steps: design PG schema DDL → add PG dual-write to Go API → initial backfill from BQ → update frontend data source priority

### Expected Value (EV) tab — admin panel (IN PROGRESS)

Goal: add an "Expected Value" tab to the admin panel as a staging ground for the EV feature before it's spun into its own repo/frontend (like `collection-market-tracker-ev-simulator`).

Starting with MTG Avatar: The Last Airbender (TLA) play booster as the first set.

Prerequisites completed:
- `catalog.sealed_products`: TLA products added (play/collector/jumpstart booster boxes)
- `catalog.pack_slots`: TLA play booster slot breakdown created
- `catalog.set_pull_rates`: TLA aggregated rates added, `unique_card_count` populated (81C/110U/60R/20M)
- `catalog.single_cards`: 475 TLA cards fetched (game fixed from `magic` → `mtg`)
- `market_data.tcgplayer_price_history`: 466/475 TLA card price snapshots (9 have no market price on TCGPlayer)

Next steps:
1. ~~Fetch TLA single cards into `catalog.single_cards`~~ ✅ DONE
2. ~~Run TCGPlayer price scraper backfill for TLA cards~~ ✅ 449/475 DONE (26 pending retry)
3. Add "Expected Value" tab to admin panel — shows EV breakdown per set/product type
4. EV formula: `pack_ev = Σ(pull_rate_per_pack[rarity] / unique_card_count[rarity]) × avg_price[rarity]` across all rarities
5. Eventually move to standalone frontend (see `collection-market-tracker-ev-simulator`)

### Precon deck support (deferred)
EV simulator JS + HTML tab structure complete. Remaining:

1. **Populate first deck lists** — create a JSON file per precon and run `bulk_insert_precon_deck_lists.py`. Format:
   ```json
   {"game":"pokemon","set_code":"sv01","product_type":"battle-deck-koraidon",
    "cards":[{"card_number":"001","quantity":4}, ...]}
   ```

### PriceCharting historical data pipeline (IN PROGRESS — next session pick up at Step 5)

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

**Step 4 — Deploy and run `set-market-metrics` ✅ DONE**
- Deployed Cloud Run job `set-market-metrics`; scheduler `compute-set-market-metrics-weekly` runs Mondays 12:00 UTC
- Backfill executed 2026-04-01; merged 55 rows across 26 dates (2025-11-06 → 2026-03-30) into `market_data.set_market_metrics`
- Fixed 3 bugs in `compute_set_metrics.py`: graceful handling of missing `set_market_metrics`, `precon_deck_lists` tables; `create_table(exists_ok=True)` before MERGE
- Fixed deploy script SA: now uses `evupdate-runner@future-gadget-labs-483502.iam.gserviceaccount.com`

**Step 5 — One Piece eb/prb pack structure**
- Extra boosters (eb01–eb03) and premium boosters (prb01–prb02) have different pack construction; needs research before adding pull rates.

**Step 6 — Pokemon older eras pull rates**
- XY, Sun & Moon, Diamond & Pearl, Base Set era all have different pack structures; add separately once needed.

### EV history backfill (TODO)

Goal: populate `market_data.ev_set_history` with historical EV snapshots going back beyond TCGPlayer's 1-year window.

- **Step 1**: Run `ev-history` job in backfill mode to compute EV for all existing dates in `tcgplayer_price_history` — gives ~1 year of weekly snapshots for sets that have been scraped.
- **Step 2**: Backfill singles price history using PriceCharting data. `pricecharting_price_history` has monthly sealed product prices but NOT singles prices. Need a new data source or scraper for historical singles prices to extend EV history further back.
- **Step 3**: Once historical singles prices are available, re-run `ev-history backfill` to fill in older EV snapshots.
- **Step 4**: Add EV-over-time chart to the Expected Value tab using `ev_set_history` data.

### Missing PriceCharting URLs (TODO — one set at a time)

Products missing `pricecharting_url` in `catalog.sealed_products`. Look up each on pricecharting.com and update via `scripts/catalog/update_pricecharting_urls.py`.

**MTG (43 products, 13 sets):**
- [ ] tla — Avatar: The Last Airbender (3 products)
- [ ] tdm — Tarkir Dragonstorm (2)
- [ ] dft — Duskmourn: Foundation (2)
- [ ] fdn — Foundations (2)
- [ ] dsk — Duskmourn: House of Horror (2)
- [ ] blb — Bloomburrow (2)
- [ ] otj — Outlaws of Thunder Junction (2)
- [ ] mkm — Murders at Karlov Manor (2)
- [ ] mh3 — Modern Horizons 3 (2)
- [ ] lci — Lost Caverns of Ixalan (3)
- [ ] woe — Wilds of Eldraine (3)
- [ ] mom — March of the Machine (3)
- [ ] one — Phyrexia All Will Be One (3)
- [ ] bro — Brothers War (3)
- [ ] dmu — Dominaria United (3)
- [ ] neo — Kamigawa Neon Dynasty (3)
- [ ] snc — Streets of New Capenna (3)

**Weiss Schwarz (33 products, 33 sets):**
- [ ] spyxfamily, oshinoko-v1, oshinoko-v2, chainsaw-man, bocchi, frieren-v1, frieren-v2
- [ ] dandadan, makeine, nikke, blue-archive, mushoku-tensei, konosuba-re
- [ ] holo-ws-v1, holo-ws-v2, holo-ws-premium, holo-ws-summer
- [ ] bdgp-5th-anniv, bdgp-countdown, bdgp-premium, mygo-avemujica, girls-band-cry
- [ ] lycoris-recoil, lycoris-premium, eminence-shadow, nazarick-v3
- [ ] jojo-stardust, jojo-stone-ocean, fairytail-100yq, fujimi-v2
- [ ] hatsune-miku-cs, p3r-premium-v1, p3r-premium-v2

**Hololive (7 products, 6 sets):**
- [ ] hl01, hl02, hl03, hl04, hl05, hl06

**Riftbound (2 products, 1 set):**
- [ ] rb03 — Unleashed (booster-pack, booster-display) — may not be on PriceCharting yet

### MTG EV expansion (TODO)

**Draft/Set booster sets (2022-2023) — need cards, prices, pack_slots:**
- [ ] woe — Wilds of Eldraine (2023-09, draft+set booster)
- [ ] lci — Lost Caverns of Ixalan (2023-11, draft+set booster)
- [ ] mom — March of the Machine (2023-04, draft+set booster)
- [ ] one — Phyrexia All Will Be One (2023-02, draft+set booster)
- [ ] bro — Brothers War (2022-11, draft+set booster)
- [ ] dmu — Dominaria United (2022-09, draft+set booster)
- [ ] neo — Kamigawa Neon Dynasty (2022-02, draft+set booster)
- [ ] snc — Streets of New Capenna (2022-04, draft+set booster)

Note: Draft boosters have different pack construction than play boosters (15 cards: 10C+3UC+1R/M+1 token/ad). Set boosters are 12 cards with different slot structure. Need separate pack_slots definitions.

**Deferred:**
- [ ] Collector boosters (different premium pack construction per set)
- [ ] Jumpstart products (different format — 20-card themed packs)
- [ ] Pre-2022 MTG sets

### Weiss Schwarz EV expansion (TODO)

**2025 sets — English only, need cards + prices + pack_slots:**
- [ ] fujimi-v2 — Re:ZERO (2025-03, standard booster)
- [ ] nazarick-v3 — Overlord Premium (2025-02, premium booster)
- [ ] eminence-shadow — Eminence in Shadow (2025-02, standard booster)
- [ ] frieren-v2 — Frieren v2 (2025-01, standard booster)
- [ ] p3r-premium-v2 — Persona 3 Reload Premium v2 (2025-01, premium booster)
- [ ] oshinoko-v2 — Oshi no Ko v2 (2025-01, standard booster)

**2024 sets:**
- [ ] fairytail-100yq — Fairy Tail 100 Years Quest (2024-12, standard)
- [ ] makeine — Too Many Losing Heroines (2024-11, standard)
- [ ] konosuba-re — KonoSuba Re (2024-11, standard)
- [ ] dandadan — Dandadan (2024-11, standard)
- [ ] mygo-avemujica — MyGO!!!!! (2024-10, standard)
- [ ] girls-band-cry — Girls Band Cry Premium (2024-09, premium)
- [ ] hatsune-miku-cs — Hatsune Miku (2024-06, standard)
- [ ] frieren-v1 — Frieren v1 (2024-05, standard)
- [ ] p3r-premium-v1 — Persona 3 Reload Premium v1 (2024-04, premium)
- [ ] nikke — NIKKE (2024-03, standard)
- [ ] jojo-stone-ocean — JoJo Stone Ocean Premium (2024-03, premium)
- [ ] blue-archive — Blue Archive (2024-02, standard)

WS standard booster: 8 cards/pack, 20 packs/box. Premium booster: 4 cards/pack, 6 packs/box.
Case rates from tcgcaserates.com for SP/SIR guarantees per set.

### EV simulator (collection-market-tracker-ev-simulator)
- CLAUDE.md created; precon-deck-lists.json data format documented there

### GCP cost reduction

**Migrate images from Artifact Registry to Docker Hub (IN PROGRESS)**
- Docker Hub account: `philwin` — using personal access token (stored as GitHub secret `DOCKERHUB_TOKEN`)
- **TODO: Rotate Docker Hub PAT** — token was exposed in a chat session; regenerate at hub.docker.com/settings/security and update `DOCKERHUB_TOKEN` secret in all repos
- Old Docker Hub repos cleaned up (8 deleted: options-ingest, lotto-analysis, market_data_loader, etc.)

**collection-market-tracker-backend — ✅ DONE (2026-04-03)**
- Workflows + deploy scripts updated to push to `docker.io/philwin/<image>`
- Images: `collection-market-tracker`, `tcgplayer-price-scraper`, `set-market-metrics`, `pricecharting-scraper`, `tcgplayer-price-sync`
- GitHub secrets `DOCKERHUB_USERNAME` + `DOCKERHUB_TOKEN` added
- Repos auto-create on first push; next workflow trigger will push to Docker Hub
- AR repo `tcg-collection` deleted (2026-04-04) — was 4.9 GB

**TODO: Homeserver-primary / Cloud Run-fallback API architecture**
- Goal: backend API (`collection-market-tracker` Cloud Run service) runs primarily on homeserver; Cloud Run is the fallback if the local API process is down
- Approach: **Nginx reverse proxy on homeserver** with `proxy_pass` to Cloud Run as upstream fallback
  - Nginx receives all API traffic, forwards to local Go API service
  - If local service is unresponsive (connect error / timeout), Nginx retries the request against the Cloud Run URL
  - Cloud Run stays at scale-to-zero — only cold-starts when local service is down
  - Limitation: if the entire Proxmox node goes down, Nginx goes with it and there's no failover — acceptable trade-off for zero cost
- Nginx config sketch:
  ```nginx
  upstream api_primary  { server 127.0.0.1:8080; }
  upstream api_fallback { server <cloud-run-host>:443; }

  server {
    location / {
      proxy_pass http://api_primary;
      proxy_next_upstream error timeout;
      proxy_next_upstream_tries 1;
      # on failure, retry against Cloud Run
      error_page 502 503 504 = @fallback;
    }
    location @fallback {
      proxy_pass https://api_fallback;
      proxy_ssl_server_name on;
    }
  }
  ```
- Steps:
  1. Deploy the Go API on the homeserver (Docker Compose or systemd unit); expose on `127.0.0.1:8080`
  2. Configure Nginx as above; point the API domain (via Cloudflare DNS) at the homeserver IP
  3. Set Cloud Run min-instances = 0 (already scale-to-zero)
  4. Copy all env vars (Firebase config, `ALLOWED_EMAILS`, BQ project, etc.) to homeserver deployment
- Note: the Cloud Run service still needs to exist as the fallback — just won't be hit under normal operation

**TODO: Homeserver-primary / Cloud Run-fallback job architecture**
- Goal: scheduled jobs run primarily on homeserver (Proxmox nodes), Cloud Run acts as a cheap safety net
- Design: each Cloud Run job is rescheduled to run ~30–60 min after the homeserver cron; on start it checks a "heartbeat" record (e.g. a BQ row or GCS file written by the homeserver job) to see if the job already ran for today/this week
  - If heartbeat found → log "homeserver already ran" and exit 0 immediately (minimal cost — just job startup)
  - If no heartbeat → run the full job in Cloud Run as fallback
- Homeserver jobs write the heartbeat on success (e.g. insert a row into a `market_data.job_heartbeats` table with `(job_name, run_date, status)`)
- Applies to: `tcgplayer-price-scraper` (daily), `set-market-metrics` (weekly), `pricecharting-scraper` (monthly)
- Steps:
  1. Define `market_data.job_heartbeats` BQ table: `(job_name STRING, run_date DATE, ran_at TIMESTAMP, source STRING)`
  2. Add heartbeat write to each homeserver job script on success
  3. Add heartbeat check at the top of each Cloud Run job entrypoint; exit 0 if found
  4. Adjust Cloud Scheduler triggers to fire 30–60 min after homeserver cron


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
