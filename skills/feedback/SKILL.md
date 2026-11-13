---
name: feedback
description: Report a problem with 10x Agent or ask it for something — draft a bug report or feature request for minanyang/10x-agent in its own issue forms, from any project, without that project's name or paths, and file it, or a comment on a matching issue, on approval. Use when the user runs /10x:feedback, reports that 10x does not work, or asks 10x for a feature.
disable-model-invocation: true
allowed-tools:
  - Bash(10x-feedback init)
  - Bash(10x-feedback check *)
  - Bash(gh issue list --repo minanyang/10x-agent *)
  - Bash(gh issue view *)
---

# Report a 10x problem

`/10x:feedback <what>` turns a problem with 10x Agent, or a request for it, into an issue on `minanyang/10x-agent` — whatever project you run it in — or a comment on an issue there that already covers it. The report is public, so it never carries the current project's name, paths or code, and it **shows the draft and waits for the user's go** before anything is filed.

Run one command per Bash call — no `&&`, `;` or `|`. Before anything else:

```bash
10x-feedback init
```

A non-zero exit stops the skill: relay its message. Its lines are what the rest of this skill works from: `gh: ok`, `gh: missing` or `gh: logged-out`; `drafts: <path>`; one `form: <file> name: … labels: … title: … required: … fields: …` line per form of the 10x repository; `banned: […]`; the `new issue:`, `search:` and `security:` URLs; and, after `environment:`, seven lines that go into every draft verbatim.

## Step 1 — Classify

A bug — 10x does something other than its docs say — takes `bug.yml`; anything else takes `feature.yml`. It is a vulnerability when the user says so, or when the report describes a way to cross a security boundary: a worker escaping its sandbox, a grant allowing more than it names, a script writing outside the paths it is given, a secret reaching a public place.

Ask the user only for what the report needs and does not say — for a bug: what was run, what happened, what was expected. Ask in general terms; do not read the current project's files to fill it in.

## Step 2 — Look for an existing issue

Skipped for a vulnerability, so its key words are never sent as a search. Skipped when `gh:` is not `ok`: say so, and give the `search:` URL for the user to look themselves. Otherwise:

```bash
gh issue list --repo minanyang/10x-agent --state all --search "<key words>" --limit 10
```

The key words are general terms for the problem — a command, a skill, an error message — never the project's name or anything else from it. When an issue covers it, open or closed, show it (`gh issue view <n> --repo minanyang/10x-agent`) and ask whether to comment on it instead of opening a new one.

## Step 3 — Draft, check and stop

Write `<drafts>/<slug>.md`, `<drafts>` being `init`'s `drafts:` path (slug: lowercase letters, digits and `-`). Line 1 is `# <title>`; header lines follow directly, then a blank line and the body.

- A new issue: `Form: <file>` in the header and one `### <label>` section per entry of the form's `fields:`, in that order, every `required:` one filled. `Acceptance criteria` holds `- [ ] AC<n> — …` lines, one per line, with no phrase of the `banned:` line. `bug.yml`'s `Version / commit` is the `10x:` version of the environment lines.
- A comment: `Comment: <n>` in the header, and the comment's text as the body.
- A vulnerability: `Vulnerability: yes` as a header line too.

Either way the body ends with a last `### Environment` section holding the `environment:` lines verbatim. Describe the problem in general terms: no project name, file path, code, URL or data of the current project — say "a TypeScript project with two worktrees", not its name.

Then:

```bash
10x-feedback check <slug>
```

It refuses a draft whose header, form sections or Environment section are wrong, and lists every line that names the project's directory, its origin's owner or repo, or its absolute path. On a refusal, reword the draft and run it again — never show a draft `10x-feedback check <slug>` refused. Once it passes, show the draft once: its path on one line, then the file verbatim. **Stop** until the user approves or edits it.

## Step 4 — File it

On the user's go:

- A vulnerability files nothing. Give the `security:` URL — GitHub's private vulnerability reporting — and the draft's path, so the user can paste it there, and leave the draft where it is.
- `gh:` not `ok`: print the draft and the `new issue:` URL with `<form>` replaced by the form's file name (no other query parameter added), or for a comment the issue's URL, for the user to paste; run nothing. Name the fix: install `gh` (https://cli.github.com) or run `gh auth login`.
- Otherwise, a new issue:

  ```bash
  10x-feedback issue <slug>
  ```

  or a comment:

  ```bash
  10x-feedback comment <slug>
  ```

`10x-feedback issue <slug>` and `10x-feedback comment <slug>` are not in this skill's `allowed-tools` on purpose: they always ask for permission, so filing a public report never rests on the model stopping. They file on `minanyang/10x-agent` only, with the form's own labels, and delete the draft once `gh` succeeds; when `gh` fails the draft stays. Report the issue or comment URL `gh` prints.

## Replies

- Lead with the result. No first sentence that announces what comes next, and no closing recap or offer.
- Between routine tool calls, at most one line per phase change — a phase is one of this skill's numbered steps.
- Say each fact once: what the reply has already shown is not summarised again.

Some things are exempt from these rules and are written in full: a security warning; an irreversible action, both its warning and the statement made before acting on it; a question to the user; and anything persisted — issue bodies, comments and the files under `.10x/`.

The final reply is Step 4's: the URL, or for a vulnerability the `security:` URL and the draft's path.

## Never

- Never file an issue or a comment before the user has seen and approved the draft.
- Never put the current project's name, paths, code, URLs, secrets or data in a draft — the report is public.
- Never attach logs, transcripts or `.10x/` files.
- Never file to another repository than `minanyang/10x-agent`, and never open a public issue for a vulnerability.
- Never reply that something is unverified, unchecked or not yet confirmed: check it first. Only when a check is impossible, say so, naming what was tried and why it cannot be checked.
