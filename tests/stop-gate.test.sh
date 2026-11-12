#!/bin/bash
# Self-test for hooks/stop-gate.js.
set -uo pipefail
GATE="$(cd "$(dirname "$0")/.." && pwd)/hooks/stop-gate.js"
tmp=$(mktemp -d)
trap 'rm -r "$tmp"' EXIT
fail=0

repo="$tmp/repo"
git init -q "$repo"
mkdir -p "$repo/.10x/t1" "$repo/.10x/t2" "$repo/.10x/gh-7" "$repo/.worktrees/t1/.git"
plan() { # <id> <status>
  printf '# %s\n\nStatus: %s\n\n## Acceptance criteria\n- AC1 — one\n- AC2 — two\n  - a nested bullet, not AC3\n\n## Approach\n- AC9 — not a criterion\n' "$1" "$2" >"$repo/.10x/$1/plan.md"
}
plan t1 approved
plan t2 draft
plan gh-7 approved
evidence() { printf '%s\n' "$@" >"$repo/.10x/t1/evidence.md"; }

# send <event> <session_id> [<key> <value>]... — a value starting with { [ or equal to true/false is JSON.
send() {
  node -e '
    const [cwd, event, sid, ...kv] = process.argv.slice(1)
    const o = { hook_event_name: event, session_id: sid, cwd }
    for (let i = 0; i < kv.length; i += 2) o[kv[i]] = /^[[{]|^(true|false)$/.test(kv[i + 1]) ? JSON.parse(kv[i + 1]) : kv[i + 1]
    process.stdout.write(JSON.stringify(o))
  ' "$repo" "$@" | (cd "$tmp" && node "$GATE")
}
prompt() { send UserPromptSubmit "$1" prompt "$2"; }
stop() { send Stop "$1" last_assistant_message "$2" "${@:3}"; }
check() { # <description> <want: block|pass> <output> [text the reason must carry]...
  local got=other out=$3
  case "$out" in
    '') got=pass ;;
    '{"decision":"block","reason":'*) got=block ;;
  esac
  for want in "${@:4}"; do [[ "$out" == *"$want"* ]] || got="block without \"$want\""; done
  if [ "$got" = "$2" ]; then
    echo "ok    $1"
  else
    echo "FAIL  $1 (want $2, got $got: ${out:-nothing})"; fail=1
  fi
}
assert() { # <description> <status of the check run just before>
  if [ "$2" -eq 0 ]; then echo "ok    $1"; else echo "FAIL  $1"; fail=1; fi
}
owner() { [ "$(cat "$repo/.10x/$1/session" 2>/dev/null)" = "$2" ]; }
unowned() { [ ! -e "$repo/.10x/$1/session" ]; }
bound() { grep -q "\"ticket\":\"$2\"" "$repo/.10x/.sessions/$1.json" 2>/dev/null; }

check "passes before any binding" pass "$(stop s1 "The change is unverified.")"

out="$(prompt s1 "/10x:work t1")"
[ -z "$out" ] && owner t1 s1 && bound s1 t1; assert "binds on /10x:work for an approved plan" $?
grep -qxF "/.10x/" "$repo/.git/info/exclude"; assert "excludes .10x before its first write" $?

prompt s2 "/10x:work t2" >/dev/null
[ ! -e "$repo/.10x/t2/session" ] && ! grep -q ticket "$repo/.10x/.sessions/s2.json"; assert "does not bind on /10x:work for a draft plan" $?

prompt s6 "/10x:work #7" >/dev/null
owner gh-7 s6; assert "binds /10x:work #<n> to gh-<n>" $?
printf 's0\n' >"$repo/.10x/gh-7/session"
prompt s6 "/10x:work https://github.com/o/r/issues/7" >/dev/null
owner gh-7 s6; assert "binds /10x:work <issue url> to gh-<n>" $?

mkdir -p "$repo/.10x/t3"
plan t3 draft
send PostToolUse s3 tool_name Bash tool_input '{"command":"10x-worktree add t3"}' >/dev/null
unowned t3; assert "does not bind on 10x-worktree add without a worktree" $?
mkdir -p "$repo/.worktrees/t3/.git"
send PostToolUse s3 tool_name Bash tool_input '{"command":"echo 10x-worktree add t3"}' >/dev/null
unowned t3; assert "does not bind on a command that only mentions 10x-worktree add" $?
send PostToolUse s3 tool_name Bash tool_input '{"command":"10x-worktree add t3"}' >/dev/null
owner t3 s3 && bound s3 t3; assert "binds on 10x-worktree add" $?

before="$(ls -A "$repo/.10x/.sessions")"
prompt "../evil" "/10x:work t1" >/dev/null
prompt "a/b" "/10x:work t1" >/dev/null
[ "$(ls -A "$repo/.10x/.sessions")" = "$before" ] && [ ! -e "$repo/.10x/evil.json" ] && owner t1 s1; assert "refuses an unsafe session id" $?

evidence "- AC1 — met: \`bash tests/x.sh\` → ok"
check "blocks when evidence lacks a criterion" block "$(stop s1 "Done.")" "AC2: no line"
evidence "- AC1 — met: commit abc, case \`x\`" "- AC2 — pending"
check "blocks on a pending criterion" block "$(stop s1 "Done.")" "AC2: pending"
evidence "- AC1 — met: x" "- AC2 — pending" "- AC2 — met: commit abc, case \`y\`"
check "the last line for a criterion wins" pass "$(stop s1 "Done.")"
evidence "- AC1 — met: x" "- AC2 — met: y" "- AC2 — maybe"
check "blocks on a criterion in no known state" block "$(stop s1 "Done.")" 'AC2: \"maybe\" is not a known state'
evidence "- AC1 — met: x" "- AC2 — deferred: \"later, in #50\""
check "passes when every criterion is met or deferred" pass "$(stop s1 "Done.")"
evidence "- AC1 — met: x" '```' "- AC2 — met: inside a fence" '```'
check "ignores evidence lines inside a fence" block "$(stop s1 "Done.")" "AC2: no line"
evidence "- AC1 — met: x" "- AC2 — asked: Should the flag  stay on by default?"
check "passes on an asked criterion quoted in the last message" pass "$(stop s1 "One question:
Should the flag stay
on by default?")"
check "blocks on an asked criterion not in the last message" block "$(stop s1 "Done.")" "AC2: asked"
evidence "- AC1 — met: x" "- AC2 — met: y" "- asked: Keep the old name?"
check "passes on a free asked line quoted in the last message" pass "$(stop s1 "Keep the old name?")"
check "blocks on a free asked line not in the last message" block "$(stop s1 "Done.")" 'asked \"Keep the old name?\"'

# shellcheck disable=SC2016  # backticks are the Markdown under test
plan_tests() { # <AC2's test file cell> <AC2's case cell> — t1's plan with a ## Tests table
  plan t1 approved
  printf '\n## Tests\n| AC | Test file | Case |\n|---|---|---|\n| AC1 | `tests/x.sh` | `one` |\n| AC2 | %s | %s |\n' "$1" "$2" >>"$repo/.10x/t1/plan.md"
}
# shellcheck disable=SC2016
plan_tests '—' '`hand check: open the page and see the badge`'
evidence "- AC1 — met: x" "- AC2 — hand-check: open the page and see the badge"
check "passes on a hand-check criterion the plan declares" pass "$(stop s1 "Done.")"
evidence "- AC1 — met: x" "- AC2 — hand-check:"
check "blocks on an empty hand-check line" block "$(stop s1 "Done.")" "AC2:" "hand-check: <what to check>"
# shellcheck disable=SC2016
plan_tests '`tests/y.sh`' '`two`'
evidence "- AC1 — met: x" "- AC2 — hand-check: open the page and see the badge"
check "blocks on a hand-check criterion the plan does not declare" block "$(stop s1 "Done.")" "AC2: hand-check, but its \`## Tests\` row is not a hand check" "| AC2 | — | hand check: … |"
plan t1 approved
evidence "- AC1 — met: x" "- AC2 — hand-check: open the page"
check "blocks on hand-check when the plan has no ## Tests" block "$(stop s1 "Done.")" "AC2: hand-check, but its"

evidence "- AC1 — met: x" "- AC2 — pending"
check "passes when stop_hook_active" pass "$(stop s1 "Done." stop_hook_active true)"
check "passes while background tasks run" pass "$(stop s1 "Done." background_tasks '[{"id":"b1","type":"shell","status":"running"}]')"
check "blocks when background_tasks is empty" block "$(stop s1 "Done." background_tasks '[]')" "AC2: pending"
prompt s4 "/10x:work t1" >/dev/null
check "passes for a ticket another session owns" pass "$(stop s1 "Done.")"
check "the new owner is held to the evidence" block "$(stop s4 "Done.")" "AC2: pending"
prompt s1 "/10x:work t1" >/dev/null
mv "$repo/.worktrees/t1" "$repo/.worktrees/t1.off"
check "passes after the worktree is removed" pass "$(stop s1 "Done.")"
mv "$repo/.worktrees/t1.off" "$repo/.worktrees/t1"
rm "$repo/.10x/t1/evidence.md"
check "passes when evidence.md cannot be read" pass "$(stop s1 "Done.")"
check "still blocks a claim when evidence.md cannot be read" block "$(stop s1 "The retry is unverified.")" "Check it now"

prompt s5 "/10x:open fix the login" >/dev/null
check "blocks an unverified claim during a flow" block "$(stop s5 "The fix is in. The retry path is not yet confirmed.")" "Check it now"
check "blocks an unverified claim in Chinese" block "$(stop s5 "修好了，但重試路徑未驗證。")" "Check it now"
# shellcheck disable=SC2016  # backticks are the Markdown under test
check "ignores an unverified claim in code" pass "$(stop s5 'Ran `grep unverified log`.
```
unchecked
```')"
check "ignores a word containing a phrase" pass "$(stop s5 "The checker is unchecked_ok.")"
check "ignores an unverified claim outside a flow" pass "$(stop s7 "The retry path is unverified.")"
prompt s9 "/10x:batch gh-7 t1" >/dev/null
check "/10x:batch is a flow" block "$(stop s9 "gh-7 landed; t1 is unverified.")" "Check it now"
grep -qx '{"flow":true}' "$repo/.10x/.sessions/s9.json" && owner gh-7 s6 && owner t1 s1; assert "/10x:batch binds no ticket" $?
prompt s10 "/10x:roadmap add a dark mode; ship export first" >/dev/null
check "/10x:roadmap marks the session as a flow" block "$(stop s10 "Draft written; the export order is unverified.")" "Check it now"
grep -qx '{"flow":true}' "$repo/.10x/.sessions/s10.json"; assert "/10x:roadmap binds no ticket" $?
prompt s7 "fix the bug, /10x:open later" >/dev/null
check "does not take a mid-prompt /10x: as a flow" pass "$(stop s7 "The retry path is unverified.")"
check "blocks a reviewer's unverified claim" block "$(send SubagentStop s7 agent_type 10x:code-reviewer last_assistant_message "Finding 2 is unverified.")" "Check it now"
check "blocks the security reviewer's unverified claim" block "$(send SubagentStop s7 agent_type 10x:security-reviewer last_assistant_message "Not checked: the hook.")" "Check it now"
check "ignores another agent's unverified claim" pass "$(send SubagentStop s7 agent_type Explore last_assistant_message "This is unverified.")"
check "a reviewer's stop does not check the parent's evidence" pass "$(send SubagentStop s4 agent_type 10x:code-reviewer last_assistant_message "No findings.")"

evidence "- AC1 — met: x" "- AC2 — pending"
out="$(stop s1 "AC2 is unverified.")"
check "one reason carries both blocks" block "$out" "AC2: pending" "Check it now"
grep -o '"decision"' <<<"$out" | wc -l | grep -qx ' *1'; assert "one block, not two" $?

check "passes on a malformed payload" pass "$(printf 'garbage' | (cd "$tmp" && node "$GATE"))"
check "passes on an empty payload" pass "$(printf '{}' | (cd "$tmp" && node "$GATE"))"
check "passes outside a git repository" pass "$(printf '{"hook_event_name":"Stop","session_id":"s1","cwd":"%s","last_assistant_message":"unverified"}' "$tmp" | (cd "$tmp" && node "$GATE"))"
echo '{ nope' >"$repo/.10x/.sessions/s8.json"
check "passes on an unreadable session file" pass "$(stop s8 "unverified")"

[ "$fail" -eq 0 ] && echo "stop-gate: all cases pass"
exit "$fail"
