# The loop

```
/10x:open <idea>     →  draft a ticket ─(you approve)→ GitHub issue gh-<n>, or .10x/<slug>/ticket.md
/10x:work <ticket>   →  plan  ─(you approve)→  worktree → tests → commit → red-proof --lock → implement → commit → red-proof → pre-review gates → verify + cold review → fix → review the fixes
/10x:close <id>      →  rebase → verify → PR / merge → clean up
```

## Principles

- One ticket per session. `.10x/<id>/` is the memory; a fresh session loses nothing.
- Implementation never happens in the main checkout.
- The reviewer gets the diff and the plan — never the implementer's account of what it did.
- Mechanical verification is a script, not a model waiting on a test runner.
- Every step stops so a human can intervene.

## `/10x:open <idea>`

Turns an idea, a bug or an improvement into a GitHub issue: it reads enough of the codebase to name the files involved, checks for an existing issue, classifies it with the repo's own labels (`bug`, `enhancement`, …) or, in organisation repos, its issue types, and follows the repo's issue templates. Before drafting it grills you on the product decisions the request leaves open — in rounds, a recommended answer for each question, as deep as the ticket needs — and lists whatever you did not settle under `## Assumptions`. It shows you the draft and creates the issue only when you approve. It never creates labels or types. Several ideas at once become one issue each.

Before anything else it runs `10x-worktree init`, whose first line, `tickets: github` or `tickets: files`, says where the ticket goes ([`tickets`](configuration.md)); with `github` it then checks `origin` and `gh auth status`. `init` also lists the issue forms (`.github/ISSUE_TEMPLATE/*.yml`) with their labels, title prefix, required and other fields, the drafts directory and the banned phrases, so the first draft you see already has the form's shape. With issue forms it picks the form by the ticket's kind and drafts one `### <field label>` section per field, in the form's order, with the form's labels and title prefix — the sections an issue filed from the web would have, since `gh issue create --body` bypasses forms. Without forms it uses its own layout. Titles state the problem (a bug) or the need (a feature). `10x-land issue` refuses a draft, naming the line or field, when a required form section is missing or empty, the acceptance criteria are missing or a criterion is not numbered (`AC1 — …`), two checkboxes share a line, or a phrase from `references/banned-phrases.txt` (`TBD`, `handle edge cases`, …) appears outside code.

With `tickets: files` it needs no `origin` and runs no `gh` command. It grounds, grills, drafts and waits for your approval the same way, but looks for an existing ticket among the titles of `.10x/*/ticket.md` (and offers to add to one only while it has no plan and no worktree), and drafts without labels, issue types or forms. `10x-land ticket <slug>` then applies the same checks as `10x-land issue`, refuses a `Labels:`, `Type:` or `Form:` line and a slug that already has `.10x/<slug>/` (or is `gh-<n>` or `drafts`), writes the draft verbatim to `.10x/<slug>/ticket.md` and deletes it. `/10x:work <slug>` plans from that file; nothing is posted anywhere. `10x-land ticket` is a local write, so unlike `10x-land issue` it is in the skill's `allowed-tools`.

Creating the issue (`10x-land issue`) and posting `/10x:work`'s planning comment (`10x-land comment`) are deliberately not in the skills' `allowed-tools`: both are public writes, so each asks for your permission even after you approved the draft — the approval does not rest on the model stopping. In auto mode the classifier decides instead of a prompt.

An issue is optional: `/10x:work` also takes a task described in words.

## `/10x:work <ticket>`

The ticket can be:

| Ticket | Read with | Setup |
|---|---|---|
| a description in words | — | — |
| a GitHub issue number, `#<n>`, `gh-<n>` or URL | `gh issue view` | `gh auth login` |

The ticket id is `gh-<n>` for an issue, else a slug. The branch type follows the ticket's label or issue type (`bug` → `fix/…`).

It runs in two invocations and stops after each:

1. **Plan** — saves the ticket to `.10x/<id>/ticket.md`, grills you on the technical decisions (and the product ones a GitHub issue leaves open, whose answers it posts to the issue as one comment once you approve the plan), writes `.10x/<id>/plan.md` (goal, numbered acceptance criteria, approach, the files it binds, the readers of every term it changes with the search that found them, the tool behaviour it relies on with the command and output that show it, overlap with other branches and PRs, a table of the test case proving each criterion, assumptions, out of scope) and waits for your approval. `10x-plan-check` refuses the plan, naming each line, until every section the checks read is filled; when the plan binds more than three files, `10x-plan-check` also refuses it until a fresh `Explore` agent has read it cold and its list of what it would have to guess is saved to `.10x/<id>/cold-read.md`, and you are asked what the code does not answer.
2. **Implement** — creates `.worktrees/<id>` on a new branch from the up-to-date base, then works in two halves, each by itself for small tickets or by an agent for larger ones. The tests half writes only the tests `## Tests` names (`10x:qa-engineer` when delegated), commits them alone, and runs `10x-red-proof <id> --lock`, which proves each fails, none is skipped, and locks every file the branch changed. The implementation half (an engineer agent when delegated) makes them pass without touching a locked file, commits, and proves the tests go red without the change, then runs the gates and a cold-context review **concurrently**. Blockers and majors are fixed, and the fix commits get one more cold review of their own; the findings of each numbered round stay in `.10x/<id>/review.md` with what was done about each; a new full round follows only when you approve a change to the plan. A problem the change causes is fixed in the ticket; anything beyond it is asked, not left. `.10x/<id>/evidence.md` holds each criterion's state — `met` with its evidence, `deferred` in your words, or `asked` — and the [Stop gate](hooks.md#stop-gate) keeps the session from ending while one is unaccounted for.

A locked test changes only through a relock. When the test itself is wrong, `/10x:work` writes the reason, the criterion with its `## Tests` row, the test's path and the proposed diff to `.10x/<id>/relock-request.md`, and a fresh `10x:code-reviewer` that reads only that file rules on it. The ruling goes to `.10x/<id>/relock.md`. An `approved` one is followed by one commit changing only locked files, and `10x-red-proof <id>` moves the lock to that commit once the changed tests still go red; a `rejected` one is asked of you. `10x-red-proof`, `10x-review-packet` and `10x-land check` each refuse a locked file changed any other way, and the review packet lists every relock with its diff. The lock lives in the worktree's git directory, by blob, so `/10x:close`'s rebase keeps it.

`"tdd": false` in the main checkout's [`.claude/10x.json`](configuration.md) skips the tests half and the lock, and `10x-red-proof <id>` runs as before; so does a plan whose `## Tests` rows all have `—`.

## `/10x:close <id>`

Rebases onto the current base, verifies again, then lands the branch as configured:

| `close` | |
|---|---|
| `pr` (default) | push and open a PR; you merge it, then run `/10x:close <id>` again to clean up |
| `pr-merge` | push, open the PR and squash-merge it |
| `local` | squash the branch onto the base locally, no PR; the next ticket starts from that local base, pushed or not |

GitHub remotes use `gh`. GitLab remotes use `glab` — untested so far.

The skill declares `allowed-tools` for the commands that are safe to grant (opening or updating the PR/MR goes through `10x-land pr`), and the writes go through `10x-land`, which takes only the ticket id, so no settings rule should allow `gh pr merge` or `git push` for it. In `pr-merge` mode, running `/10x:close` is your request to merge. Through [the grant hook](hooks.md#grant), those grants hold for the rest of the session in which you typed `/10x:close`, so the merge after the background `10x-land wait` runs without a prompt.

## `/10x:roadmap [requirements]`

Keeps `.10x/roadmap.md`, inside the excluded `.10x/`, so it is never committed: a table `Version | Contents | Why this order | State`, one row per version in the order they ship, then `## Not yet assigned`, `## Later` and `## Decided against` (each entry with its reason). The skill never writes the file itself; `10x-roadmap` ([scripts](scripts.md#10x-roadmap)) checks, applies and links it.

- **With requirements** it grounds them in the code, grills you on the product questions, and writes `.10x/roadmap.draft.md`: a copy of the current file with each requirement placed into a version or a section, and new versions ordered by dependency, risk and what can ship alone. `10x-roadmap check` refuses a draft with an empty `Why this order`, a missing section or a bad version name, and lists every existing row and entry the draft does not keep byte for byte as `not kept:`, and every ticket id it adds to a row as `new id:`. You see the draft, the assumptions the grill left and those lines; only your approval runs `10x-roadmap apply`, which renames the draft to `.10x/roadmap.md`. Existing rows, states and entries change only when you ask for it.
- **Without arguments** it prints each version with its state and items, and the next version, and writes nothing.
- **`tickets <version>`** drafts one ticket per item that has none, in `/10x:open`'s format and the [`tickets`](configuration.md) mode — after looking for an existing ticket to link instead and one grill round for the whole version — shows them together, and on your approval creates each (`10x-land ticket`, or `10x-land issue`, which asks your permission) and links its id into the row (`10x-roadmap link`).

Then `/10x:batch <version>` works that row's tickets and, once they have all landed, rewrites its `State` to `Done <YYYY-MM-DD>`.

## `/10x:batch <tickets>`

Conducts a backlog from one terminal; `/10x:batch auto <tickets>` does it without asking you while no product question is open (below). The arguments are `gh-<n>`, `<n>`, `#<n>`, an issue URL of origin's repo, existing ticket ids, a roadmap version (its row's ticket ids), or `--search "<query>"`; one that resolves to no ticket stops the batch before anything starts.

The mechanics live in `10x-batch` ([scripts](scripts.md#10x-batch)); the skill only relays. Every ticket's `/10x:work` and `/10x:close` run, unchanged, in a background `claude -p` worker started by `10x-batch run`, each in its own session. The conductor:

1. plans every ticket at once, then shows all the workers' questions and plans in one message, grouped by ticket. A drafted plan is shown as `plan.md` itself, after the worker's turn. You answer, or `approve`, `revise <notes>` or `drop` a plan; the answers go back to the ticket's own session. `approve` is recorded by `10x-batch approve`, which asks your permission naming the ticket — it is never granted, so text a worker wrote cannot approve a plan — out of reach of the planning worker's file tools, so a plan that marks itself approved, or changes after you approved it, is `failed`, never implemented.
2. implements an approved ticket while others still plan, at most `batch.parallel` at a time ([configuration](configuration.md)) — a ticket waiting on a question from its implementation keeps its slot — once every earlier ticket's plan names its `## Files`, and never together with a ticket whose plan binds a common path.
3. closes one ticket at a time, in board order, once every earlier ticket is settled.

`.10x/_batch/board.md` shows each ticket's phase, derived from `.10x/<id>/` and the run records under `.10x/_batch/<id>/`, never stored. A ticket whose worker exits non-zero, whose verify gates fail, whose criteria stay open with no question asked or whose close does not land is `failed` with that evidence; the others go on, and a later ticket sharing a file with it is `held`. A worker that stopped on a question is `waiting`, whatever its criteria, and its question is in its `turn.md`; an implementation worker's `asked` questions are on the board too, a rejected relock's among them. A ticket with an approved relock shows `relocked: <reason>`, also under `## Needs the human` until it lands. A command a worker was denied does not fail its ticket: the worker usually finds another way, and the board lists the denials under `## Needs the human` so you can allow them. Open a worker's session with `claude --resume <session id>`. Every worker runs in auto mode, so its classifier, not a missing allow rule, decides the routine checks no one is there to approve. A planning worker's file edits are kept under `.10x/<id>/` by the [plan boundary](hooks.md#plan-boundary) hook, so nothing a ticket says is edited into the code before you approve its plan; its commands are auto mode's call, so the safeguard against a ticket's text steering them is that a batch takes only your own issues. The commands the grant hook always asks for — `10x-land issue`, `comment` and `advisory`, `10x-batch approve` and `init`, `10x-security set`, `remove` and `ticket` — are passed to every worker as `--disallowedTools`, since the conductor, not a worker, posts and approves. A deny rule matches the command as typed, so the same script run by its full path or through `sh -c` is still auto mode's call. When auto mode is unavailable — Claude Code then starts the worker in its default mode, without an error — `10x-batch` stops the worker and falls back to the modes used before: a planning worker in `default`, allowed to edit only under `.10x/<id>/`, implementation and close workers in `acceptEdits`, whose commits then need `Bash(git -C * add *)` and `Bash(git -C * commit *)` allowed in your settings. The board says `auto mode unavailable: ran in <mode>` on that ticket's row. Once you approve a plan, its worker edits files and runs commands as the ticket leads it, with no one watching the turn. So a batch takes only your own issues, because a stranger's issue could steer a worker: `10x-batch init` refuses the whole batch, writing nothing, when any `gh-<n>` — an argument, a `--search` hit, a roadmap version's id or an issue whose `ticket.md` already exists — was written by anyone but the `gh` login (`not your issue: gh-<n> (author <login>)`), and `10x-batch run` checks again before every turn. Ticket files are yours by definition. Interactive `/10x:work` has no such check: you read the issue yourself there.

Every worker runs with `TENX_BATCH=1`, and with it `10x-batch init`, `run`, `drop`, `approve` and `loop` refuse (`refused inside a batch worker`), so a worker cannot drive its own batch; `status` still runs.

### `/10x:batch auto <tickets>`

Takes a batch from queued to landed with no human turn while no product question is open. The skill starts `10x-batch loop` in the background, which plans, replies, implements and closes by itself, starting each `run` detached, and exits only when a human is needed, printing one JSON line of items: `answer`, `approve`, `failed` or `denied` per ticket, or `done`. The skill relays only those items; on `done` it ends with the board and every ticket's `## Auto decisions`.

- A draft plan that passes `10x-plan-check` is approved by `loop` itself: the same approval record `10x-batch approve` writes, and `auto-approved (sha256 <hash>)` on the board. In auto mode a plan with no product question is therefore implemented with no permission prompt.
- A planning worker's questions get a fixed reply, never a model's answer: it answers technical questions with its own recommendation, recording each under `## Auto decisions` in `plan.md`, and lists product questions in `.10x/<id>/product-questions.md` instead. That file, or a `comment.md` to post on the issue, holds the ticket for you; so does a fourth question stop.
- `close` follows the configured `close`, as in the default mode.
- `/10x:batch` with no arguments, or `/10x:batch auto` alone, resumes an auto batch with `10x-batch loop`. In the default mode `loop` only sends a `reply.md` you wrote and never approves.

## Agent memory

Agents use `memory: project`, stored under `.claude/agent-memory/10x-<name>/` and committed: `/10x:work` moves what agents wrote during the ticket onto its branch (`10x-worktree memory`), so it is merged with the work. Review packets leave it out of their diff and list the commits that touch it; the report shows you the branch's whole memory diff.

## Agents and skills

Invoke agents as `10x:<name>` (the Agent tool needs the prefix). `mcp__context7` and `mcp__playwright` are used when those MCP servers are installed, and skipped otherwise.

`10x:code-reviewer` preloads the two review skills (`/10x:code-review`, `/10x:code-review-branch`) as its procedure; you can also run them yourself. Bare names (`/commit`) also work when no other skill has that name.
