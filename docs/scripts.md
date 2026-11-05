# Scripts

On the Bash tool's PATH while the plugin is enabled (not in a plain terminal). The skills call them; you rarely need to.

`10x-verify`, `10x-red-proof` and `10x-worktree add` run the project's own gates and setup commands and its test files, so granting them is as strong as granting the agent permission to write files in the repo.

## 10x-worktree

`10x-worktree init|add|list|path|rm <id>|sync-base` — one worktree per ticket.

- `init` first prints where tickets live, `tickets: github` or `tickets: files` (the `tickets` setting; any other value exits 2 before anything is created), then keeps `.10x/` out of git before anything is written there.
- `init <id>` and `add` print `ticket dir: <path>` and `base: <branch> (<ref>)`, the lines the skills resolve `.10x/<id>/` paths and the base from.
- Without an id, `init` prints what `/10x:open` drafts from: the drafts directory, each issue form (`form: <file> name: … labels: … title: … required: … fields: …`, values JSON, or `forms: none`), Markdown templates and the banned phrases.
- `rm` deletes the branch only if git sees it merged.
- `sync-base` fast-forwards the main checkout's base after a merged PR when it is on the base and git allows the fast-forward (unrelated uncommitted changes are kept).

## 10x-land

`10x-land check|rebase|push|merge|wait|squash|pr|comment <id>`, `10x-land issue|ticket <slug>` — the writes `/10x:close`, `/10x:open` and `/10x:work` need, each built from the ticket id or draft slug alone.

- `check` prints the configured close mode (`mode: <close>`, refusing any value but `pr`, `pr-merge`, `local`), then, before looking for the worktree, `ticket dir: <path>`, `base: <branch> (<ref>)`, `review: <path>` or `review: missing` and `tickets: <github|files>` (refusing any other value), and lists uncommitted changes. In `pr`/`pr-merge` mode on GitHub it prints the branch's PR state (`pr: MERGED <url>` sends `/10x:close` to cleanup), and in `pr`/`pr-merge` mode the repo's PR/MR template in the worktree (`pr template: <path>`, or `none`). Then one `locked test changed: <path>` line, and exit 1, per file `10x-red-proof --lock` locked whose content at HEAD is no longer the locked one.
- `rebase` rebases onto the base (conflicts left for you).
- `push` pushes the ticket branch (lease only if origin has it).
- `merge` squash-merges the open PR/MR into the configured base, pinned to origin's repo and the verified head commit, never a fork's PR/MR, and on GitHub only when the PR's head is the worktree's HEAD, the branch contains `origin/<base>` (exit 4 if it moved) and its checks are green (exit 3 when they are only still running).
- `wait` polls the PR's checks by the same rule until green, failed or 30 minutes.
- `squash` lands the branch on the base as one commit from `.10x/<id>/commit-msg` in `local` mode; for a `gh-<n>` ticket it adds `Closes #<n>` as its own paragraph (before a closing trailer block) unless `commit-msg` has that line, so pushing the base closes the issue.
- `pr` opens the PR/MR from `.10x/<id>/pr-title` + `pr-body.md` or updates only its body, refuses a body that lacks any `##` heading of the template `check` names, and refuses a branch whose PR is already merged.
- `issue` creates an issue from `.10x/drafts/<slug>.md` (existing labels only), then deletes the draft; it refuses `tickets: files` before any `gh` call.
- `ticket` (`tickets: files` only) writes `.10x/drafts/<slug>.md` verbatim to `.10x/<slug>/ticket.md` and deletes the draft, with the checks of `issue` for a draft without forms and no `gh` call or `origin`; it refuses `Labels:`, `Type:` and `Form:` header lines, an existing `.10x/<slug>/`, and the slugs `gh-<n>` and `drafts`.
- `comment` posts `.10x/gh-<n>/comment.md` on issue `<n>` of origin's repo, only when the url in `.10x/gh-<n>/ticket.md`'s header is that issue's, then renames it to `comment.posted.md` so it is posted once.
- `push`, `merge` and `pr` refuse when origin's push URL names another repo than its fetch URL.
- `push`, `pr`, `comment` and `squash` refuse, before any push, `gh`/`glab` call or commit, text that names an entry of `.10x/security.md` ([10x-security](#10x-security)), whatever its status: `push` checks every commit message in `<base>..<branch>`, `pr` checks `pr-title`, `pr-body.md` and every commit message in `<base>..<branch>`, `comment` checks `comment.md`, `squash` checks `commit-msg`. An entry matches by its fingerprint, its title (any case) or its `path:line` (not preceded by another path character, not followed by another digit). Each hit prints `10x: <file or commit <sha>> contains security entry <fingerprint>` — never the title or location — and the command exits 2.
- With `security.blockClose` set ([configuration](configuration.md)), `check` prints `security: <level>` after `tickets:` (`security: off` without it; exit 2 on a value other than the five severities), and after `clean:` one `security entry open: <fingerprint>` line per confirmed entry found in or seen in the ticket whose status is `new` or `fix-now` and whose severity is at or above the level; any such line exits 1. Without the key it never reads `security.md`.

## 10x-verify

`10x-verify <id>` runs every gate once; fails if the tree moved during the run.

## 10x-red-proof

`10x-red-proof <id>` runs the changed tests at HEAD, then reverts the implementation and checks they go red (jest, vitest, `node --test`, or the `redProof` command of any other stack); a test that fails at HEAD exits 2.

`10x-red-proof <id> --lock` is `/10x:work`'s tests half. It exits 2, naming the file, when the branch changes a file that is neither a test nor a test helper (`package.json` and lockfiles included), leaves out a test file `## Tests` names, has a test file that passes at HEAD, has a test the runner reports skipped or todo, or adds an unconditional skip (`.skip(`, `xit(`, `it.todo(`, `{ skip: true }`). Otherwise it records the lock in the worktree's git directory, `10x-lock`: the commit, and the blob of every file the branch changed, test helpers included. It refuses a second lock: a change to a locked file goes through a relock.

With a lock, `10x-red-proof <id>` exits 2 naming each locked file whose blob at HEAD differs from the lock, unless the relocks not yet taken in `.10x/<id>/relock.md` account for it. They are checked in file order, and each must be an entry with a `reason`, an `approved` ruling and a `commit` that is an ancestor of HEAD and changes only locked files, whose parent holds the locked files as the lock before it left them; HEAD must hold them as the last one left them. Several relocks may be pending at once, and one relock may cover several locked files. When every test file then goes red, it moves the lock through each relock commit in order (`relocked at <sha>`). A test file the lock does not hold, changed or new, is free. With TDD on, it refuses to run without a lock while `## Tests` names a test file; with `"tdd": false` ([configuration](configuration.md)) it runs without a lock, and `--lock` is refused.

## 10x-test

`10x-test <id> [test file…]` runs test files in the ticket's worktree with the runner `10x-red-proof` detects, without touching the tree: the files given (relative to the worktree root), or else every test file the branch changed — committed, uncommitted or untracked. It prints the runner's output, then `pass <file>` or `FAIL <file>` per file; exit 1 when a test fails, 2 when it cannot run (no test file, a path outside the worktree, an unsupported stack, or `10x-verify` or `10x-red-proof` holding the ticket's tree). `/10x:work` runs tests only through it, so a `/10x:batch` worker needs no settings rule for the project's test runner.

## 10x-plan-check

`10x-plan-check <id>` refuses `.10x/<id>/plan.md`, naming every line at fault, when:

- a criterion has no `## Tests` row, or the Tests table is missing or has another header;
- a phrase from `references/banned-phrases.txt` appears outside code;
- `## Readers` is empty or an entry has no hit line;
- a `## Tool behaviour relied on` claim has no `$` command block with output;
- `## Overlap` is empty;
- and, ending in `cold read required: <n> files — …`, when `## Files` has more than three top-level bullets and `.10x/<id>/cold-read.md` is missing, blank or not a regular file.

## 10x-review-packet

`10x-review-packet <id> [--fixes]` runs `preReviewGates` first (a failure exits 1, no packet), then builds the reviewer's starting material: diff, changed files, conventions, last verify result, and `## Plan checks` — each `## Tests` case not among its test file's added lines on the branch, and each `(gone)` Readers term still in the tree.

- It adds `security review: required` with the reasons when the diff touches a script a skill grants in `allowed-tools`, a skill's or agent's frontmatter, `hooks/hooks.json`, a script it registers, or a file such a script or hook loads (one level, by a static `source` or relative `require`).
- `--fixes` covers only the commits since the last review, with its findings (the plan checks still read the whole branch).
- Before the gates, it exits 2 naming each locked file that changed since the lock: run `10x-red-proof <id>`, where a relock is accepted.
- `## Relocks` lists every entry of `.10x/<id>/relock.md`: its heading; for each relock red-proof accepted, the diff of the locked files between the two locks, in a fence longer than any backtick run in it; then its reason and ruling, labelled as written by the implementer and not verified.

## 10x-batch

The mechanics of `/10x:batch`. Refusals print `10x-batch: <why>` on stderr with exit 2.

- `10x-batch init <arg>... [--search "<query>"]` resolves every argument to a ticket (`gh-<n>`, `<n>`, `#<n>`, an issue URL of origin's repo, an existing id) before writing anything, then writes `.10x/_batch/tickets` and the board. A batch with an unsettled ticket is not replaced; a settled one is moved to `.10x/_batch.<timestamp>/`.
- An argument that resolves to no ticket, is not a number and names a version of `.10x/roadmap.md` stands for the ticket ids in that version's row. A row with no id exits 2 (`version <v> has no ticket ids: run /10x:roadmap tickets <v>`); a `gh-<n>` whose issue is closed is left out and counts as landed. The versions are recorded in `.10x/_batch/versions` (the closed ids in `versions.closed`), and once every id of a version is `landed` (`pr-open` does not count), `status` or `init` rewrites only that row's `State` cell to `Done <YYYY-MM-DD>` (local date, never moved once written) and `status` prints `roadmap: <version> Done <date>`.
- `10x-batch run <id> <plan|reply|implement|close>` runs one worker turn in the foreground: `claude -p` (or `$TENX_BATCH_CLAUDE`) with `--session-id`, or `--resume` for `reply`, which sends `.10x/_batch/<id>/reply.md`; a plan session may write only under `.10x/<id>/`, implementation and close run in `acceptEdits`. It records `runs.tsv`, the stream-json log, the permission denials and `turn.md` (every assistant text block of the run) under `.10x/_batch/<id>/`, and refuses what `status` would not list, and a reply starting with `/`, which the worker would take as a typed command.
- `10x-batch status` rewrites and prints the board, then the actions allowed now: `plan <id>`, `implement <id>`, `close <id>`, `answer <id>` (` approvable` when a passing draft can be approved) and `done`.
- `10x-batch drop <id>` stops the ticket's running worker and never schedules it again.
- `10x-batch approve <id>` records your approval of a draft plan that passes `10x-plan-check` — the hash of `plan.md` with its Status line blanked, under the git directory, out of a planning worker's reach (a worker of an already approved ticket, which runs commands, could still write it) — and writes the approve reply. No skill grants it: each approval asks your permission. `init` deletes the records of the tickets it takes in, so a ticket batched again needs a new approval. A plan session's ticket is `approved` only when `plan.md` says so and still matches that record; a plan that approves itself, or changes after your approval, is `failed`.

`batch.parallel` ([configuration](configuration.md)) caps the implementation workers.

## 10x-roadmap

`10x-roadmap show [<version>] | check | apply | link <version> <item n> <id>` — the one reader and writer of `.10x/roadmap.md` for `/10x:roadmap` (and the parser `10x-batch` shares, `scripts/roadmap.js`). Refusals print `10x-roadmap: <why>` with exit 2.

- The file has a table whose header row is `| Version | Contents | Why this order | State |`, then `## Not yet assigned`, `## Later` and `## Decided against`, each once. A `Version` matches `^[A-Za-z0-9][A-Za-z0-9._-]*$`, is not all digits and is unique; `Contents` holds items separated by `; `, an item's ticket id being its last code span (`gh-<n>`, or an id with `.10x/<id>/ticket.md`); `Why this order` is never empty; a `## Decided against` entry gives a reason after ` — `.
- `show` prints `<version> — <state>`, `  <n>. <item>` per item, then `next: <version|none>` (the first version not `Done <YYYY-MM-DD>`); with a version, only that one. Without a roadmap it prints `no roadmap: .10x/roadmap.md` and exits 0. It never writes.
- `check` validates `.10x/roadmap.draft.md`: exit 1 with one `<file>:<line>: <why>` per fault, else one `not kept: <line>` per row or section entry of `roadmap.md` that the draft no longer has byte for byte (a row anywhere in the table, an entry in its own section), then one `new id: <version> <id>` per ticket id a draft row has and the same version's row in `roadmap.md` does not.
- `apply` runs `check`, writes nothing on a fault, else renames the draft to `.10x/roadmap.md` and prints `roadmap: <path>` and the `not kept:` and `new id:` lines.
- `link` appends `` `<id>` `` to an item; it refuses an item that already has an id, and an id that is neither `gh-<n>` nor a directory with `.10x/<id>/ticket.md`.

## 10x-security

`10x-security add <id> <file> | set <id> <fingerprint> <status> [reason] | remove <id> <fingerprint>` — the one writer of `.10x/security.md`, the repo-wide record of what `10x:security-reviewer` found outside a ticket's diff, or could not confirm. The file lives under `.10x/`, so it is never committed. Refusals print `10x-security: <why>` with exit 2 and write nothing.

- `add` reads a JSON array of the reviewer's `## Out of diff` records from a file under `.10x/<id>/`. Each record has exactly `verdict` (`confirmed` or `needs_validation`), `rule` (kebab-case), `title`, `path` (repo-relative), `line` (an integer ≥ 1), `snippet`, `trace`, and `severity` (`critical`, `high`, `medium`, `low` or `informational`) only when confirmed; a fault prints `records[<i>]: <field> …` for each faulty record. A new fingerprint is appended with `status: new` and `found in: <id>` (`added: <fp>`); a known one gets `<id>` in `seen in` and nothing else changes (`seen: <fp>`).
- `set` records `fix-now`, `later`, `accepted` or `rejected` (the last two need a reason) and changes only `status` and `reason`. `remove` deletes one entry. Both refuse an unknown fingerprint and an entry whose `found in` and `seen in` do not include `<id>`. The grant hook binds all three to the session's ticket. `/10x:work` grants only `add`, and the hook never allows `set` or `remove`, so they always ask: any session can put its ticket into an entry's `seen in`.
- Writes go through a temp file and a rename under the lock `.10x/security.lock`, and `.10x/` is kept in `.git/info/exclude`.

The fingerprint is `sha256:` and the hex sha256 of `<rule>\n<path>\n<snippet>`, where `snippet` is the sink line with each run of whitespace collapsed to one space and the ends trimmed. It has no line number, so the same sink keeps its fingerprint when the code around it moves, and it matches the fingerprint pattern of Cloudflare's security-audit-skill.

`.10x/security.md` is `# Security entries`, then one section per entry, separated by blank lines:

```markdown
## sha256:<hex>
- title: <text>
- verdict: confirmed
- severity: high
- rule: command-injection
- location: <path>:<line>
- trace: <text>
- status: new
- reason:
- found in: gh-1
- seen in: gh-4, gh-9
- audit fingerprint:
- not seen in:
```

Fields come in that order, one line each; an empty one ends at the colon. A backslash, newline, carriage return or tab in a value is stored as `\\`, `\n`, `\r`, `\t`. `audit fingerprint` and `not seen in` are kept as they are by every subcommand. A file that does not parse makes every reader exit 2 with `<file>:<line>: <why>`.

## 10x-grill

`10x-grill` prints the shared grill (`references/grill.md`) that `/10x:open`, `/10x:work` and `/10x:roadmap` follow; a skill cannot Read a file under the plugin root without a prompt.

## 10x-ticket

- `10x-ticket github <ref> [--out <path>]` prints a GitHub issue of origin's repo as Markdown, or writes it to `--out`, which must be that issue's `.10x/gh-<n>/ticket.md` (a number, or that repo's issue URL; another repo's is refused, and so is any other argument).
- `10x-ticket issue-types` prints the issue types of origin's repo, one per line; nothing for a repo without them.
