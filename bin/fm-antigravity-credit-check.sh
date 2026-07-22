#!/usr/bin/env bash
# Detect antigravity (agy) credit exhaustion on a crew window, for use as a
# per-task slow poll (state/<id>.check.sh). Antigravity signals an exhausted
# account with an "AI: Out of credits" footer; this poll matches ONLY that
# verified footer (broader credit/quota phrasings are deliberately not matched
# because they appear in ordinary crew output and would cause false rotations).
# When firstmate runs an antigravity crew across a rotation pool, arm this as the
# task's check so the watcher surfaces a `check:` wake the moment the active
# account runs dry; on that wake firstmate rotates and resumes:
#     bin/fm-antigravity-rotate.sh next --relaunch <window>
#
# Usage: fm-antigravity-credit-check.sh <window>
#   <window> may be a bare firstmate task name (fm-xyz), resolved through this
#   home's state/<id>.meta, or an explicit backend target (same as fm-peek).
#
# CHECK CONTRACT (AGENTS.md section 8): prints exactly ONE line only when
# firstmate should wake (the account is out of credits), prints nothing
# otherwise, and finishes quickly.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

RAW_TARGET=${1:-}
[ -n "$RAW_TARGET" ] || { echo "usage: fm-antigravity-credit-check.sh <window>" >&2; exit 1; }
N=${FM_ANTIGRAVITY_CHECK_LINES:-60}

T=$(fm_backend_resolve_selector "$RAW_TARGET" "$STATE") || exit 0
BACKEND=$(fm_backend_of_selector "$RAW_TARGET" "$T" "$STATE") || exit 0

cap=$(fm_backend_capture "$BACKEND" "$T" "$N" 2>/dev/null || true)
[ -n "$cap" ] || exit 0

# Exhaustion signature: only the verified antigravity footer "AI: Out of credits"
# (case-insensitive). Broader credit/quota phrasings are deliberately not matched
# because they can appear in ordinary crew output (test logs, an API error being
# debugged, a comment) and would trigger a false, disruptive account rotation.
if printf '%s' "$cap" | grep -qiF 'AI: Out of credits'; then
  echo "antigravity-out-of-credits $RAW_TARGET"
fi
exit 0
