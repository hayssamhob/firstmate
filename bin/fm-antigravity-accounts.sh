#!/usr/bin/env bash
# Manage the antigravity (agy) Google-account rotation pool.
#
# Antigravity keeps only the CURRENTLY-active account's OAuth tokens on disk (one
# plaintext oauth_creds.json; no per-account store, no `agy` switch command). So
# to rotate across the captain's 5-6 Google accounts, firstmate must SNAPSHOT each
# account's tokens once while it is active. The captain logs into an account in
# antigravity (interactive Google OAuth - firstmate cannot do this), then runs
# `capture` here to snapshot it into the rotation pool. Repeat per account.
#
# Usage:
#   fm-antigravity-accounts.sh capture         snapshot the CURRENT active account
#   fm-antigravity-accounts.sh list            show pool: rotation order, snapshots, active
#   fm-antigravity-accounts.sh status          one-line current state
#   fm-antigravity-accounts.sh set-rotation <email>...   set the round-robin order
#
# Snapshots (which contain live refresh tokens) are stored at
# ${FM_ANTIGRAVITY_DIR:-~/.gemini}/fm-antigravity-accounts/snapshots/, mode 600,
# NEVER in the firstmate repo. The repo config (config/antigravity-accounts.json,
# gitignored) holds only the rotation order + index.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-antigravity-lib.sh
. "$SCRIPT_DIR/fm-antigravity-lib.sh"

agy_have_jq || { echo "error: jq is required for antigravity account rotation" >&2; exit 1; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

cmd_capture() {
  local oc email snap
  oc="$(agy_oauth_creds)"
  agy_valid_json "$oc" || { echo "error: no valid oauth_creds.json at $oc - log into an account in antigravity first" >&2; exit 1; }
  email="$(agy_active_email || true)"
  if [ -z "$email" ]; then
    # Fall back to the id_token email claim if google_accounts.json is missing.
    email="$(agy_email_of_creds "$oc" || true)"
  fi
  [ -n "$email" ] || { echo "error: could not determine the active account email (google_accounts.json and id_token both unreadable)" >&2; exit 1; }

  # Sanity: the creds we are about to snapshot really belong to this email.
  local creds_email
  creds_email="$(agy_email_of_creds "$oc" || true)"
  if [ -n "$creds_email" ] && [ "$creds_email" != "$email" ]; then
    echo "error: refusing to capture - active email ($email) does not match the token's email ($creds_email); auth state is inconsistent" >&2
    exit 1
  fi

  mkdir -p "$(agy_snapshots_dir)"
  chmod 700 "$(agy_accounts_root)" "$(agy_snapshots_dir)" 2>/dev/null || true
  snap="$(agy_snapshot_path "$email")"
  agy_atomic_copy_json "$oc" "$snap" || { echo "error: snapshot write failed for $email" >&2; exit 1; }
  agy_config_add_email "$email" || { echo "error: could not record $email in the rotation list" >&2; exit 1; }
  echo "captured: $email -> $snap"
  echo "rotation list now: $(agy_config_rotation | paste -sd, - 2>/dev/null || true)"
}

cmd_list() {
  agy_config_ensure
  local active idx i=0
  active="$(agy_active_email || true)"
  idx="$(agy_config_index)"
  echo "antigravity account pool"
  echo "  auth dir:   $(agy_dir)"
  echo "  active now: ${active:-<none>}"
  echo "  index:      $idx"
  echo "  rotation:"
  if [ -z "$(agy_config_rotation)" ]; then
    echo "    <empty> - run 'capture' after logging into each account"
  else
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      local marks=""
      agy_has_snapshot "$e" && marks="snapshot" || marks="NO SNAPSHOT"
      [ "$e" = "$active" ] && marks="$marks, active"
      [ "$i" = "$idx" ] && marks="$marks, index"
      printf '    [%d] %s (%s)\n' "$i" "$e" "$marks"
      i=$((i + 1))
    done <<EOF
$(agy_config_rotation)
EOF
  fi
}

cmd_status() {
  local active; active="$(agy_active_email || true)"
  local n snaps=0
  while IFS= read -r e; do [ -n "$e" ] && agy_has_snapshot "$e" && snaps=$((snaps + 1)); done <<EOF
$(agy_config_rotation)
EOF
  n=$(agy_config_rotation | grep -c . || true)
  echo "antigravity: active=${active:-none} pool=$n snapshots=$snaps index=$(agy_config_index)"
}

cmd_set_rotation() {
  [ "$#" -ge 1 ] || { echo "error: set-rotation needs at least one email" >&2; exit 1; }
  agy_config_ensure
  local cfg e list='[]'
  cfg="$(agy_config_file)"
  # Build a JSON array from the args.
  list=$(printf '%s\n' "$@" | jq -R . | jq -s .)
  jq --argjson r "$list" '.rotation = $r | .index = (.index % ((.rotation|length) // 1))' "$cfg" \
    | agy_atomic_write_json "$cfg"
  echo "rotation set: $(agy_config_rotation | paste -sd, - 2>/dev/null || true)"
  # Warn about any email without a snapshot.
  for e in "$@"; do
    agy_has_snapshot "$e" || echo "warning: $e has no snapshot yet - 'capture' it while it is the active account before rotating to it" >&2
  done
}

case "${1:-}" in
  capture) shift; cmd_capture "$@" ;;
  list) shift; cmd_list "$@" ;;
  status) shift; cmd_status "$@" ;;
  set-rotation) shift; cmd_set_rotation "$@" ;;
  -h|--help|help|'') usage 0 ;;
  *) echo "error: unknown command '$1'" >&2; usage 1 ;;
esac
