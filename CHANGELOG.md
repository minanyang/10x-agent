# Changelog

## Unreleased

- `/10x:audit` runs Cloudflare's installed `security-audit` skill on a scope you choose (a diff, paths or the whole repo) and merges its findings into `.10x/security.md`, matching earlier entries so a re-run never triages the same issue twice. It then asks about each new or deferred entry and opens a local ticket for each `fix-now`, which `/10x:work` fixes and clears from the log. `10x-security` gains `prepare`, `import` and `ticket`; `set` and `remove` accept audit run ids, and `10x-land ticket` reserves the slug `audit`.
- `10x:security-reviewer` judges by Cloudflare's security-audit-skill criteria (boundary and result, five severity anchors, `confirmed` / `needs_validation` / `rejected`) and blocks a ticket only on confirmed findings its diff introduces or makes reachable. Everything else goes to `.10x/security.md`, never committed, through the new `10x-security` script, and `/10x:work` asks what to do with each new entry before its report.
- `/10x:roadmap` offers the deferred `confirmed` entries of `.10x/security.md` as requirements (`10x-security list --plannable`) and opens each planned one the way `10x-security route` decides, so a released vulnerability in a public repo never becomes a public issue: the new `10x-land advisory` opens a draft GitHub security advisory plus a local ticket, and `10x-land issue` refuses a `Security:` draft that routes to an advisory or names its entry. `10x-roadmap show` ends with an `audit:` line suggesting `/10x:audit <tag>..HEAD` before a release.
- `10x-land pr`, `comment` and `squash` refuse text that names a recorded security entry; `security.blockClose` in `.claude/10x.json` makes `/10x:close` refuse a ticket with an open confirmed entry at or above a severity.
- `/10x:batch` workers run in auto mode, so routine read-only checks are no longer denied with no one there to approve them. A new hook keeps a plan session's file writes under `.10x/<id>/`, symlinks and `..` included. When auto mode is unavailable, `10x-batch` stops the worker and runs the turn again in the previous modes, and the board says so. Subagents may run `10x-test` for the ticket their session is bound to.
- `/10x:batch auto <tickets>` takes a batch from queued to landed with no human turn while no product question is open: the new `10x-batch loop` plans, approves a plan that passes `10x-plan-check`, implements and closes, and stops only for what needs you. Batches now take only your own GitHub issues, and a batch worker can no longer run `10x-batch` commands that drive the batch.

## 0.1.0 — 2026-11-05

Initial release.

- `/10x:open` drafts a ticket — a GitHub issue in the repo's issue forms, labels and types, or, with `"tickets": "files"`, a file under `.10x/<slug>/ticket.md` — and creates it once you approve.
- `/10x:work` plans a ticket with you, then builds it in its own worktree: the plan's tests are written, committed and proven to fail first, then locked, so the implementation cannot weaken them except through a relock a cold arbiter approved. Then implement, commit, prove the new tests fail without the change, verify with the project's gates, and review cold. `"tdd": false` in `.claude/10x.json` turns the tests-first half off.
- `/10x:close` rebases, verifies again and lands the branch as one squash commit — a PR, a PR it merges once checks pass, or a local merge — then cleans up.
- `/10x:roadmap [requirements]` keeps `.10x/roadmap.md` — versions in order, each with the reason for its place — and `/10x:batch <tickets|version>` works and lands many tickets from one terminal, each in a background worker.
- Scripts, not the agent's word, decide: plans, evidence, test locks and review rounds are checked before you see them, and a Stop hook keeps a session from ending with a criterion unaccounted for.
- Six agents (frontend, backend, devops, QA, code review, security review), three skills (`commit`, `code-review`, `code-review-branch`) and hooks that guard destructive commands, gate on context size and keep a typed skill's grants for its session.
- Self-tests for the scripts and hooks, and an end-to-end suite that drives open, work and close against a fake `gh` (`tests/e2e/`).
