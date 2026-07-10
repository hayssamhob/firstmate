#!/usr/bin/env bash
# fm-foreman-token.sh - mint, cache, and serve GitHub App installation tokens
# for the "Claude Foreman" crew identity, so crewmates author commits and PRs
# as <app-slug>[bot] instead of the captain's personal account.
#
# Opt-in by config presence, exactly like other local knobs: the feature is
# active only when BOTH of these local, gitignored files exist -
#   config/claude-foreman.env   app coordinates (see docs/examples/claude-foreman.env):
#                                 FM_FOREMAN_APP_ID=<numeric GitHub App id>
#                                 FM_FOREMAN_INSTALLATION_ID=<numeric installation id>
#                                 FM_FOREMAN_APP_SLUG=<app slug>           (optional; default claude-foreman)
#                                 FM_FOREMAN_PEM=<abs path to private key> (optional; default config/claude-foreman.pem)
#   config/claude-foreman.pem   the app's RS256 private key (mode 600; NEVER
#                               committed, copied into a repo, or printed)
# Neither file present means not configured: exit 3, silent, zero behavior
# change. Exactly one present (or coordinates missing from the env file) is a
# broken half-config: warn to stderr and exit 4 so callers fall back to the
# default identity instead of blocking.
#
# Token TTL and renewal: GitHub installation tokens live 1h, and long crew
# tasks outlive that. Rather than injecting a static token, callers (the git
# credential helper and the per-task gh shim that fm-spawn wires up) call
# `token` ON DEMAND: it serves the per-task cache while the token is younger
# than FM_FOREMAN_CACHE_SECS (default 3000s, a 5+ minute safety margin under
# the 1h TTL) and transparently re-mints after that, so a task hours past its
# first push still authenticates without any daemon or background refresh.
#
# Subcommands:
#   configured                          exit 0 fully configured / 3 not configured (silent) / 4 half-configured (warns)
#   token <owner/repo> <cache-file>     print a valid installation token scoped to
#                                       <repo> (contents:write + pull_requests:write),
#                                       minting or serving the 0600 cache file
#   credential <owner/repo> <cache-file> <op>
#                                       git credential-helper protocol: `get` prints
#                                       username=x-access-token / password=<token>;
#                                       store/erase are accepted no-ops
#   bot-identity                        print two lines - the bot's git author name
#                                       ("<slug>[bot]") and noreply email; the bot
#                                       user id is fetched once and cached in
#                                       config/claude-foreman.bot
#
# The mint is the empirically verified sequence: an RS256 JWT built with
# openssl (iss=app id, ~9min exp), then POST
# /app/installations/<id>/access_tokens with a body scoped to one repository
# and {"contents":"write","pull_requests":"write"}.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

ENV_FILE="$CONFIG/claude-foreman.env"
DEFAULT_PEM="$CONFIG/claude-foreman.pem"
BOT_CACHE="$CONFIG/claude-foreman.bot"
API="${FM_FOREMAN_API_URL:-https://api.github.com}"
CACHE_SECS="${FM_FOREMAN_CACHE_SECS:-3000}"

FM_FOREMAN_APP_ID=
FM_FOREMAN_INSTALLATION_ID=
FM_FOREMAN_APP_SLUG=
FM_FOREMAN_PEM=

warn() { echo "fm-foreman-token: $*" >&2; }

# load_config: resolve activation state without side effects.
# Returns 0 configured, 3 not configured (silent), 4 half-configured (warns).
load_config() {
  local have_env=0 have_default_pem=0
  [ -f "$ENV_FILE" ] && have_env=1
  [ -f "$DEFAULT_PEM" ] && have_default_pem=1
  if [ "$have_env" -eq 0 ] && [ "$have_default_pem" -eq 0 ]; then
    return 3
  fi
  if [ "$have_env" -eq 0 ]; then
    warn "found $DEFAULT_PEM but no $ENV_FILE (need FM_FOREMAN_APP_ID and FM_FOREMAN_INSTALLATION_ID); falling back to the default GitHub identity"
    return 4
  fi
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  FM_FOREMAN_APP_SLUG=${FM_FOREMAN_APP_SLUG:-claude-foreman}
  FM_FOREMAN_PEM=${FM_FOREMAN_PEM:-$DEFAULT_PEM}
  if [ -z "${FM_FOREMAN_APP_ID:-}" ] || [ -z "${FM_FOREMAN_INSTALLATION_ID:-}" ]; then
    warn "$ENV_FILE is missing FM_FOREMAN_APP_ID or FM_FOREMAN_INSTALLATION_ID; falling back to the default GitHub identity"
    return 4
  fi
  if [ ! -f "$FM_FOREMAN_PEM" ]; then
    warn "private key not found at $FM_FOREMAN_PEM; falling back to the default GitHub identity"
    return 4
  fi
  return 0
}

require_tools() {
  local tool
  for tool in openssl curl jq; do
    command -v "$tool" >/dev/null 2>&1 || { warn "required tool '$tool' not found on PATH"; return 5; }
  done
}

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# mint <owner/repo>: print a fresh installation token scoped to that one repo.
mint() {
  local slug=$1 repo header payload signing_input sig jwt body response token
  repo=${slug#*/}
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' \
    "$(( $(date +%s) - 60 ))" "$(( $(date +%s) + 540 ))" "$FM_FOREMAN_APP_ID" | b64url)
  signing_input="$header.$payload"
  sig=$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$FM_FOREMAN_PEM" -binary | b64url)
  jwt="$signing_input.$sig"
  body=$(jq -cn --arg repo "$repo" \
    '{repositories: [$repo], permissions: {contents: "write", pull_requests: "write"}}')
  # Bounded timeouts: fm-spawn calls this synchronously at spawn time, so a
  # stalled GitHub API must degrade to the warn-and-fallback path, never hang
  # the spawn.
  response=$(curl -fsS --connect-timeout 5 --max-time 30 -X POST \
    -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    -d "$body" \
    "$API/app/installations/$FM_FOREMAN_INSTALLATION_ID/access_tokens") || {
    warn "token mint failed for $slug (installation $FM_FOREMAN_INSTALLATION_ID)"
    return 1
  }
  token=$(printf '%s' "$response" | jq -r '.token // empty')
  [ -n "$token" ] || { warn "token mint for $slug returned no token"; return 1; }
  printf '%s\n' "$token"
}

# cached_token <owner/repo> <cache-file>: serve the cache while fresh, else
# re-mint and rewrite the 0600 cache. The cache records the mint epoch rather
# than parsing GitHub's expires_at, so freshness needs no date parsing.
cached_token() {
  local slug=$1 cache=$2 now minted cached_slug token old_umask tmp
  now=$(date +%s)
  if [ -f "$cache" ]; then
    minted=$(jq -r '.minted // 0' "$cache" 2>/dev/null || echo 0)
    # A corrupted cache must degrade to a re-mint, not an arithmetic error
    # under set -e.
    case "$minted" in *[!0-9]*|'') minted=0 ;; esac
    cached_slug=$(jq -r '.repo // empty' "$cache" 2>/dev/null || true)
    token=$(jq -r '.token // empty' "$cache" 2>/dev/null || true)
    if [ -n "$token" ] && [ "$cached_slug" = "$slug" ] && [ $((now - minted)) -lt "$CACHE_SECS" ]; then
      printf '%s\n' "$token"
      return 0
    fi
  fi
  token=$(mint "$slug") || return 1
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "$(dirname "$cache")/$(basename "$cache").XXXXXX") || { umask "$old_umask"; return 1; }
  if jq -cn --arg token "$token" --arg repo "$slug" --argjson minted "$now" \
    '{token: $token, repo: $repo, minted: $minted}' > "$tmp"; then
    mv -f "$tmp" "$cache"
  else
    rm -f "$tmp"
  fi
  umask "$old_umask"
  printf '%s\n' "$token"
}

# bot_identity: print the bot's git author name and noreply email. The numeric
# bot user id (needed for GitHub to link the email to the bot account) is
# fetched from the public users API once and cached in config/. A failed fetch
# degrades to the id-less noreply address with a warning - commits still carry
# the bot name, they just may not hyperlink to the bot profile.
bot_identity() {
  local login bot_id encoded old_umask
  login="${FM_FOREMAN_APP_SLUG}[bot]"
  bot_id=$(cat "$BOT_CACHE" 2>/dev/null || true)
  case "$bot_id" in *[!0-9]*|'') bot_id= ;; esac
  if [ -z "$bot_id" ]; then
    encoded="${FM_FOREMAN_APP_SLUG}%5Bbot%5D"
    bot_id=$(curl -fsS --connect-timeout 5 --max-time 30 -H "Accept: application/vnd.github+json" "$API/users/$encoded" 2>/dev/null | jq -r '.id // empty' || true)
    case "$bot_id" in *[!0-9]*|'') bot_id= ;; esac
    if [ -n "$bot_id" ]; then
      old_umask=$(umask)
      umask 077
      printf '%s\n' "$bot_id" > "$BOT_CACHE"
      umask "$old_umask"
    fi
  fi
  printf '%s\n' "$login"
  if [ -n "$bot_id" ]; then
    printf '%s+%s@users.noreply.github.com\n' "$bot_id" "$login"
  else
    warn "could not resolve the bot user id for $login; commits will carry an unlinked noreply email"
    printf '%s@users.noreply.github.com\n' "$login"
  fi
}

validate_slug() {
  case "$1" in
    */*/*|*/|/*|'') warn "expected <owner>/<repo>, got '$1'"; return 1 ;;
    */*) return 0 ;;
    *) warn "expected <owner>/<repo>, got '$1'"; return 1 ;;
  esac
}

CMD=${1:-}
case "$CMD" in
  configured)
    load_config
    ;;
  token)
    [ $# -eq 3 ] || { warn "usage: fm-foreman-token.sh token <owner/repo> <cache-file>"; exit 2; }
    load_config
    validate_slug "$2"
    require_tools
    cached_token "$2" "$3"
    ;;
  credential)
    # git invokes the helper with the operation appended; consume stdin per the
    # credential-helper protocol either way.
    [ $# -eq 4 ] || { warn "usage: fm-foreman-token.sh credential <owner/repo> <cache-file> <get|store|erase>"; exit 2; }
    cat > /dev/null || true
    case "$4" in
      get)
        load_config
        validate_slug "$2"
        require_tools
        token=$(cached_token "$2" "$3")
        printf 'username=x-access-token\npassword=%s\n' "$token"
        ;;
      store|erase)
        exit 0
        ;;
      *)
        warn "unknown credential operation '$4'"
        exit 2
        ;;
    esac
    ;;
  bot-identity)
    load_config
    require_tools
    bot_identity
    ;;
  *)
    warn "usage: fm-foreman-token.sh configured | token <owner/repo> <cache-file> | credential <owner/repo> <cache-file> <op> | bot-identity"
    exit 2
    ;;
esac
