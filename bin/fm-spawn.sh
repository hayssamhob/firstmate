#!/usr/bin/env bash
# Spawn a direct report: a crewmate in a treehouse worktree, or a secondmate in
# its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] [--scout]
#        fm-spawn.sh <task-id> [<firstmate-home>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] --secondmate
#   --harness <name> is the explicit per-spawn harness/profile adapter. The old
#   positional harness arg still works for back-compat.
#   --model <name> and --effort <low|medium|high|xhigh|max> are concrete profile
#   axes chosen by firstmate at intake. They are only threaded into harnesses whose
#   installed CLIs were verified to support that axis; unsupported axes are omitted
#   from that harness's launch rather than guessed.
#   --backend <name> is the explicit runtime session-provider backend for this
#   spawn. Without it, the script resolves FM_BACKEND, then config/backend, then
#   runtime auto-detection (the runtime firstmate itself is executing inside -
#   $TMUX or HERDR_ENV=1; bin/fm-backend.sh's fm_backend_detect), then tmux.
#   Known backends are the reference tmux adapter and experimental herdr. An
#   auto-detected herdr spawn prints a loud stderr notice; auto-detected tmux
#   stays silent. Default tmux spawns do not write backend= to meta; absent
#   backend= means tmux.
#   With no harness arg, a crewmate/scout spawn resolves the CREW harness only when
#   config/crew-dispatch.json is absent. When that file exists, crewmate/scout
#   spawns require an explicit harness so firstmate cannot silently skip dispatch
#   profile consultation. A --secondmate spawn is exempt and resolves the SECONDMATE
#   harness (config/secondmate-harness -> config/crew-harness -> own), so the
#   secondmate-vs-crewmate split is DURABLE across every respawn (recovery,
#   /updatefirstmate, restart). A bare adapter name (claude|codex|opencode|pi|grok|devin)
#   overrides it for this spawn (either kind). A non-flag string containing
#   whitespace is treated as a RAW launch command - the escape hatch for verifying
#   new adapters.
#   config/secondmate-harness may also carry an optional model and effort as extra
#   whitespace-separated tokens ("<harness> [<model>] [<effort>]"). For a
#   --secondmate spawn, those tokens apply only when this spawn also resolves its
#   harness from config/secondmate-harness. An explicit per-spawn --harness,
#   positional harness arg, or raw launch command starts with clean model/effort
#   defaults unless the caller also passes explicit --model/--effort flags. When
#   the file governs the spawn, its model/effort tokens are re-resolved on every
#   respawn exactly like the harness axis, and explicit --model/--effort flags
#   still win over the file's tokens.
#   A --secondmate spawn also propagates the primary's declared inheritable config
#   into the secondmate home's config/, so the secondmate's OWN crewmates,
#   dispatch profiles, and backlog backend inherit the primary's settings
#   (fm-config-inherit-lib.sh).
#   --scout records kind=scout in the task's meta (report deliverable, scratch worktree;
#   see AGENTS.md task lifecycle); --secondmate records kind=secondmate and launches in a
#   provisioned firstmate home; the default is kind=ship.
#   Before a secondmate launch, the home is locally fast-forwarded to the primary
#   default-branch commit when safe; skipped syncs warn and launch unchanged.
#   Ship/scout spawns refuse to launch after treehouse get unless the resolved pane
#   path is a real git worktree root distinct from the primary project checkout.
# Batch dispatch: pass one or more `id=repo` pairs instead of a single <id> <project>, e.g.
#     fm-spawn.sh fix-a-k3=projects/foo add-b-q7=projects/bar [--scout]
#   Each pair re-execs this script in single-task mode, so the single path stays the only
#   source of truth; shared --scout/--harness/--model/--effort/--backend applies to every pair.
#   If config/crew-dispatch.json exists, shared --harness is required for crewmate
#   and scout batches. The loop lives here, in bash, so callers never hand-write a
#   multi-task shell loop (the tool shell is zsh, which does not word-split unquoted
#   $vars and silently breaks ad-hoc `for ... in $pairs` loops).
#   Launch templates live in launch_template() below; placeholders replaced before launch:
#     __BRIEF__    absolute path to data/<task-id>/brief.md
#     __TURNEND__  absolute path to state/<task-id>.turn-ended (for harnesses whose
#                  turn-end signal rides the launch command, e.g. codex -c notify=[...])
#     __PIEXT__    absolute path to state/<task-id>.pi-ext.ts (pi turn-end extension,
#                  written by this script; outside the worktree to avoid pi's trust gate)
# Per-harness turn-end hooks are installed automatically; some live outside the worktree.
# grok uses a firstmate-owned global hook under ${GROK_HOME:-$HOME/.grok}/hooks
# plus a gitignored .fm-grok-turnend worktree pointer and a state token.
# On success prints: spawned <id> harness=<name> kind=<ship|scout|secondmate> mode=<mode> yolo=<on|off> window=<backend-target> worktree=<path>
# mode/yolo are resolved per-project from data/projects.md for ship/scout tasks;
# secondmate spawns record mode=secondmate, yolo=off, home=, and projects=.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/fm-guard.sh" || true
KIND=ship
HARNESS_ARG=
MODEL=
EFFORT=
BACKEND_ARG=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
BACKEND_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      harness) HARNESS_ARG=$a; HARNESS_SET=1 ;;
      model) MODEL=$a; MODEL_SET=1 ;;
      effort) EFFORT=$a; EFFORT_SET=1 ;;
      backend) BACKEND_ARG=$a; BACKEND_SET=1 ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --harness) want_value=harness ;;
    --harness=*) HARNESS_ARG=${a#--harness=}; HARNESS_SET=1 ;;
    --model) want_value=model ;;
    --model=*) MODEL=${a#--model=}; MODEL_SET=1 ;;
    --effort) want_value=effort ;;
    --effort=*) EFFORT=${a#--effort=}; EFFORT_SET=1 ;;
    --backend) want_value=backend ;;
    --backend=*) BACKEND_ARG=${a#--backend=}; BACKEND_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "$HARNESS_SET" -eq 0 ] || [ -n "$HARNESS_ARG" ] || { echo "error: --harness requires a non-empty value" >&2; exit 1; }
[ "$MODEL_SET" -eq 0 ] || [ -n "$MODEL" ] || { echo "error: --model requires a non-empty value" >&2; exit 1; }
[ "$EFFORT_SET" -eq 0 ] || [ -n "$EFFORT" ] || { echo "error: --effort requires a non-empty value" >&2; exit 1; }
[ "$BACKEND_SET" -eq 0 ] || [ -n "$BACKEND_ARG" ] || { echo "error: --backend requires a non-empty value" >&2; exit 1; }
case "$EFFORT" in
  ''|low|medium|high|xhigh|max) ;;
  *) echo "error: --effort must be one of low, medium, high, xhigh, max" >&2; exit 1 ;;
esac

# Backend selection (data/fm-backend-design-d7): explicit --backend, else
# FM_BACKEND env, else config/backend, else runtime auto-detection, else
# default tmux (fm_backend_name). fm_backend_validate refuses anything not
# implemented. The resolved value is recorded in meta only when it is NOT tmux
# (fm-teardown.sh and fm-watch.sh's
# window_backend/fm_backend_of_meta already treat an absent backend= as tmux),
# so the default path's meta stays byte-identical.
if [ "$BACKEND_SET" -eq 1 ]; then
  BACKEND=$BACKEND_ARG
else
  BACKEND=$(fm_backend_name)
fi
fm_backend_validate "$BACKEND" || exit 1
fm_backend_source "$BACKEND" || exit 1

# Batch dispatch (see header): when the first positional is an `id=repo` pair, treat every
# positional as one and spawn each by re-execing this script in single-task mode. We use
# the FM_ROOT path (not $0) so it works whatever cwd or relative path invoked us, and reuse
# the single path verbatim. A failed pair is reported and skipped; the rest still launch;
# exit is non-zero if any pair failed. Single-task invocations never carry an '=' in arg
# one (task ids are bare slugs), so they fall straight through to the logic below.
idpart=${POS[0]:-}
idpart=${idpart%%=*}
if [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ] && case "$idpart" in */*) false ;; *) true ;; esac; then
  if [ "$KIND" != secondmate ] && [ -z "$HARNESS_ARG" ] && [ -f "$CONFIG/crew-dispatch.json" ]; then
    echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
    exit 1
  fi
  rc=0
  shared_args=()
  [ -z "$HARNESS_ARG" ] || shared_args+=(--harness "$HARNESS_ARG")
  [ -z "$MODEL" ] || shared_args+=(--model "$MODEL")
  [ -z "$EFFORT" ] || shared_args+=(--effort "$EFFORT")
  [ -z "$BACKEND_ARG" ] || shared_args+=(--backend "$BACKEND_ARG")
  for pair in "${POS[@]}"; do
    case "$pair" in
      *=*) : ;;
      *) echo "error: batch dispatch expects every argument as id=repo; got '$pair'" >&2; rc=2; continue ;;
    esac
    if [ "$KIND" = secondmate ]; then
      echo "error: batch dispatch does not support --secondmate; spawn each secondmate explicitly" >&2
      rc=2
      continue
    elif [ "$KIND" = scout ]; then
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" ${shared_args[@]+"${shared_args[@]}"} --scout; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    else
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" ${shared_args[@]+"${shared_args[@]}"}; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    fi
  done
  exit "$rc"
fi
ID=${POS[0]}
PROJ=
ARG3=
FIRSTMATE_HOME=

if [ "$KIND" = secondmate ]; then
  case "${POS[1]:-}" in
    ''|claude|codex|opencode|pi|grok|devin)
      ARG3=${POS[1]:-}
      ;;
    *' '*)
      if [ "${#POS[@]}" -gt 2 ] || [ -d "${POS[1]}" ]; then
        FIRSTMATE_HOME=${POS[1]}
        ARG3=${POS[2]:-}
      else
        ARG3=${POS[1]}
      fi
      ;;
    *)
      FIRSTMATE_HOME=${POS[1]}
      ARG3=${POS[2]:-}
      ;;
  esac
else
  PROJ=${POS[1]}
  ARG3=${POS[2]:-}
fi
[ -z "$HARNESS_ARG" ] || ARG3=$HARNESS_ARG

# The verified launch command per adapter. The knowledge half of each adapter
# (busy signature, exit command, dialogs, quirks) lives in the harness-adapters skill.
launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$harness" in
    # CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false disables claude's interactive
    # predicted-next-prompt ghost text, which renders as dim/faint text inside an
    # otherwise-empty composer and would otherwise read like real typed input when
    # firstmate captures the pane (see the harness-adapters skill). It is a per-launch env
    # prefix scoped to this firstmate-launched agent; it never touches the captain's
    # global config. The CLI's --prompt-suggestions flag is print/SDK-mode only and
    # does NOT suppress the interactive ghost text (verified empirically), so the env
    # var is the correct control. The dim-aware composer reader in fm-tmux-lib.sh is
    # the defense-in-depth backstop for any pane this flag cannot reach.
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(cat __BRIEF__)"'
      else
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(cat __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(cat __BRIEF__)"' ;;
    pi)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"'
      else
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(cat __BRIEF__)"'
      fi
      ;;
    # grok (Grok Build TUI): a positional prompt starts the supervised interactive
    # session. --always-approve auto-approves every tool execution (verified: the
    # crewmate runs fully autonomously, no permission gate), which an unattended
    # crewmate needs; it is the targeted equivalent of claude's
    # --dangerously-skip-permissions. grok's turn-end signal does NOT ride the
    # launch command - it is a Stop-event hook installed below (global hook +
    # per-task pointer), so the template is identical for ship/scout/secondmate.
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    # devin: --prompt-file loads the brief non-interactively as the initial
    # prompt; --permission-mode dangerous auto-approves every tool (the devin
    # equivalent of claude's --dangerously-skip-permissions). The turn-end
    # signal rides a Stop hook in .devin/hooks.v1.json (Claude Code hook format,
    # which devin reads natively), wired below - not via the launch command, so
    # the same template serves ship, scout, and secondmate spawns.
    devin) printf '%s' 'devin --prompt-file __BRIEF__ __MODELFLAG__--permission-mode dangerous' ;;
    *) return 1 ;;
  esac
}

case "$ARG3" in
  *' '*)  # raw launch command (unverified-adapter escape hatch)
    LAUNCH=$ARG3
    HARNESS=""
    for word in $LAUNCH; do
      case "$word" in [A-Za-z_]*=*) continue ;; *) HARNESS=$(basename "$word"); break ;; esac
    done
    ;;
  '')
    # No explicit harness: resolve from config. A secondmate AGENT launches on the
    # secondmate harness (config/secondmate-harness -> config/crew-harness -> own);
    # every other kind uses the crew harness only when no dispatch profile file is
    # active. Resolving here on every spawn is what makes the split DURABLE - a
    # respawn (recovery, /updatefirstmate, restart) re-resolves, so
    # config/secondmate-harness keeps governing secondmate launches across restarts.
    # The launch_template lookup below is the unverified-adapter guard for both
    # kinds: a harness with no template aborts the spawn.
    if [ "$KIND" = secondmate ]; then
      HARNESS=$("$FM_ROOT/bin/fm-harness.sh" secondmate)
      harness_src='config/secondmate-harness (falling back to config/crew-harness)'
    else
      if [ -f "$CONFIG/crew-dispatch.json" ]; then
        echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
        exit 1
      fi
      HARNESS=$("$FM_ROOT/bin/fm-harness.sh" crew)
      harness_src='config/crew-harness'
    fi
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: no launch template for harness '$HARNESS' (from $harness_src or detection); pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
  *)
    HARNESS=$ARG3
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: unknown harness '$HARNESS'; pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
esac

# config/secondmate-harness may carry optional model/effort tokens alongside the
# harness ("<harness> [<model>] [<effort>]"). They apply only when this is a
# --secondmate spawn and no explicit per-spawn harness/raw launch was supplied, so
# the harness itself came from the secondmate config fallback chain. Resolving
# here on every spawn makes the pin durable across respawns. Precedence: explicit
# --model/--effort flags still win over the file's tokens.
if [ "$KIND" = secondmate ] && [ -z "$ARG3" ]; then
  if [ "$MODEL_SET" -eq 0 ]; then
    SM_MODEL=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model)
    [ -z "$SM_MODEL" ] || MODEL=$SM_MODEL
  fi
  if [ "$EFFORT_SET" -eq 0 ]; then
    SM_EFFORT=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort)
    if [ -n "$SM_EFFORT" ]; then
      case "$SM_EFFORT" in
        low|medium|high|xhigh|max) EFFORT=$SM_EFFORT ;;
        *) echo "warning: config/secondmate-harness effort token '$SM_EFFORT' is not one of low, medium, high, xhigh, max; ignoring" >&2 ;;
      esac
    fi
  fi
fi

secondmate_registry_value() {
  local id=$1 key=$2 reg line value
  reg="$DATA/secondmates.md"
  [ -f "$reg" ] || return 1
  line=$(grep -E "^- $id( |$)" "$reg" | tail -1 || true)
  [ -n "$line" ] || return 1
  case "$key" in
    home) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p') ;;
    projects) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: [^;)]*; scope: [^;)]*; projects: \([^;)]*\); added .*/\1/p') ;;
    *) return 1 ;;
  esac
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

model_flag_for_harness() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|grok|devin)
      printf -- '--model %s ' "$(shell_quote "$model")"
      ;;
  esac
}

effort_flag_for_harness() {
  local harness=$1 effort=$2
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$harness" in
    claude)
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    codex)
      # The installed codex config schema uses model_reasoning_effort, and the
      # bundled model catalog advertises low|medium|high|xhigh. Omit max rather
      # than passing an unsupported value.
      case "$effort" in
        low|medium|high|xhigh) printf -- '-c %s ' "$(shell_quote "model_reasoning_effort=\"$effort\"")" ;;
      esac
      ;;
    grok)
      # grok exposes both --effort and --reasoning-effort; firstmate's profile
      # axis is the reasoning knob, and --reasoning-effort rejects max, so pass
      # only its accepted shared vocabulary subset.
      case "$effort" in
        low|medium|high|xhigh) printf -- '--reasoning-effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    pi)
      # pi accepts --thinking low|medium|high|xhigh. It warns and ignores max, so
      # omit max rather than passing a flag the installed CLI will reject as invalid.
      case "$effort" in
        low|medium|high|xhigh) printf -- '--thinking %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    # opencode's interactive `opencode --prompt` launch has a verified --model
    # flag but no verified effort flag. Its `opencode run --variant` flag belongs
    # to a different, non-interactive launch mode, so fm-spawn does not pass it.
  esac
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: firstmate home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

resolve_project_dir_arg() {
  local path=$1
  case "$path" in
    projects/*) printf '%s/%s\n' "$PROJECTS" "${path#projects/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

validate_firstmate_home_for_spawn() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_firstmate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_firstmate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

if [ "$KIND" = secondmate ]; then
  if [ -z "$FIRSTMATE_HOME" ] && [ -f "$STATE/$ID.meta" ]; then
    FIRSTMATE_HOME=$(grep '^home=' "$STATE/$ID.meta" | cut -d= -f2- || true)
  fi
  if [ -z "$FIRSTMATE_HOME" ]; then
    FIRSTMATE_HOME=$(secondmate_registry_value "$ID" home || true)
  fi
fi

if [ "$KIND" = secondmate ]; then
  [ -n "$FIRSTMATE_HOME" ] || { echo "error: no firstmate home supplied or registered for $ID" >&2; exit 1; }
  PROJ_ABS=$(validate_firstmate_home_for_spawn "$ID" "$FIRSTMATE_HOME")
  WT="$PROJ_ABS"
  # Local-HEAD sync: before launch, fast-forward this secondmate's worktree to the
  # PRIMARY checkout's current default-branch commit, so a freshly spawned or
  # recovery-respawned secondmate always runs the primary's version (AGENTS.md
  # spawn section). Purely local - no fetch: the home is a worktree of this same
  # repo and already holds the commit. ff-only and guarded; a dirty, diverged, or
  # wrong-branch home is left untouched and launches as-is. The agent re-reads
  # AGENTS.md fresh on launch, so no nudge is needed here.
  if sm_primary_head=$(primary_head_commit "$FM_ROOT"); then
    sm_ff_out=$(ff_target "$PROJ_ABS" "secondmate $ID" "$sm_primary_head" yes yes 2>&1 || true)
    case "$sm_ff_out" in
      *': skipped:'*)
        sm_ff_line=$(first_line "$sm_ff_out")
        sm_ff_prefix="secondmate $ID: skipped: "
        sm_ff_reason=${sm_ff_line#"$sm_ff_prefix"}
        echo "warning: secondmate $ID sync skipped before launch: $sm_ff_reason" >&2
        ;;
    esac
  else
    echo "warning: secondmate $ID sync skipped before launch: primary default-branch commit cannot be resolved" >&2
  fi
  # Inheritable-config propagation: push the primary's declared LOCAL config into
  # this secondmate home's config/, so the secondmate's OWN crewmates and backlog
  # backend inherit the primary's settings. config/ is gitignored, so this is a
  # separate copy from the local-HEAD fast-forward above;
  # primary-authoritative and re-pushed on every convergence. config/secondmate-harness
  # is the primary's own knob and is deliberately NOT in the inheritable set
  # (fm-config-inherit-lib.sh). A primary with no inheritable config set is a no-op.
  propagate_inheritable_config "$CONFIG" "$PROJ_ABS/config" \
    || echo "warning: secondmate $ID config inheritance failed for $PROJ_ABS/config" >&2
  if [ -f "$PROJ_ABS/data/charter.md" ]; then
    BRIEF="$PROJ_ABS/data/charter.md"
  else
    BRIEF="$DATA/$ID/brief.md"
  fi
else
  PROJ_ABS="$(cd "$(resolve_project_dir_arg "$PROJ")" && pwd)"
  WT=""
  BRIEF="$DATA/$ID/brief.md"
fi
[ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }

# Session-provider container-ensure + task creation. tmux stays exactly as P1
# left it (same session-name / new-window sequence, see bin/backends/tmux.sh);
# a herdr spawn goes through the version-gated, workspace-per-firstmate,
# tab-per-task sequence in bin/backends/herdr.sh instead (D4/D5;
# data/fm-backend-design-d7/herdr-addendum.md). Both branches converge on the
# same $T ("target") string that every downstream operation (send/capture/kill)
# already treats as opaque per-backend routing (fm_backend_resolve_selector).
W="fm-$ID"
case "$BACKEND" in
  tmux)
    SES=$(fm_backend_tmux_container_ensure)
    T="$SES:$W"
    fm_backend_tmux_create_task "$SES" "$W" "$PROJ_ABS" || exit 1
    ;;
  herdr)
    CONTAINER=$(fm_backend_herdr_container_ensure "$PROJ_ABS") || exit 1
    HERDR_SES=${CONTAINER%%:*}
    HERDR_WORKSPACE_ID=${CONTAINER#*:}
    HERDR_TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "$W" "$PROJ_ABS") || exit 1
    read -r HERDR_TAB_ID HERDR_PANE_ID <<EOF
$HERDR_TASK_IDS
EOF
    if [ -z "$HERDR_TAB_ID" ] || [ -z "$HERDR_PANE_ID" ]; then
      echo "error: herdr did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$HERDR_SES:$HERDR_PANE_ID"
    ;;
esac
spawn_send_text_line() {  # <target> <text>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_text_line "$1" "$2" ;;
    herdr) fm_backend_herdr_send_text_line "$1" "$2" ;;
  esac
}
spawn_current_path() {  # <target>
  case "$BACKEND" in
    tmux) fm_backend_tmux_current_path "$1" ;;
    herdr) fm_backend_herdr_current_path "$1" ;;
  esac
}
spawn_send_literal() {  # <target> <text>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_literal "$1" "$2" ;;
    herdr) fm_backend_herdr_send_literal "$1" "$2" ;;
  esac
}
spawn_send_key() {  # <target> <key>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_key "$1" "$2" ;;
    herdr) fm_backend_herdr_send_key "$1" "$2" ;;
  esac
}
# Defense in depth for the Claude Foreman crew identity (the 2026-07-12 incident:
# a devin crewmate self-merged a PR attributed to the captain's own account).
# After the pane sources the injected env, confirm that gh IN THAT pane shell -
# the same shell the agent and its exec/gh calls will use - actually resolves to
# the bot, not a personal fallback account. In the incident the injected env did
# not reach the merging shell, so gh fell through to the captain's keyring login.
# The merge-deny PreToolUse hook is the primary guard, but it is a single
# devin-internal layer that can silently stop firing (and devin's
# --permission-mode dangerous overrides devin's own declarative permissions.deny),
# so this independent check turns a silent injection failure into a loud,
# firstmate-detectable signal recorded in meta (foreman_verify=) instead of
# relying on the hook alone. It NEVER blocks the spawn (Foreman's contract).
# Disable with FM_FOREMAN_VERIFY=0 for panes that cannot execute a probe command;
# FM_FOREMAN_VERIFY_TIMEOUT overrides the completion wait (default 15s).
fm_foreman_verify_identity() {  # <target> <foreman_tmp> <bot_name> <meta_file> <id>
  [ "${FM_FOREMAN_VERIFY:-1}" != 0 ] || return 0
  fv_target=$1; fv_ftmp=$2; fv_bot=$3; fv_meta=$4; fv_task=$5
  fv_authcheck="$fv_ftmp/authcheck.txt"
  rm -f "$fv_authcheck"
  # Run gh auth status in the pane with the just-sourced Foreman env. Output goes
  # to a 0700 temp file (gh auth status can print the token, so never scrollback),
  # followed by a sentinel line so we can tell it finished.
  spawn_send_text_line "$fv_target" "{ gh auth status; } > $(shell_quote "$fv_authcheck") 2>&1; printf 'FM_AUTHCHECK_DONE\n' >> $(shell_quote "$fv_authcheck")"
  fv_limit=${FM_FOREMAN_VERIFY_TIMEOUT:-15}
  fv_waited=0
  while :; do
    [ -f "$fv_authcheck" ] && grep -q FM_AUTHCHECK_DONE "$fv_authcheck" 2>/dev/null && break
    fv_waited=$((fv_waited + 1))
    [ "$fv_waited" -ge $((fv_limit * 4)) ] && break
    sleep 0.25
  done
  if ! { [ -f "$fv_authcheck" ] && grep -q FM_AUTHCHECK_DONE "$fv_authcheck" 2>/dev/null; }; then
    printf 'foreman_verify=unknown\n' >> "$fv_meta"
    echo "warning: could not confirm the Claude Foreman identity in the pane for $fv_task (gh auth status did not complete in ${fv_limit}s); the crewmate's GitHub identity is unverified" >&2
    return 0
  fi
  # gh prints each credential's source in parentheses: (GH_TOKEN) for the injected
  # env token, (keyring)/(oauth_token) for a personal login. gh always forces an
  # env token to be the ACTIVE account whenever GH_TOKEN is set, so the presence of
  # a (GH_TOKEN) block - Failed OR Logged-in - is the authoritative signal that the
  # injected Foreman credential took effect; the 'Active account: true' marker only
  # corroborates it, and older/single-block gh renderings may omit that marker
  # entirely, so keying off the marker alone would degrade the happy path to
  # 'unknown'. A GitHub App INSTALLATION token - what the Foreman env injects -
  # cannot resolve a login through gh's viewer API, so gh renders the injected block
  # as 'Failed to log in ... using token (GH_TOKEN)' with no login; that is still
  # the bot token by construction, not a personal fallthrough. So: a (GH_TOKEN)
  # block whose login is the bot -> ok, any other resolved login -> mismatch, an
  # unresolvable login -> ok (bot by construction). Only when NO (GH_TOKEN) block
  # exists - the injection did not take effect - do we fall back to the active
  # account's resolved login to catch the personal fallthrough.
  # One field per line (a resolved login never contains a newline) so empty
  # fields - an unresolvable installation token has no login - survive parsing.
  fv_parsed=$(awk '
    /Logged in to github\.com account/ {
      login=$0; sub(/.*account[ \t]+/, "", login); sub(/[ \t]+\(.*/, "", login)
      src=$0; sub(/^[^(]*\(/, "", src); sub(/\).*/, "", src)
      cur_login=login; cur_have=1
      if (src == "GH_TOKEN") { tok_login=login; tok_seen=1 }
      next
    }
    /Failed to log in to github\.com using token/ {
      src=$0; sub(/^[^(]*\(/, "", src); sub(/\).*/, "", src)
      cur_login=""; cur_have=1
      if (src == "GH_TOKEN") { tok_login=""; tok_seen=1 }
      next
    }
    /Active account: true/ {
      if (cur_have) { active_login=cur_login; saw_active=1 }
    }
    END { printf "%d\n%s\n%d\n%s\n.\n", tok_seen, tok_login, saw_active, active_login }
  ' "$fv_authcheck" 2>/dev/null || :)
  # This whole function runs under the script's global `set -eu`, but it must
  # NEVER abort the spawn (Foreman's contract) - a defense-in-depth check that
  # can itself kill the spawn is worse than no check. So the awk substitution is
  # guarded with `|| :` (a missing/failing awk, or an unreadable authcheck,
  # yields an empty parse instead of a non-zero status that set -e would exit on)
  # and each read below with `|| :` (an empty/short parse hits EOF, which read
  # returns non-zero for). An empty parse leaves every field empty, so the logic
  # below falls through to foreman_verify=unknown + a warning - exactly the
  # intended degrade. Pre-seed the fields so set -u never trips on an unset one.
  fv_tok_seen=; fv_tok_login=; fv_saw_active=; fv_active=
  # The trailing sentinel line keeps the four field lines intact even when the
  # last field (a login) is empty and command substitution strips trailing blanks.
  {
    IFS= read -r fv_tok_seen || :
    IFS= read -r fv_tok_login || :
    IFS= read -r fv_saw_active || :
    IFS= read -r fv_active || :
  } <<EOF
$fv_parsed
EOF
  if [ "$fv_tok_seen" = 1 ]; then
    if [ -n "$fv_tok_login" ] && [ "$fv_tok_login" != "$fv_bot" ]; then
      printf 'foreman_verify=mismatch:%s\n' "$fv_tok_login" >> "$fv_meta"
      echo "WARNING: Claude Foreman identity is NOT active in the pane for $fv_task: gh resolves the injected token to '$fv_tok_login', not the bot '$fv_bot'. GitHub actions by this crewmate would be attributed to that account - the 2026-07-12 failure mode where a crewmate self-merged a PR as the captain. The injected identity did not take effect; do not trust this crewmate with push/PR/merge work until it is fixed." >&2
    else
      printf 'foreman_verify=ok\n' >> "$fv_meta"
    fi
  elif [ "$fv_saw_active" = 1 ] && [ -n "$fv_active" ]; then
    if [ "$fv_active" = "$fv_bot" ]; then
      printf 'foreman_verify=ok\n' >> "$fv_meta"
    else
      printf 'foreman_verify=mismatch:%s\n' "$fv_active" >> "$fv_meta"
      echo "WARNING: Claude Foreman identity is NOT active in the pane for $fv_task: gh resolves to '$fv_active', not the bot '$fv_bot'. GitHub actions by this crewmate would be attributed to that account - the 2026-07-12 failure mode where a crewmate self-merged a PR as the captain. The injected identity did not take effect; do not trust this crewmate with push/PR/merge work until it is fixed." >&2
    fi
  else
    printf 'foreman_verify=unknown\n' >> "$fv_meta"
    echo "warning: could not determine the active gh account in the pane for $fv_task; the crewmate's Claude Foreman identity is unverified" >&2
  fi
  return 0
}
if [ "$KIND" != secondmate ]; then
  spawn_send_text_line "$T" 'treehouse get'

  # Wait for the treehouse subshell: the pane's cwd moves from the project to the worktree.
  for _ in $(seq 1 60); do
    p=$(spawn_current_path "$T" || true)
    if [ -n "$p" ] && [ "$p" != "$PROJ_ABS" ]; then
      WT="$p"
      break
    fi
    sleep 1
  done
  if [ -z "$WT" ]; then
    echo "error: treehouse get did not enter a worktree within 60s; inspect window $T" >&2
    exit 1
  fi

  # Isolation guard: refuse to launch unless WT is a genuine, ISOLATED worktree -
  # a real git worktree root, distinct from the project's primary checkout
  # (PROJ_ABS). Firstmate is a treehouse-pooled repo of itself, so a treehouse-get
  # misfire can leave the pane in (or in a subdir of, or a symlink to) the primary
  # checkout; branching/committing there would tangle the primary onto a feature
  # branch (see fm-tangle-lib.sh). The wait loop above only proves the pane left
  # PROJ_ABS's exact path; this proves it landed in a true, separate worktree.
  wt_real=
  if ! wt_real=$(cd "$WT" 2>/dev/null && pwd -P); then
    wt_real=
  fi
  proj_real=
  if ! proj_real=$(cd "$PROJ_ABS" 2>/dev/null && pwd -P); then
    proj_real=
  fi
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
  wt_top_real=
  if ! wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P); then
    wt_top_real=
  fi
  if [ -z "$wt_real" ] || [ -z "$wt_top_real" ] || [ "$wt_real" != "$wt_top_real" ] || [ "$wt_real" = "$proj_real" ]; then
    echo "error: treehouse get did not yield an isolated worktree (resolved '$WT'; worktree root '${wt_top:-none}'; primary '$PROJ_ABS'); refusing to launch to avoid tangling the primary checkout. Inspect window $T" >&2
    exit 1
  fi
fi

# Per-task temp root: /tmp/fm-<id>/ with Go's build temp nested at gotmp/. Go won't
# create GOTMPDIR, so mkdir before it is used; fm-teardown removes the whole root.
# Nested (not a bare /tmp/fm-<id>/gotmp) so other per-task temp can live alongside
# later, and teardown cleans one deterministic path. GOTMPDIR (not TMPDIR) is the
# targeted knob: TMPDIR is too broad (affects every program's temp, not just Go's).
TASK_TMP="/tmp/fm-$ID"
mkdir -p "$TASK_TMP/gotmp"

# Per-harness turn-end hook: a file that touches state/<id>.turn-ended when the
# agent finishes a turn. Worktree-resident hooks are kept out of git's view so
# they never block teardown's dirty check or leak into a commit.
mkdir -p "$STATE"
STATE_REAL=$(cd "$STATE" && pwd -P)
TURNEND="$STATE_REAL/$ID.turn-ended"
exclude_path() {
  local rel=$1 EXCL
  EXCL=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
}
if [ "$KIND" != secondmate ]; then
  case "$HARNESS" in
    claude*)
      mkdir -p "$WT/.claude"
      cat > "$WT/.claude/settings.local.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '$TURNEND'"}]}]}}
EOF
      exclude_path '.claude/settings.local.json'
      ;;
    opencode*)
      mkdir -p "$WT/.opencode/plugins"
      cat > "$WT/.opencode/plugins/fm-turn-end.js" <<EOF
export const FmTurnEnd = async ({ \$ }) => ({
  event: async ({ event }) => {
    if (event.type === "session.idle") await \$\`touch $TURNEND\`
  },
})
EOF
      exclude_path '.opencode/plugins/fm-turn-end.js'
      ;;
    pi*)
      # Written OUTSIDE the worktree: pi's project-trust gate fires on any extension
      # loaded from inside the project (verified live), but an explicit -e path
      # elsewhere loads without a dialog. Lives in state/, cleaned by teardown.
      cat > "$STATE/$ID.pi-ext.ts" <<EOF
// Firstmate turn-end signal; written by fm-spawn.
// Use "turn_end" (fires after each turn the agent finishes), not "agent_end"
// (fires once, only when the whole run exits): the watcher needs a signal at
// every turn boundary so an idle crewmate is surfaced, not just at shutdown.
import { execFile } from "node:child_process";
export default function (pi: any) {
  pi.on("turn_end", () => execFile("touch", ["$TURNEND"]));
}
EOF
      ;;
    codex*)
      # codex: turn-end rides the launch command via -c notify=[...] and __TURNEND__.
      ;;
    grok*)
      # grok fires a Stop hook at every turn boundary (verified, grok 0.2.73), the
      # clean equivalent of codex's notify= and pi's turn_end. But grok only loads
      # PROJECT hooks (<worktree>/.grok/hooks/, <worktree>/.claude/settings.local.json)
      # after the folder is granted hook-trust, which is not automatic and which
      # firstmate cannot establish at launch without editing grok's own managed
      # trust store (a high-blast-radius write). GLOBAL hooks in ~/.grok/hooks/ are
      # always trusted and load on first launch with no gate. So the turn-end hook
      # lives OUTSIDE the worktree as a single firstmate-owned global hook that is a
      # guarded no-op for every non-firstmate grok session: it fires only when the
      # current workspace holds a .fm-grok-turnend token pointer that matches the
      # firstmate-owned hook registry. firstmate then drops that per-task pointer
      # (gitignored, like the other harnesses' worktree hook files).
      # Result: the hook is outside the worktree, needs no trust grant, and never
      # touches grok's managed config - only firstmate-owned files.
      GROK_HOOKS_DIR="${GROK_HOME:-$HOME/.grok}/hooks"
      GROK_AUTH_DIR="$GROK_HOOKS_DIR/fm-turn-end.d"
      mkdir -p "$GROK_AUTH_DIR"
      old_umask=$(umask)
      umask 077
      auth_file=$(mktemp "$GROK_AUTH_DIR/fm.XXXXXXXXXXXX")
      umask "$old_umask"
      printf '%s\n' "$TURNEND" > "$auth_file"
      printf '%s\n' "${auth_file##*/}" > "$STATE/$ID.grok-turnend-token"
      sq_grok_auth_dir=$(shell_quote "$GROK_AUTH_DIR")
      cat > "$GROK_HOOKS_DIR/fm-turn-end.sh" <<EOF
#!/usr/bin/env bash
set -u
auth_dir=$sq_grok_auth_dir
workspace=\${GROK_WORKSPACE_ROOT:-}
[ -n "\$workspace" ] || exit 0
p="\$workspace/.fm-grok-turnend"
[ -f "\$p" ] || exit 0
first=
IFS= read -r -n 256 first < "\$p" 2>/dev/null || [ -n "\$first" ] || exit 0
case "\$first" in token=*) token=\${first#token=} ;; *) exit 0 ;; esac
case "\$token" in fm.????????????) : ;; *) exit 0 ;; esac
case "\$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
t=\$(cat "\$auth_dir/\$token" 2>/dev/null) || exit 0
case "\$t" in /*.turn-ended) : ;; *) exit 0 ;; esac
touch "\$t" 2>/dev/null || true
exit 0
EOF
      chmod +x "$GROK_HOOKS_DIR/fm-turn-end.sh"
      hook_command=$(json_escape "bash $(shell_quote "$GROK_HOOKS_DIR/fm-turn-end.sh")")
      printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' "$hook_command" > "$GROK_HOOKS_DIR/fm-turn-end.json"
      printf 'token=%s\n' "${auth_file##*/}" > "$WT/.fm-grok-turnend"
      exclude_path '.fm-grok-turnend'
      ;;
    devin*)
      # devin reads Claude Code-compatible hooks from .devin/hooks.v1.json, where
      # the hooks object IS the entire file (no "hooks" wrapper key, unlike
      # settings files). The Stop event fires at every turn boundary - exactly
      # the signal the watcher needs to surface an idle crewmate.
      #
      # A PreToolUse hook BLOCKS merge-capable and main/master push commands
      # (gh pr merge, gh api .../merge, gh pr review --approve, and git push to
      # main/master) before they run - crewmates never merge or push to the
      # default branch (that is firstmate's call). devin fires PreToolUse with a
      # Claude-Code-shaped stdin JSON ({tool_name, tool_input:{command}}) and
      # treats a non-zero guard exit as a tool rejection with the guard's stderr
      # fed back to the model (exit 2 blocks the exec before execution; subagents
      # inherit the same worktree hooks - re-verified live on devin 3000.1.27,
      # where a subagent's exec of `git push ... main` was blocked while the outer
      # run_subagent delegation call, which carries no command field, correctly
      # passed). This block runs only for non-secondmate spawns (the enclosing
      # KIND guard), so secondmates - which are firstmates and legitimately merge
      # - never get the deny hook.
      #
      # IMPORTANT - this hook is NOT a hard boundary; it is one devin-internal
      # layer that can silently stop firing. On 2026-07-12 a devin 3000.1.27
      # crewmate ran `gh pr merge` in its primary loop and it SUCCEEDED even
      # though this hook and guard were present and correct (piping the exact
      # captured payload into the guard by hand still returned exit 2). Live
      # re-testing on 3000.1.27 could not deterministically reproduce that
      # non-firing - the hook fired and blocked in every fresh session tried
      # (-p and interactive, dangerous mode, allow-listed command, and subagent
      # exec) - so the incident's silent skip is non-deterministic / session-state
      # dependent and devin-internal, not fixable from here. Do NOT try to harden
      # this by adding devin's declarative permissions.deny (worktree
      # .devin/config.local.json or --agent-config): live testing proved
      # --permission-mode dangerous ("auto-approves ALL tools", which is how
      # crewmates launch) OVERRIDES deny for the primary agent, so a deny list is
      # a no-op here and would only give false security. The real containment for
      # a layer that can stop firing is the independent post-spawn identity check
      # (fm_foreman_verify_identity) plus keeping the captain's merge as the only
      # sanctioned merge path. See docs/devin-merge-deny.md for the full evidence.
      mkdir -p "$WT/.devin"
      cat > "$WT/.devin/fm-merge-deny.sh" <<'DENY'
#!/bin/sh
# firstmate crewmate merge-deny guard (PreToolUse). Blocks merge-capable and
# main/master-push commands before they run. Fails OPEN for non-matching
# commands (including malformed input), CLOSED when a deny pattern matches.
set -u
input=$(cat 2>/dev/null || true)

# Extract the tool command. Prefer a clean jq parse; if that fails (malformed
# JSON, or no jq), fall back to scanning the raw payload so a matching pattern
# is still caught (fail closed on match).
cmd=
parsed=0
if command -v jq >/dev/null 2>&1 && printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
  parsed=1
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null || true)
fi
# Scan the parsed command when jq extracted one. A cleanly parsed payload with
# no command field (file edits, writes) is not scanned at all - content that
# merely mentions a deny pattern must not block the tool. Token boundaries
# include whitespace, shell separators, and shell/JSON quote characters so the
# raw-payload fallback still fails closed when the command is wrapped in quotes.
if [ -n "$cmd" ]; then
  scan=$(printf '%s' "$cmd" | tr '\n' ' ')
elif [ "$parsed" -eq 0 ] && printf '%s' "$input" | grep -Eq '"tool_name"[[:space:]]*:[[:space:]]*"exec"|"(command|cmd)"[[:space:]]*:'; then
  # jq missing or the payload is unparseable: scan the raw payload ONLY when it
  # looks like a command/exec tool call (an "exec" tool_name or a command/cmd
  # field). A file edit/write whose CONTENT merely mentions a deny pattern has
  # no such marker and passes untouched (fail open), while a plausible command
  # tool still fails closed on a matching pattern.
  scan=$(printf '%s' "$input" | tr '\n' ' ')
else
  exit 0
fi
E='([[:space:];&|()"'\''\\]|$)'         # trailing boundary
LB='(^|[[:space:];&|()"'\''\\:=])'      # leading boundary (start, or a boundary/colon char)

blocked=0
# gh pr merge (any form)
printf '%s' "$scan" | grep -Eq "gh[[:space:]]+pr[[:space:]]+merge$E" && blocked=1
# gh api ... path containing /merge
printf '%s' "$scan" | grep -Eq "gh[[:space:]]+api$E" \
  && printf '%s' "$scan" | grep -Eq '/merge' && blocked=1
# gh pr review --approve
printf '%s' "$scan" | grep -Eq "gh[[:space:]]+pr[[:space:]]+review$E" \
  && printf '%s' "$scan" | grep -Eq -- "--approve([[:space:];&|()\"'\\=]|\$)" && blocked=1
# git push targeting main/master on any remote (incl. HEAD:main / :refs/heads/main)
if printf '%s' "$scan" | grep -Eq "git[[:space:]]+push$E"; then
  printf '%s' "$scan" | grep -Eq "$LB(\\+)?(refs/heads/)?(main|master)$E" && blocked=1
fi

if [ "$blocked" -eq 1 ]; then
  echo "BLOCKED by firstmate policy: crewmates never merge or push to main; report done and stop." >&2
  exit 2
fi
exit 0
DENY
      chmod +x "$WT/.devin/fm-merge-deny.sh"
      deny_cmd=$(json_escape "$(shell_quote "$WT/.devin/fm-merge-deny.sh")")
      cat > "$WT/.devin/hooks.v1.json" <<EOF
{"Stop":[{"hooks":[{"type":"command","command":"touch '$TURNEND'"}]}],"PreToolUse":[{"hooks":[{"type":"command","command":"$deny_cmd"}]}]}
EOF
      exclude_path '.devin/hooks.v1.json'
      exclude_path '.devin/fm-merge-deny.sh'
      ;;
  esac
fi

# Per-project delivery mode + yolo flag (bin/fm-project-mode.sh; AGENTS.md project management and task lifecycle).
# Recorded in meta so fm-teardown's safety check and the validate/merge stages can
# branch on them. Mode governs ship tasks; a scout's deliverable is a report, not a
# merge, so scout teardown ignores mode.
SECONDMATE_PROJECTS=
if [ "$KIND" = secondmate ]; then
  MODE=secondmate
  YOLO=off
  SECONDMATE_PROJECTS=$(secondmate_registry_value "$ID" projects || true)
else
  PROJ_NAME=$(basename "$PROJ_ABS")
  read -r MODE YOLO <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$PROJ_NAME")
EOF
fi

# Crew GitHub identity (Claude Foreman): for a crewmate/scout spawn into a
# project with a github.com origin, mint a per-task GitHub App installation
# token scoped to that one repo (contents:write + pull_requests:write) so the
# crewmate authors commits and PRs as <app-slug>[bot] instead of the captain's
# personal account. Opt-in by config presence (config/claude-foreman.env +
# config/claude-foreman.pem; bin/fm-foreman-token.sh): with the config absent
# this whole block is a silent no-op, and any failure with the config present
# warns and falls back to the current identity - it never blocks the spawn.
# Injection is pane-environment only (PATH shim, GH_TOKEN, GIT_CONFIG_* env
# vars): no git config file is written, globally or in the worktree, so the
# primary checkout and every other repo are untouched. The 1h token TTL is
# handled by re-minting on demand: git authenticates through a credential
# helper and gh through a per-task PATH shim, both of which call the token
# helper's per-task cache (fresh <50min, re-mint after), so long tasks outlive
# the TTL without a static token going stale. Secondmate spawns are exempt -
# they are firstmate homes, not project crews.
FOREMAN_ACTIVE=
FOREMAN_BOT_NAME=
FOREMAN_BOT_EMAIL=
FOREMAN_CACHE=
FOREMAN_SLUG=
FOREMAN_TMP=
if [ "$KIND" != secondmate ]; then
  foreman_rc=0
  "$FM_ROOT/bin/fm-foreman-token.sh" configured || foreman_rc=$?
  if [ "$foreman_rc" -eq 0 ]; then
    foreman_origin=$(git -C "$PROJ_ABS" remote get-url origin 2>/dev/null || true)
    case "$foreman_origin" in
      git@github.com:*) FOREMAN_SLUG=${foreman_origin#git@github.com:} ;;
      ssh://git@github.com/*) FOREMAN_SLUG=${foreman_origin#ssh://git@github.com/} ;;
      https://github.com/*) FOREMAN_SLUG=${foreman_origin#https://github.com/} ;;
      http://github.com/*) FOREMAN_SLUG=${foreman_origin#http://github.com/} ;;
      *) FOREMAN_SLUG= ;;
    esac
    FOREMAN_SLUG=${FOREMAN_SLUG%/}
    FOREMAN_SLUG=${FOREMAN_SLUG%.git}
    case "$FOREMAN_SLUG" in
      */*/*|*/|/*) FOREMAN_SLUG= ;;
      */*) : ;;
      *) FOREMAN_SLUG= ;;
    esac
    if [ -n "$FOREMAN_SLUG" ] && FOREMAN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-foreman-$ID.XXXXXX"); then
      FOREMAN_CACHE="$FOREMAN_TMP/foreman-token.json"
      if "$FM_ROOT/bin/fm-foreman-token.sh" token "$FOREMAN_SLUG" "$FOREMAN_CACHE" >/dev/null \
        && foreman_identity=$("$FM_ROOT/bin/fm-foreman-token.sh" bot-identity); then
        FOREMAN_BOT_NAME=$(printf '%s\n' "$foreman_identity" | sed -n 1p)
        FOREMAN_BOT_EMAIL=$(printf '%s\n' "$foreman_identity" | sed -n 2p)
        FOREMAN_ACTIVE=1
        # gh shim: re-mints per gh invocation so gh calls hours into the task
        # still authenticate as the bot. Written only when a real gh exists.
        foreman_real_gh=$(command -v gh 2>/dev/null || true)
        if [ -n "$foreman_real_gh" ]; then
          mkdir -p "$FOREMAN_TMP/bin"
          cat > "$FOREMAN_TMP/bin/gh" <<EOF
#!/bin/sh
# firstmate Claude Foreman gh shim: refresh the app installation token per call.
t=\$($(shell_quote "$FM_ROOT/bin/fm-foreman-token.sh") token $(shell_quote "$FOREMAN_SLUG") $(shell_quote "$FOREMAN_CACHE") 2>/dev/null) || t=
if [ -n "\$t" ]; then
  GH_TOKEN=\$t GITHUB_TOKEN=\$t exec $(shell_quote "$foreman_real_gh") "\$@"
fi
exec env -u GH_TOKEN -u GITHUB_TOKEN $(shell_quote "$foreman_real_gh") "\$@"
EOF
          chmod +x "$FOREMAN_TMP/bin/gh"
        fi
        # Single sourceable pane-environment file. The injection used to send
        # each export as its own long pane keystroke line, and the ~750-char
        # GIT_CONFIG_* line was observed truncating in real panes (dropping
        # GIT_CONFIG_VALUE_4 onward), which breaks every git and gh-axi call
        # in the task with "missing config value" - crewmates then work around
        # it by shedding the injected env and their PRs fall back to the
        # personal identity. Writing the environment here and sourcing it with
        # one short pane line removes that failure class. The file holds no
        # token value: GH_TOKEN is minted at source time IN the pane via the
        # helper, exactly as the old inline line did.
        foreman_cred_value="!$(shell_quote "$FM_ROOT/bin/fm-foreman-token.sh") credential $(shell_quote "$FOREMAN_SLUG") $(shell_quote "$FOREMAN_CACHE")"
        if ! {
          echo "# firstmate Claude Foreman pane environment for task $ID."
          echo "# Sourced once at spawn; safe to re-source. Holds no token value."
          if [ -x "$FOREMAN_TMP/bin/gh" ]; then
            echo "export PATH=$(shell_quote "$FOREMAN_TMP/bin"):\"\$PATH\""
          fi
          echo "fm_t=\$($(shell_quote "$FM_ROOT/bin/fm-foreman-token.sh") token $(shell_quote "$FOREMAN_SLUG") $(shell_quote "$FOREMAN_CACHE") 2>/dev/null) && [ -n \"\$fm_t\" ] && export GH_TOKEN=\"\$fm_t\" GITHUB_TOKEN=\"\$fm_t\"; unset fm_t"
          echo "export GIT_CONFIG_COUNT=6"
          echo "export GIT_CONFIG_KEY_0=credential.https://github.com.helper GIT_CONFIG_VALUE_0="
          echo "export GIT_CONFIG_KEY_1=credential.https://github.com.helper GIT_CONFIG_VALUE_1=$(shell_quote "$foreman_cred_value")"
          echo "export GIT_CONFIG_KEY_2=user.name GIT_CONFIG_VALUE_2=$(shell_quote "$FOREMAN_BOT_NAME")"
          echo "export GIT_CONFIG_KEY_3=user.email GIT_CONFIG_VALUE_3=$(shell_quote "$FOREMAN_BOT_EMAIL")"
          echo "export GIT_CONFIG_KEY_4=url.https://github.com/.insteadOf GIT_CONFIG_VALUE_4=git@github.com:"
          echo "export GIT_CONFIG_KEY_5=url.https://github.com/.insteadOf GIT_CONFIG_VALUE_5=ssh://git@github.com/"
        } > "$FOREMAN_TMP/env.sh"; then
          echo "warning: Claude Foreman identity unavailable for $FOREMAN_SLUG (env file write failed); crewmate $ID keeps the default GitHub identity" >&2
          FOREMAN_ACTIVE=
          rm -rf "$FOREMAN_TMP"
          FOREMAN_TMP=
        fi
      else
        echo "warning: Claude Foreman identity unavailable for $FOREMAN_SLUG; crewmate $ID keeps the default GitHub identity" >&2
        FOREMAN_ACTIVE=
        rm -rf "$FOREMAN_TMP"
        FOREMAN_TMP=
      fi
    fi
  fi
fi

{
  echo "window=$T"
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  echo "tasktmp=$TASK_TMP"
  echo "model=${MODEL:-default}"
  echo "effort=${EFFORT:-default}"
  # backend= is written only for a non-default (non-tmux) backend, so the
  # default path's meta stays byte-identical (absent backend= means tmux;
  # data/fm-backend-design-d7's P1 compatibility contract).
  [ "$BACKEND" = tmux ] || echo "backend=$BACKEND"
  if [ "$BACKEND" = herdr ]; then
    echo "herdr_session=$HERDR_SES"
    echo "herdr_workspace_id=$HERDR_WORKSPACE_ID"
    echo "herdr_tab_id=$HERDR_TAB_ID"
    echo "herdr_pane_id=$HERDR_PANE_ID"
  fi
  if [ "$KIND" = secondmate ]; then
    echo "home=$PROJ_ABS"
    echo "projects=$SECONDMATE_PROJECTS"
  fi
  # foreman= is written only when the Claude Foreman identity was injected, so
  # the default path's meta stays byte-identical.
  [ -z "$FOREMAN_ACTIVE" ] || echo "foreman=$FOREMAN_BOT_NAME"
  [ -z "$FOREMAN_TMP" ] || echo "foremantmp=$FOREMAN_TMP"
} > "$STATE/$ID.meta"

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
MODELFLAG=$(model_flag_for_harness "$HARNESS" "$MODEL")
EFFORTFLAG=$(effort_flag_for_harness "$HARNESS" "$EFFORT")
LAUNCH=${LAUNCH//__MODELFLAG__/$MODELFLAG}
LAUNCH=${LAUNCH//__EFFORTFLAG__/$EFFORTFLAG}
LAUNCH=${LAUNCH//__BRIEF__/$sq_brief}
LAUNCH=${LAUNCH//__TURNEND__/$sq_turnend}
LAUNCH=${LAUNCH//__PIEXT__/$sq_piext}
if [ "$KIND" = secondmate ]; then
  sq_home=$(shell_quote "$PROJ_ABS")
  LAUNCH="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME=$sq_home $LAUNCH"
fi
# Inject the Claude Foreman identity into the crewmate's pane shell before
# launch by sourcing the per-task env file written above. One short line: long
# per-export keystroke lines were observed truncating in real panes, breaking
# git/gh in the task. The file carries the same three pieces as before, all
# environment-scoped to this pane (no git config file is touched anywhere):
#   1. PATH shim (when a real gh exists): gh calls re-mint the token on demand.
#   2. GH_TOKEN/GITHUB_TOKEN: minted via command substitution IN the pane so the
#      token never appears in scrollback; covers tools that read the env directly.
#   3. GIT_CONFIG_* env: reset then install the re-minting credential helper for
#      https://github.com, set the bot author identity, and rewrite ssh GitHub
#      remotes to https so pushes authenticate with the app token.
if [ -n "$FOREMAN_ACTIVE" ]; then
  spawn_send_text_line "$T" ". $(shell_quote "$FOREMAN_TMP/env.sh")"
  sleep 0.3
  # Confirm the injected identity is actually active in this pane's shell before
  # the agent starts; records foreman_verify= in meta and warns on mismatch.
  fm_foreman_verify_identity "$T" "$FOREMAN_TMP" "$FOREMAN_BOT_NAME" "$STATE/$ID.meta" "$ID"
fi

# Export GOTMPDIR into the crewmate's pane shell so the agent and every child
# process (go build, go test, ...) inherit it. Sent before the launch command so
# the env is set when the agent starts; the brief sleep lets the export land.
spawn_send_text_line "$T" "export GOTMPDIR=$TASK_TMP/gotmp"
sleep 0.3
spawn_send_literal "$T" "$LAUNCH"
sleep 0.3
spawn_send_key "$T" Enter

echo "spawned $ID harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO window=$T worktree=$WT"
