#!/usr/bin/env bash
# scripts/sync-scrape-branch.sh — keep the `scrape` branch in sync with
# main except for netlify.toml (which the scrape branch takes from
# netlify/scrape.branch.toml).
#
# Usage: from a comfy-scraper clone:  bash scripts/sync-scrape-branch.sh
#          (add --run to ALSO trigger the full pipeline build on the
#           synced branch — see the [skip ci] note below)
# Never force-pushes: the scrape branch is fully derived from main, so a
# non-fast-forward here means something touched it by hand — stop and look.
#
# W18 DISCOVERY: every push to the scrape branch triggers a FULL branch
# build = a complete pipeline run (the site is Git-connected; the build
# command IS the scrape). Syncing docs/config changes therefore costs a
# redundant scrape AND can race concurrent lanes (2026-10-09: a sync
# push + a GHA dispatch ran 3 concurrent scrapes; upstream rate-limited
# one of them — fail-fast + alert + auto-close worked, but the noise is
# avoidable). Default = commit message carries [skip ci] (Netlify
# honors it); pass --run when a code change genuinely needs a build.
set -euo pipefail
SKIP="[skip ci]"
if [ "${1:-}" = "--run" ]; then SKIP=""; shift || true; fi

git fetch origin main scrape || true
git checkout -q main && git pull -q --ff-only origin main
git checkout -q scrape 2>/dev/null || git checkout -q -b scrape origin/scrape
git reset -q --hard origin/scrape

# apply main's tree WHOLESALE (read-tree --reset -u also propagates
# DELETIONS — `git checkout main -- .` does not, W15-r1 F8), then overlay
# the branch-specific netlify.toml
git read-tree -u --reset main
cp netlify/scrape.branch.toml netlify.toml

if git diff --cached --quiet && git diff --quiet; then
  echo "scrape branch already in sync"
else
  git add -A
  git commit -q -m "sync scrape branch from main $(date -u +%F) [script]${SKIP:+ ${SKIP}}"
  git push origin scrape
  echo "scrape branch updated + pushed"
fi
git checkout -q main
