#!/usr/bin/env bash
# trello-sync.sh — One-way push from specs/<feature_id>/tasks.json to a Trello board.
#
# tasks.json is the source of truth. This script is idempotent:
#   - Creates the board + lists + labels on first run.
#   - Creates a card per task on first run; writes trello_card_id + trello_card_url back into tasks.json.
#   - On subsequent runs: PATCHes only fields that drifted (list = status mapping, name, description, labels).
#   - Card moves done in Trello will be overwritten next sync — by design.
#
# Library mode: sourcing this file (e.g. from runner/task-update.sh) loads the
# helper functions without running the main loop. Source-guard at the bottom.
#
# Requirements: bash, curl, jq.
# Credentials: runner/trello.config.local.json OR env vars TRELLO_API_KEY / TRELLO_API_TOKEN.
#
# Usage:
#   bash runner/trello-sync.sh <feature_id>           # full sync
#   bash runner/trello-sync.sh <feature_id> --ping    # connection test only
#   bash runner/trello-sync.sh <feature_id> --dry-run # show planned actions, no API writes

set -e

# ============================================================================
# Helpers (always defined, whether sourced or run directly)
# ============================================================================

_trello_paths() {
  # arg1: feature_id. Populates path globals.
  FEATURE_ID="$1"
  CFG="runner/trello.config.json"
  LOCAL="runner/trello.config.local.json"
  SPEC_DIR="specs/$FEATURE_ID"
  TASKS="$SPEC_DIR/tasks.json"
  STATE="$SPEC_DIR/state.json"
}

_trello_preflight() {
  command -v jq   >/dev/null 2>&1 || { echo "jq required (brew install jq)"   >&2; exit 1; }
  command -v curl >/dev/null 2>&1 || { echo "curl required"                    >&2; exit 1; }
  test -f "$CFG"  || { echo "Missing $CFG"  >&2; exit 1; }
  test -d "$SPEC_DIR" || { echo "Missing $SPEC_DIR" >&2; exit 1; }
}

_trello_load_credentials() {
  if [ -n "$TRELLO_API_KEY" ] && [ -n "$TRELLO_API_TOKEN" ]; then
    KEY="$TRELLO_API_KEY"; TOKEN="$TRELLO_API_TOKEN"
  elif [ -f "$LOCAL" ]; then
    KEY=$(jq -r '.api_key'   "$LOCAL")
    TOKEN=$(jq -r '.api_token' "$LOCAL")
    if [ "$KEY" = "PASTE_YOUR_KEY_HERE" ] || [ "$TOKEN" = "PASTE_YOUR_TOKEN_HERE" ]; then
      echo "Edit $LOCAL with real credentials, or set TRELLO_API_KEY + TRELLO_API_TOKEN." >&2
      exit 1
    fi
  else
    echo "No credentials. Copy runner/trello.config.local.json.example to runner/trello.config.local.json and fill it in." >&2
    exit 1
  fi

  WORKSPACE_ID="null"
  if [ -f "$LOCAL" ]; then
    WORKSPACE_ID=$(jq -r '.workspace_id // "null"' "$LOCAL")
  fi

  API="https://api.trello.com/1"
  AUTH="key=$KEY&token=$TOKEN"
}

trello_get()  { curl -fsS         "$API$1$( [[ "$1" == *"?"* ]] && echo "&" || echo "?" )$AUTH" 2>/dev/null; }
trello_post() { curl -fsS -X POST "$API$1$( [[ "$1" == *"?"* ]] && echo "&" || echo "?" )$AUTH" "${@:2}" 2>/dev/null; }
trello_put()  { curl -fsS -X PUT  "$API$1$( [[ "$1" == *"?"* ]] && echo "&" || echo "?" )$AUTH" "${@:2}" 2>/dev/null; }

# Post a comment on a card. Used by task-update.sh to attach telemetry footers
# to completed cards.
#   arg1: card_id
#   arg2: comment text (free form, will be URL-encoded)
trello_post_card_comment() {
  local CARD_ID="$1"
  local TEXT="$2"
  local ENCODED
  ENCODED=$(jq -rn --arg v "$TEXT" '$v|@uri')
  trello_post "/cards/$CARD_ID/actions/comments?text=$ENCODED" > /dev/null
}

_trello_short_fid() {
  # "003-routines-reminders" → "003"   |   "001-pet-health-app" → "001"
  echo "$1" | grep -oE '^[0-9]+' || echo "$1"
}

_trello_ensure_board() {
  # Single project board (e.g. TailTrack) shared across ALL features.
  # Lookup order: state.json#trello.project_board_id → state.json#trello.board_id
  # (legacy, may still be set from per-feature era) → search Trello by name → create.
  BOARD_ID=$(jq -r '.trello.project_board_id // .trello.board_id // empty' "$STATE" 2>/dev/null || echo "")
  if [ -n "$BOARD_ID" ] && [ "$BOARD_ID" != "DRY_BOARD" ]; then
    # Verify the recorded board still exists + matches the expected name (catches
    # stale per-feature-era IDs that point to soon-to-be-archived boards).
    local CURRENT_NAME
    CURRENT_NAME=$(trello_get "/boards/$BOARD_ID?fields=name" 2>/dev/null | jq -r '.name // empty')
    local EXPECTED_NAME
    EXPECTED_NAME=$(jq -r '.project_board.name' "$CFG")
    if [ "$CURRENT_NAME" = "$EXPECTED_NAME" ]; then
      echo "[Trello] Using existing project board: $BOARD_ID ($CURRENT_NAME)"
      return 0
    fi
    # Stale (per-feature board, or name changed). Fall through to search/create.
    echo "[Trello] state.json#trello.board_id=$BOARD_ID is stale (name='$CURRENT_NAME', expected='$EXPECTED_NAME'); re-resolving against project board."
    BOARD_ID=""
  fi

  local BOARD_NAME BOARD_DESC
  BOARD_NAME=$(jq -r '.project_board.name'        "$CFG")
  BOARD_DESC=$(jq -r '.project_board.description' "$CFG")

  # Search workspace for an existing board with this name (idempotency across features).
  local EXISTING_BOARDS
  EXISTING_BOARDS=$(trello_get "/members/me/boards?fields=name,closed&filter=open") || EXISTING_BOARDS="[]"
  BOARD_ID=$(echo "$EXISTING_BOARDS" | jq -r --arg n "$BOARD_NAME" '.[] | select(.name == $n and (.closed // false) == false) | .id' | head -1)

  if [ -n "$BOARD_ID" ]; then
    echo "[Trello] Found existing project board: $BOARD_ID ($BOARD_NAME)"
    return 0
  fi

  echo "[Trello] Creating project board '$BOARD_NAME'"
  if [ "$DRY" -eq 0 ]; then
    local BODY RESP
    BODY="name=$(jq -rn --arg v "$BOARD_NAME" '$v|@uri')&desc=$(jq -rn --arg v "$BOARD_DESC" '$v|@uri')&defaultLists=false&prefs_permissionLevel=private"
    if [ "$WORKSPACE_ID" != "null" ] && [ -n "$WORKSPACE_ID" ]; then BODY="$BODY&idOrganization=$WORKSPACE_ID"; fi
    RESP=$(trello_post "/boards/" -d "$BODY") || { echo "[Trello] board create failed" >&2; exit 1; }
    BOARD_ID=$(echo "$RESP" | jq -r '.id')
    echo "[Trello] Project board created: $BOARD_ID"
  else
    BOARD_ID="DRY_BOARD"
  fi
}

_trello_ensure_lists_and_labels() {
  # Bash 3.2 (macOS default) has no associative arrays. Use JSON maps + jq lookups.
  LIST_IDS_JSON="{}"
  LABEL_IDS_JSON="{}"

  local EXISTING_LISTS EXISTING_LABELS NAME K COLOR LID LBID RESP
  EXISTING_LISTS="[]"
  if [ "$BOARD_ID" != "DRY_BOARD" ]; then
    EXISTING_LISTS=$(trello_get "/boards/$BOARD_ID/lists?fields=name") || EXISTING_LISTS="[]"
  fi

  while IFS= read -r NAME; do
    LID=$(echo "$EXISTING_LISTS" | jq -r --arg n "$NAME" '.[] | select(.name==$n) | .id' | head -1)
    if [ -z "$LID" ]; then
      echo "[Trello] Creating list: $NAME"
      if [ "$DRY" -eq 0 ]; then
        RESP=$(trello_post "/lists?name=$(jq -rn --arg v "$NAME" '$v|@uri')&idBoard=$BOARD_ID") || { echo "list create failed for $NAME" >&2; exit 1; }
        LID=$(echo "$RESP" | jq -r '.id')
      else
        LID="DRY_$NAME"
      fi
    fi
    LIST_IDS_JSON=$(echo "$LIST_IDS_JSON" | jq --arg n "$NAME" --arg id "$LID" '. + {($n): $id}')
  done < <(jq -r '.list_order[]' "$CFG")

  EXISTING_LABELS="[]"
  if [ "$BOARD_ID" != "DRY_BOARD" ]; then
    EXISTING_LABELS=$(trello_get "/boards/$BOARD_ID/labels?fields=name,color&limit=1000") || EXISTING_LABELS="[]"
  fi

  # Owner labels: coding-fe / coding-be / coding-devops / test / docs / security.
  # Cached EXISTING_LABELS gets re-fetched after _trello_ensure_feature_label appends a feat: label.
  while IFS= read -r K; do
    COLOR=$(jq -r --arg k "$K" '.owner_labels[$k]' "$CFG")
    LBID=$(echo "$EXISTING_LABELS" | jq -r --arg n "$K" '.[] | select(.name==$n) | .id' | head -1)
    if [ -z "$LBID" ]; then
      echo "[Trello] Creating owner label: $K ($COLOR)"
      if [ "$DRY" -eq 0 ]; then
        RESP=$(trello_post "/labels?name=$(jq -rn --arg v "$K" '$v|@uri')&color=$COLOR&idBoard=$BOARD_ID") || { echo "label create failed for $K" >&2; exit 1; }
        LBID=$(echo "$RESP" | jq -r '.id')
      else
        LBID="DRY_$K"
      fi
    fi
    LABEL_IDS_JSON=$(echo "$LABEL_IDS_JSON" | jq --arg n "$K" --arg id "$LBID" '. + {($n): $id}')
  done < <(jq -r '.owner_labels | keys[]' "$CFG")
}

# Ensure a feat:<short_fid> label exists on the project board for the current
# FEATURE_ID. Rotates color from .feature_labels.color_pool (deterministic by
# feature index — 001 = first color, 002 = second, …). Persists to
# state.json#trello.feature_label_id. Sets FEATURE_LABEL_ID global.
_trello_ensure_feature_label() {
  local SHORT_FID NAME COLOR EXISTING POOL_LEN IDX
  SHORT_FID=$(_trello_short_fid "$FEATURE_ID")
  NAME="feat:$SHORT_FID"

  FEATURE_LABEL_ID=$(jq -r '.trello.feature_label_id // empty' "$STATE" 2>/dev/null || echo "")
  if [ -n "$FEATURE_LABEL_ID" ] && [ "$FEATURE_LABEL_ID" != "DRY_FEAT" ]; then
    echo "[Trello] Using existing feature label: $FEATURE_LABEL_ID ($NAME)"
    return 0
  fi

  # Search board labels for this feat:<fid> name.
  if [ "$BOARD_ID" != "DRY_BOARD" ]; then
    EXISTING=$(trello_get "/boards/$BOARD_ID/labels?fields=name,color&limit=1000") || EXISTING="[]"
    FEATURE_LABEL_ID=$(echo "$EXISTING" | jq -r --arg n "$NAME" '.[] | select(.name==$n) | .id' | head -1)
    if [ -n "$FEATURE_LABEL_ID" ]; then
      echo "[Trello] Found existing feature label: $FEATURE_LABEL_ID ($NAME)"
      return 0
    fi
  fi

  # Pick color: rotate through pool by feature index (1-based). "001"→idx 0, "003"→idx 2.
  POOL_LEN=$(jq -r '.feature_labels.color_pool | length' "$CFG")
  IDX=$(( (10#$SHORT_FID - 1) % POOL_LEN ))
  COLOR=$(jq -r --arg i "$IDX" '.feature_labels.color_pool[$i | tonumber]' "$CFG")

  echo "[Trello] Creating feature label: $NAME ($COLOR)"
  if [ "$DRY" -eq 0 ]; then
    local RESP
    RESP=$(trello_post "/labels?name=$(jq -rn --arg v "$NAME" '$v|@uri')&color=$COLOR&idBoard=$BOARD_ID") || { echo "feature label create failed for $NAME" >&2; exit 1; }
    FEATURE_LABEL_ID=$(echo "$RESP" | jq -r '.id')
  else
    FEATURE_LABEL_ID="DRY_FEAT"
  fi
}

_trello_persist_state() {
  if [ "$DRY" -eq 0 ]; then
    local TMP
    TMP=$(mktemp)
    jq --arg bid "$BOARD_ID" \
       --arg flid "$FEATURE_LABEL_ID" \
       --argjson lists  "$LIST_IDS_JSON" \
       --argjson labels "$LABEL_IDS_JSON" \
       '.trello = (.trello // {})
        | .trello.project_board_id = $bid
        | .trello.board_id = $bid
        | .trello.feature_label_id = $flid
        | .trello.lists = $lists
        | .trello.labels = $labels' \
       "$STATE" > "$TMP" && mv "$TMP" "$STATE"
  fi
}

build_card_desc() {
  local task_id="$1"
  local fid="$2"
  local status owner refs hours deps dod scope
  status=$(jq -r --arg id "$task_id" '.tasks[] | select(.id==$id) | .status' "$TASKS")
  owner=$( jq -r --arg id "$task_id" '.tasks[] | select(.id==$id) | .owner'  "$TASKS")
  refs=$(  jq -r --arg id "$task_id" '.tasks[] | select(.id==$id) | (.spec_criterion_refs // []) | join(", ")' "$TASKS")
  hours=$( jq -r --arg id "$task_id" '.tasks[] | select(.id==$id) | (.estimated_hours // 0)' "$TASKS")
  deps=$(  jq -r --arg id "$task_id" '.tasks[] | select(.id==$id) | ((.depends_on // []) | if length==0 then "—" else join(", ") end)' "$TASKS")
  dod=$(   jq -r --arg id "$task_id" '.tasks[] | select(.id==$id) | (.definition_of_done // []) | map("- " + .) | join("\n")' "$TASKS")
  scope=$( jq -r --arg id "$task_id" '.tasks[] | select(.id==$id) | (.scope_paths // []) | map("`" + . + "`") | join("  ")' "$TASKS")
  jq -r --arg fid "$fid" --arg tid "$task_id" \
        --arg status "$status" --arg owner "$owner" --arg refs "$refs" \
        --arg hours "$hours" --arg deps "$deps" --arg dod "$dod" --arg scope "$scope" '
    .card_description_template | join("\n")
    | gsub("\\{feature_id\\}"; $fid)
    | gsub("\\{id\\}"; $tid)
    | gsub("\\{status\\}"; $status)
    | gsub("\\{owner\\}"; $owner)
    | gsub("\\{spec_criterion_refs\\}"; $refs)
    | gsub("\\{estimated_hours\\}"; $hours)
    | gsub("\\{depends_on\\}"; $deps)
    | gsub("\\{definition_of_done\\}"; $dod)
    | gsub("\\{scope_paths\\}"; $scope)
  ' "$CFG"
}

# Sync a single task's card. Creates if missing, updates if drifted.
# Uses globals: FEATURE_ID, TASKS, CFG, BOARD_ID, LIST_IDS_JSON, LABEL_IDS_JSON, DRY.
#   arg1: task_id (e.g. T005)
# Echoes a one-line summary to stdout.
sync_one_task() {
  local TID="$1"
  local TITLE STATUS OWNER CARD_ID LIST_NAME LIST_ID OWNER_LABEL_ID CARD_NAME CARD_DESC RESP CARD_URL TMP BODY LABELS_CSV SHORT_FID
  TITLE=$( jq -r --arg id "$TID" '.tasks[] | select(.id==$id) | .title'  "$TASKS")
  STATUS=$(jq -r --arg id "$TID" '.tasks[] | select(.id==$id) | .status' "$TASKS")
  OWNER=$( jq -r --arg id "$TID" '.tasks[] | select(.id==$id) | .owner'  "$TASKS")
  CARD_ID=$(jq -r --arg id "$TID" '.tasks[] | select(.id==$id) | (.trello_card_id // empty)' "$TASKS")

  LIST_NAME=$(jq -r --arg s "$STATUS" '.status_to_list[$s] // "Pending"' "$CFG")
  LIST_ID=$(echo  "$LIST_IDS_JSON"  | jq -r --arg n "$LIST_NAME" '.[$n]')
  OWNER_LABEL_ID=$(echo "$LABEL_IDS_JSON" | jq -r --arg n "$OWNER" '.[$n]')

  # Both owner + feature labels on every card. CSV per Trello API.
  LABELS_CSV="$OWNER_LABEL_ID,$FEATURE_LABEL_ID"

  # Card name: [<short_fid>] T<NNN> — <title>
  SHORT_FID=$(_trello_short_fid "$FEATURE_ID")
  CARD_NAME="[$SHORT_FID] $TID — $TITLE"
  CARD_DESC=$(build_card_desc "$TID" "$FEATURE_ID")

  if [ -z "$CARD_ID" ]; then
    echo "  + create  [$SHORT_FID] $TID  [$LIST_NAME / $OWNER]"
    if [ "$DRY" -eq 0 ]; then
      BODY="name=$(jq -rn --arg v "$CARD_NAME" '$v|@uri')&idList=$LIST_ID&desc=$(jq -rn --arg v "$CARD_DESC" '$v|@uri')&idLabels=$LABELS_CSV"
      RESP=$(trello_post "/cards" -d "$BODY") || { echo "card create failed for $TID" >&2; exit 1; }
      CARD_ID=$(echo "$RESP"  | jq -r '.id')
      CARD_URL=$(echo "$RESP" | jq -r '.shortUrl')
      TMP=$(mktemp)
      jq --arg id "$TID" --arg cid "$CARD_ID" --arg url "$CARD_URL" \
         '.tasks |= map(if .id == $id then .trello_card_id = $cid | .trello_card_url = $url else . end)' \
         "$TASKS" > "$TMP" && mv "$TMP" "$TASKS"
    fi
  else
    echo "  ~ update  [$SHORT_FID] $TID  [$LIST_NAME / $OWNER]  ($CARD_ID)"
    if [ "$DRY" -eq 0 ]; then
      BODY="name=$(jq -rn --arg v "$CARD_NAME" '$v|@uri')&idList=$LIST_ID&desc=$(jq -rn --arg v "$CARD_DESC" '$v|@uri')&idLabels=$LABELS_CSV"
      trello_put "/cards/$CARD_ID" -d "$BODY" > /dev/null || { echo "card update failed for $TID" >&2; exit 1; }
    fi
  fi
}

# Full-board setup: paths + preflight + credentials + board + lists/labels + state.
# Idempotent. Used by both the main loop and by task-update.sh single-task mode.
trello_full_setup() {
  local feature_id="$1"
  : "${DRY:=0}"
  _trello_paths "$feature_id"
  _trello_preflight
  _trello_load_credentials
  _trello_ensure_board
  _trello_ensure_lists_and_labels
  _trello_ensure_feature_label
  _trello_persist_state
}

# ============================================================================
# Main (only runs when invoked directly, skipped when sourced as library)
# ============================================================================

_trello_main() {
  local feature_id="${1:-}"
  local mode="${2:-sync}"

  if [ -z "$feature_id" ]; then
    echo "usage: bash runner/trello-sync.sh <feature_id> [--ping|--dry-run]" >&2
    exit 2
  fi

  _trello_paths "$feature_id"
  _trello_preflight
  _trello_load_credentials

  # Ping mode: verify credentials, exit.
  if [ "$mode" = "--ping" ]; then
    echo "[Trello] Pinging /members/me ..."
    local ME USER
    ME=$(trello_get "/members/me?fields=username,fullName") || { echo "[Trello] FAILED. Check key/token." >&2; exit 1; }
    USER=$(echo "$ME" | jq -r '.username + " (" + .fullName + ")"')
    echo "[Trello] OK. Authenticated as: $USER"
    exit 0
  fi

  # Pre-flight: tasks.json must be at least in_review.
  # Updated 2026-05-26: lowered gate from `active` to `in_review` so the human
  # reviewer can browse the full Trello board during plan_lock_review HITL,
  # instead of only seeing tasks after they've already approved the plan.
  # Orchestrator runs trello-sync.sh as the last step of tasks_decompose,
  # before emitting the plan_lock_review HITL request file.
  local TASKS_STATUS
  TASKS_STATUS=$(jq -r '.status' "$TASKS")
  case "$TASKS_STATUS" in
    in_review|active|frozen|completed)
      : # OK — sync proceeds
      ;;
    draft|*)
      echo "[Trello] tasks.status=$TASKS_STATUS — skipping. Sync runs from in_review onward (drafts excluded)." >&2
      exit 0
      ;;
  esac

  echo "[Trello] Feature: $FEATURE_ID  | tasks.status=$TASKS_STATUS"

  DRY=0
  if [ "$mode" = "--dry-run" ]; then DRY=1; echo "[Trello] DRY RUN — no API writes will occur."; fi

  _trello_ensure_board
  _trello_ensure_lists_and_labels
  _trello_ensure_feature_label
  _trello_persist_state

  local TASK_COUNT i TID
  TASK_COUNT=$(jq '.tasks | length' "$TASKS")
  echo "[Trello] Syncing $TASK_COUNT tasks..."

  for i in $(seq 0 $((TASK_COUNT - 1))); do
    TID=$(jq -r ".tasks[$i].id" "$TASKS")
    sync_one_task "$TID"
  done

  echo "[Trello] Sync complete for $FEATURE_ID."
}

# Source-guard: only run main if executed directly, not when sourced as library.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  _trello_main "$@"
fi
