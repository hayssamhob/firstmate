#!/usr/bin/env bash
# Behavior tests for the antigravity (agy) harness adapter: launch construction
# (default Gemini 3.6 Flash, Opus escalation, effort-omitted, no turn-end hook),
# process-ancestry detection, and the Google-account rotation mechanism (capture,
# safe swap, refusals, credit-exhaustion detection). Uses a fake tmux/agy pane and
# a scratch auth dir so nothing touches a real ~/.gemini.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
ACCOUNTS="$ROOT/bin/fm-antigravity-accounts.sh"
ROTATE="$ROOT/bin/fm-antigravity-rotate.sh"
CREDIT="$ROOT/bin/fm-antigravity-credit-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-antigravity-harness)

# --- launch construction -----------------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        [ "$prev" = "-l" ] && printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin launchlog id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

read_case_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

test_antigravity_default_launch() {
  local rec id out status launch expected
  id=agy-default-a1
  rec=$(make_spawn_case agy-default "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" antigravity)
  status=$?
  expect_code 0 "$status" "antigravity spawn should succeed"
  assert_contains "$out" "spawned $id harness=antigravity" "spawn did not report antigravity"
  assert_grep "harness=antigravity" "$HOME_DIR/state/$id.meta" "meta missing harness=antigravity"
  assert_grep "model=default" "$HOME_DIR/state/$id.meta" "meta missing model=default"

  launch=$(cat "$LAUNCH_LOG")
  expected="agy --dangerously-skip-permissions --mode accept-edits --model 'gemini-3.6-flash-high' --prompt-interactive \"\$(cat '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "antigravity default launch mismatch"$'\n'"expected: $expected"$'\n'"actual:   $launch"

  # No turn-end hook artifacts (agy has none): no .claude/.devin/.grok hook file.
  assert_absent "$WT_DIR/.claude/settings.local.json" "antigravity wrongly installed a claude Stop hook"
  assert_absent "$WT_DIR/.devin/hooks.v1.json" "antigravity wrongly installed a devin hook"
  assert_absent "$WT_DIR/.fm-grok-turnend" "antigravity wrongly installed a grok pointer"
  pass "antigravity default launch uses Gemini 3.6 Flash, autonomy flags, and installs no turn-end hook"
}

test_antigravity_escalation_model() {
  local rec id launch
  id=agy-opus-a2
  rec=$(make_spawn_case agy-opus "$id")
  read_case_record "$rec"

  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --harness antigravity --model claude-opus-4-6-thinking >/dev/null
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model 'claude-opus-4-6-thinking'" "escalation launch missing opus model"
  assert_not_contains "$launch" "gemini-3.6-flash-high" "escalation launch still carried the flash default"
  assert_grep "model=claude-opus-4-6-thinking" "$HOME_DIR/state/$id.meta" "meta missing escalation model"
  pass "antigravity escalates to Claude Opus 4.6 (Thinking) via --model"
}

test_antigravity_effort_omitted() {
  local rec id launch
  id=agy-effort-a3
  rec=$(make_spawn_case agy-effort "$id")
  read_case_record "$rec"

  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --harness antigravity --effort high >/dev/null
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--effort" "antigravity launch should carry no --effort flag"
  # effort is still recorded in meta for traceability.
  assert_grep "effort=high" "$HOME_DIR/state/$id.meta" "meta should record the requested effort"
  pass "antigravity omits --effort (model-only) but records the requested effort in meta"
}

test_antigravity_detection() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/detect-fake")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/Users/x/.local/bin/agy'; exit 0 ;;
  *"ppid="*) printf '%s\n' '1'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT PATH="$fakebin:$PATH" bash "$HARNESS")
  assert_contains "$out" "antigravity" "fm-harness did not detect antigravity from an agy process"
  pass "fm-harness detects antigravity via process ancestry"
}

# --- account rotation --------------------------------------------------------

agy_run() {  # <scratch> <cmd...> : run a rotation script against a scratch auth dir
  local scratch=$1; shift
  FM_ANTIGRAVITY_DIR="$scratch" FM_HOME="$scratch/fmhome" \
    FM_CONFIG_OVERRIDE="$scratch/fmhome/config" "$@"
}

mk_jwt() {  # <email> -> fake id_token whose payload decodes to {"email":...}
  local hdr pl
  hdr=$(printf '{"alg":"none"}' | base64 | tr '+/' '-_' | tr -d '=')
  pl=$(printf '{"email":"%s"}' "$1" | base64 | tr '+/' '-_' | tr -d '=')
  printf '%s.%s.sig' "$hdr" "$pl"
}

mk_creds() {  # <email> -> creds JSON on stdout
  jq -n --arg t "$(mk_jwt "$1")" \
    '{access_token:"at",refresh_token:"rt",id_token:$t,expiry_date:9999999999,scope:"s",token_type:"Bearer"}'
}

set_active() {  # <scratch> <email> [old...]
  local scratch=$1 email=$2; shift 2
  local old='[]'
  [ "$#" -gt 0 ] && old=$(printf '%s\n' "$@" | jq -R . | jq -s .)
  mk_creds "$email" > "$scratch/oauth_creds.json"
  jq -n --arg a "$email" --argjson o "$old" '{active:$a,old:$o}' > "$scratch/google_accounts.json"
}

creds_email() {  # <scratch> -> email inside oauth_creds id_token
  local scratch=$1 p pad b64 decoded
  p=$(jq -r '.id_token' "$scratch/oauth_creds.json" | cut -d. -f2)
  pad=$(( (4 - ${#p} % 4) % 4 ))
  # base64url -> base64 with padding, then decode portably (GNU `-d`, BSD `-D`).
  b64=$(printf '%s%*s' "$p" "$pad" '' | tr ' ' '=' | tr '_-' '/+')
  decoded=$(printf '%s' "$b64" | base64 -d 2>/dev/null)
  [ -n "$decoded" ] || decoded=$(printf '%s' "$b64" | base64 -D 2>/dev/null)
  printf '%s' "$decoded" | jq -r .email
}

test_antigravity_rotation_roundtrip() {
  local scratch out
  scratch="$TMP_ROOT/rot-ok"
  mkdir -p "$scratch/fmhome/config"

  set_active "$scratch" a@test.com
  agy_run "$scratch" "$ACCOUNTS" capture >/dev/null || fail "capture A failed"
  set_active "$scratch" b@test.com a@test.com
  agy_run "$scratch" "$ACCOUNTS" capture >/dev/null || fail "capture B failed"
  agy_run "$scratch" "$ACCOUNTS" set-rotation a@test.com b@test.com >/dev/null

  agy_run "$scratch" "$ROTATE" next >/dev/null || fail "rotate next failed"
  [ "$(jq -r .active "$scratch/google_accounts.json")" = "a@test.com" ] || fail "active did not become a@test.com"
  [ "$(creds_email "$scratch")" = "a@test.com" ] || fail "oauth_creds did not follow to a@test.com"

  agy_run "$scratch" "$ROTATE" next >/dev/null || fail "rotate next (2) failed"
  [ "$(jq -r .active "$scratch/google_accounts.json")" = "b@test.com" ] || fail "second rotation did not return to b@test.com"

  # to same is a pre-write no-op.
  out=$(agy_run "$scratch" "$ROTATE" to b@test.com)
  assert_contains "$out" "already active" "rotate to the active account should be a no-op"

  # backups made and JSON valid throughout.
  if [ ! -d "$scratch/fm-antigravity-accounts/backups" ] || [ -z "$(ls -A "$scratch/fm-antigravity-accounts/backups")" ]; then
    fail "no rotation backups were written"
  fi
  jq -e . "$scratch/oauth_creds.json" >/dev/null || fail "oauth_creds.json invalid after rotation"
  jq -e . "$scratch/google_accounts.json" >/dev/null || fail "google_accounts.json invalid after rotation"
  pass "rotation round-robins accounts, follows creds, backs up, and keeps JSON valid"
}

test_antigravity_rotation_refuses() {
  local scratch out status
  scratch="$TMP_ROOT/rot-refuse"
  mkdir -p "$scratch/fmhome/config"

  # No auth files at all.
  out=$(agy_run "$scratch" "$ROTATE" next 2>&1); status=$?
  expect_code 1 "$status" "rotate should refuse with no auth files"
  assert_contains "$out" "refusing to rotate" "missing-auth refusal message absent"

  # Invalid oauth_creds.
  printf 'not json{' > "$scratch/oauth_creds.json"
  jq -n '{active:"x@t.com",old:[]}' > "$scratch/google_accounts.json"
  out=$(agy_run "$scratch" "$ROTATE" next 2>&1); status=$?
  expect_code 1 "$status" "rotate should refuse invalid oauth_creds"

  # Valid auth but empty rotation list.
  set_active "$scratch" x@test.com
  out=$(agy_run "$scratch" "$ROTATE" next 2>&1); status=$?
  expect_code 1 "$status" "rotate should refuse an empty rotation list"
  assert_contains "$out" "rotation list is empty" "empty-rotation refusal message absent"
  pass "rotation refuses missing/invalid auth and an empty pool instead of guessing"
}

test_antigravity_credit_check() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/credit-fake")
  # Fake tmux whose capture-pane emits a canned pane driven by FM_FAKE_CAPTURE.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  capture-pane) printf '%s\n' "${FM_FAKE_CAPTURE:-}"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"

  # Out-of-credits footer -> a wake line.
  out=$(FM_FAKE_CAPTURE='? for shortcuts   accept-edits · Gemini 3.6 Flash · high · AI: Out of credits' \
        PATH="$fakebin:$PATH" bash "$CREDIT" faketmux:0)
  assert_contains "$out" "antigravity-out-of-credits faketmux:0" "credit-check missed an out-of-credits footer"

  # Healthy footer -> nothing.
  out=$(FM_FAKE_CAPTURE='? for shortcuts   accept-edits · Gemini 3.6 Flash · high' \
        PATH="$fakebin:$PATH" bash "$CREDIT" faketmux:0)
  [ -z "$out" ] || fail "credit-check should stay silent on a healthy pane, got: $out"
  pass "credit-check wakes only when the antigravity account is out of credits"
}

test_antigravity_atomic_restore() {
  local dir before after
  dir="$TMP_ROOT/atomic-restore"
  mkdir -p "$dir"
  # shellcheck source=bin/fm-antigravity-lib.sh
  . "$ROOT/bin/fm-antigravity-lib.sh"

  # A valid backup restores exactly and atomically into the live-auth path - the
  # same primitive the rotate script uses on its restore-from-backup failure paths.
  printf '{"active":"a@test.com","old":[]}\n' > "$dir/backup.json"
  printf 'PARTIAL-WRITE{' > "$dir/live.json"  # a live file left partial by a crash
  agy_atomic_copy_json "$dir/backup.json" "$dir/live.json" || fail "atomic restore of a valid backup failed"
  jq -e . "$dir/live.json" >/dev/null || fail "restored live auth is not valid JSON"
  [ "$(jq -r .active "$dir/live.json")" = "a@test.com" ] || fail "restored live auth has wrong content"

  # An invalid backup must NOT touch the live file (atomicity: never a partial
  # write to the captain's live auth) and must leave no temp file behind.
  printf '{"active":"good@test.com","old":[]}\n' > "$dir/live2.json"
  printf 'not json{' > "$dir/bad-backup.json"
  before=$(cat "$dir/live2.json")
  agy_atomic_copy_json "$dir/bad-backup.json" "$dir/live2.json" 2>/dev/null \
    && fail "restore from an invalid backup should fail, not write"
  after=$(cat "$dir/live2.json")
  [ "$before" = "$after" ] || fail "invalid restore corrupted the live auth (not atomic)"
  [ -z "$(ls "$dir"/live2.json.fm.* 2>/dev/null)" ] || fail "atomic restore left a temp file behind"
  pass "restore-from-backup is atomic and validated (an invalid backup never partially writes live auth)"
}

test_antigravity_default_launch
test_antigravity_escalation_model
test_antigravity_effort_omitted
test_antigravity_detection
test_antigravity_rotation_roundtrip
test_antigravity_rotation_refuses
test_antigravity_credit_check
test_antigravity_atomic_restore
