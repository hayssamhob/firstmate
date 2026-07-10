#!/usr/bin/env bash
# Behavior tests for bin/fm-foreman-token.sh (Claude Foreman crew identity).
#
# The helper mints per-repo GitHub App installation tokens, serves a per-task
# 0600 cache with on-demand re-mint, speaks the git credential-helper
# protocol, and resolves the bot's git author identity. Tests use a throwaway
# RSA key generated per run (never a real credential) and a fake curl that
# records the request and returns canned GitHub responses, so the real JWT
# construction and cache logic run without any network or real key.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-foreman-token.sh"
TMP_ROOT=$(fm_test_tmproot fm-foreman-token)
# fm_test_tmproot runs in a command substitution whose EXIT trap already
# removed the dir; recreate it and register cleanup in THIS shell.
mkdir -p "$TMP_ROOT"
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

if ! command -v openssl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  pass "SKIP: openssl or jq not available; foreman token tests need both"
  exit 0
fi

# Fake curl: logs every invocation's args to $FM_FAKE_CURL_LOG, honors
# FM_FAKE_CURL_FAIL, and answers by URL shape - an access_tokens POST returns a
# canned token, a /users/ GET returns a canned bot id.
make_fake_curl() {
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_CURL_LOG"
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
}

# make_case <name> [--with-env] [--with-pem]: build an isolated config dir and
# echo it. The test RSA key is generated once and symlinked in.
TEST_PEM="$TMP_ROOT/test-key.pem"
openssl genrsa -out "$TEST_PEM" 2048 2>/dev/null || fail "could not generate throwaway test key"

make_case() {
  local name=$1 with_env=0 with_pem=0 dir
  shift
  for a in "$@"; do
    case "$a" in
      --with-env) with_env=1 ;;
      --with-pem) with_pem=1 ;;
    esac
  done
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/config"
  if [ "$with_pem" -eq 1 ]; then
    ln -s "$TEST_PEM" "$dir/config/claude-foreman.pem"
  fi
  if [ "$with_env" -eq 1 ]; then
    cat > "$dir/config/claude-foreman.env" <<'ENV'
FM_FOREMAN_APP_ID=4034902
FM_FOREMAN_INSTALLATION_ID=139779760
ENV
  fi
  printf '%s\n' "$dir"
}

run_helper() {
  local dir=$1 fakebin curl_log
  shift
  fakebin=$(fm_fakebin "$dir")
  make_fake_curl "$fakebin"
  curl_log="$dir/curl.log"
  touch "$curl_log"
  FM_CONFIG_OVERRIDE="$dir/config" FM_FAKE_CURL_LOG="$curl_log" \
    PATH="$fakebin:$PATH" "$HELPER" "$@"
}

test_unconfigured_is_silent_exit_3() {
  local dir out status
  dir=$(make_case unconfigured)
  out=$(run_helper "$dir" configured 2>&1) && status=0 || status=$?
  expect_code 3 "$status" "configured with no env and no pem should exit 3"
  [ -z "$out" ] || fail "unconfigured state should be silent, got: $out"
  out=$(run_helper "$dir" token owner/repo "$dir/cache.json" 2>&1) && status=0 || status=$?
  expect_code 3 "$status" "token with no config should exit 3"
  [ -z "$out" ] || fail "token in unconfigured state should be silent, got: $out"
  assert_absent "$dir/cache.json" "no cache should be written when unconfigured"
  pass "unconfigured helper is a silent exit-3 no-op"
}

test_half_configured_warns_exit_4() {
  local dir out status
  dir=$(make_case pem-only --with-pem)
  out=$(run_helper "$dir" configured 2>&1) && status=0 || status=$?
  expect_code 4 "$status" "pem without env file should exit 4"
  assert_contains "$out" "falling back to the default GitHub identity" "pem-only state should warn about fallback"

  dir=$(make_case env-only --with-env)
  out=$(run_helper "$dir" configured 2>&1) && status=0 || status=$?
  expect_code 4 "$status" "env file without pem should exit 4"
  assert_contains "$out" "private key not found" "env-only state should name the missing key"
  pass "half-configured states warn and exit 4"
}

test_token_mints_scoped_and_caches_0600() {
  local dir out status cache curl_log perms
  dir=$(make_case mint --with-env --with-pem)
  cache="$dir/cache.json"
  out=$(run_helper "$dir" token hayssamhob/falafel "$cache" 2>&1) && status=0 || status=$?
  expect_code 0 "$status" "token mint should succeed"
  assert_contains "$out" "ghs_faketoken123" "token should print the minted token"
  curl_log="$dir/curl.log"
  assert_grep "app/installations/139779760/access_tokens" "$curl_log" "mint should POST to the installation access_tokens endpoint"
  assert_grep '"repositories":["falafel"]' "$curl_log" "mint body should scope to the bare repo name"
  assert_grep '"contents":"write"' "$curl_log" "mint body should request contents:write"
  assert_grep '"pull_requests":"write"' "$curl_log" "mint body should request pull_requests:write"
  assert_present "$cache" "mint should write the cache file"
  # GNU stat first (-c; Linux CI), BSD stat fallback (-f; macOS). The BSD form
  # must not run first: on GNU, -f means filesystem status and succeeds with
  # the wrong output instead of failing over.
  perms=$(stat -c '%a' "$cache" 2>/dev/null || stat -f '%Lp' "$cache")
  [ "$perms" = "600" ] || fail "cache file should be mode 600, got $perms"

  # Second call serves the cache: no new curl invocation.
  : > "$curl_log"
  out=$(run_helper "$dir" token hayssamhob/falafel "$cache" 2>&1) && status=0 || status=$?
  expect_code 0 "$status" "cached token call should succeed"
  assert_contains "$out" "ghs_faketoken123" "cached call should print the token"
  [ ! -s "$curl_log" ] || fail "fresh cache should be served without re-minting"
  pass "token mints a repo-scoped token and serves a 0600 cache"
}

test_stale_cache_and_repo_mismatch_remint() {
  local dir cache curl_log out
  dir=$(make_case stale --with-env --with-pem)
  cache="$dir/cache.json"
  run_helper "$dir" token owner/alpha "$cache" >/dev/null 2>&1 || fail "initial mint failed"
  curl_log="$dir/curl.log"

  # Stale: backdate the mint epoch past the cache window.
  jq -c '.minted = 1000' "$cache" > "$cache.tmp" && mv "$cache.tmp" "$cache"
  : > "$curl_log"
  out=$(run_helper "$dir" token owner/alpha "$cache" 2>&1) || fail "stale-cache re-mint failed"
  assert_grep "access_tokens" "$curl_log" "stale cache should trigger a re-mint"

  # Repo mismatch: a cache minted for another repo is never served.
  : > "$curl_log"
  out=$(run_helper "$dir" token owner/beta "$cache" 2>&1) || fail "repo-mismatch re-mint failed"
  assert_grep "access_tokens" "$curl_log" "cache for another repo should trigger a re-mint"
  pass "stale or repo-mismatched caches re-mint on demand"
}

test_credential_helper_protocol() {
  local dir cache out status
  dir=$(make_case credential --with-env --with-pem)
  cache="$dir/cache.json"
  out=$(printf 'protocol=https\nhost=github.com\n\n' | run_helper "$dir" credential owner/repo "$cache" get 2>/dev/null) && status=0 || status=$?
  expect_code 0 "$status" "credential get should succeed"
  assert_contains "$out" "username=x-access-token" "credential get should print the app username"
  assert_contains "$out" "password=ghs_faketoken123" "credential get should print the token as password"

  out=$(printf '\n' | run_helper "$dir" credential owner/repo "$cache" store 2>&1) && status=0 || status=$?
  expect_code 0 "$status" "credential store should be a silent no-op"
  [ -z "$out" ] || fail "credential store should print nothing, got: $out"
  out=$(printf '\n' | run_helper "$dir" credential owner/repo "$cache" erase 2>&1) && status=0 || status=$?
  expect_code 0 "$status" "credential erase should be a silent no-op"
  pass "credential subcommand speaks the git credential-helper protocol"
}

test_mint_failure_warns_nonzero() {
  local dir out status
  dir=$(make_case mint-fail --with-env --with-pem)
  out=$(FM_FAKE_CURL_FAIL=1 run_helper "$dir" token owner/repo "$dir/cache.json" 2>&1) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "mint failure should exit non-zero"
  assert_contains "$out" "token mint failed" "mint failure should warn to stderr"
  assert_absent "$dir/cache.json" "failed mint should not write a cache"
  pass "mint failure warns and exits non-zero without a cache"
}

test_bot_identity_resolves_and_caches_id() {
  local dir out curl_log
  dir=$(make_case bot-identity --with-env --with-pem)
  out=$(run_helper "$dir" bot-identity 2>&1) || fail "bot-identity failed"
  assert_contains "$out" "claude-foreman[bot]" "bot-identity should print the bot login"
  assert_contains "$out" "424242+claude-foreman[bot]@users.noreply.github.com" "bot-identity should print the id-linked noreply email"
  assert_grep "424242" "$dir/config/claude-foreman.bot" "bot user id should be cached in config"

  # Cached id: a second call must not hit the users API.
  curl_log="$dir/curl.log"
  : > "$curl_log"
  out=$(run_helper "$dir" bot-identity 2>&1) || fail "cached bot-identity failed"
  [ ! -s "$curl_log" ] || fail "cached bot id should be served without a users API call"
  pass "bot-identity resolves the bot login and caches the user id"
}

test_unconfigured_is_silent_exit_3
test_half_configured_warns_exit_4
test_token_mints_scoped_and_caches_0600
test_stale_cache_and_repo_mismatch_remint
test_credential_helper_protocol
test_mint_failure_warns_nonzero
test_bot_identity_resolves_and_caches_id
