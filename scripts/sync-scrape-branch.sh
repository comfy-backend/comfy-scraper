#!/usr/bin/env bash
# scripts/sync-scrape-branch.sh — keep the `scrape` branch in sync with
# main except for netlify.toml (which the scrape branch takes from
# netlify/scrape.branch.toml).
#
# Usage: from a comfy-scraper clone:  bash scripts/sync-scrape-branch.sh
# Never force-pushes: the scrape branch is fully derived from main, so a
# non-fast-forward here means something touched it by hand — stop and look.
set -euo pipefail

git fetch origin main scrape || true
git checkout -q main && git pull -q --ff-only origin main
git checkout -q scrape 2>/dev/null || git checkout -q -b scrape origin/scrape
git reset -q --hard origin/scrape

# apply main's tree, then overlay the branch-specific netlify.toml
git checkout -q main -- .
cp netlify/scrape.branch.toml netlify.toml

if git diff --cached --quiet && git diff --quiet; then
  echo "scrape branch already in sync"
else
  git add -A
  git commit -q -m "sync scrape branch from main $(date -u +%F) [script]"
  git push origin scrape
  echo "scrape branch updated + pushed"
fi
git checkout -q main
