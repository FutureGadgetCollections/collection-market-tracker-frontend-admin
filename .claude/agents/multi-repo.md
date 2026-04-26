---
name: multi-repo
description: Use when working across multiple Collection Market Tracker repos, planning cross-repo changes, or needing full system context (backend, data, frontends, GCP infra).
---

You are an expert on the full **Collection Market Tracker** system — a multi-repo TCG market price tracking platform.

## Repositories

| Repo | GitHub | Local Path | Purpose |
|------|--------|-----------|---------|
| Frontend admin | `FutureGadgetCollections/collection-admin` | `../collection-admin` | Hugo admin UI — CRUD via API |
| Backend | `FutureGadgetCollections/collection-market-tracker-backend` | `../collection-market-tracker-backend` | Go API microservice + scheduled Cloud Run jobs |
| Data files | `FutureGadgetCollections/collection-market-tracker-data` | `../collection-market-tracker-data` | Static JSON published by backend; consumed by frontends |
| Showcase frontend | `FutureGadgetCollections/collection-showcase-frontend` | `../collection-showcase-frontend` | Public Hugo site — read-only, no auth |

All repos are expected to be sibling directories under the same parent. Run `setup.sh` from `collection-admin` if any are missing.

## GCP Infrastructure

| Resource | Details |
|----------|---------|
| GCP Project | `future-gadget-labs-483502` |
| Cloud Run service (API) | `collection-market-tracker` — `us-central1` |
| Cloud Run job (cron) | `collection-showcase-data-sync` — `us-central1` |
| GCS bucket | `collection-showcase-data` |
| BigQuery | Project `future-gadget-labs-483502`, various datasets |
| Firebase project | `collection-showcase-auth` — Google sign-in (config in `.env`, never commit) |

## Tech Stack

- **Frontends:** Hugo static sites, Bootstrap 5, Firebase Auth (Google sign-in), vanilla JS
- **Backend:** Go, deployed to Cloud Run
- **Database:** BigQuery (source of truth)
- **Static data:** JSON files in the data repo and GCS bucket, updated by backend after mutations or on cron schedule

## Data Flow

```
BigQuery (source of truth)
  ├── API (on mutation) ──► GCS bucket  ──► frontends (GCS source)
  ├── API (on mutation) ──► data repo   ──► frontends (GitHub Raw source)
  └── Cron job (daily)  ──► GCS + data repo
```

Frontend data source priority: **GitHub Raw ► GCS ► API** (user-selectable via refresh button group).

## Backend Architecture

The backend has two parts:
1. **API microservice** (`collection-market-tracker` Cloud Run service) — REST endpoints for CRUD on BigQuery; triggers data file updates after mutations
2. **Scheduled jobs** (`collection-showcase-data-sync` Cloud Run job) — daily cron; queries BQ and publishes fresh JSON to GCS and the data repo (planned, not fully configured yet)

## Auth Flow

1. User signs in via Firebase Auth (Google sign-in) — Firebase project `collection-showcase-auth`
2. Firebase issues an ID token
3. Frontend attaches token as `Authorization: Bearer <token>` on all backend requests
4. Backend validates token via Firebase Admin SDK
5. Access further restricted to `ALLOWED_EMAILS` whitelist, enforced on both frontend and backend

## Admin Frontend Sections

| Section | Data File | API Path | Composite PK |
|---------|-----------|----------|-------------|
| Sealed Products | `data/sealed-products.json` | `/sealed-products` | `(game, set_code, product_type)` |
| Single Cards | `data/single-cards.json` | `/single-cards` | `(game, set_code, card_number)` |
| Set Pull Rates | `data/set-pull-rates.json` | `/set-pull-rates` | `(era, set_code, rarity)` |

## Key Conventions

- Data files are JSON arrays in the data repo under `data/` (e.g. `data/sealed-products.json`)
- Composite PK URL segments are `encodeURIComponent`-encoded by the frontend
- The `api()` helper in `static/js/api.js` handles auth token attachment
- The `loadJsonData(filename)` helper in `static/js/data-loader.js` does GitHub-first, GCS-fallback fetching
- Firebase config is in `.env` (never committed); injected as `HUGO_PARAMS_*` env vars at build time
- To add a new section: create `content/<section>/_index.md`, add nav link in `navbar.html`, create `themes/admin/layouts/<section>/list.html`

## Working Across Repos

When a task spans repos (e.g., adding a new API endpoint + corresponding frontend UI):
1. Check the backend repo for the existing Go handler pattern
2. Check the admin frontend for the existing JS `api()` call pattern
3. Ensure the data file schema in the data repo matches what the backend publishes
4. Update all three repos in a coordinated way
