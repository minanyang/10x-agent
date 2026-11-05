---
name: roadmap
description: Keep `.10x/roadmap.md` — an ordered table of versions, each with the reason for its place, plus what is not yet assigned, later or decided against. Merges new requirements into it once the user approves, shows it, and turns a version into one ticket per item for /10x:batch <version>. Use when the user runs /10x:roadmap.
disable-model-invocation: true
allowed-tools:
  - Bash(10x-worktree init)
  - Bash(10x-grill)
  - Bash(10x-roadmap show)
  - Bash(10x-roadmap show *)
  - Bash(10x-roadmap check)
  - Bash(10x-roadmap apply)
  - Bash(10x-roadmap link *)
  - Bash(10x-land ticket *)
  - Bash(10x-security list --plannable)
  - Bash(10x-security route *)
  - Bash(git remote get-url origin)
  - Bash(gh auth status)
  - Bash(gh label list *)
  - Bash(gh issue list *)
  - Bash(10x-ticket issue-types)
---

# Keep the roadmap

`/10x:roadmap [requirements]` keeps `.10x/roadmap.md`: which version comes next, what is in it, and why it comes where it does. The file is inside `.10x/`, so it is never committed. `10x-roadmap` is its only reader and writer: it checks a draft, applies it, links ticket ids and shows the file. This skill never writes `.10x/roadmap.md` itself.

Run one command per Bash call — no `&&`, `;` or `|`. The arguments pick the path:

- None → **Show**.
- Exactly `tickets <name>` → run `10x-roadmap show <name>`. When it prints that version, take **Tickets**; otherwise the arguments are requirements.
- Anything else → **Requirements**.

## The file

```markdown
# Roadmap

| Version | Contents | Why this order | State |
|---|---|---|---|
| v1 | Export as CSV `gh-12`; Export as JSON `gh-13` | Both reuse the existing export path and ship alone | Done 2026-10-20 |
| v2 | Scheduled exports | Needs v1's formats; the riskiest piece, so it waits | Planned |

## Not yet assigned
- Export to S3

## Later
- A web UI for exports

## Decided against
- Excel export — CSV opens in Excel; a second writer to maintain is not worth it
```

- One row per version, in the order they ship. A `Version` is letters, digits, `.`, `_` and `-`, starts with a letter or digit, is unique and is never all digits (`v1`, `0.2`, `beta`).
- `Contents` holds the version's items separated by `; `. An item that has a ticket ends with its id in backticks (`gh-<n>` or a `.10x/<id>/` slug); `10x-roadmap link` adds it, never you. A `|` inside a cell is written `\|`.
- `Why this order` is never empty: why this version comes here — what it depends on, the risk it takes or retires, whether it ships alone.
- `State` is free text (`Planned`, `In progress`); `Done <YYYY-MM-DD>` is written only by `/10x:batch <version>` once all the row's tickets have landed.
- The three sections each appear once, after the table. A `## Decided against` entry gives its reason after ` — `.

## Show

```bash
10x-roadmap show
```

Relay its output as printed — each version with its state and numbered items, then `next:`, then the `audit:` line when there is one (the pre-release audit of what changed since the last tag, or that there is no tag yet) — and stop. A `no roadmap:` line is relayed with the next step, `/10x:roadmap <requirements>`. Write nothing.

## Requirements

### Step 1 — Ground it

```bash
10x-worktree init
10x-roadmap show
```

A non-zero exit from either stops the skill: relay its message. `init` keeps `.10x/` out of git before anything is written there. `show` prints the roadmap as it is now; when it prints `no roadmap:`, the draft starts from the layout above with no rows.

Then list the security entries that can be planned:

```bash
10x-security list --plannable
```

Exit 2 stops the skill: relay its message. Each line is a confirmed `.10x/security.md` entry with status `later` that the roadmap does not name yet. Show them next to the user's requirements, each as `<fp> <severity> <title>`, and ask which to plan; a request such as "plan the security entries" is itself a requirement. No line means there is none: say nothing about it.

Read just enough of the codebase to place each requirement: what already exists, what it would build on, what it would touch. A claim about the code carries its evidence (`path:line`, or the command run and its output); a claim with none is looked up before it is shown.

Then grill: run `10x-grill`, which prints the plugin's shared `references/grill.md`, and follow it. The questions are product questions — what each requirement gives the user, which ones belong together, what must come first, what can wait or should not be done at all. The roadmap has no `## Assumptions` section: every assumption the grill leaves goes into the proposal message (Step 3), above the draft.

### Step 2 — Draft

Write `.10x/roadmap.draft.md`. It starts as a byte-for-byte copy of `.10x/roadmap.md` (Read it whole), or of the layout above when there is none, and the new requirements are merged into it:

- Each requirement goes into a version, or into `## Not yet assigned`, `## Later` or `## Decided against` (with its reason).
- A picked security entry becomes the item `<title> (security <fingerprint>)`: its title, with `|` written `\|` and each `; ` written `, ` so it stays one item, then its full fingerprint. Never shorten or reword the ` (security sha256:<hex>)` ending: Tickets finds the entry by it.
- A new version is a new row, placed by order: what it depends on first, then risk, then what can ship alone. Moving a row up or down keeps it.
- Every existing row, state and section entry stays byte-for-byte. Change one only when the user's own words ask for it (move, drop, rename, re-scope) — never to tidy it, and never a `Done` row.

Then:

```bash
10x-roadmap check
```

On exit 1, each `<file>:<line>: <why>` names a fault: fix the draft and run it again until it exits 0. Exit 2 (`10x-roadmap: <why>`) stops the skill: relay it. On exit 0, each `not kept: <line>` is an existing row or entry the draft no longer has as it was. One the user did not ask to change is restored from `.10x/roadmap.md` and `check` run again. Each `new id: <version> <id>` is a ticket id the draft adds to a row; add one only for a ticket the user named or approved in this session.

### Step 3 — Show and stop

Show, in one message: the assumptions the grill left (omit when none); the draft's path; the draft verbatim as rendered markdown; then the `not kept:` and `new id:` lines `check` printed, verbatim — or, when it printed no `not kept:` line, that every existing row and entry is kept. **Stop** until the user approves or asks for changes. Changes go into the draft, then `check` again and the draft shown again.

### Step 4 — Apply

Only after the user approves:

```bash
10x-roadmap apply
```

It checks the draft again and writes nothing on a fault: fix, show again and wait. Otherwise it renames the draft to `.10x/roadmap.md` and prints `roadmap: <path>` and the `not kept:` and `new id:` lines. Report those, and the next step: `/10x:roadmap tickets <next version>`.

## Tickets

`/10x:roadmap tickets <version>` turns each item of the version that has no ticket id into one ticket. `show` has already printed the items, numbered.

### Step 1 — Ground it

```bash
10x-worktree init
```

A non-zero exit stops the skill: relay its message. Its first line, `tickets: github` or `tickets: files`, picks the path for the rest of this section. The lines after it are what the drafts are built from: `drafts: <path>`, one `form: <file> name: … labels: … title: … required: … fields: …` line per issue form (or `forms: none`), one `template: <file>` line per Markdown template, and `banned: […]`. Values are JSON.

With `tickets: github`, check:

```bash
git remote get-url origin
gh auth status
```

Stop, saying which and how to fix it, when `origin` is not on github.com, `gh` is not installed (command not found → https://cli.github.com), or not logged in (non-zero exit → `gh auth login`). With `tickets: files`, run no `gh` command and no git remote command anywhere in this section.

Items that already end in an id are skipped. When none is left, say so and stop.

A security item is one whose text, before any trailing id, ends with ` (security sha256:<64 hex>)`; its fingerprint is that `sha256:<hex>`. The text anywhere else does not count. For each security item, once:

```bash
10x-security route <fp>
```

It prints `route: <route> — <reason>`, the one rule for how this entry's ticket may be opened without disclosing it: `ticket` (a local ticket file, with `tickets: files`), `issue` (a GitHub issue: a private repo, or a public one where the entry is minor or not in any release yet) or `advisory` (a public repo with a released, `medium`-or-worse entry: a draft GitHub security advisory plus a local ticket, never a public issue). Never pick the route yourself. A non-zero exit is relayed and that item skipped.

Read just enough of the codebase to make each item concrete, with evidence as in Requirements Step 1. Look for an existing ticket for each item first. With `tickets: github`:

```bash
gh issue list --state open --search "<key words>" --limit 10
```

With `tickets: files`, search the titles — line 1 — of every `.10x/*/ticket.md` with the Grep tool. A match is offered for linking instead of a new ticket; on the user's yes, link it as in Step 4.

Then grill once for the whole version: run `10x-grill` and ask the product questions of all its items in one round.

### Step 2 — Classify

With `tickets: files`, only the kind: `feature`, `bug`, `improvement`, `docs` or `chore`. With `tickets: github`, map each item's kind to what the repo already has — never create labels or types:

```bash
gh label list --limit 100 --json name,description
10x-ticket issue-types
```

A non-zero exit from `10x-ticket issue-types` stops the skill: relay its message. Pick the matching issue type (`Bug`, `Feature`, `Task`) and existing label (`bug`, `enhancement`, `documentation`); no match, none. With `form:` lines, a bug takes the form whose `labels` include the repo's bug label and anything else the one labelled `enhancement`; draft in its shape: `Form: <file>` and its `labels` as `Labels:` in the header, its `title` (unless `none`) as the title's prefix, one `### <label>` section per `fields:` entry, in order, every `required:` one filled. A `form: <file> error: …` line is relayed and that form not used.

### Step 3 — Draft and stop

One draft per item, at `<drafts>/<slug>.md`, `<drafts>` being `init`'s `drafts:` path. The slug comes from the item's text: lowercase letters, digits and `-`, starting with a letter or digit, never `gh-<n>` or `drafts`; with `tickets: files` it becomes the ticket id. Line 1 is `# <title>`; with `tickets: github`, optional `Labels: a, b`, `Type: <name>` and `Form: <file>` lines follow directly — a `tickets: files` draft has none but `Security:`; then a blank line and the body:

```markdown
# <title>
Labels: <label>
Type: <issue type>

## Context
What happens today and where — name the files or routes. The roadmap version this item belongs to.

## Goal
The outcome, in one or two sentences.

## Acceptance criteria
- [ ] AC1 — Each one checkable and numbered: a behaviour, a test, a command's output.
- [ ] AC2 — One checkbox per line.

## Out of scope
What a reader might expect here but this ticket does not cover. Omit if nothing.

## Assumptions
Decisions the grill did not settle with the user, each with the answer taken. Omit if none.
```

No `TBD`, `handle edge cases`, `as needed` or other phrase on `init`'s `banned:` line outside code: the create commands refuse them, as they refuse an unnumbered criterion.

A security item's draft differs, whatever its route:

- The slug is `security-<8 hex>`, the first 8 hex digits of its fingerprint, so `/10x:work` treats its ticket as a security ticket. When `.10x/<slug>/` already exists, the entry already has a ticket: report it and link the item to that slug as in Step 4 instead of drafting.
- Line 1 is `# Fix security entry <first 8 hex>`, and line 2 the header line `Security: <fp>`, the full fingerprint.
- The body names neither the entry's title nor its `path:line` (read them from `.10x/security.md` to understand the fix, never to quote them). For the `advisory` and `ticket` routes, whose tickets stay local, the `## Context` paragraph reads "Security entry `<fp>` in `.10x/security.md`" plus the roadmap version. For the `issue` route it leaves the fingerprint out: "A security fix planned in roadmap version <v>; the entry is in `.10x/security.md`" — the issue is public, and `10x-land issue` refuses a title or body that names the entry.
- An `advisory` draft has no `Labels:`, `Type:` or `Form:` line and the `## Acceptance criteria` layout; an `issue` draft takes them as any other.

Show all the drafts together, each once: its item (`<n>. <item>`), one line `Kind: <kind> → <label, type or form file name>` (or `→ ticket file`; a security item's names its route: `→ advisory`, `→ issue` or `→ ticket file`), its path, then the file verbatim as rendered markdown. **Stop** until the user approves or edits them.

### Step 4 — Create and link

For each approved draft, with `tickets: files`:

```bash
10x-land ticket <slug>
```

It prints `ticket: <path>`; the id is the slug. With `tickets: github`:

```bash
10x-land issue <slug>
```

It is not in this skill's `allowed-tools` on purpose: creating a public issue always asks for permission. It prints the issue URL from `gh`; the id is `gh-<n>`, `<n>` read from that URL. A security item is created with the command its route names — `ticket` → `10x-land ticket <slug>`, `issue` → `10x-land issue <slug>`, and `advisory` →

```bash
10x-land advisory <slug>
```

which opens a draft GitHub security advisory in origin's repo and writes the local ticket `.10x/<slug>/ticket.md`. It is not in this skill's `allowed-tools` either, and the grant hook never allows it: it always asks. It prints `advisory: <url>` and `ticket: <path>`; the id is the slug. When GitHub refuses the advisory it prints the error and still writes the ticket: relay the error with the ticket. Each refuses a draft that fails its checks, naming the line — fix it and run it again; an entry whose route is not the one the command needs is refused too: run the route again and use the command it names. Then link the new ticket to its item, `<n>` being the item's number in `show`'s output:

```bash
10x-roadmap link <version> <n> <id>
```

Exit 2 (`10x-roadmap: <why>`) is relayed; never edit the roadmap to work around it. Report each item with its id, and the next step: `/10x:batch <version>`.

## Replies

- Lead with the result. No first sentence that announces what comes next, and no closing recap or offer.
- Between routine tool calls, at most one line per phase change — a phase is one of this skill's numbered steps.
- Say each fact once: what the reply has already shown is not summarised again.

Some things are exempt from these rules and are written in full: a security warning; a question to the user; and anything persisted — the draft roadmap, issue bodies, and the files under `.10x/`.

The final reply is the path's last step: `show`'s output, `apply`'s `roadmap:`, `not kept:` and `new id:` lines with the next step, or the ids linked with the next step.

## Never

- Never write `.10x/roadmap.md` with Write, Edit or a shell redirect; it changes only through `10x-roadmap apply` and `10x-roadmap link`.
- Never run `10x-roadmap apply` before the user has seen and approved the draft.
- Never change an existing row, state or section entry the user did not ask to change.
- Never create an issue or a ticket file before the user has seen and approved its draft.
- Never create labels, issue types, milestones or projects.
- Never put secrets, tokens, internal URLs or customer data in an issue body — it may be public.
- Never create a security item's ticket by any route but the one `10x-security route` printed for it, and never put its title, location or trace in a draft.
- Never reply that something is unverified, unchecked or not yet confirmed: check it first. Only when a check is impossible, say so, naming what was tried and why it cannot be checked.
