# DEPLOYMENT.md — one-time PAT-gated setup (≈10 minutes once inputs land)

> **DEPLOYED 2026-10-09 (W18) — this runbook is now HISTORICAL.**
> The two user-gated inputs landed (a live Netlify PAT + the GitHub-App
> link) and every step below was executed. As-deployed state:
>
> | Item | Value |
> |---|---|
> | Site | `shiny-pavlova-86b66a` (`b631a019-21ad-4716-adf4-04aab467fdd0`), account `trinitylivy's team` (`688b02550dc1ab56456ffa16`) |
> | Git link | `comfy-backend/comfy-scraper`, production branch `main`; `allowed_branches = [main, scrape]` |
> | Build hook | `daily-scrape` (`6ac84bb93a23aeb044d152f4`), branch `scrape` |
> | Site env vars | `GH_PAT`, `ALERT_GH_PAT` (= GH_PAT for now; a dedicated issues-only PAT is pending), `GITLAB_PAT`, `NETLIFY_AUTH_TOKEN`, `NETLIFY_SITE_ID`, `BUILD_HOOK_URL` — all four scopes each |
> | Scheduled fn | `daily-scrape.mjs`, `schedule: "0 4 * * *"` (daily 04:00 UTC), env-frozen at the last production deploy (values unchanged since the 02:09 UTC republish `a49ce76`; any later rotation requires a new republish) |
> | First E2E fire | 2026-10-09 02:09:54 UTC branch build, **ready in 141 s**: data commit `490ddf52` (corpus 956→967), GL mirror same-day, Blobs snapshot `snapshots/2026-10-09/` (11.9 MB), Vercel prod verified, state `source: netlify` |
> | Ramp-up | EXECUTED same day (watchdog daily 04:30+16:30 UTC + 26h threshold + self-heal dispatch; GHA lane moved to Wed/Thu) — see the data repo's `work/comfy-templates/docs/DESIGN_W15_BACKUP_NETLIFY.md` W18 section |
>
> API gotcha discovered during deployment (free tier): the ACCOUNT env
> API rejects object bodies ("shared env var", 403 paid-only) — site env
> vars must be created via `POST /api/v1/accounts/{acct}/env?site_id={site}`
> with an **ARRAY body** `[{"key":…, "values":[{"value":…}], "site_ids":[…]}]`.
> The site-level `/sites/{id}/env` POST route does not exist (404).

The experiment is fully built; deployment is blocked ONLY on two
user-gated inputs. Everything else below is scripted or copy-paste.

## Prerequisites (the two asks)

1. **A live Netlify PAT** (`nfp_…`) — create at
   `app.netlify.com/user/applications` (scopes: sites read/write, builds,
   blobs). Any free-tier account works; a dedicated one from the
   netlify-maxxing fleet is ideal (avoids the 1-concurrent-build-slot
   contention with fleet experiments). NOTE: the token that used to live
   in `belram448O/zai-harness/.env` (`nfp_YfWh…ec87`, site
   `01c2e47f-…`, "transcendent-cheesecake") is **dead — confirmed 401 on
   2026-09-30**; the fleet's 90 live PATs live in that project's
   session-local `scripts/secrets.json`, unreachable from the
   comfy-templates sandbox.
2. **A GitHub App link** — Netlify sites build from Git only via an
   installed app; API deploys never run builds, and build hooks are
   no-ops on Git-less sites (netlify-free-tier-maxxing AGENTS.md,
   EMPIRICAL r2). The dashboard flow: connect the site to
   `comfy-backend/comfy-scraper` (install the Netlify GitHub App on the
   `comfy-backend` org if not already). This is a browser click — it
   cannot be automated from the API.

## Deploy steps

```bash
TOKEN='nfp_…'      # the live Netlify PAT
SITE=''            # filled after step 1

# 1. Create the site (no repo yet — we link in the dashboard in step 2)
SITE_JSON=$(curl -s -X POST https://api.netlify.com/api/v1/sites \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"name":"comfy-scraper"}')
SITE=$(echo "$SITE_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
echo "site: $SITE"

# 2. DASHBOARD (one time): link the site to comfy-backend/comfy-scraper
#    Site configuration → Build & deploy → Link repository → GitHub →
#    comfy-backend/comfy-scraper, production branch: main.

# 3. Site env vars (Build & deploy → Environment):
#    GH_PAT            trinitylivy PAT (repo push to comfy-templates)
#    ALERT_GH_PAT      a SEPARATE scoped PAT (issues:write on the runner
#                      repo) — so a dead GH_PAT cannot also kill the alert
#                      (the 2026-09-21 silent-death class; scrape.sh falls
#                      back to GH_PAT when unset)
#    GITLAB_PAT        the GitLab mirror PAT
#    NETLIFY_AUTH_TOKEN $TOKEN        (blobs from the build command)
#    NETLIFY_SITE_ID   $SITE
#    BUILD_HOOK_URL    https://api.netlify.com/build_hooks/<id>   (step 5)
#    — or via API:
#    curl -s -X POST https://api.netlify.com/api/v1/accounts/<acct>/env \
#      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
#      -d '{"key":"GH_PAT","values":["ghp_…"],"site_ids":["'$SITE'"]}'
#
#    NOTE (W15-r3 env-freeze): scheduled-function env vars are frozen at
#    the LAST PRODUCTION DEPLOY. Rotating BUILD_HOOK_URL or tokens later
#    requires republishing main (one 15-cr deploy on credit-based
#    accounts) — include this in any PAT-rotation runbook.

#    NETLIFY_SITE_ID   $SITE
#    BUILD_HOOK_URL    https://api.netlify.com/build_hooks/<id>   (step 5)
#    — or via API:
#    curl -s -X POST https://api.netlify.com/api/v1/accounts/<acct>/env \
#      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
#      -d '{"key":"GH_PAT","values":["ghp_…"],"site_ids":["'$SITE'"]}'

# 4. Seed the branches: push main, then derive the scrape branch
git clone https://github.com/comfy-backend/comfy-scraper && cd comfy-scraper
bash scripts/sync-scrape-branch.sh        # creates + pushes `scrape`

# 5. Create the build hook (Build & deploy → Build hooks → "daily-scrape",
#    branch: scrape) — then put its URL into BUILD_HOOK_URL (step 3).
#    API: curl -s -X POST https://api.netlify.com/api/v1/sites/$SITE/build_hooks \
#      -H "Authorization: Bearer $TOKEN" -d '{"title":"daily-scrape","branch":"scrape"}'

# 6. Production deploy: with the site Git-linked to production branch
#    `main`, pushing main (step 4) ALREADY created the production deploy —
#    do NOT also run `netlify deploy --prod` (that would mint a SECOND
#    15-credit spend on credit-based accounts; W15-r3 amendment). Just
#    confirm the main deploy is green in the dashboard. This one deploy
#    unlocks: scheduled functions (published-deploy requirement) AND blobs
#    writes (the fresh-site write gate clears on any deploy record).

# 7. Smoke-test the lane manually (a branch build, free):
curl -X POST "${BUILD_HOOK_URL}?branch=scrape"
#    → watch the deploy log; expect: pipeline → audit → consumption test
#    → push (or "No data changes") → GL mirror OK → DONE all steps green.
#    First run after a long gap may take ~6-8 min (full re-scrape).
#    Then verify the blobs lane end-to-end (W15-r1 F9 — prune/list have
#    never run live; the snapshot step above proves writes only):
#      NETLIFY_AUTH_TOKEN=$TOKEN NETLIFY_SITE_ID=$SITE \
#        python3 work/comfy-templates/scripts/blobs_backup.py list --prefix snapshots/
#    Expect: dated snapshot keys + meta + latest pointer (from step 7's
#    build, which ran blobs_backup.py snapshot).

# 8. Verify the scheduled function fires tomorrow 04:00 UTC:
#    site deploys list shows a daily scrape-branch build + the GitHub
#    state/last-run.json gains "source": "netlify".
```

## Post-deployment (the ramp-up)

Once ~3 consecutive daily fires are green:

1. **Tighten the standby watchdog** to daily cadence + ~26h freshness
   window (it currently checks weekly with a 7-day window — see
   `comfy-templates-standby/.github/workflows/watchdog.yml`; the
   Netlify-cron-unreliability risk is exactly what it catches).
2. **Promote the blobs step** from warning to fatal (refresh.yml +
   scrape.sh) — Blobs becomes load-bearing once the migration is proven.
3. GHA weekly cron STAYS as backup (user directive 2026-09-30). Consider
   moving its schedule to Wednesday so its no-op runs confirm the GHA
   lane weekly without racing the daily Netlify fires.

## Teardown / rollback

- Disable daily fires: delete the build hook (or set the fn's schedule
  far out) — the GHA weekly cron continues untouched.
- Full teardown: delete the site; the Blobs store `site:comfy-backup`
  keeps its snapshots until deleted (store-path DELETE = bulk purge —
  careful, it is NOT reversible).
