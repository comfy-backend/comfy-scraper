# comfy-scraper — Netlify-hosted daily data refresh (cloud build as compute)

This repo is the **Netlify migration experiment** for the comfy-templates
data pipeline: the weekly GitHub Actions scrape moves to a **daily run on
Netlify's build infrastructure** (free tier), with the existing GHA weekly
cron kept as a backup.

> **Status: LIVE — deployed 2026-10-09, daily 04:00 UTC** (site
> `shiny-pavlova-86b66a`; first E2E fire green in 141 s: data commit,
> GitLab mirror, Blobs snapshot, Vercel prod verified — see
> `docs/DEPLOYMENT.md` for the as-deployed record). The GHA weekly
> cron (now Wed/Thu) remains the backup lane; the standby watchdog
> (daily 04:30 + 16:30 UTC) alerts + self-heals if this lane goes
> quiet.

## How it works

```
Netlify scheduled function (production deploy, daily 04:00 UTC, <1s)
   └─ POSTs the site's build hook  (?branch=scrape)
         └─ Netlify CLOUD BUILD runs on the `scrape` branch (~2–5 min, free):
               netlify/scrape.sh — an exact port of the GHA refresh.yml:
                 1. clone trinitylivy/comfy-templates (GH_PAT)
                 2. daily_refresh.sh   — the 8-step pipeline (stdlib Python)
                 3. audit_refresh.py   — 10 structural checks A–J
                 4. bun + vitest       — app consumption contract test
                 5. race-safe commit + push to GitHub main
                 6. GitLab mirror push (redundant data backup)
                 7. Netlify Blobs snapshot (tertiary backup)
                 8. prod verify (Vercel built_at poll)
                 9. state/last-run.json update (public observability)
              failure → alert issue on comfy-backend/comfy-templates-runner
                        (same marker/label protocol as the GHA workflow;
                        any green run — GHA or Netlify — auto-closes)
```

The daily data commit flows exactly as it does from GHA today: push to
`trinitylivy/comfy-templates` main → Vercel auto-deploys.

## Why a branch build (not production builds)

Netlify free tier (credit-based accounts, post-Apr-2026): **production
deploys cost 15 credits each; branch deploys and previews are free**.
Daily production builds would burn ~450 cr/month — over the 300 cr pool.
Daily BRANCH builds (`?branch=scrape`) cost **zero credits**, and build
minutes are not metered on either free cohort (free-is-free accounts have
a 300 build-min/month hard cap — our ~5 min/day ≈ 150). See
`docs/ARCHITECTURE.md` for the full budget math.

## Branch layout

| branch   | role                                                            |
|----------|-----------------------------------------------------------------|
| `main`   | production deploy: the tiny status stub + `netlify/functions/` scheduled fn |
| `scrape` | the compute lane: identical tree, but `netlify.toml` points `build.command` at `netlify/scrape.sh` |

The scheduled function only fires on **published** (production) deploys —
that is why it lives on `main` while the heavy build lives on `scrape`.

## Repo contents

```
netlify.toml                      main-branch build (inert stub publish)
netlify/scrape.branch.toml        the scrape branch's netlify.toml (build cmd)
netlify/scrape.sh                 the runner — port of GHA refresh.yml
netlify/functions/daily-scrape.mjs  scheduled fn: in-flight guard + build-hook POST
dist/index.html                   publish stub / status page
docs/DEPLOYMENT.md                one-time PAT-gated setup runbook
docs/ARCHITECTURE.md              design + free-tier budget + risk register
```

## Semantics parity with the GHA workflow

- Same gates in the same order — a green Netlify run means exactly what a
  green GHA run means (audit A–J, consumption test, race-safe push,
  GL mirror fatal-on-fail, blobs warning-class).
- Same alert protocol — both runners write to the same alert issue class;
  `data-refresh-alert` label, `<!-- bot: data-refresh-alert -->` marker.
- Same race-safety — rebase + retry ×3 against origin/main, never force.
- `TARGET_BRANCH` env (default `main`) allows dry-running against a
  scratch branch (used by the local E2E validation).
