# EV History — backfill remaining commander deck singles

## Status

The EV History admin tab (`/expected-value-history/`) charts singles
EV vs sealed price per commander deck. As of the first run only WHO
(Doctor Who) precons have a real time series. Other sets show one EV
data point and no sealed history because:

1. TCGPlayer's annual price-history endpoint rate-limits direct HTTP
   calls. Our Playwright backfill (`scripts/backfill_deck_singles.py`
   in the backend repo) succeeded for WHO singles + sealed (2025-04-24
   .. 2026-04-13) but skipped most FIC/BLC/TDC/EOC products with
   "no annual data captured".
2. The 19 commander deck SKUs have now been added to
   `catalog.sealed_products` with their `tcgplayer_id`, so the regular
   weekly TCGPlayer scrape (Mon 08:00 UTC) starts collecting sealed
   prices for them — the chart's sealed line fills in one weekly
   point at a time from here on.

## Why this matters

We're going to add a lot more commander decks. Every new deck shows
up empty until either (a) several weeks of weekly scraping accumulate
or (b) a backfill is run. Backfill is the only way to get historical
trend on day one.

## What to try next

1. Re-run the Playwright backfill in 1-2 weeks — TCGPlayer's
   rate-limiting on annual history is intermittent and the FIC/BLC/
   TDC/EOC products that failed once may succeed on a retry.
2. Slow the backfill down (currently 5 concurrent browsers, no
   per-request delay). Try 1 concurrent browser with a 2-3s delay
   between products.
3. Bake the backfill into the new-deck onboarding flow: when a new
   commander deck JSON is added, automatically queue its singles +
   sealed precon id for an annual-history backfill rather than
   waiting for the weekly scraper to catch up.
4. Consider a fallback data source for older history (MTGJSON
   AllPrices.json has ~3 months of TCGPlayer history for every card
   keyed by Scryfall id; not as deep as TCGPlayer's annual but
   covers more ids reliably).

## Related files

- `backend/scripts/backfill_deck_singles.py` — one-off Playwright
  backfill, scoped to deck-referenced ids
- `backend/scripts/product_ev_history/build.py` — weekly Cloud Run
  job that publishes data/product-ev-history.json
- `admin/themes/admin/layouts/expected-value-history/list.html` —
  the chart UI
