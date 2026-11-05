---
name: close
description: Land a ticket that /10x:work finished — rebase it onto the current base, verify again, then open a PR, merge it, or merge locally, as the project configures; remove the worktree once merged. Use when the user runs /10x:close <id>.
disable-model-invocation: true
allowed-tools:
  - Bash(10x-land check *)
  - Bash(10x-land rebase *)
  - Bash(10x-land push *)
  - Bash(10x-land merge *)
  - Bash(10x-land wait *)
  - Bash(10x-land squash *)
  - Bash(10x-land pr *)
  - Bash(10x-verify *)
  - Bash(10x-worktree path *)
  - Bash(10x-worktree rm *)
  - Bash(10x-worktree sync-base)
  - Bash(git remote get-url origin)
  - Bash(gh auth status)
  - Bash(gh pr view *)
  - Bash(gh issue view *)
  - Bash(glab auth status)
  - Bash(glab mr view *)
---

# Close a ticket

`/10x:close <id>` lands the branch `/10x:work` produced. How it lands is the `close` setting in `.claude/10x.json`, which `10x-land check` prints in Step 0:

| `close` | What happens |
|---|---|
| `pr` (default) | push the branch, open a PR; a human merges it. Run `/10x:close <id>` again after the merge to clean up. |
| `pr-merge` | push, open the PR, and squash-merge it. |
| `local` | no PR: squash the ticket branch onto the base branch locally. Pushing the base is left to the user. |

The PR tool follows `origin`: github.com → `gh`, a GitLab host → `glab`. Any other host, or no `origin`, supports only `local`.

Run one command per Bash call — no `&&`, `;` or `|` — so each call matches this skill's `allowed-tools` on its own. In `pr-merge` mode, running `/10x:close` is the user's request to merge: state the PR URL, then merge.

## Step 0 — Take stock, stop on anything unfinished

```bash
10x-land check <id>
10x-worktree path <id>
```

`check` prints `mode: <close>` first: that value is the mode for the whole run, in every step below — never read `.claude/10x.json` for it. An exit 2 from `check` that names an unknown close mode or an unreadable config is a stop: quote the script's line and say the valid values are `pr`, `pr-merge` and `local`. Then, before it looks for the worktree, it prints `ticket dir: <path>`, `base: <branch> (<ref>)`, and `review: <path>` or `review: missing`, then `tickets: <value>`. An exit 2 right after the `tickets:` line whose message is `unknown tickets value …` is a stop: quote the script's line and say the valid values are `github` and `files`. Next comes `security: <level>` or `security: off` — the `security.blockClose` setting; an exit 2 whose message is `unknown security.blockClose …` is a stop: quote it and say the valid values are `critical`, `high`, `medium`, `low` and `informational`. Every `.10x/<id>/` path in this skill (`review.md`, `pr-title`, `pr-body.md`, `commit-msg`) is under that ticket dir — in the main checkout, never under the worktree — and `<base>` is the branch on the `base:` line. An exit 2 after the `tickets:` line saying the ticket has no worktree is the no-worktree case below. In `pr` or `pr-merge` mode, `check` also prints the branch's PR on GitHub: `pr: <STATE> <url>`, or `pr: none`; and the repo's PR/MR template the body must follow, `pr template: <path>` (relative to the worktree), or `pr template: none`.

Stop and say why if any of these holds:

- only in `pr` or `pr-merge` mode (`local` never calls `gh` or `glab`, not even to check): the PR tool is missing or logged out — check with `gh auth status` (or `glab auth status`) **before** rebasing or pushing, so a failure never leaves a pushed branch without a PR. Command not found → install it (https://cli.github.com, https://gitlab.com/gitlab-org/cli); non-zero exit → `gh auth login` / `glab auth login`. Mention that `"close": "local"` in `.claude/10x.json` needs neither;
- no worktree for `<id>`: look for an open PR of the branch instead (the second run of `pr` mode, Step 4);
- uncommitted changes in the worktree;
- `check` printed `locked test changed: <path>` lines: a locked test changed without a relock that red-proof accepted — that is `/10x:work`'s job;
- `check` printed `security entry open: <fp>` lines: a confirmed security entry of this ticket at or above `security.blockClose` is still `new` or `fix-now` — name the fingerprints only; the user settles them through `/10x:work`. Not a stop on the `pr: MERGED` cleanup run below;
- `review: missing`, or the review it names lists a `blocker` / `major` with neither a fix nor a reason — each round's in that round's `### Fixes applied` — that is `/10x:work`'s job.

`pr: MERGED <url>` means the PR was merged since the last run: once the `gh auth status` and uncommitted-changes checks pass, go straight to Step 4, whatever `security entry open:` lines `check` printed (`sync-base`, then `rm`) — no `review.md` check, rebase, verify, push or `10x-land pr`. Any other `pr:` line (`OPEN`, `CLOSED`, `none`) goes on as below.

## Step 1 — Rebase onto the current base

```bash
10x-land rebase <id>
```

The base is the branch on `check`'s `base:` line (`base` from the config, else `develop` when origin has it, else origin's default branch). In `local` mode the rebase goes onto the local base when it contains `origin/<base>`, so tickets closed earlier and not pushed yet are kept; when the two have diverged it refuses — stop and leave reconciling the base to the user. On a conflict `10x-land rebase` lists the conflicting files and leaves the rebase: stop, show them, and leave it for the user to resolve (or resolve it with them). Never `git rebase --skip` or drop a commit to get past it.

## Step 2 — Verify the rebased tree

```bash
10x-verify <id>
```

It must pass on the rebased tree. A failure here is new (the base moved): fix it as a commit on the branch, or stop and report it.

## Step 3 — Land it

**`pr` and `pr-merge`:**

1. Push: `10x-land push <id>` — it pushes only the ticket branch, with `--force-with-lease` only when origin already has it.
2. Open the PR against the base: write `.10x/<id>/pr-title` (one line: the ticket's title, in the repo's commit style, read with `git log -n 5 --oneline` in the main checkout) and `.10x/<id>/pr-body.md`, then run `10x-land pr <id>`. It creates the PR/MR, or, when the branch already has an open one (a previous run that stopped before merging), replaces only its body and refuses a PR whose base is not the configured base, and refuses a branch whose PR is already merged. Body:
   - the plan's goal and acceptance criteria as a checklist, the final `10x-verify` table, the review verdict with what was done about each finding, and `Closes #<n>` for a `gh-<n>` ticket or the ticket's URL for any other source.
   - When `check` printed `pr template: <path>`, read `<worktree>/<path>` (the worktree from `10x-worktree path <id>`) with the Read tool and fill its sections with this content instead of using this layout, copying its `##` heading lines verbatim. When `10x-land pr` refuses because `pr-body.md` lacks sections of the template, add them to `pr-body.md` and run `10x-land pr <id>` again.
3. `pr-merge` only: state the PR URL, then `10x-land merge <id>` — a squash merge without the delete-branch flags: `gh` would remove the worktree and branch behind 10x's back; Step 4 removes both, local and remote. It refuses a PR whose base is not the configured base. On exit 0 go to Step 4. Otherwise, by exit code:
   - **3** — checks still running or not registered yet. Wait for them in the background, never in a foreground polling loop:

     ```bash
     10x-land wait <id>
     ```

     Run it with `run_in_background`; you are woken when it exits. Exit 0: run `10x-land merge <id>` again and act on its exit code the same way. Exit 1 (a check failed, or still pending after 30 minutes) or 2 (a refusal): stop, report the PR URL and the checks it named; the worktree stays.
   - **4** — `origin/<base>` moved since the rebase: go back to Step 1 (rebase, verify, push, `10x-land pr <id>` to refresh the body) and merge again. At most 3 rounds of rebase in all; after the third, stop and report the PR URL.
   - **2** — failed checks or any other refusal: stop, report the PR URL and what it named.

   Never merge around a refusal.

   `10x-land pr`, `squash` and `comment` refuse text that names an entry of `.10x/security.md` — its fingerprint, title or `path:line` — naming only the file or commit and the fingerprint. For `pr-title`, `pr-body.md` or `commit-msg`, rewrite the text without it and run the command again; a commit message on the branch is the user's to reword — stop and name the commit. Never remove or re-set an entry to get past the refusal.
4. `pr`: report the PR URL and stop. The worktree stays until the PR is merged.

**`local`:**

1. Write `.10x/<id>/commit-msg` — the squash commit's message: the ticket's title in the repo's commit style (`git log -n 5 --oneline` in the main checkout), then a blank line and a short body when it helps. For a `gh-<n>` ticket `10x-land squash` adds `Closes #<n>` itself (before a closing trailer block), so `commit-msg` need not carry it.
2. `10x-land squash <id>` — one commit on the base with the branch's tree, applied in the main checkout with `git merge --ff-only` if it is on the base branch (uncommitted changes to files the ticket does not touch are kept), otherwise by updating the base ref. A refusal that says the base moved means go back to Step 1; one that names uncommitted changes in the main checkout is the user's to commit or stash — stop and show it, never stash, reset or discard them yourself.
3. Go to Step 4.

## Step 4 — Clean up after the merge

Only once the branch is merged (squash-merged PR, or the local squash). After a merged PR (`pr-merge`, or `pr` on its cleanup run) bring the main checkout's base up to date first; skip `sync-base` in `local` mode, whose base is already ahead:

```bash
10x-worktree sync-base
10x-worktree rm <id>
```

`sync-base` fast-forwards the base only when the main checkout is on it and `git merge --ff-only` allows it — uncommitted changes to files the incoming commits do not touch are kept; otherwise it leaves the base and says why. Never pull, reset or switch branches in the main checkout to make it go through.

It removes the worktree and deletes the branch once its changes are on the base — merged as git sees it, or squash-merged (every file it touched is identical on `origin/<base>`, or on the local base after a local squash) — along with the pushed branch on origin if a merged PR left it behind. A branch whose changes are not on the base is kept and reported; never delete it yourself. Keep `.10x/<id>/` — it is the ticket's record.

## Step 5 — Report

What landed and where (PR URL or base commit), the final verify table — on a cleanup run, which runs no verify, the merged PR's URL instead — what `sync-base` did to the local base (fast-forwarded to which commit, or left behind and why), and what was cleaned up or left.

## Replies

- Lead with the result. No first sentence that announces what comes next, and no closing recap or offer.
- Between routine tool calls, at most one line per phase change — a phase is one of this skill's numbered steps.
- Say each fact once: what the reply has already shown is not summarised again.

Some things are exempt from these rules and are written in full: a security warning; an irreversible action, both its warning and the statement made before acting on it, such as `/10x:close` stating the PR URL before it merges; a question to the user; and anything persisted — code, commits, issue and PR bodies, and the files under `.10x/`.

The final reply is Step 5's report.

## Never

- Never land a branch whose rebased tree did not pass `10x-verify`.
- Never force-push (except `10x-land push`'s `--force-with-lease`), and never push the base branch in `local` mode.
- Never resolve a rebase conflict by dropping commits or `--skip`.
- Never remove a worktree before its branch is merged.
- Never merge in `pr` mode — that is the human's click.
- Never reply that something is unverified, unchecked or not yet confirmed: check it first. Only when a check is impossible, say so, naming what was tried and why it cannot be checked.
