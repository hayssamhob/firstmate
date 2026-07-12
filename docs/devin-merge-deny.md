# devin crewmate merge-deny: layers, limits, and the 2026-07-12 incident

This document records the empirical investigation behind the devin crewmate merge-deny machinery in `bin/fm-spawn.sh` and the post-spawn identity check (`fm_foreman_verify_identity`).
It is the "why" behind two firstmate invariants: crewmates never merge or push to the default branch (that is firstmate's call), and a crewmate's GitHub actions are attributable to the Claude Foreman bot, never the captain's personal account.
Read it before changing the devin `PreToolUse` hook, the guard script, the launch permission mode, or the Foreman identity injection.

## The incident (2026-07-12, devin 3000.1.27, SWE-1.7)

A direct-PR crewmate on Falafel.ma ran `gh pr merge 1499 --merge --subject "..."` in its primary agent loop and it SUCCEEDED - a real merge - even though the `PreToolUse` merge-deny hook and its guard script were present and correct in the worktree.
Piping the exact captured payload (`{"tool_name":"exec","tool_input":{"command":"gh pr merge 1499 --merge --subject \"...\""}}`) into `.devin/fm-merge-deny.sh` by hand still printed `BLOCKED by firstmate policy` and exited 2, so the guard logic was not the bug: devin simply did not invoke the hook for that specific tool call.
Two things then compounded the damage.
First, the merge landed at all (the hook did not stop it).
Second, GitHub recorded `mergedBy: hayssamhob` - the captain's own personal identity - not the Foreman bot: the per-task bot-identity injection was present in the worktree's shim dir, but the shell that actually ran `gh pr merge` did not have it active, so `gh` fell through to the single machine-global OAuth login (the captain's keyring account).

## What live re-testing on devin 3000.1.27 established

All of the following were reproduced against a fresh scratch git repo with the exact `fm-spawn` guard installed (instrumented to log every hook invocation), using a denied-but-harmless probe command `git push nonexistent-remote-xyz main` (matches the `git push * main*` deny shape; if it runs it only errors "remote does not exist", touching nothing).

- The `PreToolUse` hook FIRES and BLOCKS in every fresh-session configuration tried: non-interactive `-p` dangerous mode, interactive `--prompt-file` dangerous mode, dangerous mode with the probe command already on `permissions.allow`, and a subagent's `exec` (subagent hook inheritance still holds - the inner `exec` was blocked while the outer `run_subagent` delegation call, which carries no command field, correctly passed).
  The hook mechanism is therefore not fundamentally broken on this version.
- The incident's silent non-firing could NOT be reproduced deterministically.
  It is real (the merge happened) but tied to session state not reproduced here.
  A plausible mechanism is a transient hook-execution failure that devin fails OPEN on - for example the git-excluded guard script being deleted by a `git clean -fdx` or reset mid-session, or a hook-spawn race under load - but this was not confirmed, and it is devin-internal in any case, not fixable from firstmate.
  The operational conclusion is simply that this hook is one devin-internal layer that can silently stop firing, so it is NOT a hard boundary.
- devin's declarative `permissions.deny` is OVERRIDDEN by `--permission-mode dangerous` for the primary agent.
  Crewmates launch with `--permission-mode dangerous` ("auto-approves ALL tools") for autonomy, and under it a `permissions.deny` list - whether in the worktree's `.devin/config.local.json` or in an `--agent-config` file - is a no-op: the probe command ran (exit 128) with the deny list present and the hook disabled.
  So adding a declarative deny for the primary crewmate would give false security, not a real boundary.
  The subagent merge that WAS blocked in the incident (a different crewmate, via a named subagent) blocked because subagents run under their own agent-definition permissions rather than the primary's dangerous mode - a mechanism not available to the dangerous-mode primary.

## The layered defense firstmate ships

Because no single in-devin layer is a hard boundary under dangerous mode, firstmate relies on layers, one of which is fully outside devin's control.

1. **The `PreToolUse` merge-deny hook** (`bin/fm-spawn.sh`, `.devin/fm-merge-deny.sh`).
   Kept because it blocks in the common case, and it is the only layer that also stops a bare `git push main` and covers subagent `exec` calls.
   Not trusted as a hard boundary, for the reasons above.
   Do NOT try to "fix" it by adding declarative `permissions.deny`: proven ineffective under dangerous mode.
2. **The post-spawn identity check** (`fm_foreman_verify_identity` in `bin/fm-spawn.sh`).
   Independent of devin's tool-approval flow entirely.
   Right after the pane sources the injected Foreman env, and before the agent starts, firstmate runs `gh auth status` in that same pane shell and confirms the ACTIVE gh account is the bot, not a personal fallback account.
   It inspects both the active account's resolved login and its credential source: a login equal to `<app-slug>[bot]` is `ok`, and because a GitHub App installation token cannot resolve a login through gh's viewer API (gh renders it as `Failed to log in ... using token (GH_TOKEN)`), an active account whose source is `(GH_TOKEN)` with no resolvable login is also `ok` - that is the injected Foreman token by construction, not a personal fallthrough.
   Any other resolvable login (e.g. the captain's keyring account) is a mismatch.
   The result is recorded in `state/<id>.meta` as `foreman_verify=ok`, `foreman_verify=mismatch:<account>`, or `foreman_verify=unknown`, and a mismatch prints a loud stderr warning at spawn.
   This turns the incident's silent injection failure (the merging shell falling through to the captain's login) into a loud, firstmate-detectable signal.
   It NEVER blocks the spawn (Foreman's contract), and it is disabled with `FM_FOREMAN_VERIFY=0` for panes that cannot execute a probe command; `FM_FOREMAN_VERIFY_TIMEOUT` overrides the completion wait (default 15s).
   The check is harness-agnostic - the identity-fallthrough risk applies to any pane that sheds the injected env, though the motivating incident was devin.
3. **The captain's merge as the only sanctioned merge path.**
   Firstmate never merges without the captain's explicit word (or a project's `yolo` flag), so even a crewmate that reaches `gh pr merge` is acting outside the sanctioned flow, and the identity check plus branch protection remain the containment.

## Residual unknowns

The exact trigger for the hook's silent non-firing on devin 3000.1.27 remains unexplained and was not deterministically reproducible.
If devin exposes a distinct built-in tool for GitHub operations that carries the merge intent in a field other than `tool_input.command`/`tool_input.cmd`, the guard would not scan it; no such tool was observed (the incident command was a literal `gh pr merge` `exec`), but it is worth re-checking after any devin version bump.
Re-verify this whole picture live (a real devin tool call, not just a piped-in guard test) after any devin or harness version change, per the note in the `harness-adapters` skill.
