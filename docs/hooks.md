# Hooks

10x Agent registers four hooks while the plugin is enabled.

## Guard

Blocks destructive Bash commands: `rm -rf`, force push (`--force-with-lease` is allowed), `git reset --hard`, `git clean -f`, `git branch -D`, `git checkout -- .`, package publishing, raw disk writes. It is **best-effort, not a sandbox**: it matches the command text, so a script, alias or `eval` gets past it, and a command that merely contains such a string (in a heredoc, say) is blocked too. If a project ships its own guard at `.claude/scripts/guard-bash.sh`, 10x Agent's steps aside.

## Context gate

Refuses `/10x:work` and `/10x:close` when the session already carries more than `contextGate.maxTokens` ([configuration](configuration.md)), and asks for `/clear` first.

## Stop gate

A session owns a ticket once it runs `10x-worktree add <id>` or types `/10x:work <id>` for an approved plan (the latest session to bind it owns it). While the ticket's worktree exists, the session cannot end a turn while `.10x/<id>/evidence.md` misses a criterion, leaves one `pending`, or has an `asked` question that is not in the turn's last message.

In a session that typed `/10x:open`, `/10x:work`, `/10x:close`, `/10x:batch` or `/10x:roadmap`, and for `10x:code-reviewer` and `10x:security-reviewer`, it also refuses a last message that calls something unverified, unchecked or not yet confirmed (English or Chinese, outside code).

It blocks once per stop, lets the turn end while background tasks run, and fails open on its own errors. Session bindings live in `.10x/.sessions/`.

## Grant

Claude Code applies a skill's `allowed-tools` only to the turn in which you typed it: the turn a background task wakes (close's merge after `10x-land wait`, work's steps after the gates or reviewers finish), a later turn of the same session (work after you say "approved, go") and a `--resume` turn fall back to your normal permissions, so the loop would stop to ask, or be refused under `claude -p`.

When you type `/10x:open`, `/10x:work`, `/10x:close`, `/10x:batch` or `/10x:roadmap`, the hook records that skill's `Bash(...)` grants as its `SKILL.md` lists them at that moment, and allows a single command (no `;`, `&`, `|`, `<`, `>`, `$`, backtick or newline) matching one of them for the whole session in which you typed the skill — not in subagents, and not another skill's grants. `/10x:batch`'s `10x-batch init *` is the exception: only the typed turn runs it, so a later turn cannot start a batch you never named. `/10x:roadmap` binds no ticket: it creates one ticket per item of a version, so its `10x-land ticket` grant holds for every slug. `10x-land issue`, `10x-land comment`, `10x-batch approve` and `10x-batch init` are never allowed by the hook, whatever a session's record holds.

Only a skill you typed (or passed to `claude -p`) counts: the hook confirms the prompt against the session's transcript before its first grant, so a prompt you did not type — a scheduled (`CronCreate`) one naming the skill, say — grants nothing.

A 10x Agent script run on a ticket (`10x-land`, `10x-worktree`, `10x-verify`, `10x-red-proof`, `10x-review-packet`, `10x-plan-check`, `10x-test`) is allowed only for the ticket you typed the skill for — `/10x:work 53` binds `gh-53`; a task in words binds the first ticket the skill works on.

`10x-verify`, `10x-review-packet`, `10x-red-proof` and `10x-test` run the commands in that worktree's `.claude/10x.json`, so an edit to that file runs without a prompt the next time they run in the session; likewise, with 10x Agent loaded through `--plugin-dir` from a checkout inside the working directory, an edit to its `bin/` scripts runs unprompted under the grants.

"Typed" means what the transcript records as your input: a prompt another program types into the session's terminal, or the opening prompt of a teammate session a model starts, counts as typed if Claude Code records it so.

Records live in `${CLAUDE_PLUGIN_DATA}/sessions/`, outside the repo, so the agent cannot write itself one without asking. For the loop to finish unattended you need to allow nothing for the skills' grants; `10x-land issue`, `10x-land comment` and `10x-batch approve` still ask by design.
