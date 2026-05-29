#!/usr/bin/env bash
# trello-migrate-to-project-board.sh — one-shot migration from per-feature
# Trello boards to a single project board (TailTrack).
#
# What it does:
#   1. Ensures the project board (per trello.config.json#project_board.name) exists.
#   2. For each feature under specs/<NNN-slug>/ that has tasks.json and
#      state.json#trello.board_id pointing to a per-feature legacy board:
#      a. Creates a feat:<short_fid> label on the project board (color from
#         feature_labels.color_pool, rotated by feature index).
#      b. For each task with trello_card_id (i.e. it has a card on the legacy
#         board): reads the card name + desc + idLabels + comments, then
#         creates a new card on the project board with [<short_fid>] prefix
#         + both owner-label + feat:<fid> label. Re-posts the comments in
#         chronological order so telemetry footers survive.
#      c. Rewrites tasks.json: trello_card_id + trello_card_url → new card.
#      d. Rewrites state.json: trello.project_board_id + trello.feature_label_id
#         set; old per-feature trello.board_id moved to trello.legacy_board_id.
#   3. Reports per-feature legacy board IDs that the user should close/delete
#      manually on Trello (script does NOT auto-delete to keep the migration
#      reversible if something looks wrong).
#
# Idempotent in the happy path: re-runs detect already-migrated cards by
# checking whether the project board has a card with the same [<sfid>] T<NNN>
# prefix, and skip if so.
#
# Usage:
#   bash runner/trello-migrate-to-project-board.sh            # live
#   bash runner/trello-migrate-to-project-board.sh --dry-run  # preview only
#   bash runner/trello-migrate-to-project-board.sh --feature 003-routines-reminders
#                                                             # one feature only
#
# Requires: runner/trello.config.json + runner/trello.config.local.json (creds)
# Honors:   feedback_no_push (no git ops); Trello API only.

set -euo pipefail

DRY=0
ONLY_FEATURE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)      DRY=1; shift ;;
    --feature)      ONLY_FEATURE="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,/^set -euo/p' "$0" | head -40
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Source the sync helpers (we reuse trello_get / trello_post / etc.).
# Note: trello-sync.sh has `set -e`. We're in `set -euo pipefail` too. Sourcing
# is safe; we just need to populate the path globals it expects before calling
# _trello_preflight (which checks SPEC_DIR — set by _trello_paths usually).
source runner/trello-sync.sh

CFG="runner/trello.config.json"
LOCAL="runner/trello.config.local.json"
# _trello_preflight wants SPEC_DIR to exist. Point at 000-template (always present)
# since the migration walks ALL features; no single one is canonical.
SPEC_DIR="specs/000-template"
# Optional env-var creds (preflight will use these if set, else LOCAL file).
TRELLO_API_KEY="${TRELLO_API_KEY:-}"
TRELLO_API_TOKEN="${TRELLO_API_TOKEN:-}"

[ "$DRY" -eq 1 ] && echo "[Migrate] DRY-RUN mode — no API writes will occur."

# --- Preflight: creds + workspace ---------------------------------------
_trello_preflight       # exits if creds missing
_trello_load_credentials

PROJECT_BOARD_NAME=$(jq -r '.project_board.name' "$CFG")
PROJECT_BOARD_DESC=$(jq -r '.project_board.description' "$CFG")

# --- 1. Ensure project board --------------------------------------------
echo "[Migrate] Resolving project board: $PROJECT_BOARD_NAME"
EXISTING=$(trello_get "/members/me/boards?fields=name,closed&filter=open") || EXISTING="[]"
PROJECT_BOARD_ID=$(echo "$EXISTING" | jq -r --arg n "$PROJECT_BOARD_NAME" '.[] | select(.name == $n and (.closed // false) == false) | .id' | head -1)

if [ -z "$PROJECT_BOARD_ID" ]; then
  echo "[Migrate] Creating project board '$PROJECT_BOARD_NAME'"
  if [ "$DRY" -eq 0 ]; then
    BODY="name=$(jq -rn --arg v "$PROJECT_BOARD_NAME" '$v|@uri')&desc=$(jq -rn --arg v "$PROJECT_BOARD_DESC" '$v|@uri')&defaultLists=false&prefs_permissionLevel=private"
    if [ "$WORKSPACE_ID" != "null" ] && [ -n "$WORKSPACE_ID" ]; then BODY="$BODY&idOrganization=$WORKSPACE_ID"; fi
    RESP=$(trello_post "/boards/" -d "$BODY")
    PROJECT_BOARD_ID=$(echo "$RESP" | jq -r '.id')
  else
    PROJECT_BOARD_ID="DRY_PROJECT_BOARD"
  fi
  echo "[Migrate]   created: $PROJECT_BOARD_ID"
else
  echo "[Migrate]   exists: $PROJECT_BOARD_ID"
fi

# --- 2. Ensure lists (Pending / In Progress / Blocked / Completed) ------
PROJECT_LISTS_JSON="{}"
EXISTING_LISTS=$(trello_get "/boards/$PROJECT_BOARD_ID/lists?fields=name") || EXISTING_LISTS="[]"
while IFS= read -r NAME; do
  LID=$(echo "$EXISTING_LISTS" | jq -r --arg n "$NAME" '.[] | select(.name==$n) | .id' | head -1)
  if [ -z "$LID" ]; then
    echo "[Migrate] Creating list: $NAME"
    if [ "$DRY" -eq 0 ]; then
      RESP=$(trello_post "/lists?name=$(jq -rn --arg v "$NAME" '$v|@uri')&idBoard=$PROJECT_BOARD_ID")
      LID=$(echo "$RESP" | jq -r '.id')
    else
      LID="DRY_$NAME"
    fi
  fi
  PROJECT_LISTS_JSON=$(echo "$PROJECT_LISTS_JSON" | jq --arg n "$NAME" --arg id "$LID" '. + {($n): $id}')
done < <(jq -r '.list_order[]' "$CFG")

# --- 3. Ensure owner labels ----------------------------------------------
PROJECT_OWNER_LABELS_JSON="{}"
EXISTING_LABELS=$(trello_get "/boards/$PROJECT_BOARD_ID/labels?fields=name,color&limit=1000") || EXISTING_LABELS="[]"
while IFS= read -r K; do
  COLOR=$(jq -r --arg k "$K" '.owner_labels[$k]' "$CFG")
  LBID=$(echo "$EXISTING_LABELS" | jq -r --arg n "$K" '.[] | select(.name==$n) | .id' | head -1)
  if [ -z "$LBID" ]; then
    echo "[Migrate] Creating owner label: $K ($COLOR)"
    if [ "$DRY" -eq 0 ]; then
      RESP=$(trello_post "/labels?name=$(jq -rn --arg v "$K" '$v|@uri')&color=$COLOR&idBoard=$PROJECT_BOARD_ID")
      LBID=$(echo "$RESP" | jq -r '.id')
    else
      LBID="DRY_$K"
    fi
  fi
  PROJECT_OWNER_LABELS_JSON=$(echo "$PROJECT_OWNER_LABELS_JSON" | jq --arg n "$K" --arg id "$LBID" '. + {($n): $id}')
done < <(jq -r '.owner_labels | keys[]' "$CFG")

# --- 4. Walk features ----------------------------------------------------
LEGACY_BOARD_IDS=()

shopt -s nullglob
for feature_dir in specs/[0-9][0-9][0-9]-*/; do
  fid=$(basename "$feature_dir")
  [ "$fid" = "000-template" ] && continue
  [ -n "$ONLY_FEATURE" ] && [ "$fid" != "$ONLY_FEATURE" ] && continue

  TASKS="$feature_dir/tasks.json"
  STATE="$feature_dir/state.json"
  [ -f "$TASKS" ] || { echo "[Migrate] $fid: no tasks.json — skipping"; continue; }
  [ -f "$STATE" ] || { echo "[Migrate] $fid: no state.json — skipping"; continue; }

  SHORT_FID=$(echo "$fid" | grep -oE '^[0-9]+' || echo "$fid")
  echo
  echo "[Migrate] === Feature: $fid (short=$SHORT_FID) ==="

  LEGACY_BOARD_ID=$(jq -r '.trello.board_id // empty' "$STATE")
  if [ -n "$LEGACY_BOARD_ID" ] && [ "$LEGACY_BOARD_ID" != "$PROJECT_BOARD_ID" ]; then
    LEGACY_BOARD_IDS+=("$fid:$LEGACY_BOARD_ID")
    echo "[Migrate]   legacy board: $LEGACY_BOARD_ID"
  else
    echo "[Migrate]   no legacy board to migrate from"
  fi

  # Ensure feat:<sfid> label on the project board.
  FEAT_LABEL_NAME="feat:$SHORT_FID"
  FEAT_LABEL_ID=$(echo "$EXISTING_LABELS" | jq -r --arg n "$FEAT_LABEL_NAME" '.[] | select(.name==$n) | .id' | head -1)
  if [ -z "$FEAT_LABEL_ID" ]; then
    POOL_LEN=$(jq -r '.feature_labels.color_pool | length' "$CFG")
    IDX=$(( (10#$SHORT_FID - 1) % POOL_LEN ))
    FCOLOR=$(jq -r --arg i "$IDX" '.feature_labels.color_pool[$i | tonumber]' "$CFG")
    echo "[Migrate]   creating feature label: $FEAT_LABEL_NAME ($FCOLOR)"
    if [ "$DRY" -eq 0 ]; then
      RESP=$(trello_post "/labels?name=$(jq -rn --arg v "$FEAT_LABEL_NAME" '$v|@uri')&color=$FCOLOR&idBoard=$PROJECT_BOARD_ID")
      FEAT_LABEL_ID=$(echo "$RESP" | jq -r '.id')
      # Refresh local cache so subsequent features don't re-create.
      EXISTING_LABELS=$(trello_get "/boards/$PROJECT_BOARD_ID/labels?fields=name,color&limit=1000")
    else
      FEAT_LABEL_ID="DRY_FEAT_$SHORT_FID"
    fi
  else
    echo "[Migrate]   feature label exists: $FEAT_LABEL_ID ($FEAT_LABEL_NAME)"
  fi

  # Walk tasks. For each task that has a trello_card_id (legacy card), copy
  # to project board (unless an equivalent [<sfid>] T<NNN> card already exists).
  PROJECT_CARDS=$(trello_get "/boards/$PROJECT_BOARD_ID/cards?fields=name,idList,idLabels&limit=1000" 2>/dev/null) || PROJECT_CARDS="[]"

  task_count=$(jq -r '.tasks | length' "$TASKS")
  copied=0
  skipped=0
  while IFS= read -r TID; do
    LEGACY_CARD_ID=$(jq -r --arg id "$TID" '.tasks[] | select(.id==$id) | (.trello_card_id // empty)' "$TASKS")
    [ -z "$LEGACY_CARD_ID" ] && continue

    TITLE=$(jq -r --arg id "$TID" '.tasks[] | select(.id==$id) | .title'  "$TASKS")
    OWNER=$(jq -r --arg id "$TID" '.tasks[] | select(.id==$id) | .owner'  "$TASKS")
    STATUS=$(jq -r --arg id "$TID" '.tasks[] | select(.id==$id) | .status' "$TASKS")
    NEW_CARD_NAME="[$SHORT_FID] $TID — $TITLE"

    # Idempotency: skip if a card with this exact name already exists on project board.
    EXISTING_PROJECT_CARD_ID=$(echo "$PROJECT_CARDS" | jq -r --arg n "$NEW_CARD_NAME" '.[] | select(.name == $n) | .id' | head -1)
    if [ -n "$EXISTING_PROJECT_CARD_ID" ]; then
      echo "[Migrate]   skip $TID — already on project board ($EXISTING_PROJECT_CARD_ID)"
      # Still rewrite tasks.json to point at the existing card.
      if [ "$DRY" -eq 0 ]; then
        SHORT_URL="https://trello.com/c/${EXISTING_PROJECT_CARD_ID}"
        TMP=$(mktemp)
        jq --arg id "$TID" --arg cid "$EXISTING_PROJECT_CARD_ID" --arg url "$SHORT_URL" \
           '.tasks |= map(if .id == $id then .trello_card_id = $cid | .trello_card_url = $url else . end)' \
           "$TASKS" > "$TMP" && mv "$TMP" "$TASKS"
      fi
      skipped=$((skipped+1))
      continue
    fi

    # Fetch legacy card with desc + idLabels.
    LEGACY_CARD=$(trello_get "/cards/$LEGACY_CARD_ID?fields=name,desc,idLabels,idList") || {
      echo "[Migrate]   $TID: legacy card $LEGACY_CARD_ID not found — skipping"
      continue
    }
    LEGACY_DESC=$(echo "$LEGACY_CARD" | jq -r '.desc // ""')

    # Map status → list ID on project board.
    LIST_NAME=$(jq -r --arg s "$STATUS" '.status_to_list[$s] // "Pending"' "$CFG")
    LIST_ID=$(echo "$PROJECT_LISTS_JSON" | jq -r --arg n "$LIST_NAME" '.[$n]')

    # Owner label + feature label.
    OWNER_LABEL_ID=$(echo "$PROJECT_OWNER_LABELS_JSON" | jq -r --arg n "$OWNER" '.[$n]')
    LABELS_CSV="$OWNER_LABEL_ID,$FEAT_LABEL_ID"

    echo "[Migrate]   + copy $TID → [$SHORT_FID] (list=$LIST_NAME, owner=$OWNER)"
    if [ "$DRY" -eq 0 ]; then
      BODY="name=$(jq -rn --arg v "$NEW_CARD_NAME" '$v|@uri')&idList=$LIST_ID&desc=$(jq -rn --arg v "$LEGACY_DESC" '$v|@uri')&idLabels=$LABELS_CSV"
      RESP=$(trello_post "/cards" -d "$BODY")
      NEW_CARD_ID=$(echo "$RESP" | jq -r '.id')
      NEW_CARD_URL=$(echo "$RESP" | jq -r '.shortUrl')

      # Copy comments (chronological, oldest first).
      COMMENTS=$(trello_get "/cards/$LEGACY_CARD_ID/actions?filter=commentCard&limit=1000" 2>/dev/null) || COMMENTS="[]"
      cmt_count=$(echo "$COMMENTS" | jq -r 'length')
      if [ "$cmt_count" -gt 0 ]; then
        # Reverse: Trello returns newest first; we want chronological.
        echo "$COMMENTS" | jq -r 'reverse | .[] | .data.text' | while IFS= read -r LINE; do
          : # placeholder; below loop walks the array properly
        done
        # Walk via index for portability.
        for i in $(seq $((cmt_count - 1)) -1 0); do
          TEXT=$(echo "$COMMENTS" | jq -r --arg i "$i" '.[$i | tonumber] | .data.text')
          [ -z "$TEXT" ] && continue
          # Prepend a migration tag so the trail is auditable.
          MIGRATED_TEXT="[migrated from legacy board $LEGACY_BOARD_ID]
$TEXT"
          ENCODED=$(jq -rn --arg v "$MIGRATED_TEXT" '$v|@uri')
          trello_post "/cards/$NEW_CARD_ID/actions/comments?text=$ENCODED" > /dev/null || true
        done
      fi

      # Rewrite tasks.json: legacy card_id → new card_id.
      TMP=$(mktemp)
      jq --arg id "$TID" --arg cid "$NEW_CARD_ID" --arg url "$NEW_CARD_URL" \
         '.tasks |= map(if .id == $id then .trello_card_id = $cid | .trello_card_url = $url else . end)' \
         "$TASKS" > "$TMP" && mv "$TMP" "$TASKS"
    fi
    copied=$((copied+1))
  done < <(jq -r '.tasks[].id' "$TASKS")

  echo "[Migrate]   $fid: copied=$copied, skipped=$skipped (of $task_count tasks)"

  # Rewrite state.json: project_board_id + feature_label_id; move old board_id aside.
  if [ "$DRY" -eq 0 ]; then
    TMP=$(mktemp)
    jq --arg bid "$PROJECT_BOARD_ID" --arg flid "$FEAT_LABEL_ID" --arg legacy "$LEGACY_BOARD_ID" \
       --argjson lists "$PROJECT_LISTS_JSON" --argjson labels "$PROJECT_OWNER_LABELS_JSON" \
       '.trello = (.trello // {})
        | .trello.project_board_id = $bid
        | .trello.feature_label_id = $flid
        | (if $legacy != "" and $legacy != $bid then .trello.legacy_board_id = $legacy else . end)
        | .trello.board_id = $bid
        | .trello.lists = $lists
        | .trello.labels = $labels' \
       "$STATE" > "$TMP" && mv "$TMP" "$STATE"
  fi
done

# --- 5. Report legacy boards user should close manually -----------------
echo
echo "[Migrate] === Migration complete ==="
if [ ${#LEGACY_BOARD_IDS[@]} -gt 0 ]; then
  echo "[Migrate] LEGACY boards that should be closed manually on Trello:"
  for entry in "${LEGACY_BOARD_IDS[@]}"; do
    fid="${entry%%:*}"
    bid="${entry##*:}"
    echo "[Migrate]   $fid → board $bid   ( https://trello.com/b/$bid )"
  done
  echo "[Migrate] To close (archive) a legacy board on Trello: Board menu → ... More → Close Board."
  echo "[Migrate] The script does NOT auto-close them so you can verify the migration first."
else
  echo "[Migrate] No legacy per-feature boards found to migrate from."
fi
