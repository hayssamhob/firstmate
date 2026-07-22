# Antigravity account rotation

Antigravity (Google's agent CLI, the `agy` binary) authenticates as one Google account at a time.
On the free/Pro tiers an account runs out of daily credits, so the captain keeps several accounts and switches when one is exhausted.
firstmate automates that switch for an antigravity crew: detect the exhaustion, rotate to the next account, and resume.

This document is the operator guide.
The supervision playbook lives in the `harness-adapters` skill; the mechanics live in the `bin/fm-antigravity-*` scripts.

## How antigravity stores accounts

The `agy` CLI keeps only the CURRENTLY-active account's OAuth tokens on disk:

- `~/.gemini/oauth_creds.json` - the active account's live tokens (`access_token`, `refresh_token`, `id_token`, `expiry_date`, `scope`, `token_type`). No email field; the account is identified by the `email` claim inside the `id_token` JWT.
- `~/.gemini/google_accounts.json` - `{"active":"<email>","old":["<email>",...]}`. The `active` email always mirrors the account whose tokens are in `oauth_creds.json`.

There is **no per-account credential store** on disk and **no `agy` account-switch subcommand**.
Switching the account `agy` authenticates as therefore means REPLACING `oauth_creds.json` with the target account's tokens and pointing `.active` at it.
Because only the active account's tokens exist on disk at any moment, firstmate must SNAPSHOT each account once - while it is active - before it can ever rotate to it.

(Override the auth dir with `FM_ANTIGRAVITY_DIR` for testing; it defaults to `~/.gemini`.)

## One-time setup (captain)

Interactive Google login is captain-only - firstmate cannot log in for you.
For each of your accounts:

1. In antigravity, log into the account (or confirm the one already active).
2. Snapshot it into the pool:

   ```sh
   bin/fm-antigravity-accounts.sh capture
   ```

3. Repeat for every account you want in the rotation (5-6 is typical).

Then, optionally, set the round-robin order and review the pool:

```sh
bin/fm-antigravity-accounts.sh set-rotation you@gmail.com you+work@gmail.com you+alt@gmail.com
bin/fm-antigravity-accounts.sh list
bin/fm-antigravity-accounts.sh status
```

### Where things are stored

- **Snapshots** (which contain live refresh tokens) live at `~/.gemini/fm-antigravity-accounts/snapshots/<email>.oauth_creds.json`, mode 600, next to the auth they belong to - **never** in the firstmate repo, as defense in depth against ever committing a credential.
- **Rotation config** (order + index only, never a token) lives in the firstmate repo at `config/antigravity-accounts.json`, which is gitignored. See `docs/examples/antigravity-accounts.json`.
- **Backups** of the live auth pair are written before every swap under `~/.gemini/fm-antigravity-accounts/backups/<timestamp>/`.

## Automatic rotation during a crew run

When firstmate runs an antigravity crew across the pool, it arms the credit poll as the task's per-task check so the watcher surfaces the exhaustion the instant it happens:

```sh
printf '#!/usr/bin/env bash\nexec %s/bin/fm-antigravity-credit-check.sh fm-<id>\n' "$FM_HOME" > state/<id>.check.sh
chmod +x state/<id>.check.sh
```

The poll greps the crew's pane for `AI: Out of credits` (and common credit/quota errors) and prints an `antigravity-out-of-credits <window>` wake line only when the account is dry.
On that `check:` wake, firstmate rotates and resumes in one command:

```sh
bin/fm-antigravity-rotate.sh next --relaunch fm-<id>
```

- `next` round-robins to the next pool account that has a snapshot.
- `--relaunch fm-<id>` sends `agy --continue` to the crew's window to resume the stalled turn on the fresh account.
- `to <email>` targets a specific account instead of round-robin.
- `--verify` runs one small `agy -p` request afterward to confirm the new account authenticates.

## Safety

Every mutation of the live auth is defensive.
`bin/fm-antigravity-rotate.sh`:

- backs up `oauth_creds.json` + `google_accounts.json` before any write;
- re-snapshots the OUTGOING account so its latest refresh token is preserved for a future rotation back;
- writes both files atomically (temp + `mv`) and validates JSON before and after;
- restores from the backup if a write fails;
- serializes concurrent rotations under a lock;
- refuses on any inconsistency (missing/invalid auth, missing snapshot, a snapshot whose token does not match its email) rather than guessing.

`capture` only READS the live auth (it writes a snapshot copy elsewhere), so populating the pool never risks the active session.

The swap mechanism was proven non-corrupting empirically: a scratch-dir round-robin across two accounts (creds and `active` follow correctly, JSON stays valid, backups are made) plus a live `capture` that left `~/.gemini` byte-identical.

What is **not** auto-provable without a second logged-in account: whether a restored snapshot re-authenticates cleanly and how long a stored Google refresh token stays valid.
Confirm this on the first real rotation after you have captured a second account.
If a rotation ever fails to authenticate, the stored token for that account went stale - re-run `capture` while that account is active to refresh its snapshot.
