#!/usr/bin/env bash
# netlify/scrape.sh — the Netlify cloud-build port of the GHA refresh.yml
# (comfy-backend/comfy-templates-runner). Semantics parity is the contract:
# same gates, same order, same failure semantics, same alert protocol.
#
# Runs on the Netlify `scrape` branch build (build hook ?branch=scrape,
# fired daily by netlify/functions/daily-scrape.mjs). ~5 min.
#
# Required env: GH_PAT            (push access to DATA_REPO)
#               ALERT_GH_PAT      (issues:write on RUNNER_REPO — a SEPARATE
#                                  token so a dead GH_PAT cannot also kill
#                                  the alert, the 2026-09-21 silent-death
#                                  class; falls back to GH_PAT if unset)
# Optional env: GITLAB_PAT        (redundant mirror; REQUIRED for main runs —
#                                  absence reds the run, same as GHA)
#               NETLIFY_AUTH_TOKEN + NETLIFY_SITE_ID  (tertiary blobs backup)
#               TARGET_BRANCH     (default main; a scratch branch = dry-run:
#                                  prod-verify + state + alert-close skipped)
#               DATA_REPO         (default trinitylivy/comfy-templates)
#               RUNNER_REPO       (default comfy-backend/comfy-templates-runner)
#               GL_REPO           (default ansgareutychisO/comfy-templates)
set -uo pipefail

GH_PAT="${GH_PAT:-}"
ALERT_GH_PAT="${ALERT_GH_PAT:-$GH_PAT}"   # separate alert credential (F1)
GITLAB_PAT="${GITLAB_PAT:-}"
NETLIFY_AUTH_TOKEN="${NETLIFY_AUTH_TOKEN:-}"
NETLIFY_SITE_ID="${NETLIFY_SITE_ID:-}"
TARGET_BRANCH="${TARGET_BRANCH:-main}"
DATA_REPO="${DATA_REPO:-trinitylivy/comfy-templates}"
RUNNER_REPO="${RUNNER_REPO:-comfy-backend/comfy-templates-runner}"
GL_REPO="${GL_REPO:-ansgareutychisO/comfy-templates}"
DEPLOY_URL="${DEPLOY_URL:-https://app.netlify.com/sites/${SITE_NAME:-comfy-scraper}}"

WORK="${NETLIFY_BUILD_BASE:-$HOME}/comfy-scrape-work"
LOG_PREFIX="[scrape]"
PUSHED=false
SUCCEEDED=false
GL_RESULT="not_run"        # set by the GL mirror step (success/failure)
BLOBS_RESULT="skipped_no_push"  # W19: initialized at the TOP — the exit-trap
                           # state write reads it BEFORE section 8 runs (an
                           # early fatal left it unbound under set -u; caught
                           # live by the W19 ordering probe)
STATE_DONE=false           # the exit trap must not double-write state

log()  { echo "$LOG_PREFIX $*"; }
fatal(){ echo "::error::$*" >&2; exit 1; }

# ─── failure alerting (same marker/label as the GHA workflow) ──────────
alert_on_failure() {
  local reason="${1:-unknown}"
  # Dry-runs (scratch branch) must never page the PROD alert path (F10)
  [ "${TARGET_BRANCH}" = "main" ] || return 0
  [ "${ALERTS_ENABLED:-1}" = "1" ] || return 0
  GH_PAT="$ALERT_GH_PAT" RUNNER_REPO="$RUNNER_REPO" \
  DEPLOY_URL="$DEPLOY_URL" REASON="$reason" python3 - <<'PYEOF' || true
import datetime, json, os, urllib.request
token = os.environ.get("GH_PAT", "")
repo  = os.environ["RUNNER_REPO"]
if not token:
    raise SystemExit(0)
marker, label = "<!-- bot: data-refresh-alert -->", "data-refresh-alert"
url = os.environ["DEPLOY_URL"]; reason = os.environ["REASON"]

def call(method, path, body=None):
    req = urllib.request.Request(
        f"https://api.github.com{path}", method=method, data=body,
        headers={"Authorization": f"token {token}",
                 "User-Agent": "comfy-scraper",
                 "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read(); return resp.status, (json.loads(raw) if raw else {})

try: call("GET", f"/repos/{repo}/labels/{label}")
except Exception:
    try: call("POST", f"/repos/{repo}/labels", json.dumps(
        {"name": label, "color": "d73a4a",
         "description": "automated data-refresh failure alert"}).encode())
    except Exception: pass

try: _, issues = call("GET", f"/repos/{repo}/issues?labels={label}&state=open")
except Exception: raise SystemExit(0)
open_alerts = [i for i in issues if marker in (i.get("body") or "")]
body_text = (
    f"{marker}\n**Netlify daily scrape FAILED** — production data goes "
    f"stale until this is fixed.\n\n"
    f"- Build log: {url} (Netlify dashboard)\n"
    f"- Failed at: `{reason}`\n"
    f"- Time (UTC): {datetime.datetime.now(datetime.timezone.utc).isoformat()}\n\n"
    f"Read the last red line of the build log. Common causes mirror the "
    f"GHA workflow: dead/rotted `GH_PAT` (fails at clone), upstream drift "
    f"(audit A–J red — conscious re-pin procedure in the pin file), "
    f"app-parser break (consumption test withholds the data by design).\n\n"
    f"cc @trinitylivy")
if not open_alerts:
    call("POST", f"/repos/{repo}/issues", json.dumps(
        {"title": "Netlify data refresh FAILED — action required",
         "body": body_text, "labels": [label]}).encode())
    print("[alert] issue CREATED")
else:
    call("POST", f"/repos/{repo}/issues/{open_alerts[0]['number']}/comments",
         json.dumps({"body": body_text}).encode())
    print(f"[alert] issue #{open_alerts[0]['number']} COMMENTED")
PYEOF
}

# ─── 9. runner-repo state writer (W19: DEFINED EARLY, above the trap
#      registration — the exit trap calls it on ANY exit, so it must
#      be parsed before any fatal can fire; defined late it was dead
#      code on every failure path: the trap hit `update_state: command
#      not found`, masked by `|| echo ::warning` — W19-C2 P1) ─────
update_state() {
  log "state/last-run.json update (best-effort)…"
  GH_PAT="$GH_PAT" RUNNER_REPO="$RUNNER_REPO" GL_MIRROR="$GL_RESULT" \
  BLOBS_SNAPSHOT="$BLOBS_RESULT" \
  python3 - <<'PYEOF' || echo "::warning::state commit failed (non-fatal)"
import base64, datetime, json, os, urllib.request
pat, repo = os.environ["GH_PAT"], os.environ["RUNNER_REPO"]
today = datetime.datetime.now(datetime.timezone.utc).strftime("%F")
api = f"https://api.github.com/repos/{repo}/contents/state/last-run.json"

def call(method, body=None):
    req = urllib.request.Request(api, method=method, data=body,
        headers={"Authorization": f"token {pat}",
                 "User-Agent": "comfy-scraper",
                 "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read(); return resp.status, (json.loads(raw) if raw else {})

sha, existing, existing_blobs, _existing_rec = "", "", "", {}
try:
    _, d = call("GET"); sha = d.get("sha", "")
    _existing_rec = json.loads(base64.b64decode(d.get("content", "")))
    existing = _existing_rec.get("date", "")
    existing_blobs = _existing_rec.get("blobs_snapshot", "")
except Exception: pass
# W18-r1 P2 (mirror of the refresh.yml fix): first-writer-of-the-day-wins,
# EXCEPT an unhealthy blobs record — a later same-day run with a real,
# DIFFERENT blobs outcome may overwrite it, or the watchdog reds 2-3x on
# a single transient failure. An empty outcome must NOT mask a failure.
new_blobs = os.environ.get("BLOBS_SNAPSHOT", "")
new_gl = os.environ.get("GL_MIRROR", "")
# W18-r3 P3-1: skip-class values are NOT real outcomes — they must not
# "heal" a recorded failure (a skipped step yields 'skipped', never '').
NOT_AN_OUTCOME = ("", "skipped", "skipped_no_push", "cancelled", "not_run")
heals = (
    (existing_blobs in ("failed", "skipped_no_secrets")
     and new_blobs not in NOT_AN_OUTCOME and new_blobs != existing_blobs)
    or (_existing_rec.get("gl_mirror") == "failure"
        and new_gl not in NOT_AN_OUTCOME and new_gl != "failure")
)
if existing == today and not heals:
    print(f"state/last-run.json already records {today} — skipping."); raise SystemExit(0)
if existing == today:
    print(f"state/last-run.json records {today} with an unhealthy record "
          f"(blobs={existing_blobs!r}, gl={_existing_rec.get('gl_mirror')!r}) — "
          f"overwriting with this run's outcomes "
          f"(blobs={new_blobs!r}, gl={new_gl!r}).")

built_at, total = "", None
try:
    stats = json.load(open("public/data/stats.json"))
    built_at, total = stats.get("built_at", ""), stats.get("total_workflows")
except Exception: pass
payload = {"date": today, "built_at": built_at, "corpus_total": total,
           "gl_mirror": os.environ.get("GL_MIRROR", ""),
           "blobs_snapshot": os.environ.get("BLOBS_SNAPSHOT", ""),
           "source": "netlify",
           "purpose": "public observability: last successful data-refresh run "
                      "(keeps GHA schedules alive + shows liveness of the workload)"}
body = json.dumps({"message": f"state: netlify refresh ran on {today}",
                   "content": base64.b64encode(json.dumps(payload, indent=2).encode()).decode()}).encode()
if sha:
    body = json.loads(body.decode()); body["sha"] = sha; body = json.dumps(body).encode()
call("PUT", body)
print(f"state/last-run.json updated to {today}.")
PYEOF
  STATE_DONE=true
}

on_exit() {
  local rc=$?
  if [ $rc -ne 0 ] && [ "$SUCCEEDED" != "true" ]; then
    alert_on_failure "exit rc=$rc"
  fi
  # W18-b (GAP 5a): the state update must run on ANY exit for main runs —
  # a GL-mirror failure (fatal, AFTER prod-verify now) used to skip the
  # state write entirely, leaving state/last-run.json stale, which reds
  # watchdog probe 2 spuriously and hides the real failure (gl_mirror).
  if [ "${TARGET_BRANCH}" = "main" ] && [ "${STATE_DONE}" != "true" ]; then
    update_state || echo "::warning::state update (exit path) failed (non-fatal)"
  fi
}
trap on_exit EXIT

# ─── 0. preflight ───────────────────────────────────────────────────────
[ -n "$GH_PAT" ] || fatal "GH_PAT is not set — cannot clone $DATA_REPO"
if [ "$TARGET_BRANCH" = "main" ] && [ -z "$GITLAB_PAT" ]; then
  fatal "GITLAB_PAT is not set — the GitLab mirror (redundant data backup) cannot run"
fi
log "preflight OK: data=$DATA_REPO target=$TARGET_BRANCH runner=$RUNNER_REPO"

# ─── 1. clone (full history — the race-safe rebase needs a merge-base) ──
rm -rf "$WORK"
log "cloning $DATA_REPO…"
git clone -q "https://x-access-token:${GH_PAT}@github.com/${DATA_REPO}.git" "$WORK/repo" \
  || fatal "clone failed — GH_PAT dead/rotted? (same class as the 2026-09-21 incident)"
cd "$WORK/repo"
git config user.name  "trinitylivy"
git config user.email "trinitylivy@gmail.com"   # Vercel blocks other authors

# ─── 2. the 8-step pipeline (01-07 + verify) + public/data mirror ──────
log "running the 8-step refresh pipeline…"
bash work/comfy-templates/scripts/cron/daily_refresh.sh \
  || fatal "refresh pipeline failed (see log above)"

# ─── 3. post-refresh audit — 10 structural checks A–J ───────────────────
log "running audit A–J…"
python3 scripts/audit_refresh.py || fatal "audit failed (A–J structural checks)"

# ─── 4. app consumption contract test (served corpus vs app parsers) ────
log "setting up bun…"
if ! command -v bun >/dev/null 2>&1; then
  curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1 || fatal "bun install failed"
  export PATH="$HOME/.bun/bin:$PATH"
fi
log "app consumption contract test…"
bun install --frozen-lockfile --silent || fatal "bun install failed"
bunx vitest run tests/lib/public-data-consumption.test.ts --reporter=dot \
  || fatal "consumption test failed — corpus withheld by design"

# ─── 5. race-safe commit + push ─────────────────────────────────────────
log "commit + push (race-safe)…"
git add work/comfy-templates/data public/data
if git diff --cached --quiet; then
  log "No data changes — upstream static since the last run"
else
  PUSHED=true
  git commit -q -m "chore(data): daily upstream refresh $(date -u +%Y-%m-%d) [netlify]" \
    || fatal "git commit failed — refusing to push a stale HEAD (F11)"
  # Rebase onto the branch we are pushing to when it exists remotely,
  # else main (first push of a scratch branch cannot conflict) (F12)
  REBASE_BASE=main
  if git ls-remote --heads origin "${TARGET_BRANCH}" 2>/dev/null | grep -q .; then
    REBASE_BASE="${TARGET_BRANCH}"
  fi
  for attempt in 1 2 3; do
    if git push origin "HEAD:${TARGET_BRANCH}"; then
      log "data commit pushed (attempt ${attempt})"
      break
    fi
    if [ "${attempt}" -lt 3 ]; then
      log "push attempt ${attempt} rejected — rebasing on origin/${REBASE_BASE}, retrying"
      if ! git pull --rebase origin "${REBASE_BASE}"; then
        git rebase --abort 2>/dev/null || true
        fatal "rebase onto origin/${REBASE_BASE} failed (conflict with a concurrent push?)"
      fi
    else
      fatal "could not push the data commit after 3 attempts"
    fi
  done
fi

# ─── 6. prod verify (Vercel built_at poll) — main runs only ─────────────
# (W18-b: runs BEFORE the fatal GL mirror so a GL outage cannot hide a
# broken Vercel deploy — order now matches refresh.yml.)
if [ "$TARGET_BRANCH" = "main" ]; then
  log "verifying production deployment…"
  expected="$(python3 -c "import json; print(json.load(open('public/data/stats.json'))['built_at'])" 2>/dev/null || true)"
  [ -n "$expected" ] || fatal "stats.json unreadable — cannot verify prod (F5: an empty expected must never match an unreachable prod)"
  log "expecting prod built_at = ${expected}"
  verified=false
  # 26×12s ≈ 5.2 min (W18-b: +6 over W15-r3's 20 — a rapid push series
  # to main floods the Vercel build queue (every push = one Next.js
  # build, serialized on Hobby); observed 2026-10-09: ~10 pushes/hour
  # pushed deploy latency past 5 min and red'd a healthy run. Keep the
  # total under the ~15-min Netlify build cap.)
  for attempt in $(seq 1 26); do
    got="$(curl -sf --max-time 15 "https://comfy-templates.vercel.app/data/stats.json" \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('built_at',''))" 2>/dev/null || true)"
    if [ "${got}" = "${expected}" ]; then
      log "prod verified: built_at ${got} live (attempt ${attempt})"; verified=true; break
    fi
    log "attempt ${attempt}: prod built_at = '${got:-unreachable}' — waiting for the Vercel deploy"
    sleep 12
  done
  [ "$verified" = "true" ] || fatal "prod does not serve built_at ${expected} after ~5 min (26x12s) — Vercel deploy failed or very slow"
fi

# ─── 7. GitLab mirror (redundant data backup — fatal on failure) ────────
# (W18-b/GAP 5a: moved AFTER prod-verify — a GL failure must not kill
# deploy verification; the state write now happens on ANY exit.)
if [ "$TARGET_BRANCH" = "main" ]; then
  log "GitLab mirror…"
  mirrored=false
  for attempt in 1 2 3 4 5; do
    if git push "https://oauth2:${GITLAB_PAT}@gitlab.com/${GL_REPO}.git" HEAD:main 2>&1 | tee /tmp/glmirror.err; then
      log "GitLab mirror OK (attempt ${attempt})"; mirrored=true; GL_RESULT="success"; break
    fi
    if grep -qE "HTTP Basic: Access denied|Authentication failed|401" /tmp/glmirror.err 2>/dev/null; then
      GL_RESULT="failure"  # W19 P2: record it — the state write must never say not_run for a real mirror failure
      fatal "GitLab mirror got 401 — GITLAB_PAT dead/rotted (deterministic; not retrying)"
    fi
    log "mirror attempt ${attempt} failed — retrying in 20s"; sleep 20
  done
  if [ "$mirrored" != "true" ]; then
    GL_RESULT="failure"
    fatal "GitLab mirror failed after 5 attempts — redundant copy stale: gitlab.com/${GL_REPO}"
  fi
fi

# ─── 8. Netlify Blobs snapshot (tertiary — warning on failure) ──────────
BLOBS_RESULT="skipped_no_push"
if [ "$PUSHED" = "true" ] && [ -n "$NETLIFY_AUTH_TOKEN" ] && [ -n "$NETLIFY_SITE_ID" ]; then
  log "blobs snapshot (tertiary backup)…"
  if python3 work/comfy-templates/scripts/blobs_backup.py snapshot --keep 45; then
    BLOBS_RESULT="success"
  else
    BLOBS_RESULT="failed"
    echo "::warning::blobs snapshot failed (non-fatal — tertiary layer)"
  fi
elif [ "$PUSHED" = "true" ]; then
  BLOBS_RESULT="skipped_no_secrets"
  log "blobs snapshot skipped (Netlify secrets not set)"
fi
log "blobs snapshot result: ${BLOBS_RESULT}"


if [ "$TARGET_BRANCH" = "main" ]; then
  update_state || echo "::warning::state update failed (non-fatal)"

  log "auto-closing resolved alerts…"
  GH_PAT="$GH_PAT" RUNNER_REPO="$RUNNER_REPO" DEPLOY_URL="$DEPLOY_URL" \
  python3 - <<'PYEOF' || true
import json, os, urllib.request
token, repo = os.environ["GH_PAT"], os.environ["RUNNER_REPO"]
label, marker = "data-refresh-alert", "<!-- bot: data-refresh-alert -->"
url = os.environ["DEPLOY_URL"]
def call(method, path, body=None):
    req = urllib.request.Request(f"https://api.github.com{path}", method=method, data=body,
        headers={"Authorization": f"token {token}", "User-Agent": "comfy-scraper",
                 "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read(); return resp.status, (json.loads(raw) if raw else {})
try: _, issues = call("GET", f"/repos/{repo}/issues?labels={label}&state=open")
except Exception: raise SystemExit(0)
closed = 0
for issue in issues:
    if marker not in (issue.get("body") or ""): continue
    call("POST", f"/repos/{repo}/issues/{issue['number']}/comments",
         json.dumps({"body": f"Recovered: green Netlify run {url} — alert auto-closed."}).encode())
    call("PATCH", f"/repos/{repo}/issues/{issue['number']}",
         json.dumps({"state": "closed"}).encode())
    closed += 1
print(f"resolved {closed} alert issue(s)")
PYEOF
fi

# ─── 10. watchdog-of-the-watchdog (GAP 1, W18-b) — main runs only ───────
# The standby watchdog is the OUTER safety net (daily probes + self-heal).
# Nothing probes the prober — if IT dies, every later lane failure goes
# unnoticed. This daily lane is the independent rail that watches it: the
# standby's state/watchdog.json heartbeat is PUBLIC. A DEDICATED label is
# used so green refresh runs do NOT auto-close it (only a freshly-observed
# heartbeat closes it — the probe itself is the closer).
if [ "$TARGET_BRANCH" = "main" ]; then
  log "standby-watchdog heartbeat probe…"
  GH_PAT="$ALERT_GH_PAT" RUNNER_REPO="$RUNNER_REPO" DEPLOY_URL="$DEPLOY_URL" \
  python3 - <<'PYEOF' || echo "::warning::watchdog-stale probe failed (non-fatal)"
import datetime, json, os, urllib.request
token = os.environ.get("GH_PAT", "")
repo = os.environ["RUNNER_REPO"]
url = os.environ["DEPLOY_URL"]
label, marker = "watchdog-stale-alert", "<!-- bot: watchdog-stale-alert -->"
state_url = ("https://raw.githubusercontent.com/comfyui-catalog/"
             "comfy-templates-standby/main/state/watchdog.json")
if not token:
    raise SystemExit(0)

def call(method, path, body=None):
    req = urllib.request.Request(f"https://api.github.com{path}", method=method, data=body,
        headers={"Authorization": f"token {token}", "User-Agent": "comfy-scraper",
                 "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read(); return resp.status, (json.loads(raw) if raw else {})

wd_date, age_days = "", None
try:
    with urllib.request.urlopen(state_url, timeout=30) as resp:
        wd_date = json.load(resp).get("date", "")
    age_days = (datetime.datetime.now(datetime.timezone.utc).date()
                - datetime.date.fromisoformat(wd_date)).days
except Exception as e:
    print(f"watchdog.json unreachable ({e}) — treating as STALE (loud)")
    age_days = 999

try: _, issues = call("GET", f"/repos/{repo}/issues?labels={label}&state=open")
except Exception: issues = []
open_alerts = [i for i in issues if marker in (i.get("body") or "")]

if age_days is not None and age_days > 2:
    body_text = (
        f"{marker}\n**STANDBY WATCHDOG HEARTBEAT STALE** — the outer safety "
        f"net (daily freshness probes + self-heal dispatch) appears DEAD: "
        f"state/watchdog.json last heartbeat = {wd_date or 'unreachable'} "
        f"({age_days}d old). Every failure it would catch is currently "
        f"unguarded. Check the standby repo's watchdog workflow state + its "
        f"schedules.\n\n- Observed by the Netlify daily lane: {url}\n"
        f"- Time (UTC): {datetime.datetime.now(datetime.timezone.utc).isoformat()}\n\n"
        f"cc @trinitylivy")
    if not open_alerts:
        call("POST", f"/repos/{repo}/issues", json.dumps(
            {"title": "Standby watchdog heartbeat STALE — action required",
             "body": body_text, "labels": [label]}).encode())
        print("watchdog-stale alert issue CREATED")
    else:
        call("POST", f"/repos/{repo}/issues/{open_alerts[0]['number']}/comments",
             json.dumps({"body": body_text}).encode())
        print(f"watchdog-stale alert issue #{open_alerts[0]['number']} COMMENTED")
else:
    for issue in open_alerts:
        call("POST", f"/repos/{repo}/issues/{issue['number']}/comments",
             json.dumps({"body": f"Recovered: standby watchdog heartbeat is "
                                 f"fresh again ({wd_date}) — closing."}).encode())
        call("PATCH", f"/repos/{repo}/issues/{issue['number']}",
             json.dumps({"state": "closed"}).encode())
    print(f"standby watchdog fresh ({wd_date}, {age_days}d) — "
          f"closed {len(open_alerts)} stale-alert issue(s)")
PYEOF
fi

SUCCEEDED=true
log "DONE — all steps green (pushed=${PUSHED})"
