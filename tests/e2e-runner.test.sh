#!/bin/bash
# Self-test for tests/e2e/run.sh with a stub `claude` (TENX_E2E_CLAUDE): no model is called.
# The stub writes $STUB_STREAM (canned stream-json) to stdout and, when $STUB_RUN is set, runs that script first
# (to call the fake gh or not). Real scenario ids drive the runner: 3 is the one-turn duplicate-issue flow.
# Cases: unknown ids exit 2 before any claude run; a permission denial in the skills' scope is reported with its
# command, and one outside it is a note on stderr that fails nothing; a gh call in the
# tool log that the fake never saw fails the flow; a plugin without bin/10x-land fails before claude runs; a
# failing scenario makes the exit code non-zero; a failure after a checkpoint keeps the results judged at it; W3
# counts a plan.md written by a Bash redirect; the fake gh answers a call with gh's global --hostname; a denied command
# chained with |, ; or && is a note; F2 needs no plan.md for a small ticket whose work reached its report, a failure
# naming the missing report when it did not, and still needs plan.md otherwise; R2 accepts a version row that gained
# items at the end of its Contents cell and fails any other change to the first roadmap.
# shellcheck disable=SC2015,SC2016  # `cond && ok || bad` is safe: ok always returns 0; $HOME is literal command text
set -uo pipefail
RUN_SH="$(cd "$(dirname "$0")" && pwd)/e2e/run.sh"
fail=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }

tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT

cat >"$tmp/claude" <<'STUB'
#!/bin/bash
echo run >>"$STUB_MARK"
if [ -n "${STUB_RUN:-}" ]; then bash "$STUB_RUN" >/dev/null 2>&1; fi
# A second call reads $STUB_STREAM_2 when it is set.
if [ "$(grep -c . "$STUB_MARK")" -ge 2 ] && [ -n "${STUB_STREAM_2:-}" ]; then cat "$STUB_STREAM_2"; else cat "$STUB_STREAM"; fi
STUB
chmod +x "$tmp/claude"

# A stream whose one Bash call is `gh issue list`, with an optional denial of another command: `10x-land merge`
# is in the skills' scope, `echo $HOME` is not.
printf '%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"gh issue list --state open --search greet"}}]}}' \
  '{"type":"result","subtype":"success","permission_denials":[],"total_cost_usd":0.01,"duration_ms":10}' >"$tmp/stream-ok"
printf '%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"10x-land merge gh-5"}}]}}' \
  '{"type":"result","subtype":"success","permission_denials":[{"tool_name":"Bash","tool_use_id":"t2","tool_input":{"command":"10x-land merge gh-5"}}],"total_cost_usd":0.01,"duration_ms":10}' >"$tmp/stream-denied"
printf '%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"gh issue list --state open --search greet"}}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"echo $HOME"}}]}}' \
  '{"type":"result","subtype":"success","permission_denials":[{"tool_name":"Bash","tool_use_id":"t2","tool_input":{"command":"echo $HOME"}}],"total_cost_usd":0.01,"duration_ms":10}' >"$tmp/stream-adhoc"
# The model piping a skill's gh command, denied, then running it bare.
printf '%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"gh issue list --state open --search greet 2>&1 | head"}}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"gh issue list --state open --search greet"}}]}}' \
  '{"type":"result","subtype":"success","permission_denials":[{"tool_name":"Bash","tool_use_id":"t2","tool_input":{"command":"gh issue list --state open --search greet 2>&1 | head"}}],"total_cost_usd":0.01,"duration_ms":10}' >"$tmp/stream-chained"
printf '%s\n' '#!/bin/bash' 'gh issue list --state open --search greet' >"$tmp/calls-gh"
# The work-bug plan turn: ticket.md and plan.md under an excluded .10x/, nothing else. Only the first call writes.
printf '%s\n' '#!/bin/bash' '[ -e .10x/gh-5/plan.md ] && exit 0' '10x-worktree init gh-5' \
  'echo ticket >.10x/gh-5/ticket.md' 'echo plan >.10x/gh-5/plan.md' >"$tmp/writes-plan"
printf '%s\n' '{"type":"result","subtype":"success","permission_denials":[],"total_cost_usd":0.01,"duration_ms":10}' >"$tmp/stream-empty"
mkdir -p "$tmp/plugin/bin"

# runner <expected exit> <description> <env...> -- <args...>; leaves the output in $tmp/out and the stub's runs in $tmp/mark.
runner() {
  local want="$1" what="$2" got
  shift 2
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : >"$tmp/mark"
  env "TENX_E2E_CLAUDE=$tmp/claude" "STUB_MARK=$tmp/mark" ${envs[@]+"${envs[@]}"} bash "$RUN_SH" "$@" >"$tmp/out" 2>"$tmp/err"
  got=$?
  if [ "$got" -ne "$want" ]; then bad "$what (want exit $want, got $got)"; sed 's/^/      /' "$tmp/out" "$tmp/err"; return 1; fi
}
line_matches() { grep -Eq -- "$1" "$tmp/out"; }

# unknown ids
if runner 2 "unknown scenario id exits 2" -- 99; then
  [ ! -s "$tmp/mark" ] && grep -q "unknown scenario id '99'" "$tmp/err" && ok "unknown scenario id exits 2" || bad "unknown scenario id exits 2 (claude ran or no message)"
fi
if runner 2 "ids are case-sensitive" -- o1; then
  [ ! -s "$tmp/mark" ] && ok "ids are case-sensitive: o1 exits 2" || bad "ids are case-sensitive: o1 exits 2 (claude ran)"
fi
if runner 2 "one unknown id among known ones" -- 3 W10; then
  [ ! -s "$tmp/out" ] && [ ! -s "$tmp/mark" ] && ok "an unknown id exits 2 before any scenario runs" || bad "an unknown id exits 2 before any scenario runs"
  grep -q "known: .* W9 " "$tmp/err" && ok "W9 is a known scenario id" || bad "W9 is a known scenario id"
fi

# control: the gh call is in the fake's log, no denial
if runner 0 "a clean run exits 0" "STUB_STREAM=$tmp/stream-ok" "STUB_RUN=$tmp/calls-gh" -- 3; then
  [ "$(grep -c . "$tmp/out")" = 2 ] && line_matches '^pass  3  [0-9]+s$' && line_matches '^total [0-9]+s$' && ok "a clean run prints one pass line and the total, exit 0" || { bad "a clean run prints one pass line and the total"; sed 's/^/      /' "$tmp/out"; }
fi

# a run's PATH is built from resolved directories, not the caller's shim directory
real_node="$(node -p process.execPath)"
mkdir -p "$tmp/shims"
printf '#!/bin/bash\nexec "%s" "$@"\n' "$real_node" >"$tmp/shims/node"
chmod +x "$tmp/shims/node"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$PATH" >"$STUB_PATH_OUT"' 'gh issue list --state open --search greet' >"$tmp/writes-path"
if runner 0 "a run's PATH drops the shim directory" "PATH=$tmp/shims:$PATH" "STUB_STREAM=$tmp/stream-ok" "STUB_RUN=$tmp/writes-path" "STUB_PATH_OUT=$tmp/run-path" -- 3; then
  case ":$(cat "$tmp/run-path" 2>/dev/null):" in
    *":$tmp/shims:"*) bad "a run's PATH drops the caller's shim directory and keeps the resolved node (shim dir on the run's PATH)"; cat "$tmp/run-path" ;;
    *":$(dirname "$real_node"):"*) ok "a run's PATH drops the caller's shim directory and keeps the resolved node" ;;
    *) bad "a run's PATH drops the caller's shim directory and keeps the resolved node (node dir missing)"; cat "$tmp/run-path" ;;
  esac
fi

# denial
if runner 1 "a permission denial fails the flow" "STUB_STREAM=$tmp/stream-denied" "STUB_RUN=$tmp/calls-gh" -- 3; then
  line_matches '^FAIL  3  [0-9]+s  .*permission denied: 10x-land merge gh-5' && ok "a permission denial fails the flow and names the command; a failing scenario makes the exit code non-zero" || { bad "a permission denial fails the flow and names the command"; sed 's/^/      /' "$tmp/out"; }
fi

# a denial outside the skills' scope
if runner 0 "an ad-hoc denial passes" "STUB_STREAM=$tmp/stream-adhoc" "STUB_RUN=$tmp/calls-gh" -- 3; then
  line_matches '^pass  3  [0-9]+s$' && grep -Fq "note: open-dup denied (not the skill's): echo \$HOME" "$tmp/err" \
    && ok "a denial outside the skills' scope is a note, not a failure" || { bad "a denial outside the skills' scope is a note, not a failure"; sed 's/^/      /' "$tmp/out" "$tmp/err"; }
fi

# a denied gh command the model chained with a pipe
if runner 0 "a chained denial passes" "STUB_STREAM=$tmp/stream-chained" "STUB_RUN=$tmp/calls-gh" -- 3; then
  line_matches '^pass  3  [0-9]+s$' && grep -Fq "note: open-dup denied (not the skill's): gh issue list --state open --search greet 2>&1 | head" "$tmp/err" \
    && ok "a denied command chained with a pipe is a note, not a failure" || { bad "a denied command chained with a pipe is a note, not a failure"; sed 's/^/      /' "$tmp/out" "$tmp/err"; }
fi

# scenario 14 (close-blocker) runs in local mode: the grant hook denies gh there, so a denied gh command is not the flow's failure
printf '%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"10x-land check gh-5"}}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"gh auth status"}}]}}' \
  '{"type":"result","subtype":"success","permission_denials":[{"tool_name":"Bash","tool_use_id":"t2","tool_input":{"command":"gh auth status"}}],"total_cost_usd":0.01,"duration_ms":10}' >"$tmp/stream-local-gh"
if runner 0 "a denied gh command in a local-mode run does not fail the flow" "STUB_STREAM=$tmp/stream-local-gh" -- 14; then
  line_matches '^pass  14  [0-9]+s$' && grep -Fq "note: close-blocker denied (local mode): gh auth status" "$tmp/err" \
    && ok "a denied gh command in a local-mode run does not fail the flow" || { bad "a denied gh command in a local-mode run does not fail the flow"; sed 's/^/      /' "$tmp/out" "$tmp/err"; }
fi

# a denial after the plan checkpoint fails only the scenarios judged after it
if runner 1 "a later failure keeps an earlier checkpoint" "STUB_STREAM=$tmp/stream-empty" "STUB_STREAM_2=$tmp/stream-denied" "STUB_RUN=$tmp/writes-plan" -- 5 6; then
  line_matches '^pass  5  [0-9]+s$' && line_matches '^FAIL  6  [0-9]+s  .*permission denied: 10x-land merge gh-5' \
    && ok "a failure after a checkpoint keeps the results judged at it" || { bad "a failure after a checkpoint keeps the results judged at it"; sed 's/^/      /' "$tmp/out" "$tmp/err"; }
fi

# a gh call the fake never saw
if runner 1 "a gh call missing from the fake log fails" "STUB_STREAM=$tmp/stream-ok" -- 3; then
  line_matches "^FAIL  3  [0-9]+s  .*tool log has 1 'gh issue list' calls, the fake gh saw 0" && ok "a gh call missing from the fake log fails the flow" || { bad "a gh call missing from the fake log fails the flow"; sed 's/^/      /' "$tmp/out"; }
fi

# the plugin under test has no bin/10x-land
if runner 1 "a plugin without 10x-land fails" "STUB_STREAM=$tmp/stream-ok" "STUB_RUN=$tmp/calls-gh" "TENX_E2E_PLUGIN=$tmp/plugin" -- 3; then
  line_matches '^FAIL  3  [0-9]+s  .*10x-land resolves to' && [ ! -s "$tmp/mark" ] && ok "10x-land outside the plugin under test fails the flow before claude runs" || { bad "10x-land outside the plugin under test fails the flow before claude runs"; sed 's/^/      /' "$tmp/out"; }
fi

# W3: a plan.md written by a Bash heredoc, then an Explore, counts as the cold read of a wide plan
printf '%s\n' '#!/bin/bash' 'for t in gh-5 gh-6; do' '  [ -e .10x/$t/plan.md ] && continue' '  10x-worktree init $t' \
  '  printf "## Files\n- a\n- b\n- c\n- d\n" >.10x/$t/plan.md' '  echo cold >.10x/$t/cold-read.md' 'done' >"$tmp/writes-wide-plan"
printf '%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"cat > .10x/gh-5/plan.md <<'"'"'EOF'"'"'\nplan\nEOF"}}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"cat > .10x/gh-6/plan.md <<'"'"'EOF'"'"'\nplan\nEOF"}}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"Agent","input":{"subagent_type":"Explore","prompt":"cold read"}}]}}' \
  '{"type":"result","subtype":"success","permission_denials":[],"total_cost_usd":0.01,"duration_ms":10}' >"$tmp/stream-wide-plan"
if runner 0 "a plan written by Bash counts as written" "STUB_STREAM=$tmp/stream-wide-plan" "STUB_RUN=$tmp/writes-wide-plan" -- W3; then
  line_matches '^pass  W3  [0-9]+s$' && ok "W3 counts a plan.md written by a Bash redirect" || { bad "W3 counts a plan.md written by a Bash redirect"; sed 's/^/      /' "$tmp/out" "$tmp/err"; }
fi

# F2: a small ticket needs no plan.md, only a work session that reached its report; any other ticket still needs plan.md.
# The stub opens a draft, approves it into .10x/greet-twice/ticket.md, then runs the work turn: STUB_SIZE=small puts
# `Size: small` in the ticket, STUB_WORK is met (review.md and a met evidence line), pending or none.
cat >"$tmp/f2-stub" <<'STUB'
#!/bin/bash
if [ -e .10x/greet-twice/ticket.md ]; then
  case "${STUB_WORK:-none}" in
    met) echo report >.10x/greet-twice/review.md; echo '- AC1 — met: test greet once' >.10x/greet-twice/evidence.md ;;
    pending) echo report >.10x/greet-twice/review.md; echo '- AC1 — pending' >.10x/greet-twice/evidence.md ;;
  esac
elif [ -e .10x/drafts/greet-twice.md ]; then
  mkdir -p .10x/greet-twice
  mv .10x/drafts/greet-twice.md .10x/greet-twice/ticket.md
else
  mkdir -p .10x/drafts
  { echo '# greet prints every greeting twice'; [ "${STUB_SIZE:-}" = small ] && echo 'Size: small'; printf '\n## Acceptance criteria\n- AC1 — greet prints each greeting once\n'; } >.10x/drafts/greet-twice.md
fi
STUB
if runner 0 "F2 passes a small ticket with a report" "STUB_STREAM=$tmp/stream-empty" "STUB_RUN=$tmp/f2-stub" STUB_SIZE=small STUB_WORK=met -- F2; then
  line_matches '^pass  F2  [0-9]+s$' && ok "F2 passes a small ticket with no plan.md once work reached its report" || { bad "F2 passes a small ticket with no plan.md once work reached its report"; sed 's/^/      /' "$tmp/out" "$tmp/err"; }
fi
if runner 1 "F2 fails a small ticket without a report" "STUB_STREAM=$tmp/stream-empty" "STUB_RUN=$tmp/f2-stub" STUB_SIZE=small STUB_WORK=pending -- F2; then
  line_matches '^FAIL  F2  [0-9]+s  .*work did not reach its report' && ok "F2 fails a small ticket whose work did not reach its report" || { bad "F2 fails a small ticket whose work did not reach its report"; sed 's/^/      /' "$tmp/out" "$tmp/err"; }
fi
if runner 1 "F2 fails a ticket that is not small without a plan" "STUB_STREAM=$tmp/stream-empty" "STUB_RUN=$tmp/f2-stub" STUB_WORK=none -- F2; then
  line_matches '^FAIL  F2  [0-9]+s  .*plan\.md is missing' && ! line_matches 'work did not reach its report' && ok "F2 still requires plan.md for a ticket that is not small" || { bad "F2 still requires plan.md for a ticket that is not small"; sed 's/^/      /' "$tmp/out" "$tmp/err"; }
fi

# R2: the stub's calls are the roadmap flow's turns: 1 writes the first draft, 2 approves it, 3 writes the second draft,
# 4 applies it. v1's Contents gains `--from file` at the end; STUB_V2_WHY changes v2's Why this order cell.
cat >"$tmp/r2-stub" <<'STUB'
#!/bin/bash
n="$(grep -c . "$STUB_MARK")"
roadmap() {
  printf '%s\n' '| Version | Contents | Why this order | State |' '|---|---|---|---|' \
    "| v1 | $1 | smallest first | Planned |" "| v2 | --lang flag | $2 | Planned |" '' \
    '## Not yet assigned' '' '## Later' '' '## Decided against' ''
}
mkdir -p .10x
case "$n" in
  1) roadmap '--shout flag; several names' 'needs v1' >.10x/roadmap.draft.md ;;
  2) mv .10x/roadmap.draft.md .10x/roadmap.md ;;
  3) roadmap '--shout flag; several names; --from file' 'needs v1' >.10x/roadmap.draft.md ;;
  4) roadmap '--shout flag; several names; --from file' "${STUB_V2_WHY:-needs v1}" >.10x/roadmap.md; rm .10x/roadmap.draft.md ;;
esac
STUB
if runner 0 "R2 accepts a grown Contents cell" "STUB_STREAM=$tmp/stream-empty" "STUB_RUN=$tmp/r2-stub" -- R2; then
  line_matches '^pass  R2  [0-9]+s$' && ok "R2 accepts a first-run row that gained items at the end of its Contents cell" || { bad "R2 accepts a first-run row that gained items at the end of its Contents cell"; sed 's/^/      /' "$tmp/out" "$tmp/err"; }
fi
if runner 1 "R2 fails a row changed elsewhere" "STUB_STREAM=$tmp/stream-empty" "STUB_RUN=$tmp/r2-stub" "STUB_V2_WHY=needs nothing" -- R2; then
  line_matches '^FAIL  R2  [0-9]+s  ' && grep -Fq 'roadmap.md lost the line: | v2 | --lang flag | needs v1 | Planned |' "$tmp/out" && ! grep -Fq 'lost the line: | v1 ' "$tmp/out" \
    && ok "R2 fails a first-run row changed anywhere else" || { bad "R2 fails a first-run row changed anywhere else"; sed 's/^/      /' "$tmp/out" "$tmp/err"; }
fi

# the fake gh takes gh's global --hostname before the subcommand, as 10x-ticket issue-types sends it
mkdir -p "$tmp/ghd"
echo '{"graphql":{"data":{"repository":{"issueTypes":{"nodes":[{"name":"Bug"}]}}}}}' >"$tmp/ghd/canned.json"
if E2E_GH_DIR="$tmp/ghd" "$(dirname "$RUN_SH")/bin/gh" api --hostname github.com graphql -f 'query=q' >"$tmp/out" 2>"$tmp/err" &&
  [ "$(jq -r '.data.repository.issueTypes.nodes[0].name' "$tmp/out")" = Bug ]; then
  ok "the fake gh answers api --hostname <host> graphql"
else
  bad "the fake gh answers api --hostname <host> graphql"; sed 's/^/      /' "$tmp/out" "$tmp/err"
fi

[ "$fail" -eq 0 ] && echo "e2e-runner: all cases pass"
exit "$fail"
