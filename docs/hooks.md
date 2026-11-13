# Hooks

10x Agent registers five hooks while the plugin is enabled.

## Guard

Blocks destructive Bash commands: `rm -rf`, force push (`--force-with-lease` is allowed), `git reset --hard`, `git clean -f`, `git branch -D`, `git checkout -- .`, package publishing, raw disk writes. It is **best-effort, not a sandbox**: it matches the command text, so a script, alias or `eval` gets past it, and a command that merely contains such a string (in a heredoc, say) is blocked too. If a project ships its own guard at `.claude/scripts/guard-bash.sh`, 10x Agent's steps aside.

## Context gate

Refuses `/10x:work` and `/10x:close` when the session already carries more than `contextGate.maxTokens` ([configuration](configuration.md)), and asks for `/clear` first.

## Stop gate

A session owns a ticket once it runs `10x-worktree add <id>` or types `/10x:work <id>` for an approved plan (the latest session to bind it owns it). While the ticket's worktree exists, the session cannot end a turn while `.10x/<id>/evidence.md` misses a criterion, leaves one `pending`, or has an `asked` question that is not in the turn's last message. A criterion's `hand-check: <what to check>` counts as settled only when the plan's `## Tests` declares it a hand check (`| AC<n> | — | hand check: … |`); on any other criterion the gate blocks, naming that missing row. A `Size: small` ticket with no `plan.md` takes its criteria from `.10x/<id>/ticket.md` instead: the bullets, checkbox or not, under its `## Acceptance criteria` or a form's `### Acceptance criteria`, never from `## Comments` on.

In a session that typed `/10x:open`, `/10x:work`, `/10x:close`, `/10x:batch` or `/10x:roadmap`, and for `10x:code-reviewer` and `10x:security-reviewer`, it also refuses a last message that calls something unverified, unchecked or not yet confirmed (English or Chinese, outside code).

It blocks once per stop, lets the turn end while background tasks run, and fails open on its own errors. Session bindings live in `.10x/.sessions/`.

## Grant

Claude Code applies a skill's `allowed-tools` only to the turn in which you typed it: the turn a background task wakes (close's merge after `10x-land wait`, work's steps after the gates or reviewers finish), a later turn of the same session (work after you say "approved, go") and a `--resume` turn fall back to your normal permissions, so the loop would stop to ask, or be refused under `claude -p`.

When you type `/10x:open`, `/10x:work`, `/10x:close`, `/10x:batch`, `/10x:roadmap`, `/10x:audit` or `/10x:feedback`, the hook records that skill's `Bash(...)` grants as its `SKILL.md` lists them at that moment, and allows a single command (no `;`, `&`, `|`, `<`, `>`, `$`, backtick or newline) matching one of them for the whole session in which you typed the skill — not another skill's grants, and in a subagent only `10x-test <id>…` (as `/10x:work` asks its engineer and QA agents to run it), on the ticket the session's confirmed entry has already bound; a subagent never binds a ticket or confirms an entry. `/10x:batch`'s `10x-batch init *` is the exception: only the typed turn runs it, so a later turn cannot start a batch you never named. `/10x:roadmap` binds no ticket: it creates one ticket per item of a version, so its `10x-land ticket` grant holds for every slug. `/10x:audit` binds no ticket either: its `10x-security prepare` and `10x-security import` grants hold for the session. `10x-land issue`, `10x-land comment`, `10x-land advisory`, `10x-batch approve`, `10x-batch init`, `10x-batch accept-green`, `10x-batch checked`, `10x-security set`, `10x-security remove`, `10x-security ticket`, `10x-feedback issue` and `10x-feedback comment` are never allowed by the hook, whatever a session's record holds.

Only a skill you typed (or passed to `claude -p`) counts: the hook confirms the prompt against the session's transcript before its first grant, so a prompt you did not type — a scheduled (`CronCreate`) one naming the skill, say — grants nothing.

A 10x Agent script run on a ticket (`10x-land`, `10x-worktree`, `10x-verify`, `10x-red-proof`, `10x-review-packet`, `10x-plan-check`, `10x-test`, `10x-security`) is allowed only for the ticket you typed the skill for — `/10x:work 53` binds `gh-53`; a task in words binds the first ticket the skill works on. `10x-security list` and `10x-security route` take no ticket, so they bind none.

`10x-verify`, `10x-review-packet`, `10x-red-proof` and `10x-test` run the commands in that worktree's `.claude/10x.json`, so an edit to that file runs without a prompt the next time they run in the session; likewise, with 10x Agent loaded through `--plugin-dir` from a checkout inside the working directory, an edit to its `bin/` scripts runs unprompted under the grants.

"Typed" means what the transcript records as your input: a prompt another program types into the session's terminal, or the opening prompt of a teammate session a model starts, counts as typed if Claude Code records it so.

While `/10x:close` is the latest 10x skill typed in the session and the main checkout's `.claude/10x.json` has `"close": "local"`, the hook denies any Bash command that runs `gh` or `glab` — at the start, after `;`, `&`, `|`, `(`, `$(` or a backtick, behind `env`, `command`, `exec` or variable assignments, or by a path such as `/opt/homebrew/bin/gh` — with the reason `10x: close is local in .claude/10x.json: /10x:close runs no gh or glab command in local mode`, in a subagent too and whatever the skill grants. It matches the text and is best-effort. Typing another 10x skill ends it; a later `gh` request in the same session is still refused until then, and you can run it yourself with `!gh …`. A record written before this check existed refuses nothing, and so does a missing config or a failing `git` call.

Records live in `${CLAUDE_PLUGIN_DATA}/sessions/`, outside the repo, so the agent cannot write itself one without asking. For the loop to finish unattended you need to allow nothing for the skills' grants; `10x-land issue`, `10x-land comment`, `10x-land advisory`, `10x-batch approve`, `10x-batch accept-green`, `10x-batch checked`, `10x-security set`/`remove` and `10x-feedback issue`/`comment` still ask by design.

## Plan boundary

Keeps a `/10x:batch` plan session's file writes inside its ticket directory. `10x-batch run` sets `TENX_BATCH_PLAN_DIR` to the absolute `.10x/<id>/` for a plan session's worker (a reply to one included) and removes it from every other worker's environment; the worker cannot change the environment its hooks get. With it set, `Edit`, `Write` and `NotebookEdit` are denied — in subagents too — unless the target, with no `..` in it and every symlink resolved, lies under that directory; any error of the hook's own is a deny. Without it — an interactive session, a batch implementation or close session — the hook does nothing. It covers the file tools only: a plan session's Bash is left to auto mode.
