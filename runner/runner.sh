#!/usr/bin/env bash
set -e

CONFIG="runner/runner.config.json"

# Read config values. Prefer jq when available; fall back to grep.
if command -v jq >/dev/null 2>&1; then
  AUTO_PUSH=$(jq -r '.auto_push' "$CONFIG")
  PREFIX=$(jq -r '.commit_message_prefix' "$CONFIG")
  WATCH_PATHS=$(jq -r '.watch_paths | join(" ")' "$CONFIG")
  BLOCK_ON_HITL=$(jq -r '.spec_driven.block_on_hitl_pending // true' "$CONFIG")
else
  AUTO_PUSH=$(grep -o '"auto_push"\s*:\s*[^,}]*' "$CONFIG" | head -1 | awk -F: '{gsub(/[[:space:]]*/,"",$2); print $2}')
  PREFIX=$(grep -o '"commit_message_prefix"\s*:\s*"[^"]*"' "$CONFIG" | head -1 | sed -E 's/.*"commit_message_prefix"\s*:\s*"([^"]*)".*/\1/')
  WATCH_PATHS="specs src docs constitution.md"
  BLOCK_ON_HITL="true"
fi

[ -z "$AUTO_PUSH" ] && AUTO_PUSH="false"
[ -z "$PREFIX" ] && PREFIX="auto: agent update"
[ -z "$WATCH_PATHS" ] && WATCH_PATHS="specs src docs constitution.md"

echo "[Runner] Mode: spec-driven"
echo "[Runner] Watching: $WATCH_PATHS"
echo "[Runner] Auto-push: $AUTO_PUSH"
echo "[Runner] Block on HITL: $BLOCK_ON_HITL"

command -v fswatch >/dev/null 2>&1 || { echo >&2 "[Runner] fswatch is required. Install via: brew install fswatch"; exit 1; }

fswatch -or $WATCH_PATHS | while read changes; do
  echo "[Runner] Changes detected."

  # Check for pending HITL requests anywhere in specs/.
  if [ "$BLOCK_ON_HITL" = "true" ]; then
    shopt -s nullglob
    hitl_pending=(specs/*/staging/hitl/*.json)
    shopt -u nullglob
    if [ ${#hitl_pending[@]} -gt 0 ]; then
      echo "[Runner] HITL pending (${hitl_pending[*]}) — skipping commit."
      continue
    fi
  fi

  bash runner/validate.sh || { echo "[Runner] Validation failed — not committing."; continue; }

  git add .
  git commit -m "$PREFIX $(date +'%Y-%m-%d %H:%M:%S')" || echo "[Runner] Nothing to commit."

  if [ "$AUTO_PUSH" = "true" ] || [ "$AUTO_PUSH" = "True" ]; then
    git push origin main || echo "[Runner] Git push failed."
  else
    echo "[Runner] Auto-push disabled."
  fi
done
