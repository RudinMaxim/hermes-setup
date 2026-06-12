#!/usr/bin/env bash
# Commit local vault changes, integrate remote commits, and push the result.

set -euo pipefail
IFS=$'\n\t'

REPO="${OBSIDIAN_REPO:-}"
REMOTE="${OBSIDIAN_REMOTE:-origin}"
BRANCH="${OBSIDIAN_BRANCH:-main}"
MAX_PUSH_ATTEMPTS="${OBSIDIAN_PUSH_ATTEMPTS:-3}"

log() {
  printf '%s [obsidian-sync] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

[[ -n "$REPO" ]] || die "OBSIDIAN_REPO is not set"
[[ -d "$REPO/.git" ]] || die "$REPO is not a Git repository"

cd "$REPO"

git rev-parse --verify "$BRANCH" >/dev/null 2>&1 \
  || die "local branch '$BRANCH' does not exist"
[[ "$(git branch --show-current)" == "$BRANCH" ]] \
  || die "vault must be on branch '$BRANCH'"

git remote get-url "$REMOTE" >/dev/null 2>&1 \
  || die "remote '$REMOTE' is not configured"

git_dir=$(git rev-parse --git-dir)
lock_dir="$git_dir/hermes-obsidian-sync.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  log "another sync is already running; skipping"
  exit 0
fi
trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT

for state in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD; do
  [[ ! -e "$git_dir/$state" ]] \
    || die "unfinished Git operation detected ($state); resolve it manually"
done

git add -A
if ! git diff --cached --quiet; then
  stamp=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
  host=$(scutil --get ComputerName 2>/dev/null || hostname -s)
  git commit -m "vault sync: $stamp ($host)"
  log "committed local vault changes"
fi

git fetch --prune "$REMOTE" "$BRANCH"
if ! git rebase "$REMOTE/$BRANCH"; then
  git rebase --abort >/dev/null 2>&1 || true
  die "rebase conflict; no files were overwritten, resolve the conflict manually"
fi

attempt=1
while (( attempt <= MAX_PUSH_ATTEMPTS )); do
  if git push "$REMOTE" "$BRANCH"; then
    log "vault is synchronized"
    exit 0
  fi

  if (( attempt == MAX_PUSH_ATTEMPTS )); then
    break
  fi

  log "push raced with another device; fetching and rebasing (attempt $attempt)"
  git fetch "$REMOTE" "$BRANCH"
  if ! git rebase "$REMOTE/$BRANCH"; then
    git rebase --abort >/dev/null 2>&1 || true
    die "rebase conflict after concurrent push; resolve it manually"
  fi
  attempt=$((attempt + 1))
done

die "push failed after $MAX_PUSH_ATTEMPTS attempts"
