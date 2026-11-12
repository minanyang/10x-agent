---
name: batch
description: Conduct a backlog from one terminal — each ticket runs /10x:work then /10x:close in its own background worker, and the user answers grills and approves plans in batched rounds. Use when the user runs /10x:batch <tickets> or /10x:batch auto <tickets>.
disable-model-invocation: true
allowed-tools:
  - Bash(10x-batch init *)
  - Bash(10x-batch run *)
  - Bash(10x-batch replan *)
  - Bash(10x-batch loop)
  - Bash(10x-batch status)
  - Bash(10x-batch drop *)
---

# Conduct a batch of tickets

`/10x:batch <tickets>` works through many tickets from this terminal. You relay: `10x-batch` schedules, records and lands the tickets, each in its own background `claude -p` worker, and you carry the workers' turns to the user and the user's answers back.

Run one command per Bash call — no `&&`, `;` or `|` — so each call matches this skill's `allowed-tools` on its own.

## Step 0 — Start or resume

With arguments (`gh-<n>`, `<n>`, `#<n>`, an issue URL, existing ticket ids, `--search "<query>"`), run:

```bash
10x-batch init <args>
```

With none, run `10x-batch status`. An exit 2 from either is a stop: quote its `10x-batch:` line and ask the user how to go on.

A first argument `auto` always means auto mode, so a ticket named `auto` is written `/10x:batch auto auto`:

- `auto` followed by tickets: run `10x-batch init --auto <tickets>`, then go to Step 4.
- `/10x:batch auto` alone, with no tickets, or no arguments when the board `status` printed says `mode: auto`: go to Step 4, which resumes with `10x-batch loop`.

## Step 1 — Act on `status`

```bash
10x-batch status
```

`status` prints the board, then the actions allowed now, one per line: `plan <id>`, `implement <id>`, `close <id>`, `answer <id>` (` approvable` appended when `approve` is allowed), and `done`.

Start every `plan`, `implement` and `close` action as `10x-batch run <id> <kind>` with `run_in_background` and `timeout: 7200000`, all the actions of one `status` in one message, then end your turn. When a run wakes you, run `10x-batch status` again.

A refused `10x-batch run` (a permission or the schedule) is reported to the user as it was printed. Never work around it, and never retry it differently.

A ticket the board lists as `failed` under `## Needs the human` is shown with its evidence and the choices `replan` and `drop`. On the user's `replan` for that ticket, start `10x-batch replan <id>` with `run_in_background` and `timeout: 7200000`, like a `run`: it sends the ticket back to planning on its existing `plan.md`, with its approval revoked, and it ends `waiting`.

The board's `## Hand checks pending` section lists each criterion a landed ticket left for the user to check by hand, `- <version> — <id> AC<n>: <text>` (`(no version)` for a ticket in no recorded version), earlier batches' tickets of the same version included. It is not an action and never holds the batch, but a version is not marked `Done` while it lists one. When the user says a check passed, run `10x-batch checked <id> AC<n> "<what you saw>"` with their words; the ticket need not be in this batch. It is not in this skill's `allowed-tools` on purpose: each record asks the user's permission. A check that failed is not reopened: it is a new ticket, opened with `/10x:open` and linked into the same version with `/10x:roadmap`, and the original stays pending until the user runs it again.

## Step 2 — Rounds of answers

When `status` lists `answer` lines, Read each such ticket's `.10x/_batch/<id>/turn.md` and show them all, grouped by ticket, in one message. For an `approvable` one, also Read `.10x/<id>/plan.md` and show the lines above its `# Appendix` line — the first line that is exactly `# Appendix` outside a code fence; an approvable plan has passed `10x-plan-check`, so there is one — verbatim after its turn, under its path, and tell the user the appendix is in that file and they can open it themselves before approving: the user approves the plan, not the worker's account of it. Give the choices per ticket: answers to its questions, or, for an `approvable` one, `approve`, `revise <notes>` and `drop`; when the message shows two or more `approvable` tickets, also offer `approve all`. Wait for the reply; it may cover several tickets.

Write each ticket's reply to `.10x/_batch/<id>/reply.md`, then start `10x-batch run <id> reply` in the background (same flags as Step 1):

- answers: the user's words for that ticket, verbatim.
- `approve`: run `10x-land comment <id>` first when `.10x/<id>/comment.md` exists (left to the user's permissions), then `10x-batch approve <id>`, which records the approval and writes the reply itself. It is not in this skill's `allowed-tools` on purpose: each approve asks the user's permission, naming the ticket, so text a worker wrote can never approve a plan. Only the user's `approve` for that ticket, or their `approve all` (below), starts it.
- `approve all`: run `10x-land comment <id>` for each approvable ticket shown in that message that has `.10x/<id>/comment.md`, then one `10x-batch approve <id> <id>…` naming exactly the approvable tickets shown in that message. Leave out of it a ticket whose comment was denied or failed, and report it. `approve` records nothing when any id is refused: an exit 2 is quoted, and the user asked how to go on, as in Step 0.
- accepting a `GREEN` file: when a worker's `asked` line asks to accept a `GREEN` test file and the user says yes for that file, run `10x-batch accept-green <id> <file> "<reason>"`, with the user's reason, then write "Accepted GREEN for <file>, recorded by the user. Run 10x-red-proof <id> again and go on." as the reply. It is not in this skill's `allowed-tools` on purpose: each acceptance asks the user's permission, and in a batch red-proof reads the record it writes in the state directory, not the worker's `.10x/<id>/accepted-green.md`.
- `revise <notes>`: write "Revise the plan: <notes>". Show its next turn on its own, not in a round.
- `drop`: run `10x-batch drop <id>`.

## Step 3 — Done

On `done`, end with the board.

## Step 4 — Auto mode

Start `10x-batch loop` with `run_in_background` and `timeout: 7200000`, then end your turn. It plans, approves a plan with no product question, implements and closes by itself, and exits when a human is needed. When it wakes you:

- No JSON line (it was stopped at its limit): start `10x-batch loop` again the same way.
- Exit 2: quote its `10x-batch:` line and ask the user how to go on.
- Otherwise read its one line, `{"items":[…]}`, and relay only the items it printed, grouped by ticket, in one message:
  - `answer`: Read and show `.10x/_batch/<id>/turn.md`, and `.10x/<id>/product-questions.md` when it exists.
  - `approve`: as in Step 2 — show the turn and the lines of `plan.md` above its `# Appendix` line verbatim, under its path; on the user's `approve`, `10x-land comment <id>` when `.10x/<id>/comment.md` exists, then `10x-batch approve <id>`, which still asks permission; `approve all` as in Step 2.
  - `failed`: show its evidence and offer `replan` and `drop`, as in Step 1.
  - `denied`: show its evidence, for the user to decide on.

After the user's reply, write each `reply.md` or approve as in Step 2, then start `10x-batch loop` again (not `10x-batch run`). After a background `replan`, end your turn instead, and start `10x-batch loop` again only when the replan wakes you: a `loop` started before the replan's run is recorded would report the ticket `failed` again and exit.

On `done`, run `10x-batch status`. The final reply is the board, then, for each ticket under its id, the `## Auto decisions` section of `.10x/<id>/plan.md` verbatim, or `(none)` when the plan has no such section.

## Replies

- Lead with the result. No first sentence that announces what comes next, and no closing recap or offer.
- Between routine tool calls, at most one line per phase change — a phase is one of this skill's numbered steps.
- Say each fact once: what the reply has already shown is not summarised again.

Some things are exempt from these rules and are written in full: a security warning; a question to the user; a worker's turn shown to the user; and anything persisted, such as `reply.md`.

The final reply is the board; in auto mode, followed by each ticket's `## Auto decisions` (Step 4).

## Never

- Never run `/10x:work` or `/10x:close` yourself, and never edit anything but `.10x/_batch/<id>/reply.md`.
- Never run `10x-batch approve` for a ticket the user did not approve in their own words — `approve all` covers only the approvable tickets shown in the message it answers — nor `10x-batch accept-green` for a file the user did not accept in theirs.
- Never run `10x-batch checked` for a hand check the user did not report as passed in their own words.
- Never run `10x-batch replan` for a ticket the user did not ask to replan in their own words.
- Never use `CronCreate`, `ScheduleWakeup` or `/loop`; background runs wake you.
- Never reply that something is unverified, unchecked or not yet confirmed: check it first. Only when a check is impossible, say so, naming what was tried and why it cannot be checked.
