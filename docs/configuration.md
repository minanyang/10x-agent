# Configuration

Optional `.claude/10x.json`, committed with the project:

```json
{
  "base": "develop",
  "gates": ["pnpm lint", "pnpm typecheck", "pnpm test"],
  "setup": "pnpm install --frozen-lockfile",
  "close": "pr",
  "tickets": "files",
  "worktreeDir": ".worktrees",
  "generated": ["src/api/generated"],
  "redProof": { "command": "pytest {file}", "tests": ["tests/test_*.py"] },
  "preReviewGates": ["ruff check ."],
  "contextGate": { "maxTokens": 200000 },
  "batch": { "parallel": 2 },
  "security": { "blockClose": "high", "paths": ["src/auth/**", "src/billing/**"] }
}
```

| Key | Default |
|---|---|
| `base` | `develop` if origin has it, else origin's default branch |
| `gates` | package.json `verify`, else whichever of `lint`, `typecheck`, `test` exist |
| `setup` | install dependencies from the lockfile (`pnpm` / `yarn` / `bun` / `npm ci`) |
| `close` | `pr` |
| `tickets` | `github` when `origin`'s host is exactly `github.com`, else `files` (another host, a local-path `origin`, or none). `github`: `/10x:open` files GitHub issues. `files`: it writes the approved draft to `.10x/<slug>/ticket.md` and runs no `gh` command. Any other value, an empty string included, is refused |
| `worktreeDir` | `.worktrees` |
| `generated` | paths left out of the review diff (lockfiles always are) |
| `redProof.command` | JavaScript runners (jest, vitest, `node --test`) are detected. For any other stack, a shell command containing `{file}`, run once per changed test file in the worktree root with the shell-quoted path substituted; the file's exit code is the result |
| `redProof.tests` | required with `redProof.command`: git pathspec globs naming the test files (`tests/*.test.sh`) |
| `preReviewGates` | none. Shell commands (quick gates: lint, typecheck) that `10x-review-packet` runs first; a failure exits 1 and no packet is built |
| `tdd` | on. `/10x:work` writes, commits and locks the tests (`10x-red-proof <id> --lock`) before implementing, and a locked test changes only through a relock a fresh reviewer approved. `false` (or `"false"`) skips the tests half and the lock |
| `security.blockClose` | off. One of `critical`, `high`, `medium`, `low`, `informational`: `10x-land check` then refuses to close a ticket while `.10x/security.md` has a confirmed entry found in or seen in it, at or above that severity, whose status is `new` or `fix-now`. Any other value exits 2 |
| `security.paths` | none. Git pathspec globs (`**` crosses directories) of the project's sensitive files: a diff touching one makes `10x-review-packet` require a security review (`<file> matches security.paths`), which escalates a `Size: small` ticket to the normal review, and `10x-land` refuses `Size: small` on a draft that names one in code. A value that is not an array of non-empty strings, none starting with `:`, exits 2 |
| `batch.parallel` | `2`. The most implementation workers `/10x:batch` runs at once; an integer of 1 or more, else `10x-batch` exits 2. Planning always starts every ticket, and close is one at a time |
| `contextGate.maxTokens` | `200000`; `0` turns the gate off. A file that does not parse, or a `maxTokens` that is not a number, gets the default and a warning |

The close modes are described in [the loop](loop.md#10xclose-id). `tickets` and `close` are read independently: where tickets live does not decide how they land, so a repo on GitHub can keep its ticket files off GitHub with `"tickets": "files"` and still land each one by PR (the PR body still carries the plan's goal and acceptance criteria), and every combination of the two is valid.

## Where each key is read from

`10x-verify` reads `gates` from the ticket's worktree, so a gate the ticket adds verifies that ticket; when the list differs from the base branch's, it lists the gates added and removed. The context gate reads `contextGate` from the nearest `.claude/10x.json` at or above the session's working directory, up to the repo root (none outside a repo), so inside a worktree it is the worktree's file. `redProof` and `preReviewGates` are read from the ticket's worktree, else the main checkout. Every other key comes from the main checkout — `tdd` included, so a ticket's branch cannot turn off its own lock, and `security.paths`, so it cannot drop its own entry.

`.10x/` and the worktree directory are added to `.git/info/exclude` automatically — your `.gitignore` is not touched.
