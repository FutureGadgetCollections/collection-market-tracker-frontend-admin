# collection-market-tracker-frontend-admin

Admin interface for the Collection Market Tracker — a Hugo-based static site that lets admins manage tracked products and view market pricing data.

## Architecture

```
Browser
  │
  ├── Read (static JSON data)
  │     └── GitHub Raw (FutureGadgetCollections/collection-market-tracker-data)
  │           └── GCS fallback (collection-market-tracker-data bucket)
  │
  └── Write (create, update, delete)
        └── Backend API (collection-market-tracker-backend on Cloud Run)
              ├── Firebase Auth token verified
              ├── Operation applied to BigQuery
              └── Updated JSON published to GitHub + GCS
```

**Reads** are served from static JSON files in the data repo, published by the backend after each mutation. The frontend fetches from GitHub Raw first and falls back to GCS.

**Writes** go to the backend API, which validates the Firebase ID token, applies the operation to BigQuery, and republishes the static data files.

## Related Repositories

| Repo | Purpose |
|------|---------|
| [`FutureGadgetCollections/collection-market-tracker-backend`](https://github.com/FutureGadgetCollections/collection-market-tracker-backend) | Cloud Run backend — BigQuery CRUD + data sync |
| [`FutureGadgetCollections/collection-market-tracker-data`](https://github.com/FutureGadgetCollections/collection-market-tracker-data) | Static JSON data files served to the frontend |

## Tech Stack

- **[Hugo](https://gohugo.io/)** — static site generator
- **Bootstrap 5** — UI framework
- **Firebase Auth (JS SDK)** — Google sign-in and ID token issuance
- **GitHub Pages** — hosting (deployed via GitHub Actions)
- **GitHub Raw / GCS** — static data sources for reads

## Sections

| Section | Path | Data File | Backend Endpoint |
|---------|------|-----------|-----------------|
| Sealed Products | `/sealed-products/` | `data/sealed-products.json` | `/sealed-products` |
| Single Cards | `/single-cards/` | `data/single-cards.json` | `/single-cards` |
| Set Pull Rates | `/set-pull-rates/` | `data/set-pull-rates.json` | `/set-pull-rates` |

## Local Development

1. Copy `.env.example` to `.env` and fill in your Firebase config and backend URL.
2. Start the dev server:

```bash
source .env && hugo server
```

3. Open [http://localhost:1313](http://localhost:1313) and sign in with an allowed email.

## Configuration

All configuration is supplied via `HUGO_PARAMS_*` environment variables at build/serve time. See `.env.example` for the full list.

### GitHub Actions Variables (non-sensitive)

| Variable | Purpose |
|----------|---------|
| `GITHUB_PAGES_URL` | Full URL of the GitHub Pages site |
| `HUGO_PARAMS_FIREBASE_AUTH_DOMAIN` | Firebase auth domain |
| `HUGO_PARAMS_FIREBASE_PROJECT_ID` | Firebase project ID |
| `HUGO_PARAMS_FIREBASE_STORAGE_BUCKET` | Firebase storage bucket |
| `HUGO_PARAMS_BACKENDURL` | Backend API base URL (Cloud Run URL) |
| `HUGO_PARAMS_ALLOWED_EMAILS` | Comma-separated list of admin emails |
| `HUGO_PARAMS_GCS_DATA_BUCKET` | GCS bucket name for static data fallback |
| `HUGO_PARAMS_GITHUB_DATA_REPO` | `FutureGadgetCollections/collection-market-tracker-data` |

### GitHub Actions Secrets (sensitive)

| Secret | Purpose |
|--------|---------|
| `HUGO_PARAMS_FIREBASE_API_KEY` | Firebase API key |
| `HUGO_PARAMS_FIREBASE_APP_ID` | Firebase app ID |
| `HUGO_PARAMS_FIREBASE_MESSAGING_SENDER_ID` | Firebase messaging sender ID |

## Data Files

The backend syncer exports these files to GCS and GitHub after every write operation:

| Path in repo | Format | Description |
|---|---|---|
| `data/sealed-products.json` | JSON array | Sealed product catalog |
| `data/single-cards.json` | JSON array | Single card catalog |
| `data/set-pull-rates.json` | JSON array | Pull rate reference data |
| `schema/sealed-products.json` | BQ schema | Field definitions |
| `schema/single-cards.json` | BQ schema | Field definitions |
| `schema/set-pull-rates.json` | BQ schema | Field definitions |

> **Note:** The data repo (`FutureGadgetCollections/collection-market-tracker-data`) has not been fully set up yet. The backend will publish these files automatically after each sync operation.
