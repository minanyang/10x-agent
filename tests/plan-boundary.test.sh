#!/bin/bash
# Self-test for hooks/plan-boundary.js, run against a copy of the hook on fixtures in a temp dir.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -r "$tmp"' EXIT
fail=0

cp "$ROOT/hooks/plan-boundary.js" "$tmp/plan-boundary.js" || exit 1
HOOK="$tmp/plan-boundary.js"
repo="$tmp/repo"
outside="$tmp/outside"
mkdir -p "$repo/.10x/t1" "$repo/.10x/t2" "$outside/dir"
echo plan >"$repo/.10x/t1/plan.md"
echo other >"$repo/.10x/t2/plan.md"
echo secret >"$outside/file"
echo readme >"$repo/README.md"
ln -s "$outside/file" "$repo/.10x/t1/out"
ln -s "$outside/missing" "$repo/.10x/t1/dangling"
ln -s "$outside/dir" "$repo/.10x/t1/linkdir"
unset TENX_BATCH_PLAN_DIR

# send <tool> <path> [<event>] — the PreToolUse input Claude Code gives the hook for a file tool, from the repo.
send() {
  node -e '
    const [cwd, tool, p, event] = process.argv.slice(1)
    const input = tool === "NotebookEdit" ? { notebook_path: p, new_source: "x" } : { file_path: p, content: "x", old_string: "a", new_string: "b" }
    process.stdout.write(JSON.stringify({ hook_event_name: event || "PreToolUse", session_id: "s1", cwd, tool_name: tool, tool_input: input }))
  ' "$repo" "$@" | (cd "$repo" && node "$HOOK")
}
plan() { TENX_BATCH_PLAN_DIR="$repo/.10x/t1" send "$@"; } # a batch plan session for t1
check() { # <description> <want: deny|nothing> <output>
  local got=other out=$3
  case "$out" in
    '') got=nothing ;;
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"'*) got=deny ;;
  esac
  if [ "$got" = "$2" ]; then
    echo "ok    $1"
  else
    echo "FAIL  $1 (want $2, got $got: ${out:-nothing})"; fail=1
  fi
}

T="a batch plan session writes only under its ticket dir"
for tool in Edit Write NotebookEdit; do
  check "$T: $tool outside" deny "$(plan "$tool" "$repo/README.md")"
  check "$T: $tool outside, relative to cwd" deny "$(plan "$tool" README.md)"
  check "$T: $tool outside the repo" deny "$(plan "$tool" "$outside/new.md")"
  check "$T: $tool through .." deny "$(plan "$tool" "$repo/.10x/t1/../../README.md")"
  check "$T: $tool through .. back inside" deny "$(plan "$tool" "$repo/.10x/t1/../t1/plan.md")"
  check "$T: $tool a symlink to an outside file" deny "$(plan "$tool" "$repo/.10x/t1/out")"
  check "$T: $tool a dangling symlink" deny "$(plan "$tool" "$repo/.10x/t1/dangling")"
  check "$T: $tool under a symlink to an outside dir" deny "$(plan "$tool" "$repo/.10x/t1/linkdir/new.md")"
  check "$T: $tool the dir itself" deny "$(plan "$tool" "$repo/.10x/t1")"
  check "$T: $tool an existing file" nothing "$(plan "$tool" "$repo/.10x/t1/plan.md")"
  check "$T: $tool a new file" nothing "$(plan "$tool" "$repo/.10x/t1/comment.md")"
  check "$T: $tool a new file in a new dir" nothing "$(plan "$tool" "$repo/.10x/t1/verify/notes.md")"
  check "$T: $tool a new file, relative to cwd" nothing "$(plan "$tool" .10x/t1/evidence.md)"
done
check "$T: no path" deny "$(plan Write "")"
check "$T: no notebook path" deny "$(plan NotebookEdit "")"
check "$T: a relative ticket dir" deny "$(TENX_BATCH_PLAN_DIR=.10x/t1 send Write "$repo/.10x/t1/plan.md")"
check "$T: a ticket dir that does not exist" deny "$(TENX_BATCH_PLAN_DIR="$repo/.10x/t9" send Write "$repo/.10x/t9/plan.md")"
check "$T: a malformed payload" deny "$(printf 'garbage' | (cd "$repo" && TENX_BATCH_PLAN_DIR="$repo/.10x/t1" node "$HOOK"))"
check "$T: another tool" nothing "$(plan Bash "$repo/README.md")"
check "$T: another event" nothing "$(plan Write "$repo/README.md" PostToolUse)"

T="prints nothing outside a batch plan session"
for tool in Edit Write NotebookEdit; do
  check "$T: $tool, unset (interactive, implement, close)" nothing "$(send "$tool" "$repo/README.md")"
  check "$T: $tool, empty" nothing "$(TENX_BATCH_PLAN_DIR='' send "$tool" "$repo/README.md")"
  check "$T: $tool through a symlink, unset" nothing "$(send "$tool" "$repo/.10x/t1/out")"
done
check "$T: a malformed payload" nothing "$(printf 'garbage' | (cd "$repo" && node "$HOOK"))"

T="denies another ticket's dir"
for tool in Edit Write NotebookEdit; do
  check "$T: $tool" deny "$(plan "$tool" "$repo/.10x/t2/plan.md")"
  check "$T: $tool, a new file" deny "$(plan "$tool" "$repo/.10x/t2/comment.md")"
  check "$T: $tool, a dir sharing the prefix" deny "$(plan "$tool" "$repo/.10x/t10/plan.md")"
done

# The record `10x-batch approve` writes lies in the state dir S (AC2), which is not under .10x/<id>/. A plan session's
# Write to it is denied; the case first locates the record where approve really puts it, so it fails until it is in S.
T="denies a plan session's Write to the batch state dir"
frepo="$tmp/frepo"
mkdir -p "$frepo/.claude" "$frepo/.10x/t1" "$tmp/stub" "$tmp/t"
cat >"$tmp/stub/worker" <<'STUB'
#!/bin/bash
echo '{"type":"result","result":"done"}'
STUB
chmod +x "$tmp/stub/worker"
echo '{"close":"local"}' >"$frepo/.claude/10x.json"
echo '# t1' >"$frepo/.10x/t1/ticket.md"
git -c init.defaultBranch=main init -q "$frepo"
git -C "$frepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$frepo" remote add origin git@github.com:acme/batch.git
export XDG_STATE_HOME="$tmp/state" TMPDIR="$tmp/t"
unset TENX_BATCH
S="$(cd "$frepo" && node -e '
  const fs = require("fs"), os = require("os"), path = require("path")
  const { execFileSync } = require("child_process"), { createHash } = require("crypto")
  const common = fs.realpathSync(execFileSync("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], { encoding: "utf8" }).trim())
  const h = createHash("sha256").update(common).digest("hex").slice(0, 16)
  const x = process.env.XDG_STATE_HOME
  const base = x && path.isAbsolute(x) ? x : path.join(os.homedir(), ".local", "state")
  let cur = path.join(base, "10x", h)
  const rest = []
  while (!fs.lstatSync(cur, { throwIfNoEntry: false })) { rest.unshift(path.basename(cur)); cur = path.dirname(cur) }
  console.log(path.join(fs.realpathSync(cur), ...rest))
')"
batch() { (cd "$frepo" && PATH="$ROOT/bin:$PATH" TENX_BATCH_CLAUDE="$tmp/stub/worker" 10x-batch "$@") >"$tmp/batch.out" 2>&1; }
batch init t1 && batch run t1 plan
# shellcheck disable=SC2016  # backticks are literal Markdown
printf '# t1\n\nStatus: draft\n\n## Acceptance criteria\n- AC1 — the change works\n\n## Approach\nOne change.\n\n## Files\n- `a` — changed\n\n## Readers\n- `thing` — `grep -rn thing`\n  - no hits\n\n## Overlap\n- none\n\n## Tests\n| AC | Test file | Case |\n|---|---|---|\n| AC1 | `tests/x.sh` | `works` |\n' >"$frepo/.10x/t1/plan.md"
batch approve t1
if [ -s "$S/t1.approved" ]; then
  check "$T" deny "$(plan Write "$S/t1.approved")"
else
  echo "FAIL  $T (10x-batch approve wrote no t1.approved under the state dir $S: $(tr '\n' ' ' <"$tmp/batch.out"))"; fail=1
fi

[ "$fail" -eq 0 ] && echo "plan-boundary: all cases pass"
exit "$fail"
