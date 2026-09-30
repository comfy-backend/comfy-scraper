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

on_exit() {
  local rc=$?
  if [ $rc -ne 0 ] && [ "$SUCCEEDED" != "true" ]; then
    alert_on_failure "exit rc=$rc"
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

# ─── 6. GitLab mirror (redundant data backup — fatal on failure) ────────
if [ "$TARGET_BRANCH" = "main" ]; then
  log "GitLab mirror…"
  mirrored=false
  for attempt in 1 2 3 4 5; do
    if git push "https://oauth2:${GITLAB_PAT}@gitlab.com/${GL_REPO}.git" HEAD:main; then
      log "GitLab mirror OK (attempt ${attempt})"; mirrored=true; break
    fi
    log "mirror attempt ${attempt} failed — retrying in 20s"; sleep 20
  done
  [ "$mirrored" = "true" ] || fatal "GitLab mirror failed after 5 attempts — redundant copy stale: gitlab.com/${GL_REPO}"
fi

# ─── 7. Netlify Blobs snapshot (tertiary — warning on failure) ──────────
if [ "$PUSHED" = "true" ] && [ -n "$NETLIFY_AUTH_TOKEN" ] && [ -n "$NETLIFY_SITE_ID" ]; then
  log "blobs snapshot (tertiary backup)…"
  python3 work/comfy-templates/scripts/blobs_backup.py snapshot --keep 45 \
    || echo "::warning::blobs snapshot failed (non-fatal — tertiary layer)"
elif [ "$PUSHED" = "true" ]; then
  log "blobs snapshot skipped (Netlify secrets not set)"
fi

# ─── 8. prod verify (Vercel built_at poll) — main runs only ─────────────
if [ "$TARGET_BRANCH" = "main" ]; then
  log "verifying production deployment…"
  expected="$(python3 -c "import json; print(json.load(open('public/data/stats.json'))['built_at'])" 2>/dev/null || true)"
  [ -n "$expected" ] || fatal "stats.json unreadable — cannot verify prod (F5: an empty expected must never match an unreachable prod)"
  log "expecting prod built_at = ${expected}"
  verified=false
  # 20×12s ≈ 4 min (W15-r3: trim the tail — full re-scrape + this loop
  # approached Netlify's inferred 15-min build cap)
  for attempt in $(seq 1 20); do
    got="$(curl -sf --max-time 15 "https://comfy-templates.vercel.app/data/stats.json" \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('built_at',''))" 2>/dev/null || true)"
    if [ "${got}" = "${expected}" ]; then
      log "prod verified: built_at ${got} live (attempt ${attempt})"; verified=true; break
    fi
    log "attempt ${attempt}: prod built_at = '${got:-unreachable}' — waiting for the Vercel deploy"
    sleep 12
  done
  [ "$verified" = "true" ] || fatal "prod does not serve built_at ${expected} after ~4 min — Vercel deploy failed or very slow"
fi

# ─── 9. runner-repo state + alert auto-close — main runs only ───────────
if [ "$TARGET_BRANCH" = "main" ]; then
  log "state/last-run.json update (best-effort)…"
  GH_PAT="$GH_PAT" RUNNER_REPO="$RUNNER_REPO" GL_MIRROR="success" \
  BLOBS_SNAPSHOT="$([ "$PUSHED" = "true" ] && echo success || echo skipped)" \
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

sha, existing = "", ""
try:
    _, d = call("GET"); sha = d.get("sha", "")
    existing = json.loads(base64.b64decode(d.get("content", ""))).get("date", "")
except Exception: pass
if existing == today:
    print(f"state/last-run.json already records {today} — skipping."); raise SystemExit(0)

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

SUCCEEDED=true
log "DONE — all steps green (pushed=${PUSHED})"
