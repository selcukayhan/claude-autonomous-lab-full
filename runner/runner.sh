
#!/usr/bin/env bash
set -e

CONFIG="runner/runner.config.json"

# Read config values without requiring jq (fallback to defaults)
AUTO_PUSH=$(grep -o '"auto_push"\s*:\s*[^,}]*' "$CONFIG" | head -1 | awk -F: '{gsub(/[[:space:]]*/,"",$2); print $2}')
PREFIX=$(grep -o '"commit_message_prefix"\s*:\s*"[^"]*"' "$CONFIG" | head -1 | sed -E 's/.*"commit_message_prefix"\s*:\s*"([^"]*)".*/\1/')

[ -z "$AUTO_PUSH" ] && AUTO_PUSH="false"
[ -z "$PREFIX" ] && PREFIX="auto: agent update"

WATCH_PATHS="artifacts contracts src docs"
echo "[Runner] Watching: $WATCH_PATHS"
echo "[Runner] Auto-push: $AUTO_PUSH"

# Require fswatch on macOS; on Linux you can alias to inotifywait change easily.
command -v fswatch >/dev/null 2>&1 || { echo >&2 "[Runner] fswatch is required. Install via: brew install fswatch"; exit 1; }

fswatch -or $WATCH_PATHS | while read changes; do
  echo "[Runner] Changes detected."
  bash runner/validate.sh || { echo "[Runner] Validation failed."; continue; }
  git add .
  git commit -m "$PREFIX $(date +'%Y-%m-%d %H:%M:%S')" || echo "[Runner] Nothing to commit."
  if [ "$AUTO_PUSH" = "true" ] || [ "$AUTO_PUSH" = "True" ]; then
    git push origin main || echo "[Runner] Git push failed."
  else
    echo "[Runner] Auto-push disabled."
  fi
done
