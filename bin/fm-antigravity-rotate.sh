#!/usr/bin/env bash
# Rotate the antigravity (agy) CLI to the next Google account when the active one
# is out of credits. Performs the SAFE, non-interactive account swap: it replaces
# oauth_creds.json with a previously-captured snapshot of the target account and
# points google_accounts.json .active at it. See fm-antigravity-lib.sh for the
# storage model and fm-antigravity-accounts.sh for capturing snapshots.
#
# Usage:
#   fm-antigravity-rotate.sh next [--verify] [--relaunch <window>]
#   fm-antigravity-rotate.sh to <email> [--verify] [--relaunch <window>]
#
#   next        rotate round-robin to the next pool account that has a snapshot
#   to <email>  rotate to a specific captured account
#   --verify    after swapping, run `agy -p` once to confirm the new account
#               authenticates (consumes one small request)
#   --relaunch <window>  after a successful swap, resume the stalled crew by
#               exiting the still-running agy (Ctrl+D twice) so the pane returns
#               to a shell, then relaunching agy there with the task's autonomy
#               flags plus --continue so it re-reads the new creds. (Sending
#               `agy --continue` as text would just be typed into the stalled
#               agy's composer as a chat message, not relaunch it.)
#
# SAFETY: backs up oauth_creds.json + google_accounts.json before any write,
# re-snapshots the outgoing account so its latest tokens are never lost, writes
# atomically, validates JSON throughout, and refuses on any inconsistency rather
# than risking the captain's live auth. A single rotation runs under a lock.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-antigravity-lib.sh
. "$SCRIPT_DIR/fm-antigravity-lib.sh"

agy_have_jq || { echo "error: jq is required for antigravity account rotation" >&2; exit 1; }

VERIFY=0
RELAUNCH_WINDOW=
MODE=
TARGET=

args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --verify) VERIFY=1 ;;
    --relaunch) shift; RELAUNCH_WINDOW=${1:-}; [ -n "$RELAUNCH_WINDOW" ] || { echo "error: --relaunch needs a window" >&2; exit 1; } ;;
    --relaunch=*) RELAUNCH_WINDOW=${1#--relaunch=} ;;
    -h|--help|help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) args+=("$1") ;;
  esac
  shift
done
set -- ${args[@]+"${args[@]}"}
MODE=${1:-}
case "$MODE" in
  next) : ;;
  to) TARGET=${2:-}; [ -n "$TARGET" ] || { echo "error: 'to' needs an email" >&2; exit 1; } ;;
  '') echo "error: specify 'next' or 'to <email>'" >&2; exit 1 ;;
  *) echo "error: unknown command '$MODE'" >&2; exit 1 ;;
esac

OC="$(agy_oauth_creds)"
GA="$(agy_google_accounts)"
agy_valid_json "$OC" || { echo "error: oauth_creds.json missing or invalid ($OC); refusing to rotate" >&2; exit 1; }
agy_valid_json "$GA" || { echo "error: google_accounts.json missing or invalid ($GA); refusing to rotate" >&2; exit 1; }

CURRENT="$(agy_active_email || true)"
[ -n "$CURRENT" ] || { echo "error: cannot read the active account; refusing to rotate" >&2; exit 1; }

# Build the rotation list into a bash array.
ROTATION=()
while IFS= read -r e; do [ -n "$e" ] && ROTATION+=("$e"); done <<EOF
$(agy_config_rotation)
EOF
[ "${#ROTATION[@]}" -ge 1 ] || { echo "error: rotation list is empty - capture accounts first (fm-antigravity-accounts.sh capture)" >&2; exit 1; }

# Resolve the target email.
if [ "$MODE" = next ]; then
  # Find CURRENT's position; scan forward (wrapping) for the next snapshotted,
  # different account.
  start=-1
  for i in "${!ROTATION[@]}"; do [ "${ROTATION[$i]}" = "$CURRENT" ] && start=$i && break; done
  [ "$start" -ge 0 ] || start=$(( $(agy_config_index) - 1 ))
  n=${#ROTATION[@]}
  TARGET=
  for off in $(seq 1 "$n"); do
    idx=$(( (start + off) % n ))
    cand=${ROTATION[$idx]}
    [ "$cand" = "$CURRENT" ] && continue
    if agy_has_snapshot "$cand"; then TARGET=$cand; break; fi
  done
  [ -n "$TARGET" ] || { echo "error: no other pool account has a snapshot to rotate to (capture more accounts)" >&2; exit 1; }
fi

# Validate the target has a usable snapshot.
SNAP="$(agy_snapshot_path "$TARGET")"
agy_valid_json "$SNAP" || { echo "error: no valid snapshot for $TARGET at $SNAP - capture it first" >&2; exit 1; }
if [ "$TARGET" = "$CURRENT" ]; then
  echo "already active: $CURRENT (nothing to rotate)"
  exit 0
fi
# Confirm the snapshot really belongs to the target email.
snap_email="$(agy_email_of_creds "$SNAP" || true)"
if [ -n "$snap_email" ] && [ "$snap_email" != "$TARGET" ]; then
  echo "error: snapshot for $TARGET actually holds tokens for $snap_email; refusing to rotate" >&2
  exit 1
fi

# Serialize rotation with a simple mkdir lock.
LOCK="$(agy_accounts_root)/.rotate.lock"
mkdir -p "$(agy_accounts_root)"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "error: another rotation is in progress ($LOCK); refusing to run concurrently" >&2
  exit 1
fi
cleanup() { rmdir "$LOCK" 2>/dev/null || true; }
trap cleanup EXIT

STAMP=$(date -u +%Y%m%dT%H%M%SZ)

# 1. Back up the live auth pair.
BACKUP_DIR="$(agy_backup_live "$STAMP")" || { echo "error: backup failed; refusing to rotate" >&2; exit 1; }

# 2. Re-snapshot the OUTGOING account so its latest refresh token is preserved for
#    a future rotation back. Best-effort: warn but continue if it fails, since we
#    already have the full backup.
mkdir -p "$(agy_snapshots_dir)"
out_email="$(agy_email_of_creds "$OC" || true)"
if [ -n "$out_email" ] && [ "$out_email" = "$CURRENT" ]; then
  agy_atomic_copy_json "$OC" "$(agy_snapshot_path "$CURRENT")" \
    || echo "warning: could not refresh snapshot for outgoing account $CURRENT (backup at $BACKUP_DIR retains it)" >&2
fi

# 3. Swap the target snapshot into oauth_creds.json (atomic).
if ! agy_atomic_copy_json "$SNAP" "$OC"; then
  echo "error: failed to install $TARGET creds; restoring from backup" >&2
  # Atomic restore (mktemp-in-same-dir + validate + mv, like the write path), so
  # an interrupted restore can never leave the captain's live oauth_creds.json
  # partial; the backup dir stays intact if the restore itself fails.
  if [ -f "$BACKUP_DIR/oauth_creds.json" ]; then
    agy_atomic_copy_json "$BACKUP_DIR/oauth_creds.json" "$OC" \
      || echo "warning: could not restore oauth_creds.json; the intact backup is at $BACKUP_DIR" >&2
  fi
  exit 1
fi

# 4. Update google_accounts.json: active=target, old=every other known email.
#    Old is the union of the previous active+old and the rotation list, minus the
#    new active, deduped - so the record stays consistent no matter the pool.
rotation_json=$(printf '%s\n' "${ROTATION[@]}" | jq -R . | jq -s .)
if ! jq \
      --arg active "$TARGET" \
      --argjson rot "$rotation_json" \
      '
      ( ([.active] + (.old // []) + $rot)
        | map(select(. != null and . != "" and . != $active))
        | unique ) as $old
      | {active: $active, old: $old}
      ' "$GA" | agy_atomic_write_json "$GA"; then
  echo "error: failed to update google_accounts.json; restoring auth from backup" >&2
  # Atomic restore of BOTH files (the swap already replaced oauth_creds.json), so a
  # crash mid-restore never leaves the captain's live auth partial; the backup dir
  # stays intact if a restore fails.
  if [ -f "$BACKUP_DIR/oauth_creds.json" ]; then
    agy_atomic_copy_json "$BACKUP_DIR/oauth_creds.json" "$OC" \
      || echo "warning: could not restore oauth_creds.json; the intact backup is at $BACKUP_DIR" >&2
  fi
  if [ -f "$BACKUP_DIR/google_accounts.json" ]; then
    agy_atomic_copy_json "$BACKUP_DIR/google_accounts.json" "$GA" \
      || echo "warning: could not restore google_accounts.json; the intact backup is at $BACKUP_DIR" >&2
  fi
  exit 1
fi

# 5. Advance the config index to the target's position (if it is in the list).
for i in "${!ROTATION[@]}"; do
  if [ "${ROTATION[$i]}" = "$TARGET" ]; then agy_config_set_index "$i" || true; break; fi
done

echo "rotated: $CURRENT -> $TARGET (backup: $BACKUP_DIR)"

# 6. Optional post-swap auth verification.
if [ "$VERIFY" = 1 ]; then
  if command -v agy >/dev/null 2>&1; then
    if agy --model gemini-3.6-flash --print-timeout 60s -p "reply with exactly: ROTATED_OK" 2>/dev/null | grep -q ROTATED_OK; then
      echo "verify: $TARGET authenticates OK"
    else
      echo "warning: post-rotation verify did not confirm auth for $TARGET; inspect the account (it may also be out of credits)" >&2
    fi
  else
    echo "warning: agy not on PATH; skipped verify" >&2
  fi
fi

# 7. Optional resume of the stalled crew.
#    The out-of-credits footer fires while agy's interactive TUI is still up, so
#    the crew pane sits at agy's composer, NOT a shell prompt. A single fm-send
#    text line would type into that composer and be submitted as a CHAT MESSAGE
#    to the stalled (still-old-account) session - it would never relaunch agy on
#    the freshly swapped creds. So resume is exit-then-relaunch: quit agy (Ctrl+D
#    twice) to drop the pane back to a shell prompt, then launch a fresh agy
#    there so it re-reads the new oauth_creds.json and resumes with --continue.
#    Fully best-effort: a failed send warns but never aborts the completed swap.
if [ -n "$RELAUNCH_WINDOW" ]; then
  if [ -x "$SCRIPT_DIR/fm-send.sh" ]; then
    # agy's verified exit is Ctrl+D pressed twice (first press arms the confirm).
    "$SCRIPT_DIR/fm-send.sh" "$RELAUNCH_WINDOW" --key C-d 2>/dev/null || true
    sleep 0.5
    "$SCRIPT_DIR/fm-send.sh" "$RELAUNCH_WINDOW" --key C-d 2>/dev/null || true
    sleep 1.5
    # Relaunch at the now-shell prompt with the task's autonomy flags preserved.
    # A bare --continue resumes on the account's default model; firstmate may add
    # --model <id> to hold the tier, but the base autonomy resume is enough here.
    if "$SCRIPT_DIR/fm-send.sh" "$RELAUNCH_WINDOW" 'agy --dangerously-skip-permissions --mode accept-edits --continue'; then
      echo "relaunch: exited stalled agy and relaunched on $TARGET at $RELAUNCH_WINDOW"
    else
      echo "warning: could not relaunch agy at $RELAUNCH_WINDOW; resume it manually (exit with Ctrl+D twice, then 'agy --dangerously-skip-permissions --mode accept-edits --continue')" >&2
    fi
  else
    echo "warning: fm-send.sh not found; resume the crew manually (exit agy with Ctrl+D twice, then 'agy --dangerously-skip-permissions --mode accept-edits --continue')" >&2
  fi
fi
