#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's Claude Foreman crew-identity injection.
#
# These drive the real fm-spawn.sh with a fake tmux pane, a real isolated git
# worktree, and a fake curl behind the real fm-foreman-token.sh, asserting the
# pane-environment injection (PATH shim, GH_TOKEN mint line, GIT_CONFIG_* env)
# and the skip/fallback paths: config absent is a silent no-op, mint failure
# warns and falls back, non-GitHub origins skip, and secondmate spawns are
# exempt. No real key: a throwaway RSA key is generated per run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-foreman-spawn)
# fm_test_tmproot runs in a command substitution whose EXIT trap already
# removed the dir; recreate it and register cleanup in THIS shell. Spawned
# tasks also create real /tmp/fm-<id> temp roots; register those too.
mkdir -p "$TMP_ROOT"
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

if ! command -v openssl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  pass "SKIP: openssl or jq not available; foreman spawn tests need both"
  exit 0
fi

TEST_PEM="$TMP_ROOT/test-key.pem"
openssl genrsa -out "$TEST_PEM" 2048 2>/dev/null || fail "could not generate throwaway test key"

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
    # Log every text payload: both the -l literal launch send and the plain
    # `send-keys -t <target> "<text>" Enter` used for spawn-time export lines.
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      skip_next=1  # skip the leading "send-keys" verb itself
      for a in "$@"; do
        if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l|Enter) continue ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_FAKE_CURL_FAIL:-}" ]; then
  exit 22
fi
case "$*" in
  *access_tokens*) printf '{"token":"ghs_faketoken123","expires_at":"2099-01-01T00:00:00Z"}' ;;
  */users/*) printf '{"login":"claude-foreman[bot]","id":424242}' ;;
  *) exit 22 ;;
esac
SH
  chmod +x "$fakebin/curl"
  fm_fake_exit0 "$fakebin" treehouse gh
  printf '%s\n' "$fakebin"
}

# make_spawn_case <name> <id> [origin-url]: build a case dir with a firstmate
# home, a project with an optional origin remote, and a worktree. Echoes the
# case record consumed by read_case_record.
make_spawn_case() {
  local name=$1 id=$2 origin=${3:-} case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' claude > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  if [ -n "$origin" ]; then
    git -C "$proj" remote add origin "$origin"
  fi
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

enable_foreman() {
  local home=$1
  ln -s "$TEST_PEM" "$home/config/claude-foreman.pem"
  cat > "$home/config/claude-foreman.env" <<'ENV'
FM_FOREMAN_APP_ID=4034902
FM_FOREMAN_INSTALLATION_ID=139779760
ENV
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

register_task_tmp() {
  FM_TEST_CLEANUP_DIRS+=("/tmp/fm-$1")
}

test_no_config_is_zero_behavior_change() {
  local rec id out status launch
  id=foreman-off-z1
  register_task_tmp "$id"
  rec=$(make_spawn_case foreman-off "$id" "git@github.com:owner/repo.git")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn without foreman config should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_not_contains "$out" "Claude Foreman" "no-config spawn must stay silent about foreman"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "GIT_CONFIG_COUNT" "no-config spawn must not inject git env config"
  assert_not_contains "$launch" "GH_TOKEN" "no-config spawn must not inject GH_TOKEN"
  assert_no_grep "foreman=" "$HOME_DIR/state/$id.meta" "no-config spawn must not record foreman= in meta"
  pass "absent foreman config is a silent zero-behavior-change spawn"
}

test_configured_spawn_injects_identity() {
  local rec id out status launch
  id=foreman-on-z1
  register_task_tmp "$id"
  rec=$(make_spawn_case foreman-on "$id" "git@github.com:owner/repo.git")
  read_case_record "$rec"
  enable_foreman "$HOME_DIR"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "configured foreman spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "token 'owner/repo' '/tmp/fm-$id/foreman-token.json'" "pane should mint GH_TOKEN via the helper"
  assert_contains "$launch" "export GH_TOKEN=" "pane should export GH_TOKEN"
  assert_contains "$launch" "GIT_CONFIG_COUNT=6" "pane should get the git env config block"
  assert_contains "$launch" "credential.https://github.com.helper" "git env config should install the credential helper"
  assert_contains "$launch" "GIT_CONFIG_VALUE_1='!'" "credential helper value should be a shell-command helper"
  assert_contains "$launch" "fm-foreman-token.sh" "credential helper should route through the token helper"
  assert_contains "$launch" "GIT_CONFIG_VALUE_2='claude-foreman[bot]'" "git author name should be the bot login"
  assert_contains "$launch" "424242+claude-foreman[bot]@users.noreply.github.com" "git author email should be the id-linked noreply address"
  assert_contains "$launch" "url.https://github.com/.insteadOf" "ssh remotes should be rewritten to https"
  assert_contains "$launch" "export PATH='/tmp/fm-$id/bin'" "pane PATH should get the gh shim dir"
  assert_present "/tmp/fm-$id/bin/gh" "gh shim should be written into the task temp root"
  assert_grep "fm-foreman-token.sh' token 'owner/repo'" "/tmp/fm-$id/bin/gh" "gh shim should re-mint via the token helper"
  assert_grep "foreman=claude-foreman[bot]" "$HOME_DIR/state/$id.meta" "meta should record the injected foreman identity"
  # The token itself must never be echoed into the pane.
  assert_not_contains "$launch" "ghs_faketoken123" "raw token must not appear in pane input"
  pass "configured spawn injects the foreman identity into the pane environment"
}

test_mint_failure_warns_and_falls_back() {
  local rec id out status launch
  id=foreman-fail-z1
  register_task_tmp "$id"
  rec=$(make_spawn_case foreman-fail "$id" "https://github.com/owner/repo")
  read_case_record "$rec"
  enable_foreman "$HOME_DIR"
  out=$(FM_FAKE_CURL_FAIL=1 run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "mint failure must never block the spawn"
  assert_contains "$out" "Claude Foreman identity unavailable" "mint failure should warn about the fallback"
  assert_contains "$out" "spawned $id" "spawn should still complete after mint failure"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "GIT_CONFIG_COUNT" "failed mint must not inject git env config"
  assert_no_grep "foreman=" "$HOME_DIR/state/$id.meta" "failed mint must not record foreman= in meta"
  pass "mint failure warns and falls back to the default identity"
}

test_non_github_origin_skips() {
  local rec id out status launch
  id=foreman-nogh-z1
  register_task_tmp "$id"
  rec=$(make_spawn_case foreman-nogh "$id" "git@gitlab.example.com:owner/repo.git")
  read_case_record "$rec"
  enable_foreman "$HOME_DIR"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "non-GitHub origin spawn should succeed"
  assert_not_contains "$out" "Claude Foreman" "non-GitHub origin should skip silently"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "GIT_CONFIG_COUNT" "non-GitHub origin must not inject git env config"
  pass "non-GitHub origins skip foreman injection silently"
}

test_secondmate_spawn_is_exempt() {
  local rec id out status launch sm_home
  id=foreman-sm-z1
  rec=$(make_spawn_case foreman-sm "$id")
  read_case_record "$rec"
  enable_foreman "$HOME_DIR"
  sm_home="$CASE_DIR/sm-home"
  mkdir -p "$sm_home/bin" "$sm_home/data"
  printf '# Firstmate\n' > "$sm_home/AGENTS.md"
  printf '%s\n' "$id" > "$sm_home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm_home/data/charter.md"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm_home" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn with foreman config should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "GIT_CONFIG_COUNT" "secondmate spawn must not inject git env config"
  assert_not_contains "$launch" "GH_TOKEN" "secondmate spawn must not inject GH_TOKEN"
  assert_no_grep "foreman=" "$HOME_DIR/state/$id.meta" "secondmate meta must not record foreman="
  pass "secondmate spawns are exempt from foreman injection"
}

test_no_config_is_zero_behavior_change
test_configured_spawn_injects_identity
test_mint_failure_warns_and_falls_back
test_non_github_origin_skips
test_secondmate_spawn_is_exempt
