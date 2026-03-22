# collection-market-tracker-frontend-admin

## Project Overview

Hugo-based admin frontend for the **Collection Market Tracker** — tracks TCG market prices and listings. Deployed to GitHub Pages; reads static JSON from the data repo and writes via the backend API.

## Related Repositories

| Repo | Local Path |
|------|-----------|
| Backend (Cloud Run / Go) | `C:\Users\nguye\IdeaProjects\FutureGadgetLabs\collection-market-tracker-backend` |
| Data files (static JSON) | `C:\Users\nguye\IdeaProjects\FutureGadgetLabs\collection-market-tracker-data` |

- Data GitHub repo: `FutureGadgetCollections/collection-market-tracker-data` (not fully set up yet)
- Backend GitHub repo: `FutureGadgetCollections/collection-market-tracker-backend`

## Architecture

- **Framework:** [Hugo](https://gohugo.io/) — static site generator with Go templates
- **Theme:** Custom theme (`themes/admin/`) — Bootstrap 5 layout
- **Auth:** Firebase Authentication — Google sign-in; ID token attached to all backend requests
- **Backend communication:** `api()` helper in `static/js/api.js` handles token attachment automatically
- **Data reads:** Static JSON from GitHub Raw (`collection-market-tracker-data`) with GCS fallback, via `static/js/data-loader.js`
- **Deployment:** GitHub Pages via GitHub Actions (`.github/workflows/deploy.yml`)

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
- Composite PKs: sealed-products `(game, set_code, product_type)`, single-cards `(game, set_code, card_number)`, set-pull-rates `(era, set_code, rarity)`
- URL segments for composite PKs are `encodeURIComponent`-encoded by the frontend
- To add a new section: create `content/<section>/_index.md`, add a nav link in `navbar.html`, and create `themes/admin/layouts/<section>/list.html`
