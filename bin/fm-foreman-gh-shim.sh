#!/usr/bin/env bash
# fm-foreman-gh-shim.sh - install/remove/status for the firstmate-owned gh
# wrapper that makes PRs opened by the no-mistakes pipeline author as the
# Claude Foreman bot.
#
# Why: crewmate panes carry the per-task Claude Foreman GH_TOKEN (fm-spawn.sh),
# so gh calls from the pane author as <app-slug>[bot]. But on a no-mistakes
# project the PR is opened by the no-mistakes DAEMON, which runs `gh pr create`
# from its own login-shell environment - outside the pane - so those PRs author
# as the captain's personal account. gh has no per-repo token mechanism, so the
# fix is a wrapper ahead of the real gh on the login PATH that interposes
# exactly one case:
#
#   `gh pr create` + a no-mistakes process in the caller's ancestry
#   + no explicit GH_TOKEN already set + a repo the Claude Foreman identity
#   can mint an installation token for
#
# and execs the real gh with a freshly minted GH_TOKEN for that repo. Every
# other invocation (interactive gh, other subcommands, non-foreman repos,
# mint failures) execs the real gh untouched - in particular the captain's own
# gh calls, including approving bot PRs, are never re-identified.
#
# This is a firstmate-owned global artifact like the grok turn-end hook:
# installed only on explicit request (bootstrap reports FOREMAN_DAEMON_SHIM
# lines through the normal detect -> consent -> install flow, it never
# installs by itself), clearly marked, and removal refuses anything that is
# not ours. No token value is ever printed; the private key is referenced by
# path only through bin/fm-foreman-token.sh.
#
# Subcommands:
#   install   render the wrapper to $FM_FOREMAN_SHIM_BIN_DIR/gh
#             (default ~/.local/bin/gh); refuses to overwrite a non-wrapper gh
#   remove    delete the wrapper if it is ours; refuses a foreign file
#   status    print one line: "installed <path>" / "missing <path>" /
#             "foreign <path>" (a non-wrapper gh occupies the path)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

BIN_DIR="${FM_FOREMAN_SHIM_BIN_DIR:-$HOME/.local/bin}"
TARGET="$BIN_DIR/gh"
MARKER='fm-foreman-gh-shim wrapper'

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

is_ours() {
  [ -f "$TARGET" ] && head -n 2 "$TARGET" 2>/dev/null | grep -q "$MARKER"
}

render_wrapper() {
  cat <<EOF
#!/bin/sh
# $MARKER - firstmate-owned gh interposer. DO NOT EDIT; regenerate with
# $(shell_quote "$FM_ROOT/bin/fm-foreman-gh-shim.sh") install.
#
# Interposes ONLY \`gh pr create\` invoked by a no-mistakes process (the
# daemon's pipeline opens crewmate PRs outside the pane that carries the
# Claude Foreman GH_TOKEN), for repos the Claude Foreman identity can mint an
# installation token for. Everything else execs the real gh untouched, so
# interactive gh use - including the captain approving bot PRs - keeps the
# personal identity.
set -u
FM_ROOT=$(shell_quote "$FM_ROOT")
FM_HOME=$(shell_quote "$FM_HOME")

self_dir=\$(CDPATH= cd -- "\$(dirname -- "\$0")" 2>/dev/null && pwd -P)
real_gh=
old_ifs=\$IFS; IFS=:
for d in \$PATH; do
  [ -n "\$d" ] || continue
  [ -x "\$d/gh" ] || continue
  [ "\$d" = "\$self_dir" ] && continue
  case "\$(head -n 2 "\$d/gh" 2>/dev/null)" in *"$MARKER"*) continue ;; esac
  real_gh="\$d/gh"
  break
done
IFS=\$old_ifs
if [ -z "\$real_gh" ]; then
  echo "fm-foreman-gh-shim: no real gh found on PATH" >&2
  exit 127
fi

passthrough() { exec "\$real_gh" "\$@"; }

# Interpose only \`gh pr create\`, and only when the caller has not already
# chosen a token explicitly (a crewmate pane's GH_TOKEN wins, per gh semantics).
{ [ "\${1:-}" = pr ] && [ "\${2:-}" = create ]; } || passthrough "\$@"
{ [ -z "\${GH_TOKEN:-}" ] && [ -z "\${GITHUB_TOKEN:-}" ]; } || passthrough "\$@"

# Gate on a no-mistakes process in the ancestry so nothing else is ever
# re-identified. Bounded walk; any ps failure falls through to passthrough.
pid=\$\$ hops=0 nm_ancestor=
while [ "\$hops" -lt 40 ]; do
  pid=\$(ps -o ppid= -p "\$pid" 2>/dev/null | tr -d ' ') || break
  case "\$pid" in ''|*[!0-9]*) break ;; esac
  [ "\$pid" -gt 1 ] || break
  case "\$(ps -o comm= -p "\$pid" 2>/dev/null)" in
    *no-mistakes*) nm_ancestor=1; break ;;
    *)
      case "\$(ps -o command= -p "\$pid" 2>/dev/null)" in
        *no-mistakes*) nm_ancestor=1; break ;;
      esac
      ;;
  esac
  hops=\$((hops + 1))
done
[ -n "\$nm_ancestor" ] || passthrough "\$@"

# Repo slug: an explicit -R/--repo flag wins; else the cwd repo's origin.
slug=
prev=
for a in "\$@"; do
  if [ "\$prev" = repo ]; then slug=\$a; prev=; continue; fi
  case "\$a" in
    -R|--repo) prev=repo ;;
    --repo=*) slug=\${a#--repo=} ;;
  esac
done
if [ -z "\$slug" ]; then
  origin=\$(git remote get-url origin 2>/dev/null || true)
  case "\$origin" in
    git@github.com:*) slug=\${origin#git@github.com:} ;;
    ssh://git@github.com/*) slug=\${origin#ssh://git@github.com/} ;;
    https://github.com/*) slug=\${origin#https://github.com/} ;;
    http://github.com/*) slug=\${origin#http://github.com/} ;;
    *) slug= ;;
  esac
fi
case "\$slug" in *github.com/*) slug=\${slug#*github.com/} ;; esac
slug=\${slug%/}
slug=\${slug%.git}
case "\$slug" in
  */*/*|*/|/*|'') passthrough "\$@" ;;
  */*) ;;
  *) passthrough "\$@" ;;
esac

env -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="\$FM_HOME" \\
  "\$FM_ROOT/bin/fm-foreman-token.sh" configured >/dev/null 2>&1 || passthrough "\$@"

cache_dir="\$FM_HOME/state/foreman-shim"
mkdir -p "\$cache_dir" 2>/dev/null && chmod 700 "\$cache_dir" 2>/dev/null || passthrough "\$@"
cache="\$cache_dir/\$(printf '%s' "\$slug" | tr '/' '_').json"
t=\$(env -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="\$FM_HOME" \\
  "\$FM_ROOT/bin/fm-foreman-token.sh" token "\$slug" "\$cache" 2>/dev/null) || t=
[ -n "\$t" ] || passthrough "\$@"
GH_TOKEN="\$t" GITHUB_TOKEN="\$t" exec "\$real_gh" "\$@"
EOF
}

case "${1:-}" in
  install)
    if [ -e "$TARGET" ] && ! is_ours; then
      echo "error: $TARGET exists and is not the firstmate wrapper; refusing to overwrite" >&2
      exit 1
    fi
    if ! "$FM_ROOT/bin/fm-foreman-token.sh" configured; then
      echo "error: Claude Foreman is not configured (config/claude-foreman.env + config/claude-foreman.pem); nothing to install" >&2
      exit 1
    fi
    mkdir -p "$BIN_DIR"
    tmp=$(mktemp "$BIN_DIR/.gh-shim.XXXXXX")
    render_wrapper > "$tmp"
    chmod 755 "$tmp"
    mv -f "$tmp" "$TARGET"
    echo "installed $TARGET (interposes 'gh pr create' from no-mistakes processes for Claude Foreman repos)"
    ;;
  remove)
    if [ ! -e "$TARGET" ]; then
      echo "nothing installed at $TARGET"
    elif is_ours; then
      rm -f "$TARGET"
      echo "removed $TARGET"
    else
      echo "error: $TARGET is not the firstmate wrapper; refusing to remove" >&2
      exit 1
    fi
    ;;
  status)
    if [ ! -e "$TARGET" ]; then
      echo "missing $TARGET"
    elif is_ours; then
      echo "installed $TARGET"
    else
      echo "foreign $TARGET"
    fi
    ;;
  *)
    echo "usage: fm-foreman-gh-shim.sh install | remove | status" >&2
    exit 2
    ;;
esac
