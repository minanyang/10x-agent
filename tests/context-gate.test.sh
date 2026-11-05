#!/bin/bash
# Self-test for hooks/context-gate.js.
set -uo pipefail
GATE="$(cd "$(dirname "$0")/.." && pwd)/hooks/context-gate.js"
tmp=$(mktemp -d)
trap 'rm -r "$tmp"' EXIT
fail=0

transcript() { # <file> <tokens> [compact-after]
  printf '{"type":"assistant","message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":%s}}}\n' "$2" >"$1"
  [ -n "${3:-}" ] && printf '{"type":"user","isCompactSummary":true}\n' >>"$1"
  return 0
}
run() { # <prompt> <transcript> [cwd]
  node -e 'process.stdout.write(JSON.stringify({prompt:process.argv[1],transcript_path:process.argv[2],cwd:process.argv[3]}))' "$1" "$2" "${3:-$tmp}" | node "$GATE"
}
check() { # <description> <want: block|pass|warn|warn+block> <prompt> <transcript> [cwd]
  local out got; out="$(run "$3" "$4" "${5:-$tmp}")"
  case "$out" in
    '') got=pass ;;
    *'"decision":"block"'*'"systemMessage":"10x: '*) got=warn+block ;;
    *'"decision":"block"'*) got=block ;;
    '{"systemMessage":"10x: '*) got=warn ;;
    *) got=other ;;
  esac
  if [ "$got" = "$2" ]; then
    echo "ok    $1"
  else
    echo "FAIL  $1 (want $2, got: ${out:-nothing})"; fail=1
  fi
}

transcript "$tmp/big.jsonl" 250000
transcript "$tmp/mid.jsonl" 150000
transcript "$tmp/small.jsonl" 50000
transcript "$tmp/compacted.jsonl" 250000 yes

check "blocks /10x:work on a big context" block "/10x:work gh-12" "$tmp/big.jsonl"
check "blocks /10x:close on a big context" block "/10x:close gh-12" "$tmp/big.jsonl"
check "passes on a small context" pass "/10x:work gh-12" "$tmp/small.jsonl"
check "default limit is 200k" pass "/10x:work gh-12" "$tmp/mid.jsonl"
check "passes right after a compaction" pass "/10x:work gh-12" "$tmp/compacted.jsonl"
check "ignores other prompts" pass "fix the bug" "$tmp/big.jsonl"
check "ignores other skills" pass "/work TASK-1" "$tmp/big.jsonl"
check "passes with no transcript" pass "/10x:work x" "$tmp/missing.jsonl"
check "passes on a malformed payload" pass "" ""
mkdir -p "$tmp/proj/.claude" "$tmp/proj/.git"
echo '{ "contextGate": { "maxTokens": 300000 } }' >"$tmp/proj/.claude/10x.json"
check "honours a raised limit" pass "/10x:work x" "$tmp/big.jsonl" "$tmp/proj"
mkdir -p "$tmp/proj/a/b"
check "honours a raised limit from a subdirectory" pass "/10x:work x" "$tmp/big.jsonl" "$tmp/proj/a/b"
mkdir -p "$tmp/proj/inner/.git" "$tmp/proj/inner/sub"
check "ignores a config above the repo root" block "/10x:work x" "$tmp/big.jsonl" "$tmp/proj/inner/sub"
mkdir -p "$tmp/norepo/.claude" "$tmp/norepo/sub"
echo '{ "contextGate": { "maxTokens": 300000 } }' >"$tmp/norepo/.claude/10x.json"
check "ignores a config outside any repo" block "/10x:work x" "$tmp/big.jsonl" "$tmp/norepo/sub"
mkdir -p "$tmp/proj/wt/.claude" "$tmp/proj/wt/sub"
echo 'gitdir: ../.git/worktrees/wt' >"$tmp/proj/wt/.git"
echo '{ "contextGate": { "maxTokens": 100000 } }' >"$tmp/proj/wt/.claude/10x.json"
transcript "$tmp/110k.jsonl" 110000
check "nearest config wins" block "/10x:work x" "$tmp/110k.jsonl" "$tmp/proj/wt/sub"
echo '{ "base": "main" }' >"$tmp/proj/wt/.claude/10x.json"
check "a config without contextGate is final and silent" block "/10x:work x" "$tmp/big.jsonl" "$tmp/proj/wt/sub"
echo '{ nope' >"$tmp/proj/wt/.claude/10x.json"
check "warns on a broken config and passes" warn "/10x:work x" "$tmp/small.jsonl" "$tmp/proj/wt/sub"
echo 'TOKEN=s3cret' >"$tmp/proj/wt/.claude/10x.json"
out="$(run "/10x:work x" "$tmp/small.jsonl" "$tmp/proj/wt/sub")"
case "$out" in
  *s3cret*) echo "FAIL  the warning quotes the file (got: $out)"; fail=1 ;;
  *SyntaxError*) echo "ok    the warning names the error type, not the file's contents" ;;
  *) echo "FAIL  the warning names no error type (got: ${out:-nothing})"; fail=1 ;;
esac
echo '{ "contextGate": { "maxTokens": "lots" } }' >"$tmp/proj/wt/.claude/10x.json"
check "warns on a non-numeric maxTokens and blocks" warn+block "/10x:close x" "$tmp/big.jsonl" "$tmp/proj/wt/sub"
check "does not warn on other prompts" pass "fix the bug" "$tmp/big.jsonl" "$tmp/proj/wt/sub"
mkdir -p "$tmp/fifo/.claude" "$tmp/fifo/.git"
mkfifo "$tmp/fifo/.claude/10x.json"
check "skips a config that is not a regular file" block "/10x:work x" "$tmp/big.jsonl" "$tmp/fifo"
echo '{ "contextGate": { "maxTokens": 0 } }' >"$tmp/proj/.claude/10x.json"
check "maxTokens 0 turns it off" pass "/10x:work x" "$tmp/big.jsonl" "$tmp/proj"
if printf 'garbage' | node "$GATE" | grep -q block; then echo "FAIL  garbage input blocked"; fail=1; else echo "ok    garbage input passes"; fi

[ "$fail" -eq 0 ] && echo "context-gate: all cases pass"
exit "$fail"
