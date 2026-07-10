#!/usr/bin/env bash
# Behavior tests for bin/fm-foreman-gh-shim.sh - the login-PATH gh wrapper
# that makes PRs opened by the no-mistakes daemon author as the Claude
# Foreman bot.
#
# These drive the real installer and the rendered wrapper with a fake real gh
# (logging argv + GH_TOKEN), a fake ps (steering the ancestry walk), and a
# fake curl behind the real fm-foreman-token.sh. Asserted: install/remove/
# status lifecycle including the foreign-file refusal, and the wrapper's
# interposition matrix - only `gh pr create` + no-mistakes ancestry + no
# preexisting GH_TOKEN + a mintable repo gets the bot token; every other path
# passes through to the real gh untouched. No real key: a throwaway RSA key
# is generated per run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHIM="$ROOT/bin/fm-foreman-gh-shim.sh"
TMP_ROOT=$(fm_test_tmproot fm-foreman-gh-shim)
mkdir -p "$TMP_ROOT"
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

if ! command -v openssl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  pass "SKIP: openssl or jq not available; foreman gh shim tests need both"
  exit 0
fi

TEST_PEM="$TMP_ROOT/test-key.pem"
openssl genrsa -out "$TEST_PEM" 2048 2>/dev/null || fail "could not generate throwaway test key"

# make_case <name>: a home with foreman config, a shim bin dir, a fake real gh
# dir, and fake ps/curl. Echoes "home|bindir|fakebin|ghlog".
make_case() {
  local name=$1 case_dir home bindir fakebin ghlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  bindir="$case_dir/shim-bin"
  fakebin="$case_dir/fake"
  ghlog="$case_dir/gh.log"
  mkdir -p "$home/config" "$home/state" "$bindir" "$fakebin"
  ln -s "$TEST_PEM" "$home/config/claude-foreman.pem"
  cat > "$home/config/claude-foreman.env" <<'ENV'
FM_FOREMAN_APP_ID=4034902
FM_FOREMAN_INSTALLATION_ID=139779760
ENV
  # Fake real gh: records argv and whether GH_TOKEN arrived.
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
# Mask any token that is not one of the test's known fakes so a real token
# from the invoking environment can never land in logs.
t=${GH_TOKEN:-unset}
case "$t" in unset|ghs_shimtoken456|ghs_panetoken789) ;; *) t=MASKED ;; esac
printf 'argv=%s GH_TOKEN=%s\n' "$*" "$t" >> "$FM_FAKE_GH_LOG"
SH
  chmod +x "$fakebin/gh"
  # Fake ps: FM_FAKE_PPID steers the parent chain, FM_FAKE_COMM the short
  # command name, FM_FAKE_COMMAND the full argv (defaults to FM_FAKE_COMM).
  # FM_FAKE_PPID=1 means "no interesting ancestry" (walk stops at once).
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *ppid*) printf '%s\n' "${FM_FAKE_PPID:-1}" ;;
  *command*) printf '%s\n' "${FM_FAKE_COMMAND:-${FM_FAKE_COMM:-bash}}" ;;
  *comm*) printf '%s\n' "${FM_FAKE_COMM:-bash}" ;;
esac
SH
  chmod +x "$fakebin/ps"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_FAKE_CURL_FAIL:-}" ]; then
  exit 22
fi
case "$*" in
  *access_tokens*) printf '{"token":"ghs_shimtoken456","expires_at":"2099-01-01T00:00:00Z"}' ;;
  *) exit 22 ;;
esac
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$home|$bindir|$fakebin|$ghlog"
}

read_case() {
  IFS='|' read -r HOME_DIR BIN_DIR FAKEBIN GH_LOG <<EOF
$1
EOF
}

install_shim() {
  FM_HOME="$HOME_DIR" FM_FOREMAN_SHIM_BIN_DIR="$BIN_DIR" "$SHIM" install
}

# run_wrapper <extra-env...> -- <gh args...>: invoke the installed wrapper
# with the fake tool dir on PATH (fake gh is the "real" gh it resolves; jq and
# openssl stay real, so their dirs ride along for the token helper).
JQ_DIR=$(dirname "$(command -v jq)")
OPENSSL_DIR=$(dirname "$(command -v openssl)")
run_wrapper() {
  local envs=() unsets=(-u GH_TOKEN -u GITHUB_TOKEN)
  while [ "$1" != -- ]; do
    if [ "$1" = "IFS_UNSET=1" ]; then
      unsets+=(-u IFS)
    else
      envs+=("$1")
    fi
    shift
  done
  shift
  : > "$GH_LOG"
  env "${unsets[@]}" "${envs[@]}" FM_FAKE_GH_LOG="$GH_LOG" \
    PATH="$BIN_DIR:$FAKEBIN:$JQ_DIR:$OPENSSL_DIR:/usr/bin:/bin" "$BIN_DIR/gh" "$@"
}

test_install_status_remove_lifecycle() {
  local rec out
  rec=$(make_case lifecycle)
  read_case "$rec"
  out=$(FM_HOME="$HOME_DIR" FM_FOREMAN_SHIM_BIN_DIR="$BIN_DIR" "$SHIM" status)
  assert_contains "$out" "missing $BIN_DIR/gh" "status should report missing before install"
  out=$(install_shim) || fail "install should succeed with foreman configured"
  assert_contains "$out" "installed $BIN_DIR/gh" "install should report the wrapper path"
  assert_present "$BIN_DIR/gh" "wrapper should exist after install"
  assert_grep "fm-foreman-gh-shim wrapper" "$BIN_DIR/gh" "wrapper should carry the ownership marker"
  out=$(FM_HOME="$HOME_DIR" FM_FOREMAN_SHIM_BIN_DIR="$BIN_DIR" "$SHIM" status)
  assert_contains "$out" "installed $BIN_DIR/gh" "status should report installed"
  out=$(install_shim) || fail "reinstall over our own wrapper should succeed"
  out=$(FM_HOME="$HOME_DIR" FM_FOREMAN_SHIM_BIN_DIR="$BIN_DIR" "$SHIM" remove)
  assert_contains "$out" "removed $BIN_DIR/gh" "remove should delete our wrapper"
  [ ! -e "$BIN_DIR/gh" ] || fail "wrapper should be gone after remove"
  pass "install/status/remove lifecycle works"
}

test_refuses_foreign_gh() {
  local rec out status
  rec=$(make_case foreign)
  read_case "$rec"
  printf '#!/bin/sh\necho real gh\n' > "$BIN_DIR/gh"
  chmod +x "$BIN_DIR/gh"
  out=$(install_shim 2>&1)
  status=$?
  expect_code 1 "$status" "install must refuse to overwrite a non-wrapper gh"
  assert_contains "$out" "refusing to overwrite" "install should explain the foreign-file refusal"
  out=$(FM_HOME="$HOME_DIR" FM_FOREMAN_SHIM_BIN_DIR="$BIN_DIR" "$SHIM" status)
  assert_contains "$out" "foreign $BIN_DIR/gh" "status should report a foreign gh"
  out=$(FM_HOME="$HOME_DIR" FM_FOREMAN_SHIM_BIN_DIR="$BIN_DIR" "$SHIM" remove 2>&1)
  status=$?
  expect_code 1 "$status" "remove must refuse a foreign gh"
  assert_contains "$out" "refusing to remove" "remove should explain the foreign-file refusal"
  pass "foreign gh at the wrapper path is never overwritten or removed"
}

test_install_requires_foreman_config() {
  local rec out status
  rec=$(make_case unconfigured)
  read_case "$rec"
  rm -f "$HOME_DIR/config/claude-foreman.env" "$HOME_DIR/config/claude-foreman.pem"
  out=$(install_shim 2>&1)
  status=$?
  expect_code 1 "$status" "install must refuse when foreman is not configured"
  assert_contains "$out" "not configured" "install should explain the missing config"
  pass "install refuses without foreman config"
}

test_daemon_pr_create_gets_bot_token() {
  local rec out
  rec=$(make_case interpose)
  read_case "$rec"
  install_shim >/dev/null || fail "install failed"
  run_wrapper FM_FAKE_PPID=4242 FM_FAKE_COMM=/usr/local/bin/no-mistakes -- pr create -R owner/repo --title t
  out=$(cat "$GH_LOG")
  assert_contains "$out" "argv=pr create -R owner/repo --title t" "wrapper should forward argv to the real gh"
  assert_contains "$out" "GH_TOKEN=ghs_shimtoken456" "daemon pr create should get the minted bot token"
  assert_present "$HOME_DIR/state/foreman-shim" "wrapper should keep its token cache under the home's state dir"
  pass "no-mistakes-ancestry gh pr create authenticates as the bot"
}

test_attached_repo_flag_and_unset_ifs() {
  local rec out
  rec=$(make_case attached-flag)
  read_case "$rec"
  install_shim >/dev/null || fail "install failed"
  # -Rowner/repo (attached form) must resolve the slug exactly like -R owner/repo.
  run_wrapper FM_FAKE_PPID=4242 FM_FAKE_COMM=no-mistakes -- pr create -Rowner/repo --title t
  out=$(cat "$GH_LOG")
  assert_contains "$out" "GH_TOKEN=ghs_shimtoken456" "attached -Rowner/repo form should mint the bot token"
  # An unset IFS in the caller's environment must not crash the wrapper under set -u.
  run_wrapper FM_FAKE_PPID=4242 FM_FAKE_COMM=no-mistakes IFS_UNSET=1 -- pr create -R owner/repo --title t
  out=$(cat "$GH_LOG")
  assert_contains "$out" "GH_TOKEN=ghs_shimtoken456" "wrapper must not crash or fall through when IFS is unset"
  pass "attached -R flag resolves and an unset IFS does not crash the wrapper"
}

test_non_daemon_and_non_pr_create_pass_through() {
  local rec out
  rec=$(make_case passthrough)
  read_case "$rec"
  install_shim >/dev/null || fail "install failed"
  # No no-mistakes ancestry: untouched.
  run_wrapper FM_FAKE_PPID=1 -- pr create -R owner/repo
  out=$(cat "$GH_LOG")
  assert_contains "$out" "GH_TOKEN=unset" "non-daemon pr create must pass through untouched"
  # Daemon ancestry but a different subcommand: untouched.
  run_wrapper FM_FAKE_PPID=4242 FM_FAKE_COMM=no-mistakes -- pr merge -R owner/repo
  out=$(cat "$GH_LOG")
  assert_contains "$out" "argv=pr merge -R owner/repo GH_TOKEN=unset" "non-pr-create calls must pass through untouched"
  # Preexisting GH_TOKEN (the crewmate pane path): respected, not replaced.
  run_wrapper FM_FAKE_PPID=4242 FM_FAKE_COMM=no-mistakes GH_TOKEN=ghs_panetoken789 -- pr create -R owner/repo
  out=$(cat "$GH_LOG")
  assert_contains "$out" "GH_TOKEN=ghs_panetoken789" "an explicit GH_TOKEN must win over the wrapper"
  # Preexisting GITHUB_TOKEN only: also respected, not replaced.
  run_wrapper FM_FAKE_PPID=4242 FM_FAKE_COMM=no-mistakes GITHUB_TOKEN=ghs_panetoken789 -- pr create -R owner/repo
  out=$(cat "$GH_LOG")
  assert_contains "$out" "GH_TOKEN=unset" "an explicit GITHUB_TOKEN must win over the wrapper"
  # Interpreter daemon whose comm is generic but argv shows no-mistakes: interposed.
  run_wrapper FM_FAKE_PPID=4242 FM_FAKE_COMM=node FM_FAKE_COMMAND="node /opt/no-mistakes/daemon.js" -- pr create -R owner/repo
  out=$(cat "$GH_LOG")
  assert_contains "$out" "GH_TOKEN=ghs_shimtoken456" "an argv-visible no-mistakes ancestor must interpose via the command= fallback"
  pass "everything but a daemon pr create passes through untouched"
}

test_mint_failure_and_no_slug_pass_through() {
  local rec out
  rec=$(make_case fallback)
  read_case "$rec"
  install_shim >/dev/null || fail "install failed"
  # Mint failure: fall back to the real gh untouched, never block.
  run_wrapper FM_FAKE_PPID=4242 FM_FAKE_COMM=no-mistakes FM_FAKE_CURL_FAIL=1 -- pr create -R owner/repo
  out=$(cat "$GH_LOG")
  assert_contains "$out" "GH_TOKEN=unset" "mint failure must fall back to the real gh untouched"
  # No resolvable slug (no -R flag, cwd not a git repo): untouched.
  ( cd "$TMP_ROOT" && run_wrapper FM_FAKE_PPID=4242 FM_FAKE_COMM=no-mistakes -- pr create --title t )
  out=$(cat "$GH_LOG")
  assert_contains "$out" "GH_TOKEN=unset" "an unresolvable repo slug must pass through untouched"
  pass "mint failure and missing slug fall back to the real gh"
}

test_install_status_remove_lifecycle
test_refuses_foreign_gh
test_install_requires_foreman_config
test_daemon_pr_create_gets_bot_token
test_attached_repo_flag_and_unset_ifs
test_non_daemon_and_non_pr_create_pass_through
test_mint_failure_and_no_slug_pass_through
