#!/usr/bin/env bash
# Shared helpers for antigravity (agy) Google-account rotation.
#
# Antigravity's CLI keeps the CURRENTLY-active account's live OAuth tokens in a
# single plaintext file, ${AGY_DIR}/oauth_creds.json (keys: access_token,
# refresh_token, id_token, expiry_date, scope, token_type - no email field), and
# a companion ${AGY_DIR}/google_accounts.json of the form
# {"active":"<email>","old":["<email>",...]}. The active email always mirrors the
# account whose tokens are in oauth_creds.json (verified: the id_token's email
# claim equals .active). There is NO per-account credential store on disk and NO
# `agy` account-switch subcommand, so switching the account the CLI authenticates
# as means REPLACING oauth_creds.json with the target account's tokens and setting
# google_accounts.json .active to match.
#
# Because only the active account's tokens exist on disk, firstmate must SNAPSHOT
# each account's oauth_creds.json once (while it is active) before it can rotate
# to it. Snapshots (which contain live refresh tokens) live OUTSIDE the firstmate
# repo, next to the auth they belong to, at ${AGY_DIR}/fm-antigravity-accounts/,
# mode 600 - never in the gitignored config/ tree, as defense in depth against
# ever committing a credential. The firstmate-repo config only holds the rotation
# order + index (config/antigravity-accounts.json), never a token.
#
# SAFETY CONTRACT (every mutation): back up oauth_creds.json AND
# google_accounts.json first, validate JSON before and after, write atomically
# (temp + mv), and never destroy an account's only copy of its creds. A dirty or
# unreadable auth state refuses rather than guesses.
set -u

# Resolve the antigravity data dir (holds oauth_creds.json + google_accounts.json).
# Override with FM_ANTIGRAVITY_DIR (used by tests to point at a scratch copy so the
# captain's live auth is never touched).
agy_dir() {
  printf '%s\n' "${FM_ANTIGRAVITY_DIR:-$HOME/.gemini}"
}

agy_oauth_creds() { printf '%s/oauth_creds.json\n' "$(agy_dir)"; }
agy_google_accounts() { printf '%s/google_accounts.json\n' "$(agy_dir)"; }
agy_accounts_root() { printf '%s/fm-antigravity-accounts\n' "$(agy_dir)"; }
agy_snapshots_dir() { printf '%s/snapshots\n' "$(agy_accounts_root)"; }
agy_backups_dir() { printf '%s/backups\n' "$(agy_accounts_root)"; }

# Rotation config lives in the firstmate repo (LOCAL, gitignored): the ordered
# email list + current index only. FM_CONFIG_OVERRIDE / FM_HOME are honored so a
# secondmate home or a test can point elsewhere.
agy_config_file() {
  local root config
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  config="${FM_CONFIG_OVERRIDE:-${FM_HOME:-$root}/config}"
  printf '%s/antigravity-accounts.json\n' "$config"
}

agy_have_jq() { command -v jq >/dev/null 2>&1; }

# 0 if the file exists and is valid JSON.
agy_valid_json() {
  local f=$1
  [ -f "$f" ] || return 1
  jq -e . "$f" >/dev/null 2>&1
}

# The email the target snapshot / active belongs to is derived from the id_token's
# email claim, so a captured snapshot is self-identifying and a swap can be
# post-verified. Prints the email, or nothing on failure.
agy_email_of_creds() {
  local f=$1 payload
  [ -f "$f" ] || return 1
  payload=$(jq -r '.id_token // empty' "$f" 2>/dev/null | cut -d. -f2) || return 1
  [ -n "$payload" ] || return 1
  # base64url -> base64 with padding, then decode and read the email claim.
  local pad=$(( (4 - ${#payload} % 4) % 4 ))
  printf '%s%*s' "$payload" "$pad" '' | tr ' ' '=' | tr '_-' '/+' \
    | base64 -D 2>/dev/null | jq -r '.email // empty' 2>/dev/null
}

# Current active email from google_accounts.json (authoritative record).
agy_active_email() {
  agy_valid_json "$(agy_google_accounts)" || return 1
  jq -r '.active // empty' "$(agy_google_accounts)" 2>/dev/null
}

# Atomic write: content on stdin -> dest, validated as JSON first.
agy_atomic_write_json() {
  local dest=$1 tmp
  tmp=$(mktemp "${dest}.fm.XXXXXX") || return 1
  cat > "$tmp" || { rm -f "$tmp"; return 1; }
  if ! jq -e . "$tmp" >/dev/null 2>&1; then
    echo "error: refusing to write invalid JSON to $dest" >&2
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dest"
}

# Copy a file atomically, preserving 600 perms; validates JSON.
agy_atomic_copy_json() {
  local src=$1 dest=$2
  agy_valid_json "$src" || { echo "error: source is not valid JSON: $src" >&2; return 1; }
  agy_atomic_write_json "$dest" < "$src"
}

# Back up the live auth pair (oauth_creds.json + google_accounts.json) into a
# fresh timestamped dir; prints the backup dir. Never overwrites a prior backup.
# The timestamp comes in as arg 1 (callers stamp it; scripts cannot rely on
# Date.now-style calls being reproducible, but a plain `date` is fine in a shell
# script). Falls back to a counter if the stamped dir somehow exists.
agy_backup_live() {
  local stamp=$1 base dir n
  base="$(agy_backups_dir)"
  mkdir -p "$base" || return 1
  dir="$base/$stamp"
  n=0
  while [ -e "$dir" ]; do
    n=$((n + 1))
    dir="$base/$stamp.$n"
  done
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  local oc ga
  oc="$(agy_oauth_creds)"; ga="$(agy_google_accounts)"
  [ -f "$oc" ] && { cp -p "$oc" "$dir/oauth_creds.json" || return 1; }
  [ -f "$ga" ] && { cp -p "$ga" "$dir/google_accounts.json" || return 1; }
  printf '%s\n' "$dir"
}

# Ensure the rotation config exists with an empty rotation list.
agy_config_ensure() {
  local cfg; cfg="$(agy_config_file)"
  mkdir -p "$(dirname "$cfg")" || return 1
  [ -f "$cfg" ] && agy_valid_json "$cfg" && return 0
  agy_atomic_write_json "$cfg" <<'JSON'
{"rotation":[],"index":0}
JSON
}

agy_config_rotation() { jq -r '.rotation[]? // empty' "$(agy_config_file)" 2>/dev/null; }
agy_config_index() { jq -r '.index // 0' "$(agy_config_file)" 2>/dev/null; }

# Add an email to the rotation list if not already present (idempotent).
agy_config_add_email() {
  local email=$1 cfg; cfg="$(agy_config_file)"
  agy_config_ensure || return 1
  jq --arg e "$email" '.rotation |= (if (index($e)) then . else . + [$e] end)' "$cfg" \
    | agy_atomic_write_json "$cfg"
}

agy_config_set_index() {
  local idx=$1 cfg; cfg="$(agy_config_file)"
  agy_config_ensure || return 1
  jq --argjson i "$idx" '.index = $i' "$cfg" | agy_atomic_write_json "$cfg"
}

agy_snapshot_path() { printf '%s/%s.oauth_creds.json\n' "$(agy_snapshots_dir)" "$1"; }
agy_has_snapshot() { [ -f "$(agy_snapshot_path "$1")" ]; }
