#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's post-spawn Claude Foreman identity check
# (fm_foreman_verify_identity). This is the defense-in-depth added after the
# 2026-07-12 incident, where a devin crewmate self-merged a PR attributed to the
# captain because the injected bot identity never reached the merging shell and
# gh fell through to the captain's personal keyring login.
#
# Unlike fm-foreman-spawn.test.sh (whose fake pane only LOGS the sends), this
# suite's fake tmux EXECUTES the identity-probe line so a fake gh writes the
# authcheck file, exercising the real verification end to end: the check reads
# the pane's active gh account and records foreman_verify= in meta, warning
# loudly when it is not the bot. Cases: bot active -> ok (silent), a personal
# fallback active -> mismatch + loud warning, no active account -> unknown, and a
# non-executing pane -> unknown by timeout - and the spawn always still succeeds.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-foreman-verify)
mkdir -p "$TMP_ROOT"
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

if ! command -v openssl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  pass "SKIP: openssl or jq not available; foreman verify tests need both"
  exit 0
fi

TEST_PEM="$TMP_ROOT/test-key.pem"
openssl genrsa -out "$TEST_PEM" 2048 2>/dev/null || fail "could not generate throwaway test key"

make_verify_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  # Fake tmux: logs sends AND executes the identity-probe line (the one carrying
  # FM_AUTHCHECK_DONE) so the fake gh actually writes the authcheck file - unless
  # FM_FAKE_TMUX_NOEXEC simulates a pane that never runs the probe.
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
    skip_next=1
    for a in "$@"; do
      if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
      case "$a" in
        -t) skip_next=1; continue ;;
        -l|Enter) continue ;;
      esac
      [ -n "${FM_FAKE_LAUNCH_LOG:-}" ] && printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
      case "$a" in
        *FM_AUTHCHECK_DONE*) [ -z "${FM_FAKE_TMUX_NOEXEC:-}" ] && bash -c "$a" ;;
      esac
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *access_tokens*) printf '{"token":"ghs_faketoken123","expires_at":"2099-01-01T00:00:00Z"}' ;;
  */users/*) printf '{"login":"claude-foreman[bot]","id":424242}' ;;
  *) exit 22 ;;
esac
SH
  chmod +x "$fakebin/curl"
  # Fake gh: `auth status` renders a switchable active account (FM_FAKE_GH_ACTIVE,
  # default the bot). Empty -> no account is marked active. Everything else exit 0.
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  active="${FM_FAKE_GH_ACTIVE-claude-foreman[bot]}"
  echo "github.com"
  if [ -n "$active" ]; then
    echo "  ✓ Logged in to github.com account $active (GH_TOKEN)"
    echo "  - Active account: true"
  fi
  echo "  ✓ Logged in to github.com account hayssamhob (keyring)"
  echo "  - Active account: false"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_verify_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_verify_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' claude > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  git -C "$proj" remote add origin "git@github.com:owner/repo.git"
  ln -s "$TEST_PEM" "$home/config/claude-foreman.pem"
  cat > "$home/config/claude-foreman.env" <<'ENV'
FM_FOREMAN_APP_ID=4034902
FM_FOREMAN_INSTALLATION_ID=139779760
ENV
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  # CASE_DIR is part of the shared record format but unused in this suite.
  # shellcheck disable=SC2034
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FOREMAN_VERIFY_TIMEOUT="${FM_FOREMAN_VERIFY_TIMEOUT:-5}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

register_task_tmp() { FM_TEST_CLEANUP_DIRS+=("/tmp/fm-$1"); }

register_foreman_tmp() {
  local meta=$1 ftmp
  ftmp=$(grep '^foremantmp=' "$meta" 2>/dev/null | cut -d= -f2-)
  [ -n "$ftmp" ] && FM_TEST_CLEANUP_DIRS+=("$ftmp")
}

test_bot_active_verifies_ok() {
  local rec id out status
  id=verify-ok-z1
  register_task_tmp "$id"
  rec=$(make_verify_case verify-ok "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  register_foreman_tmp "$HOME_DIR/state/$id.meta"
  expect_code 0 "$status" "spawn with a verified bot identity should succeed"
  assert_contains "$out" "spawned $id" "spawn did not complete"
  assert_grep "foreman_verify=ok" "$HOME_DIR/state/$id.meta" "bot-active pane should record foreman_verify=ok"
  assert_not_contains "$out" "WARNING: Claude Foreman identity is NOT active" "a verified bot identity must not warn"
  pass "bot active in the pane records foreman_verify=ok and stays silent"
}

test_personal_fallthrough_warns_mismatch() {
  local rec id out status
  id=verify-mismatch-z1
  register_task_tmp "$id"
  rec=$(make_verify_case verify-mismatch "$id")
  read_case_record "$rec"
  out=$(FM_FAKE_GH_ACTIVE=hayssamhob run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  register_foreman_tmp "$HOME_DIR/state/$id.meta"
  expect_code 0 "$status" "identity mismatch must never block the spawn"
  assert_contains "$out" "spawned $id" "spawn should still complete on mismatch"
  assert_grep "foreman_verify=mismatch:hayssamhob" "$HOME_DIR/state/$id.meta" "captain-active pane should record the mismatch and the found account"
  assert_contains "$out" "WARNING: Claude Foreman identity is NOT active" "a personal-account fallthrough must warn loudly"
  assert_contains "$out" "hayssamhob" "the warning should name the account gh actually resolved to"
  pass "personal-account fallthrough records mismatch and warns loudly"
}

test_no_active_account_is_unknown() {
  local rec id out status
  id=verify-unknown-z1
  register_task_tmp "$id"
  rec=$(make_verify_case verify-unknown "$id")
  read_case_record "$rec"
  out=$(FM_FAKE_GH_ACTIVE='' run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  register_foreman_tmp "$HOME_DIR/state/$id.meta"
  expect_code 0 "$status" "an unverifiable identity must never block the spawn"
  assert_grep "foreman_verify=unknown" "$HOME_DIR/state/$id.meta" "no active account should record foreman_verify=unknown"
  assert_contains "$out" "unverified" "an unknown identity should warn that it is unverified"
  pass "no active gh account records foreman_verify=unknown and warns"
}

test_nonexecuting_pane_times_out_unknown() {
  local rec id out status
  id=verify-timeout-z1
  register_task_tmp "$id"
  rec=$(make_verify_case verify-timeout "$id")
  read_case_record "$rec"
  out=$(FM_FAKE_TMUX_NOEXEC=1 FM_FOREMAN_VERIFY_TIMEOUT=1 run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  register_foreman_tmp "$HOME_DIR/state/$id.meta"
  expect_code 0 "$status" "a probe that never completes must never block the spawn"
  assert_contains "$out" "spawned $id" "spawn should still complete when the probe never runs"
  assert_grep "foreman_verify=unknown" "$HOME_DIR/state/$id.meta" "a non-executing pane should record foreman_verify=unknown by timeout"
  assert_contains "$out" "did not complete" "a timed-out probe should warn that it did not complete"
  pass "a non-executing pane times out to foreman_verify=unknown without blocking"
}

test_verify_disabled_is_silent() {
  local rec id out status
  id=verify-off-z1
  register_task_tmp "$id"
  rec=$(make_verify_case verify-off "$id")
  read_case_record "$rec"
  out=$(FM_FOREMAN_VERIFY=0 run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  register_foreman_tmp "$HOME_DIR/state/$id.meta"
  expect_code 0 "$status" "spawn with the identity check disabled should succeed"
  assert_no_grep "foreman_verify=" "$HOME_DIR/state/$id.meta" "FM_FOREMAN_VERIFY=0 must not record any foreman_verify= line"
  pass "FM_FOREMAN_VERIFY=0 disables the identity check entirely"
}

test_bot_active_verifies_ok
test_personal_fallthrough_warns_mismatch
test_no_active_account_is_unknown
test_nonexecuting_pane_times_out_unknown
test_verify_disabled_is_silent
