#!/usr/bin/env bash
# Sync the Obsidian vault clone with GitHub for the Hermes agent.
# commit agent edits -> pull --rebase -> push. On conflict: abort the rebase,
# keep local commits, push nothing, log an ERROR line. Never force-pushes.
set -uo pipefail

VAULT="${OBSIDIAN_VAULT_PATH:-$HOME/obsidian_store}"
BRANCH="${OBSIDIAN_BRANCH:-main}"
LOG="${HOME}/.hermes/logs/obsidian-sync.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
ts() { date -u +%FT%TZ; }

cd "$VAULT" || { echo "$(ts) ERROR: vault not found at $VAULT"; exit 1; }

exec 9>"$VAULT/.git/hermes-sync.lock"
flock -n 9 || { echo "$(ts) skip: another sync is running"; exit 0; }

if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
  echo "$(ts) ERROR: unfinished rebase in vault — manual fix needed"; exit 1
fi

git add -A
if ! git diff --cached --quiet; then
  git commit -q -m "hermes: agent edits $(ts)" || { echo "$(ts) ERROR: commit failed"; exit 1; }
fi

if ! git pull -q --rebase origin "$BRANCH"; then
  git rebase --abort 2>/dev/null || true
  echo "$(ts) ERROR: conflict on pull --rebase; local commits kept, nothing pushed"; exit 1
fi

if [ -n "$(git log --oneline "origin/$BRANCH..HEAD" 2>/dev/null)" ]; then
  git push -q origin "HEAD:$BRANCH" && echo "$(ts) pushed $(git rev-parse --short HEAD)" \
    || { echo "$(ts) ERROR: push failed"; exit 1; }
fi
