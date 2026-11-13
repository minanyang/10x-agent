<div align="center">

# 10x Agent

A multi-agent workflow for shipping code: agents plan, build and review, and nothing lands without evidence a script can check.

[![Release](https://img.shields.io/github/v/release/minanyang/10x-agent)](https://github.com/minanyang/10x-agent/releases/latest) [![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE) [![Claude Code plugin](https://img.shields.io/badge/Claude_Code-plugin-D97757)](https://code.claude.com/docs/en/plugins)

**English** · [繁體中文](README.zh-TW.md)

</div>

Each ticket is planned with you, built in its own worktree, verified by scripts and reviewed by an agent that never saw it built — then merged. 10x Agent is a Claude Code plugin; a Codex edition is planned.

## Why

Left to itself, a coding agent:

- **reports work done without verifying it** — "tests pass" because it says so, not because they ran;
- **works from a vague plan** — what counts as done, which files it touches and what else depends on them are never written down;
- **merges with nothing checking it** — the same context that wrote the change judges it.

10x Agent turns each ticket into a loop that does not take the agent's word:

- one ticket per session, with everything the next session needs in `.10x/<id>/`;
- implementation in its own worktree, never in the main checkout;
- a plan with numbered acceptance criteria, checked by a script before you see it;
- verification by scripts — the project's gates, and new tests that must fail without the change;
- review by an agent that gets the diff and the plan, never the implementer's account;
- a stop at every step, so you can intervene.

## The commands

```
/10x:open <idea>     →  draft a ticket ─(you approve)→ GitHub issue gh-<n>, or .10x/<slug>/ticket.md
/10x:work <ticket>   →  plan  ─(you approve)→  worktree → tests → commit → red-proof --lock → implement → commit → red-proof → pre-review gates → verify + cold review → fix → review the fixes
/10x:close <id>      →  rebase → verify → PR / merge → clean up
/10x:roadmap [reqs]  →  order requirements into versions; /10x:batch <version> runs one
/10x:audit           →  run the installed security-audit skill on a scope; merge its findings into .10x/security.md and settle each one
/10x:batch <tickets> →  work and close many tickets from one terminal, each in a background worker
/10x:feedback <what> →  draft a bug report or feature request for 10x Agent ─(you approve)→ issue on minanyang/10x-agent
```

**`/10x:open <idea>`** turns an idea, a bug or an improvement into a GitHub issue in the repo's own issue forms, labels and types — or, with `tickets: files`, into a ticket file under `.10x/` that stays on your machine. It asks the product questions the idea leaves open, shows the draft, and creates the ticket only on approval.

**`/10x:work <ticket>`** takes an issue or a task in words. It asks the technical questions, plans acceptance criteria, the files it binds and a test per criterion, and stops for your approval. Then, in a worktree, it commits and locks failing tests, implements, runs the gates and a cold review together, fixes the findings, and reports. A locked test changes only through a relock a fresh reviewer approves; `"tdd": false` disables it.

**`/10x:close <id>`** rebases, verifies again and lands the branch as one squash commit — a PR you merge, a PR it merges once checks pass, or a local merge — then cleans up.

Every step in detail: [docs/loop.md](docs/loop.md).

## Install

```
/plugin marketplace add minanyang/claude-plugins
/plugin install 10x@minanyang
```

Requires `git` and `node` (18+). GitHub issue tickets (`tickets: github`, which `/10x:open` then files) and the `pr` / `pr-merge` close modes also need [`gh`](https://cli.github.com) logged in (`gh auth login`), or [`glab`](https://gitlab.com/gitlab-org/cli) for GitLab; without it, `tickets: files` and `close: local` still work. 10x Agent checks before it pushes and names what is missing.

### Quick start

```
/10x:open add a --json flag to the export command
/10x:work 12
/10x:close gh-12
```

1. `/10x:open` asks its questions, shows the draft, and creates the issue (say #12) on approval.
2. `/10x:work 12` plans ticket `gh-12` and stops. Read the plan, answer or approve, then run `/10x:work gh-12` again (or say "go") to build it.
3. `/10x:close gh-12` lands it. By default it opens a PR; once you merge it, run `/10x:close gh-12` again to clean up.

Optional settings — base branch, gates, close mode, where tickets live — live in `.claude/10x.json`: see [docs/configuration.md](docs/configuration.md). `tickets` is `"github"` (GitHub issues) or `"files"` (`.10x/<slug>/ticket.md`, never pushed); without it, a repo whose `origin` is on github.com gets `github` and any other gets `files`. It is independent of `close`: a repo can keep its ticket files off GitHub and still land them by PR, though in PR modes the PR body carries the plan's goal and acceptance criteria.

## Batch

`/10x:batch gh-12 gh-13` or `--search "label:bug"` plans all tickets and asks in one round. `.10x/_batch/board.md` shows each ticket's phase, session and outcome.

- `batch.parallel` caps implementation workers (default `2`); tickets land one at a time.
- `claude --resume <session id>` opens a worker.
- `/10x:batch auto <tickets>` approves plans with no product question itself; batches take only your own issues, because a stranger's could steer workers.
- Allow `Bash(git -C * add *)` and `Bash(git -C * commit *)` ([caveat](tests/e2e/README.md)); the board lists other denials.
- In `pr` mode, tickets sharing files give overlapping PRs; above 1, agent memory lands on several branches.

## What's inside

### Agents

Invoke as `10x:<name>` (the Agent tool needs the prefix).

| Agent | Does | Does not |
|---|---|---|
| `10x:frontend-engineer` | UI changes in the project's existing frontend stack | backend, infra |
| `10x:backend-engineer` | APIs, data access, server-side logic | UI, infra |
| `10x:devops-engineer` | CI/CD, containers, IaC, deploy config | application code |
| `10x:qa-engineer` | test design, reproducing bugs, flaky-test triage | production fixes |
| `10x:code-reviewer` | cold-context review; reports only findings it is ≥ 80% confident in, read-only | fixes |
| `10x:security-reviewer` | security review, threat modelling, dependency audit, read-only | fixes |

### Skills

| Skill | Does |
|---|---|
| `/10x:open` | Draft a ticket — a GitHub issue, or with `tickets: files` a file under `.10x/` — and create it on approval |
| `/10x:work` | Plan a ticket, then build, verify and review it in a worktree |
| `/10x:close` | Rebase, verify, land and clean up |
| `/10x:audit` | Run the installed Cloudflare `security-audit` skill on a scope (a diff, paths or the whole repo) and merge its findings into `.10x/security.md`, so a re-run never triages the same issue twice; then settle each new or deferred entry with you and open a local ticket for each `fix-now` |
| `/10x:roadmap` | Order requirements into versions in `.10x/roadmap.md`, each with the reason for its place, once you approve; turn a version into one ticket per item, which `/10x:batch <version>` works and marks `Done`. Offers deferred `confirmed` entries of `.10x/security.md` as requirements; `10x-security route` picks how each security ticket is opened: a local ticket with `tickets: files`, an issue for a private repo or an unreleased or minor entry, and for a released `medium`-or-worse entry in a public repo a draft security advisory plus a local ticket, never a public issue. `show` ends by suggesting a pre-release `/10x:audit <tag>..HEAD` |
| `/10x:feedback` | From any project, draft a bug report or feature request for `minanyang/10x-agent` in its issue forms, with a generated environment and without the project's name or paths; file it, or a comment on a matching issue, on approval. A vulnerability goes to private reporting, never a public issue |
| `/10x:batch` | Work and close many tickets from one terminal, each in a background worker |
| `/10x:commit` | Commit what this session changed — only those paths, in the repo's own message style. Commits straight away; stops to ask only on a likely secret, unclear scope or unrelated changes. Say "message only" for a draft |
| `/10x:code-review` | Review pending (uncommitted) changes |
| `/10x:code-review-branch` | Review the whole branch against its base |

The scripts the skills run are in [docs/scripts.md](docs/scripts.md).

### Hooks

| Hook | Does |
|---|---|
| Guard | Blocks destructive Bash commands (`rm -rf`, force push, `git reset --hard`, …) |
| Context gate | Refuses `/10x:work` and `/10x:close` in a session already too large |
| Stop gate | Keeps a session from ending while a criterion is unaccounted for |
| Grant | Keeps a typed flow skill's grants for the rest of its session |

Details: [docs/hooks.md](docs/hooks.md).

## Safety and permissions

- **The guard is best-effort, not a sandbox.** It matches the command text, so a script, alias or `eval` gets past it.
- **Public writes always ask.** Creating an issue or advisory and posting the planning comment are not in any skill's `allowed-tools`, so each asks even after you approved the draft. In auto mode the classifier decides.
- **Writes take only the ticket id.** Pushing, opening and merging the PR go through `10x-land`, which builds each command from the ticket id, so no settings rule should allow `gh pr merge` or `git push`.
- **Grants last for the session you typed the skill in.** [The grant hook](docs/hooks.md#grant) allows a single command matching the skill's grants, never in subagents, and runs 10x Agent's scripts only for the ticket you typed the skill for.
- **Some scripts run project code.** `10x-verify`, `10x-red-proof`, `10x-test` and `10x-worktree add` run the project's gates, setup and tests, so granting them equals letting the agent write files in the repo.

## License

10x Agent is released under the [MIT License](LICENSE).

The name 10x Agent refers to this project; please don't use it as the name of a fork or derivative work — saying a fork is based on 10x Agent is fine.
