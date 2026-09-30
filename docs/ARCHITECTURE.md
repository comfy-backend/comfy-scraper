# ARCHITECTURE.md — why cloud-build-as-compute, the budget, the risks

## The constraint set

- The pipeline is **Python, 100% stdlib** (urllib/json/gzip — no pip
  installs needed anywhere), runs in ~1–3 min on GHA (incremental, cached
  by meta.json etags), needs git + a GitHub PAT to push results.
- Netlify Functions are **JS-only** (30s sync / 15 min background) —
  porting the Python pipeline is a rewrite, rejected.
- Netlify **cloud builds** run arbitrary bash on Ubuntu 24.04 (Node 24,
  Python available, outbound HTTP, `curl | bash` works for bun) — exactly
  the environment the pipeline already runs in on GHA.
- **API deploys never run builds** and **build hooks are no-ops without a
  Git-connected site** (both EMPIRICAL, netlify-free-tier-maxxing r2) —
  so cloud compute is reachable ONLY through the Git-connected build
  path: git push, build hook, or build trigger.
- **Scheduled functions fire only on published (production) deploys**,
  30s cap — fine for a fire-and-forget build-hook POST.

⇒ Architecture: **scheduled function (production deploy) → build hook →
daily `scrape`-branch build running `netlify/scrape.sh`** (a faithful
port of the GHA refresh.yml).

## Free-tier budget (per month, daily cadence)

| Resource            | Usage                                | Free allowance                    |
|---------------------|--------------------------------------|-----------------------------------|
| Branch builds       | 30 × ~5 min = ~150 build-min         | credit-based: not metered; free-is-free: 300 min hard ✅ |
| Production deploys  | **1** (the unlock, manual)           | 15 cr once (credit-based) / 0 (free-is-free) |
| Scheduled function  | 30 × <1 s ≈ 0.1–0.2 cr/month         | negligible on both cohorts ✅     |
| Blobs storage       | ~45 × 5.5 MB snapshots ≈ 250 MB + 8 git bundles ≈ 700 MB | no storage meter documented (5 GB/object) ✅ |
| Web requests        | ~30 fn invocations                   | 2 cr / 10K ✅                     |

Worst case on a **credit-based** free account: ~15–16 cr/month total
(one-time 15 + ~1 ongoing). On **free-is-free**: 150/300 build minutes.
Both comfortable.

## Risk register

| Risk | Class | Mitigation |
|---|---|---|
| Scheduled functions unreliable on Free (pre-r4 finding; r4 doc-confirmed the published-deploy requirement, but daily-cadence reliability is unproven) | ⚠ main experiment risk | (1) deploy on production deploy per docs; (2) the **GHA weekly cron stays armed** (≤7-day worst-case staleness); (3) post-migration the **standby watchdog tightens to daily + 26h window** → same-day alert on missed fires; (4) deploy history = the evidence stream |
| Build-slot contention (1 concurrent build/account) | ops | fn's in-flight guard skips firing while a build runs; use a dedicated account, not one running fleet experiments |
| Build queue pile-up on a stuck build | ops | guard skips; stuck builds can be cancelled: `POST /api/v1/deploys/{id}/cancel`; 25-min `timeout-minutes` equivalent via Netlify's build timeout |
| Upstream API rate limits at 7× cadence | etiquette | 05 now runs a fresh-on-change + 7-day TTL cache (W15): daily steady state ≈ 94 detail fetches/day (same weekly volume as before, spread out); title changes refresh immediately; the weekly GHA lane still full-refreshes |
| Data churn / alert noise at daily cadence | calibration | audit check-D caps + verify thresholds were tuned weekly — the W15 daily-cadence audit reviews every gate; worst case a floor needs conscious re-calibration (never loosen to go green) |
| Vercel deploy volume (Hobby: 100/day) | quota | 1/day ✅ |
| GHA + Netlify accidental overlap | race | race-safe push (rebase ×3) already handles it; schedules are 7h apart anyway |
| Blobs fresh-site write gate | ops | clears on the first deploy record (the production publish in DEPLOYMENT step 6) |
| `scrape` branch drift from main | process | `scripts/sync-scrape-branch.sh` (derived branch, scripted, never force-push) |
| PAT death (the 2026-09-21 class) | ops | alert issue fires from the build itself (clone step reds loudly); GH_PAT rotation procedure already exists (`set-secret.py`) — extend to the Netlify site env when rotating |

## Backup layering after migration (the user's 2026-09-30 directive)

| Layer | What | When | Where |
|---|---|---|---|
| 1 | git history + data (primary disk) | every push | github.com/trinitylivy/comfy-templates |
| 2 | same git history (redundant copy) | every data commit (fatal-on-fail step) | gitlab.com/ansgareutychisO/comfy-templates |
| 3 | data-layer snapshots (dated tar.gz) + weekly git bundles | every pushed refresh | Netlify Blobs store `site:comfy-backup` |

Sizing note: the repo is ~90 MiB packed (largest blob 8.6 MB) — years of
headroom on GitLab's free limits; Blobs is therefore redundancy-by-design
(three independent providers), not a size necessity today.
