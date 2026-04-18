# collection-market-tracker-frontend-admin

Hugo-based admin frontend for the **Collection Market Tracker** — TCG market prices and listings. Deployed to GitHub Pages; reads static JSON from the data repo and writes via the backend API.

Run `./setup.sh` after cloning to clone all sibling repos to the correct local paths.

## Repos

| Repo | Purpose |
|------|---------|
| `collection-market-tracker-frontend-admin` (this) | Hugo admin UI — CRUD via backend API |
| `collection-market-tracker-frontend` | Hugo public site — read-only; sealed products, single cards, pull rates |
| `collection-market-tracker-backend` | Go API microservice + scheduled Cloud Run jobs |
| `collection-market-tracker-data` | Static JSON published by backend; read by frontends |
| `collection-showcase-frontend` | Public showcase site |
| `collection-market-tracker-ev-simulator` | Public EV calculator + pack opening simulator |

All under GitHub org `FutureGadgetCollections`, cloned as siblings under `../`.

## GCP Infrastructure

| Resource | Details |
|----------|---------|
| GCP Project | `future-gadget-labs-483502` |
| Cloud Run service (API) | `collection-market-tracker` — `us-central1` |
| Cloud Run jobs | `tcgplayer-price-scraper` (Mon 08:00 UTC), `tcgplayer-price-scraper-cards-weekly` (Mon 10:00 UTC), `set-market-metrics` (Mon 12:00 UTC), `pricecharting-scraper` (16th 06:00 UTC), `ev-history` |
| GCS bucket | `collection-tracker-data` |
| BigQuery | datasets `catalog` (reference), `market_data` (price history + ML features) |
| Firebase project | `collection-showcase-auth` (Google sign-in; config in `.env`, never committed) |
| Docker Hub | `philwin/collection-market-tracker`, `tcgplayer-price-scraper`, `set-market-metrics`, `pricecharting-scraper`, `tcgplayer-price-sync` |

## Architecture

- **Framework:** Hugo + custom theme (`themes/admin/`), Bootstrap 5
- **Auth:** Firebase Google sign-in; ID token attached via `static/js/api.js`. Backend validates via Firebase Admin SDK + `ALLOWED_EMAILS` whitelist (enforced both sides).
- **Data reads:** `static/js/data-loader.js` — GitHub Raw → GCS → API (user-selectable via refresh buttons). Files live under `data/` in the data repo; JSON arrays.
- **Deployment:** GitHub Pages via `.github/workflows/deploy.yml`
- **Hugo config:** `hugo.toml`. Env injected as `HUGO_PARAMS_*` → `.Site.Params.*`.

## Backend concerns (collection-market-tracker-backend)

1. **API microservice** — Cloud Run `collection-market-tracker`: REST CRUD on BigQuery `catalog`; triggers GCS + GitHub data publish after mutations.
2. **TCGPlayer price scraper** — Cloud Run job `tcgplayer-price-scraper` (Python + Playwright, `scripts/tcgplayer_prices/`). Writes `market_data.tcgplayer_price_history` via MERGE on `(tcgplayer_id, date)`. Modes: `--daily` (snapshot all products) and `--backfill` (full annual history for new products).
3. **Set market metrics job** — Cloud Run job `set-market-metrics` (`scripts/set_market_metrics/`). Computes `set_market_value` (sum of singles) and `pack_ev` per set, writes `market_data.set_market_metrics`. Modes: `MODE=weekly` (default) and `MODE=backfill` (all missing dates).
4. **PriceCharting scraper** — Cloud Run job `pricecharting-scraper` (`scripts/pricecharting_scraper/`). Monthly sealed product prices into `pricecharting_price_history`.
5. **EV history job** — `scripts/ev_history/`. Per-rarity prices, pack/box EV, value ratio into `ev_set_history`.

## BigQuery Tables

### market_data

| Table | Grain | Purpose |
|-------|-------|---------|
| `tcgplayer_price_history` | `(tcgplayer_id, date)` | Weekly TCGPlayer scrape — market price, avg daily sold, listed median, sellers |
| `set_market_metrics` | `(game, set_code, snapshot_date)` | Weekly. `set_market_value` (Σ singles), `pack_ev`. Feeds ML table. |
| `pricecharting_price_history` | `(game, set_code, product_type, date)` | Monthly PriceCharting sealed prices. Partitioned by `date`, clustered by `(game, set_code)`. |
| `graded_price_history` | `(pricecharting_url, date)` | Monthly PriceCharting graded prices: ungraded, grade 7/8/9/9.5, PSA 10. Scraped by `graded_price_scraper.py`. |
| `psa_population_history` | `(psa_spec_id, snapshot_date)` | Daily PSA pop reports (free API, 100 calls/day). total_graded, grades 7–10, gem_rate, deltas. |
| `ev_set_history` | `(game, set_code, product_type, snapshot_date)` | Weekly EV snapshots: per-rarity sifted-$0.25 prices, pack EV (gross/TCGPlayer 13.25%/Manapool 7.9%), box EV, value ratio. |
| `ml_price_features_sealed` | `(game, set_code, product_type, snapshot_date)` | ML feature table for sealed price prediction. See ML section. |
| `latest_tcgplayer_prices` | view | Latest row per `tcgplayer_id`. |
| `ev_card_prices` | view | `single_cards` LEFT JOIN `latest_tcgplayer_prices`. |
| `ev_set_summary` | view | Aggregated card prices by `(game, set_code, rarity, treatment, collector_only)`. |

### catalog

| Table | Purpose |
|-------|---------|
| `sealed_products` | PK `(game, set_code, product_type)`. Has `pricecharting_url`, `release_date`, `era`, `ev_approved`, `ev_approved_at`. |
| `single_cards` | PK `(game, set_code, card_number)`. Cols: `treatment` (base, borderless, showcase, extended_art, neon_ink, raised_foil, source_material, token), `collector_only` bool, `psa_spec_id`. |
| `set_pull_rates` | PK `(set_code, rarity)`. Has `unique_card_count`. |
| `pack_slots` | PK `(game, set_code, product_type, slot_index)`. Per-slot probability distributions. |
| `precon_deck_lists` | Precon deck contents — see EV simulator. |

### Pull rate / pack construction coverage

| Game | Sets | Pack |
|------|------|------|
| Riftbound | rb01–rb03 | 14: 7C + 3UC + 2 rare+ foil + 1 foil wildcard + 1 token |
| One Piece | op01–op14 (Main) | 12: 7C + 3UC + 1 DON!! + 1 hit slot (R/SR/SEC) |
| One Piece | eb01–eb03, prb01–prb02 | per-slot in `pack_slots` (different per set) |
| Pokemon | sv01–sv10 + sub-sets | 10: 4C + 3UC + 2 reverse holo + 1 holo |
| Pokemon | swsh01–swsh12 + sub-sets | 10: 5C + 3UC + 1 reverse holo + 1 holo |
| Pokemon | older eras (XY/SM/DP/Base/Neo/EX) | C/UC base rates only — no `pack_slots` yet |
| MTG | tla | 14: 6C + 3UC + 1 wildcard + 1 R/M + 1 foil + 1 land + 1 token |

C/UC base rates come from `bulk_insert_pack_construction.py` (era-based matching from `sealed_products.era`). Hard-rarity rates (Pokemon double_rare+, Riftbound epic/alt_art/etc.) from `bulk_insert_pokemon_pull_rates.py` and manual imports.

**One Piece set names:** op01 Romance Dawn · op02 Paramount War · op03 Pillars of Strength · op04 Kingdoms of Intrigue · op05 Awakening of the New Era · op06 Wings of the Captain · op07 500 Years in the Future · op08 Two Legends · op09 Emperors in the New World · op10 Royal Bloodline · op11 A Fist of Divine Speed · op12 Master and Student Bonds · op13 Carrying on His Will · op14 The Azure Sea's Seven

## ML Feature Table: ml_price_features_sealed

**Live** — 16,168 rows · 462 products · 2021-05-15 → 2026-04-15. Targets: `log_return_{6mo,1yr,2yr} = log(price_future / market_price)`. Train only on rows where label is non-NULL.

| Group | Columns |
|---|---|
| Identity | `snapshot_date`, `game`, `set_code`, `product_type` |
| Time | `month`, `release_age_days` |
| Core signals | `market_price`, `avg_daily_sold`*, `listed_median`*, `seller_count`*, `price_source` |
| Lag | `price_{7,30,90,180,365}d_ago`, `pct_change_{7,30,90}d` |
| Set-level | `set_market_value`, `pack_expected_value` (thin — only 300 rows) |
| Pull rates | `packs_to_master_r1` … `packs_to_master_r3` (rarest → more common) |
| Chase | `max_single_price`, `top_3_singles_sum`, `chase_multiple` |
| Graded | `avg_psa_10_price`, `avg_cgc_95_price`, `avg_psa_9_price`, `graded_premium_ratio` |
| Macro | `sp500_close`, `sp500_52w_pct`, `btc_close`, `btc_52w_pct` (all 16k rows) |
| Trends | `trends_game_interest`, `trends_game_anchor`, `trends_set_interest`, `trends_set_anchor` (~2.3k rows, in progress) |
| Labels | `price_6mo`, `price_1yr`, `price_2yr`, `log_return_6mo`, `log_return_1yr`, `log_return_2yr` |

\* NULL for data predating the project.

Label coverage: 6mo 12.7k · 1yr 10.6k · 2yr 6.8k.

Jobs: weekly scraper appends core signals → feature computation fills lags + joins `set_market_metrics` → daily label backfill fills 180d/365d/730d-old rows → pull rate sync on demand.

**TODO:** `ml_price_features_singles` — per-card variant; adds `card_number`, `rarity`, `card_pct_of_set_value`. Singles scraper already runs weekly.

## PRIMARY GOAL: sealed price prediction at 6mo / 1yr / 2yr

North-star use case. Every pipeline should be evaluated against whether it produces a feature or label for this model. Detailed feature taxonomy + roadmap in `memory/primary_goal_price_prediction.md`. Top open items:

1. Finish in-flight: graded price backfill (~2.5k/5k done), populate `psa_spec_id`, schedule daily PSA pop fetches → unblocks PSA-tier features. Graded premium cols (`avg_psa_10_price`, `graded_premium_ratio`, …) already wired for 13.5k rows but need the rest.
2. Backfill `pack_expected_value` — only 300/16k rows populated; join to `set_market_metrics` likely broken for historical snapshots.
3. `reprint_events` table: `(game, original_set_code, reprint_set_code, announce_date, release_date, reprint_ratio, notes)` → derives `out_of_print`, `months_since_last_reprint`.
4. Finish Trends backfill — `trends_set_interest` only on 2.3k/16k rows.
5. Build `ml_price_features_singles` (per-card variant).
6. Attention signals stretch: Reddit/YouTube; character-name Trends as chase proxy.

**Done (formerly on this list):** 6mo label backfill; chase cols (`max_single_price`, `top_3_singles_sum`, `chase_multiple`); macro signals (`sp500_*`, `btc_*`).

## MTG TLA (Avatar: The Last Airbender) — reference set

| Field | Value |
|-------|-------|
| Set / Game / Era | `tla` / `mtg` / Universes Beyond |
| Released | 2025-11-21 |
| Size | 286: 96C (81 draftable), 110U, 60R, 20M |
| Products | play-booster-box (30 packs, TCGPlayer 648643), collector-booster-box (12, 648650), jumpstart-booster-box (24, 648679) |
| Pull rates source | magic.wizards.com/en/news/feature/collecting-avatar-the-last-airbender |

Single cards: `fetch_single_cards.py` with TCGPlayer URL `magic/avatar-the-last-airbender`; game slug "magic" maps to "mtg".

**Play Booster slots (14 cards = 13 + 1 token):**

| Slot | Name | C | U | R | M | Special | Foil |
|---|---|---|---|---|---|---|---|
| 1–6 | common | 96.2 | — | — | — | 3.85 (source material) | No |
| 7–9 | uncommon | — | 96.4 | — | — | 3.6 (scene cards) | No |
| 10 | wildcard | 4.2 | 74.1 | 16.7 | 2.6 | 2.4 | No |
| 11 | rare_mythic | — | — | 80 | 12.6 | 7.4 (booster fun) | No |
| 12 | foil | 53.9 | 36.7 | 6.7 | 1.2 | 1.5 | Yes |
| 13 | land | — | — | — | — | 100 | No |

Aggregated per pack (`set_pull_rates`): C ~6.35 · U ~4.00 · R ~1.034 · M ~0.164. Per-slot in `catalog.pack_slots`.

## Open work

### Active

- **Graded card tracking** — `graded_price_history` populating in background (~2.5k/5k cards). Next: `psa_spec_id` backfill → daily PSA pop → graded premium view → admin frontend chart. Spec ID checklist: `docs/todos/psa-spec-id-backfill.md`. Feature cols already wired on 13.5k/16k feature rows.
- **Trends backfill** — `trends_set_interest` only on 2.3k/16k feature rows; finish the sweep across historical snapshots.
- **`pack_expected_value` backfill** — only 300/16k rows populated; fix the `set_market_metrics` join for historical snapshots.
- **EV history backfill** — Step 1: run `ev-history` in backfill mode for existing TCGPlayer history (~1yr coverage). Step 2: blocked on historical singles prices (PriceCharting only has sealed). Step 3: add EV-over-time chart to admin EV tab.
- **One Piece rare_leader / hit_slot EV** — slot 11 + 12 calc looks off. Check per-slot note parsing, `weightedSpecialAvg` weighting for OP, leader double-counting between slots, validate against known box breaks.
- **Sentiment / market focus** — derive metrics from existing TCGPlayer signals (price velocity 7/30/90d, volume trends), build admin dashboard. External sources (Reddit/YouTube) optional.

### EV expansion

- **MTG draft/set boosters (2022–23)** — `docs/todos/mtg-ev-expansion.md` (8 sets, draft + set booster slots needed).
- **Weiss Schwarz English (2024–25)** — `docs/todos/ws-ev-expansion.md` (~18 sets).
- **Missing PriceCharting URLs** — `docs/todos/pricecharting-urls.md` (~85 products across MTG / WS / Hololive / Riftbound).
- **Precon deck lists** — JS + tab structure done; need to populate first JSON files and run `bulk_insert_precon_deck_lists.py`. Format: `{game, set_code, product_type, cards: [{card_number, quantity}]}`.

### Cost reduction

- **Docker Hub migration done** for backend (2026-04-03). Images push to `docker.io/philwin/<image>`. Old AR repo `tcg-collection` deleted. **Rotate Docker Hub PAT** — token was exposed in a chat session; regenerate at hub.docker.com/settings/security and update `DOCKERHUB_TOKEN` in all repos.
- **Homeserver-primary / Cloud Run-fallback** for API + jobs — `docs/todos/homeserver-failover.md`.
- **PG-primary migration** (major, 2–3 weekends) — flip data layer to Postgres on homelab; BQ becomes outbox-fed analytics replica. `docs/todos/pg-primary-migration.md`.

### EV tab — still open

- **"Sell as 1× collection set"** (combined multi-rarity bundle) — deferred. Would be a third tier card next to Normal/Foil Playset.
- **Lycoris Recoil Premium** — `data/playset-tiers.json` entry ready; verify `lycoris-premium` has pull rates + single cards in BQ before use.
- **PSA 10 population-based gem-rate autofill** — would feed the per-rarity Grade & Sell input from `psa_population_history` once `psa_spec_id` is populated.

## Data Flow

```
BigQuery (source of truth)
  ├── API (on mutation) ──► GCS bucket ──┐
  ├── API (on mutation) ──► data repo  ──┤──► frontends (GitHub Raw → GCS → API)
  └── Cron job (weekly) ──► GCS + data repo
```

## Sections

| Section | Layout | Data | API |
|---|---|---|---|
| Sealed Products | `themes/admin/layouts/sealed-products/list.html` | `data/sealed-products.json` | `/sealed-products` |
| Single Cards | `themes/admin/layouts/single-cards/list.html` | `data/single-cards.json` | `/single-cards` |
| Set Pull Rates | `themes/admin/layouts/set-pull-rates/list.html` | `data/set-pull-rates.json` | `/set-pull-rates` |
| Expected Value | `themes/admin/layouts/expected-value/list.html` | (composes above) | (PUT `/sealed-products/.../ev-approval`) |

To add a section: create `content/<section>/_index.md`, add nav link in `navbar.html`, create `themes/admin/layouts/<section>/list.html`.

## Key files

| Path | Purpose |
|------|---------|
| `static/js/firebase-init.js` | Firebase init, `authSignOut()`, `isEmailAllowed()`, auth state listener |
| `static/js/api.js` | `api(method, path, body)` (token attached) + `qs()` query builder |
| `static/js/app.js` | `showToast()`, `triggerSync()` |
| `static/js/data-loader.js` | `loadJsonData(filename)` — GitHub-first, GCS-fallback |
| `data/jumpstart-decks.json` | Half-deck lists (e.g. MTG TLA jumpstart) |
| `data/playset-tiers.json` | Grouped Playset Tiers config (Normal / Foil per game/set) |

## Composite PK URL encoding

Sealed `(game, set_code, product_type)`, single-cards `(game, set_code, card_number)`, set-pull-rates `(set_code, rarity)`. Segments are `encodeURIComponent`-encoded by the frontend.
