#!/usr/bin/env bash
# task-update.sh — Single-task status update with file lock + live Trello sync + telemetry.
#
# Replaces ad-hoc `jq` edits to tasks.json from coding agents. Solves three problems:
#   1. Concurrent tasks.json writes (mkdir-based lock serializes parallel agents).
#   2. Live Trello visibility (one card pushed immediately, not at end-of-batch).
#   3. Single chokepoint to merge telemetry into the change_set + append the
#      runs/telemetry.jsonl log + post a completion comment on Trello.
#
# Coding agent usage (no telemetry — agent doesn't know its own duration/tokens):
#   bash runner/task-update.sh <feature_id> <task_id> in_progress
#   bash runner/task-update.sh <feature_id> <task_id> completed
#
# Orchestrator usage (after Agent return, parsing <usage> block):
#   bash runner/task-update.sh <feature_id> <task_id> completed \
#     --telemetry-json '{"agent_id":"coding-fe","model":"claude-opus-4-7","duration_ms":337000,"total_tokens":76982,"tool_uses":46,"started_at":"2026-05-24T08:00:00Z","finished_at":"2026-05-24T08:05:55Z"}'
#
# The orchestrator call is idempotent w.r.t. status (re-flipping completed → completed
# is a no-op for tasks.json) but DOES merge telemetry + post a Trello comment.
# Run it exactly once per Agent return.
#
# Options:
#   --telemetry-json <json>   Inline JSON merged into change_set.telemetry, appended
#                             to runs/telemetry.jsonl, and rendered as a Trello comment.
#   --change-set-ref <path>   Override the default change_set path
#                             (default: specs/<feat>/evidence/change_sets/<task>.json).
#   --no-trello               Skip the Trello push (for offline / CI / dry-run).
#   --blocked-reason <text>   When status=blocked, set tasks.json blocked_reason.

set -e

FEATURE_ID="${1:-}"
TASK_ID="${2:-}"
NEW_STATUS="${3:-}"
shift 3 2>/dev/null || true

TELEMETRY_JSON=""
CHANGE_SET_REF=""
NO_TRELLO=0
BLOCKED_REASON=""

while [ $# -gt 0 ]; do
  case "$1" in
    --telemetry-json)  TELEMETRY_JSON="$2"; shift 2 ;;
    --change-set-ref)  CHANGE_SET_REF="$2";  shift 2 ;;
    --no-trello)       NO_TRELLO=1; shift ;;
    --blocked-reason)  BLOCKED_REASON="$2"; shift 2 ;;
    *) echo "[task-update] Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$FEATURE_ID" ] || [ -z "$TASK_ID" ] || [ -z "$NEW_STATUS" ]; then
  echo "usage: bash runner/task-update.sh <feature_id> <task_id> <new_status> [--telemetry-json <json>] [--change-set-ref <path>] [--no-trello] [--blocked-reason <text>]" >&2
  exit 2
fi

case "$NEW_STATUS" in
  pending|in_progress|completed|blocked) ;;
  *) echo "[task-update] Invalid status: $NEW_STATUS (allowed: pending|in_progress|completed|blocked)" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "jq required (brew install jq)" >&2; exit 1; }

TASKS="specs/$FEATURE_ID/tasks.json"
test -f "$TASKS" || { echo "[task-update] Missing $TASKS" >&2; exit 1; }

if [ -z "$CHANGE_SET_REF" ]; then
  CHANGE_SET_REF="specs/$FEATURE_ID/evidence/change_sets/$TASK_ID.json"
fi

# ----- Lock (mkdir is atomic on all POSIX FS; macOS has no flock by default) -----
LOCK_DIR="$TASKS.lock"
LOCK_HELD=0
_release_lock() {
  if [ "$LOCK_HELD" = "1" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_HELD=0
  fi
}
trap _release_lock EXIT INT TERM

acquire_lock() {
  local i=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge 30 ]; then
      echo "[task-update] Could not acquire lock on $TASKS after 30s — another writer is stuck. Inspect $LOCK_DIR." >&2
      return 1
    fi
    sleep 1
  done
  LOCK_HELD=1
}

# ----- Validate task exists -----
TASK_EXISTS=$(jq --arg id "$TASK_ID" '[.tasks[] | select(.id == $id)] | length' "$TASKS")
if [ "$TASK_EXISTS" != "1" ]; then
  echo "[task-update] Task $TASK_ID not found in $TASKS" >&2
  exit 1
fi

# ----- Flip status under lock -----
acquire_lock

OLD_STATUS=$(jq -r --arg id "$TASK_ID" '.tasks[] | select(.id == $id) | .status' "$TASKS")

TMP=$(mktemp)
if [ "$NEW_STATUS" = "completed" ]; then
  jq --arg id "$TASK_ID" --arg st "$NEW_STATUS" --arg csref "$CHANGE_SET_REF" \
     '.tasks |= map(
        if .id == $id
        then .status = $st
           | .completion_evidence = ((.completion_evidence // {}) + {change_set_ref: $csref})
        else . end
      )' "$TASKS" > "$TMP" && mv "$TMP" "$TASKS"
elif [ "$NEW_STATUS" = "blocked" ]; then
  jq --arg id "$TASK_ID" --arg st "$NEW_STATUS" --arg reason "$BLOCKED_REASON" \
     '.tasks |= map(
        if .id == $id
        then .status = $st
           | (if $reason != "" then .blocked_reason = $reason else . end)
        else . end
      )' "$TASKS" > "$TMP" && mv "$TMP" "$TASKS"
else
  jq --arg id "$TASK_ID" --arg st "$NEW_STATUS" \
     '.tasks |= map(if .id == $id then .status = $st else . end)' "$TASKS" > "$TMP" && mv "$TMP" "$TASKS"
fi

_release_lock

echo "[task-update] $TASK_ID: $OLD_STATUS → $NEW_STATUS"

# ----- Merge telemetry into change_set + append to runs/telemetry.jsonl -----
if [ -n "$TELEMETRY_JSON" ]; then
  # Validate the JSON parses before we touch anything.
  if ! echo "$TELEMETRY_JSON" | jq -e . >/dev/null 2>&1; then
    echo "[task-update] --telemetry-json is not valid JSON" >&2
    exit 1
  fi

  if [ -f "$CHANGE_SET_REF" ]; then
    TMP=$(mktemp)
    jq --argjson new "$TELEMETRY_JSON" '.telemetry = ((.telemetry // {}) + $new)' "$CHANGE_SET_REF" > "$TMP" && mv "$TMP" "$CHANGE_SET_REF"
    echo "[task-update] telemetry merged into $CHANGE_SET_REF"
  else
    echo "[task-update] warning: change_set $CHANGE_SET_REF not found — telemetry written only to runs/telemetry.jsonl" >&2
  fi

  mkdir -p runs
  jq -cn --arg fid "$FEATURE_ID" --arg tid "$TASK_ID" \
         --argjson tel "$TELEMETRY_JSON" \
         '{feature_id: $fid, task_id: $tid, recorded_at: (now | todate), telemetry: $tel}' \
         >> runs/telemetry.jsonl
fi

# ----- Push to Trello (single card) -----
if [ "$NO_TRELLO" = "1" ]; then
  echo "[task-update] --no-trello set; skipping Trello sync."
  exit 0
fi

# Skip Trello if tasks.json is pre-active (matches trello-sync.sh behavior).
TASKS_STATUS=$(jq -r '.status' "$TASKS")
if [ "$TASKS_STATUS" != "active" ] && [ "$TASKS_STATUS" != "frozen" ] && [ "$TASKS_STATUS" != "completed" ]; then
  echo "[task-update] tasks.status=$TASKS_STATUS — skipping Trello (sync runs only after plan_lock_review)."
  exit 0
fi

# Skip Trello if credentials are absent (so the script still works in CI / offline).
if [ ! -f "runner/trello.config.local.json" ] && [ -z "$TRELLO_API_KEY" ]; then
  echo "[task-update] No Trello credentials configured; skipping Trello sync."
  exit 0
fi

# Source trello-sync.sh as a library and run a single-card sync.
# shellcheck disable=SC1091
source runner/trello-sync.sh

trello_full_setup "$FEATURE_ID"

echo "[Trello] Syncing 1 task..."
sync_one_task "$TASK_ID"

# Post completion comment with the telemetry footer (only on completed + telemetry).
if [ "$NEW_STATUS" = "completed" ] && [ -n "$TELEMETRY_JSON" ]; then
  CARD_ID=$(jq -r --arg id "$TASK_ID" '.tasks[] | select(.id == $id) | (.trello_card_id // empty)' "$TASKS")
  if [ -n "$CARD_ID" ]; then
    COMMENT=$(jq -rn --arg tid "$TASK_ID" --argjson tel "$TELEMETRY_JSON" --arg csref "$CHANGE_SET_REF" '
      "**Completed:** \($tid)\n" +
      "**Agent:** \($tel.agent_id // "—") · **Model:** \($tel.model // "—")\n" +
      "**Duration:** \(((($tel.duration_ms // 0) / 1000) | floor) | tostring)s · " +
      "**Tokens:** \($tel.total_tokens // 0) · " +
      "**Tool uses:** \($tel.tool_uses // 0)\n" +
      "**Change set:** \($csref)\n" +
      "**Started:** \($tel.started_at // "—") · **Finished:** \($tel.finished_at // "—")"
    ')
    trello_post_card_comment "$CARD_ID" "$COMMENT"
    echo "[Trello] Posted completion comment on $CARD_ID"
  else
    echo "[task-update] warning: no trello_card_id for $TASK_ID; skipping comment" >&2
  fi
fi

echo "[task-update] Done."
