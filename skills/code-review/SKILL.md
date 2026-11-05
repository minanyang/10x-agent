---
name: code-review
description: Review the user's pending/uncommitted work — staged + unstaged changes only, never committed history or branch-wide diffs. Trigger on "review my changes", "code review", "review this diff", "review what I'm working on", "review my WIP", or when the user points at a specific dirty file/hunk. Runs the repo's lint/format check scripts if present, produces a structured report (Summary, Issues with severity/file/line, Action items, verbatim tool output), then applies fixes directly to the codebase while keeping the user's original work staged and all of the skill's edits unstaged so the separation is visible in `git diff`. Use `code-review-branch` instead when the user wants their entire branch reviewed against a base like `develop`/`main`. Supports findings-only mode (no fixes, no git state changed) when invoked by a read-only reviewer.
---

# Code Review (uncommitted scope)

Review only what the user has not yet committed. Stage their work, leave your fixes unstaged, never touch commit history.

## Scope contract

- **In scope:** the working tree — staged + unstaged changes at the moment the skill runs.
- **Out of scope:** committed changes, branch-vs-base diffs, history rewrites. If the user wants those, hand off to `code-review-branch`.
- **Never run:** `git commit`, `git commit --amend`, `git reset`, `git push`, `git rebase`, `git stash drop`.
- **Never stage your own fixes.** Only the user's pre-existing work stays staged; your edits remain unstaged so the user sees a clean before/after in `git diff`.

## Modes

**Default — review and apply fixes.** What an engineer wants when self-polishing. Run all steps. Stage user's work as baseline (step 2), apply fixes as unstaged edits (step 6) — the staged-vs-unstaged separation in `git diff` is the load-bearing pattern.

**Findings-only.** Invoked when the caller says "no fixes" / "report only" / "review without patching", or when the calling agent is `10x:code-reviewer`. Never modify git state, never edit files. Skip step 2 (no `git add`) and skip step 6 (no fixes). In step 3, read uncommitted work via `git diff` and `git diff --cached` directly. The report from step 5 is the deliverable.

## Defaults

- **Package manager:** detect from the lockfile — `pnpm-lock.yaml` → pnpm, `yarn.lock` → yarn, `bun.lockb` / `bun.lock` → bun, else npm. Use that PM for every script run below.
- **Review target:** if the user names a specific file/path (e.g. "review `src/auth.ts`"), scope every `git add` and `git diff --cached` to that path. Otherwise, full working tree.

## Procedure

### 1. Run the repo's check scripts (only ones that exist)

Read `package.json` → `scripts`. Run only what's defined; don't invent commands.

- `scripts.lint` → run it, capture full stdout + stderr.
- `scripts["format:check"]` → run it, capture stdout + stderr.
- `scripts.format` → run **only if** the command body contains `--check`, `--list-different`, or the word `check` (i.e. it's check-only, not a writer). Capture output.

If none of these exist, skip tool output entirely — this becomes a findings-only review. Do not substitute other scripts.

### 2. Lock in the user's work as the staged baseline

*Findings-only mode: skip this step entirely — never stage, never modify git state. Read uncommitted work via `git diff` and `git diff --cached` directly in step 3.*

Stage by explicit path only — never `git add -A` or `git add .`; a sweep pulls in files that were never part of the work (scratch, `.env*`, build output) and erases any staging the user did on purpose.

- User named specific paths → `git add -- <paths>`.
- Otherwise, if nothing is staged yet → stage the tracked files with changes (`git diff --name-only`) by path. For untracked files, list them and stage only the ones the user confirms belong to the work.
- Something is already staged and other changes are not → that split is the user's deliberate staging. Don't fold the unstaged part in; ask whether to stage it as part of the baseline or to run findings-only (fixing on top of unstaged user work would make your edits indistinguishable from theirs).

Say which paths you staged. From this point forward, the staged diff IS the user's work. Do not restage, unstage, or rewrite it.

Deleted files: `git add` will stage the deletion and `git diff --cached` will show it. Review the deletion intent (was it accidental? does anything still import it?), but don't re-add files the user clearly meant to remove.

### 3. Determine review scope

```
git status
git diff --cached            # or: git diff --cached -- <paths>
```

Review **only** the cached diff (scoped to `<paths>` if the user named any). Ignore committed changes and branch-wide diffs even if they look interesting.

*Findings-only mode: there's no staging baseline (step 2 was skipped). Read both `git diff` (truly unstaged) and `git diff --cached` (already-staged) — their union is the review scope. `git diff --cached` alone would miss work the user hasn't staged yet.*

### 4. Apply project rules during review

Read the project's own conventions — `CLAUDE.md`, `AGENTS.md`, `.claude/rules/`, `.cursor/rules/`, whichever exist — and apply the relevant ones (architecture, naming, TypeScript, imports, framework-specific) as review criteria. Don't restate the rules in the report — just use them to find issues.

If the diff includes React or Next.js code, also apply the `react` / `nextjs` skills' guidance.

### 5. Produce the structured report

Output in this order:

- **Summary** — 2–5 bullets on what changed and why it matters.
- **Issues** — one entry per problem, with:
  - severity (`blocker` / `major` / `minor` / `nit`)
  - file + line range
  - what's wrong
  - concrete suggestion (what to change)
- **Positive notes** *(optional)* — call out genuinely good patterns; skip if there's nothing real to say.
- **Action items** — checklist of what the user should verify / do before committing.
- **Tool output** — verbatim stdout/stderr for every check actually executed. If a single block is enormous, mark it clearly as truncated and keep the warnings/errors intact.

### 6. Apply fixes — keep them unstaged

*Findings-only mode: skip this step entirely. The report from step 5 is the deliverable — never edit files.*

For every Issue you listed and every warning/error from the executed checks, edit the code directly to fix it. Follow the project conventions from step 4 (import aliases, types vs constants layout, etc.).

**Do not `git add` your edits.** When you finish, the state must be:

- Staged: only the user's original work (untouched since step 2).
- Unstaged: your fixes, visible in `git diff`.

A final `git status` should make this separation obvious.

## When NOT to use this skill

- User asks to review the whole branch / compare against `main` or `develop` → use `code-review-branch`.
- User asks to review a specific PR by number → use `/review <pr#>` or `gh pr view`. Claude Code's bundled `/review` takes a PR number, branch, or path; this skill (`/10x:code-review`) does not.
- User asks for a security audit → use `security-review`.
- There are no uncommitted changes (`git status` is clean) → tell the user the working tree is clean and stop. Don't fabricate findings.

## NEVER

- Never commit, amend, reset, push, or rebase.
- Never stage your fixes.
- Never review committed or branch-wide changes in this skill.
- Never run scripts that don't exist in `package.json`.
- Never run a `format` script that mutates files (no `--check` flag) — that would corrupt the user's staged baseline.
- Never invent lint output. If a check wasn't run, don't include a tool-output section for it.
- Never reply that something is unverified, unchecked or not yet confirmed: check it first. Only when a check is impossible, say so, naming what was tried and why it cannot be checked.
