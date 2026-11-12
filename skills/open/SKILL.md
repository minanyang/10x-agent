---
name: open
description: Open a ticket — turn an idea, a bug or an improvement into a GitHub issue, or with `tickets: files` a ticket file under `.10x/`, grounded in the codebase, classified with the repo's own labels or issue types, ready for /10x:work. Use when the user runs /10x:open with something to file.
disable-model-invocation: true
allowed-tools:
  - Bash(10x-worktree init)
  - Bash(git remote get-url origin)
  - Bash(gh auth status)
  - Bash(gh issue list *)
  - Bash(gh issue view *)
  - Bash(10x-grill)
  - Bash(gh label list *)
  - Bash(10x-ticket issue-types)
  - Bash(10x-land ticket *)
---

# Open a ticket

`/10x:open <what>` files one ticket for later work: a GitHub issue, worked with `/10x:work gh-<n>`, or, with `tickets: files`, a ticket file `.10x/<slug>/ticket.md`, worked with `/10x:work <slug>`. It does not plan or implement. Opening an issue is visible to everyone who can see the repo, so it **shows the draft and waits for the user's go** before creating anything.

Run one command per Bash call — no `&&`, `;` or `|`. Before anything else:

```bash
10x-worktree init
```

A non-zero exit stops the skill: relay its message. Its first line, `tickets: github` or `tickets: files`, picks the path for the rest of this skill. The lines after it are what the draft is built from: `drafts: <path>`, one `form: <file> name: … labels: … title: … required: … fields: …` line per issue form in `.github/ISSUE_TEMPLATE/` (or `forms: none`), one `template: <file>` line per Markdown template, and `banned: […]`. Values are JSON. Steps 2 and 3 use them.

With `tickets: github`, check:

```bash
git remote get-url origin
gh auth status
```

Stop, saying which and how to fix it, when `origin` is not on github.com, `gh` is not installed (command not found → https://cli.github.com), or not logged in (non-zero exit → `gh auth login`). Do not fall back to the web API or a browser.

With `tickets: files`, no `origin` and no `gh` are needed: run no `gh` command and no git remote command anywhere in this skill.

## Step 1 — Ground it

Read just enough of the codebase to make the ticket concrete: which module, route, component or file it is about, and what happens there today. Search before claiming something is missing.

Every file, route or current behaviour the draft's Context names carries its evidence: `path:line`, or the command run and its output. A claim with none is looked up before the draft is shown — never shown as a guess.

Look for an existing ticket first. With `tickets: github`:

```bash
gh issue list --state open --search "<key words>" --limit 10
```

If one already covers it, show it (`gh issue view <number>`) and ask whether to add to it instead.

With `tickets: files`, search the titles — line 1 — of every `.10x/*/ticket.md` with the Grep tool, `gh-<n>` copies of issues included. If one already covers it, show it and ask whether to add to it instead; on yes, show the edit and apply it with the Edit tool only once the user approves it. A ticket that has a `plan.md`, or a worktree (`.worktrees/<id>`, or `<worktreeDir>/<id>` when `.claude/10x.json` sets `worktreeDir`), is already being worked: do not edit it — say so and suggest a new ticket.

Then grill: run `10x-grill`, which prints the plugin's shared `references/grill.md`, and follow it. The questions here are product questions — what changes for the user, the edge cases, what counts as done.

## Step 2 — Classify

Decide the kind: `feature`, `bug`, `improvement`, `docs` or `chore`.

With `tickets: files`, that is all: no labels, issue types, forms or templates — the `form:` and `template:` lines `init` printed are ignored. Go to Step 3.

With `tickets: github`, map the kind to what the repo already has — never create labels or types:

```bash
gh label list --limit 100 --json name,description
10x-ticket issue-types
```

A non-zero exit from `10x-ticket issue-types` stops the skill: relay its message, as for the checks above.

- Issue types (one per line; nothing outside organisation repos): pick the one that matches — typically `Bug`, `Feature`, `Task`.
- Labels: the matching existing label — `bug` for a bug, `enhancement` for a feature or improvement, `documentation` for docs — if the repo has it. No match, no label.

If `init` printed `form:` lines, pick the form by the kind: a bug takes the form whose `labels` include the repo's bug label; a feature, improvement, docs or chore takes the one labelled `enhancement`, else the closest by `name`. Draft in its shape instead of the layout below: the line's file as `Form: <file>` in the header, its `labels` as `Labels:`, its `title` (unless `none`) as the title's prefix, and one `### <label>` section per `fields:` entry, in that order — every `required:` one filled. A `form: <file> error: …` line is relayed to the user, and that form is not used. When no form fits and a `template:` line names a matching Markdown template, read that one file, `.github/ISSUE_TEMPLATE/<file>`, and follow its sections.

## Step 3 — Draft and stop

Write the draft to `<drafts>/<short-slug>.md`, `<drafts>` being the path on `init`'s `drafts:` line (slug: lowercase letters, digits and `-`; with `tickets: files` it becomes the ticket id, so never `gh-<n>` or `drafts`). Line 1 is `# <title>`; with `tickets: github`, optional `Labels: a, b` (existing labels only), `Type: <name>` and `Form: <file name>` lines follow directly — a `tickets: files` draft has none of them; in either mode, `Size: small` is the last header line of a small ticket (below); then a blank line and the body:

```markdown
# <title>
Labels: <label>, <label>
Type: <issue type>

## Context
What happens today and where — name the files or routes. For a bug: steps to reproduce, expected, actual.

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

Title: a bug by the problem observed (`Close reports a merged PR as open`), a feature by the need (`A way to file issues that follow the repo's forms`), in the repo's language — never a `scope:` prefix unless the form's `title` sets one, even when existing issues have one.

Every criterion is checkable: no `TBD`, `handle edge cases`, `as needed` or the other phrases on `init`'s `banned:` line — `10x-land issue` and `10x-land ticket` refuse them outside code, as they refuse an unnumbered criterion, two checkboxes on one line and an empty or missing required form section.

Propose `Size: small` only when the change touches ≤ 3 files whose place Step 1 found, is copy, styling, a located bug fix or a field added to an existing shape, and names no sensitive path — auth, permissions, payments, secrets, a file matching `security.paths` in the main checkout's `.claude/10x.json`. `/10x:work` then works it without a plan and with one review. Otherwise write no `Size:` line: normal is the default. `10x-land issue` and `10x-land ticket` refuse a `Size:` other than `small` or `normal`, `Size: small` beside a `Security:` line, and a `Size: small` draft whose body names, in an inline code span, a tracked file matching `security.paths` — naming the line and the file: drop the `Size:` line and run it again.

Show the draft once: one line `Kind: <kind> → <label, type or form file name>`, or `Kind: <kind> → ticket file` with `tickets: files` (the kind is not in the file), ending in ` · Size: small` for a small draft, the draft's path on one line, then the file verbatim as rendered markdown — never summarised again in the same reply. **Stop** until the user approves or edits it.

## Step 4 — Create

With `tickets: files`:

```bash
10x-land ticket <short-slug>
```

It reads only that draft and refuses a `Labels:`, `Type:` or `Form:` line, a draft that fails the checks above, or a slug that already has a `.10x/<slug>/` directory, naming the line or the directory — fix the draft, or rename it to a new slug, and run it again. Otherwise it writes the draft verbatim to `.10x/<short-slug>/ticket.md`, deletes the draft and prints `ticket: <path>`. Report that path and the next step, `/10x:work <short-slug>`.

With `tickets: github`:

```bash
10x-land issue <short-slug>
```

It reads only that draft, refuses a label the repo does not have or a draft that fails the checks above (naming the line or field — fix the draft and run it again), and creates the issue in origin's repo. It is not in this skill's `allowed-tools` on purpose: creating a public issue always asks for permission, so the approval does not rest on the model stopping.

Report the issue URL and the next step, `/10x:work gh-<n>`. `10x-land issue` deletes the draft once the issue exists; when creation fails the draft stays for the next run.

## Several at once

When one request yields several tickets, first show a table of the request's goals, each mapped to the ticket and the criterion that covers it. A goal with no row is raised with the user before any draft is written. Then draft each, show them together — each as in Step 3, its `Kind:` line, path and file verbatim, shown once — and create the ones the user approves. One issue per independent piece of work: a piece that can ship and be reviewed alone is its own ticket.

## Replies

- Lead with the result. No first sentence that announces what comes next, and no closing recap or offer.
- Between routine tool calls, at most one line per phase change — a phase is one of this skill's numbered steps.
- Say each fact once: what the reply has already shown is not summarised again.

Some things are exempt from these rules and are written in full: a security warning; an irreversible action, both its warning and the statement made before acting on it, such as `/10x:close` stating the PR URL before it merges; a question to the user; and anything persisted — code, commits, issue and PR bodies, and the files under `.10x/`.

The final reply is Step 4's: the issue URL or the `ticket:` path, and the next step.

## Never

- Never create an issue or a ticket file before the user has seen and approved the draft.
- Never create labels, issue types, milestones or projects.
- Never assign people, set milestones or add to projects unless asked.
- Never put secrets, tokens, internal URLs or customer data in an issue body — it may be public.
- Never reply that something is unverified, unchecked or not yet confirmed: check it first. Only when a check is impossible, say so, naming what was tried and why it cannot be checked.
