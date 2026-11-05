---
name: code-review-branch
description: Review the entire current branch against its base (`origin/develop` if it exists, else `origin/main`) — every commit on the branch plus any uncommitted local work — as a pre-PR full-branch audit. Use when the user wants their whole branch reviewed before opening a PR or merging, asks to "review my branch", "review before I open the PR", "code review this branch vs main/develop", "audit my feature branch", or wants the multi-commit diff (not just unstaged hunks) checked. Produces summary + severity-tagged issues + action items + lint/format output, then applies fixes as unstaged edits so the user's original work stays cleanly separated in `git diff --cached`. Use `code-review` instead when you only want pending unstaged/uncommitted work reviewed (no committed branch history). Supports findings-only mode (no fixes, no git state changed) when invoked by a read-only reviewer.
---

# Code Review: Branch vs Base

Full-branch review covering every commit on the current branch since it diverged from the base, plus any uncommitted local work. This is the pre-PR audit — use it when the user wants the whole branch checked, not just pending hunks.

## NEVER

- **Never run `git commit`.** The user commits after reviewing your changes.
- **Never stage your fixes.** The user's existing work stays staged; your edits stay unstaged so `git diff` shows a clean separation.
- **Never fabricate tool output.** Only paste output from checks you actually ran. If the repo has no supported check scripts, omit the tool-output section entirely.
- **Never invent a base branch.** Detect it per step 1; if neither `origin/develop` nor `origin/main` exists, ask which base to use (`master`, release branch, etc.) before diffing.
- **Never use `..` (two-dot) for the branch-vs-base diff.** It includes base-branch movement since divergence and gives the wrong answer. Always use `<base>...HEAD` (three-dot) — see the callout in step 3.
- Never reply that something is unverified, unchecked or not yet confirmed: check it first. Only when a check is impossible, say so, naming what was tried and why it cannot be checked.

## Modes

**Default — review and apply fixes.** What an engineer wants pre-PR. Run all steps. Stage user's work as baseline (step 3); apply fixes as unstaged edits (step 5).

**Findings-only.** Invoked when the caller says "no fixes" / "report only", or when the calling agent is `10x:code-reviewer`. Never modify git state, never edit files. In step 3, skip staging and instead capture three diffs — `git diff`, `git diff --cached`, and `git diff <base>...HEAD` — treating their union as the user's work. Skip step 5 entirely. The report from step 4 is the deliverable.

## Procedure

### 1. Determine the base branch

`git fetch origin --prune` first — a stale local ref makes the three-dot diff include work that already landed. Then use `origin/develop` if `git rev-parse --verify --quiet origin/develop` succeeds, else `origin/main`. If neither exists, ask the user. A base the user names explicitly always wins. Record which base you used — it goes in the report.

### 2. Run repo checks (only those that exist)

Inspect the project's package manifest and run only check-scripts that are actually defined. Capture full stdout/stderr verbatim for the report.

- **Node (`package.json` → `scripts`)**: detect the package manager from the lockfile (`pnpm-lock.yaml` → `pnpm`, `yarn.lock` → `yarn`, `bun.lockb` → `bun`, else `npm`). Run only:
  - `lint` if defined
  - `format:check` if defined
  - `format` only if its command is check-only (contains `--check`, `--list-different`, or the word `check`); skip if it would rewrite files
  - `typecheck` / `tsc` if defined
- **Python (`pyproject.toml`, `tox.ini`, `Makefile`)**: run configured `ruff`, `mypy`, `black --check`, etc., only if already wired up.
- **Other ecosystems**: run analogous read-only checks (e.g. `cargo clippy`, `go vet`) only if the project already configures them.

Do not install tooling. Do not run write-mode formatters. Do not run the full test suite unless the user explicitly asks.

### 3. Stage the user's uncommitted work, then capture both diffs

*Findings-only mode: skip staging. Capture three diffs instead — `git diff` (unstaged), `git diff --cached` (already-staged), and `git diff <base>...HEAD` (branch vs base) — and treat the union as the user's work. Don't modify git state.*

Stage by explicit path only — never `git add -A` or `git add .` (same rules as `code-review` step 2): user-named paths → `git add -- <paths>`; nothing staged yet → the tracked changed files (`git diff --name-only`) by path, untracked files only once the user confirms them; a partial staging already in place is deliberate — ask before folding the rest in. Say which paths you staged.

```
git add -- <paths>
git diff --cached            # the user's uncommitted work
git diff <base>...HEAD       # everything this branch added vs base (multi-commit branch diff)
```

*(Default mode only:)* From this point on, treat the staged tree as **the user's work**. Any edit you make in step 5 must remain **unstaged** so it shows up clearly in `git diff` (working tree vs index). In findings-only mode this paragraph doesn't apply — there's no staging baseline and no step 5.

> **CRITICAL: three-dot, not two-dot.** `git diff <base>...HEAD` compares HEAD against the **merge-base** with `<base>` — i.e. exactly what this branch added since it diverged. `git diff <base>..HEAD` (two-dot) compares the current tips, so any commits that landed on `<base>` after divergence pollute the diff. Always three-dot for branch reviews.

**Large-branch fallback.** If the branch diff exceeds ~2000 lines or ~50 files (check with `git diff <base>...HEAD --shortstat` and `--stat`), switch to per-file summary mode: list every changed file with a one-line summary, flag the hot paths (core logic, security-sensitive, large net-new modules), then deep-dive only the flagged files. Don't dump 5000 lines of issues into the report — that defeats the purpose of a review. Call out in the report header that you used summary mode and which files got the deep read.

### 4. Write the review report

Open with one line stating the base branch and the two diffs you reviewed:

> Reviewed: `git diff --cached` (staged) and `git diff origin/develop...HEAD` (branch vs origin/develop).

Then:

- **Summary** — 2-5 bullets describing the branch's overall change set. Think PR description, not commit log.
- **Issues** — for each, give: severity (`blocker` / `major` / `minor` / `nit`), file path with line range, short description, concrete fix or strategy. Apply project conventions from `CLAUDE.md`, `AGENTS.md`, `.claude/rules/`, `.cursor/rules/`, `.editorconfig`, and any style configs you find — use them to inform review, don't restate them.
- **Positive notes** (optional) — patterns worth keeping or repeating elsewhere.
- **Action items** — what the user must do before merging (verify behavior X, add test Y, confirm Z with PM/design, rebase, squash, etc.).
- **Tool output** — verbatim stdout/stderr per executed check. Omit the section if no checks ran.

Severity calibration: `blocker` = must fix before merge (bugs, regressions, security, broken types). `major` = should fix (design issues, missing tests for new logic). `minor` = should fix if cheap. `nit` = optional polish.

### 5. Apply fixes — leave them unstaged

*Findings-only mode: skip this step entirely. The report from step 4 is the deliverable — never edit files.*

Fix every Issue you listed and every warning/error from the check tools you ran. Constraints:

- Match existing import style and module conventions (check `CLAUDE.md` / `AGENTS.md` / `.claude/rules/` / `.cursor/rules/`, `tsconfig` paths, existing files in the same package).
- If the project separates types from constants/values (or has similar layering rules), respect that — move things to the right file and update imports.
- Stay surgical. Don't refactor adjacent code that wasn't in scope. Don't reformat untouched files.
- **Do not `git add` your fixes.** Final state: user's original work staged, your improvements visible as unstaged modifications.

End by telling the user how to inspect:

```
git diff             # your unstaged improvements
git diff --cached    # their original staged work
```

## Distinction from `code-review`

`code-review` reviews **only pending changes** (uncommitted/unstaged hunks) — fast loop while working. `code-review-branch` reviews the **whole branch vs base** including all committed history on the branch — the pre-PR audit. If the user only has unstaged edits and no branch divergence, prefer `code-review`.

A PR by number goes to Claude Code's bundled `/review <pr#>` or `gh pr view`, not this skill.
