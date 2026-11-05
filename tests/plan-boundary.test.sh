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

[ "$fail" -eq 0 ] && echo "plan-boundary: all cases pass"
exit "$fail"
