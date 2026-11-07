#!/bin/bash
# Unit cases for bin/10x-batch on a throwaway repository with a bare origin, a stub gh and a stub worker
# (TENX_BATCH_CLAUDE). Run records are written by real runs where the spawn matters, and by hand where only the
# derived phase does.
# shellcheck disable=SC2015,SC2016,SC2329  # `cond && ok || bad` is safe: ok always returns 0; backticks in patterns are literal Markdown; helpers run through need and trap
set -uo pipefail
BIN="$(cd "$(dirname "$0")/.." && pwd)/bin"
fail=0
ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }

tmp=$(cd "$(mktemp -d)" && pwd -P)
# The conductor's temp dir and the state dir both lie under $tmp, outside each other and outside the repository.
mkdir "$tmp/t"
export TMPDIR="$tmp/t" XDG_STATE_HOME="$tmp/state"
sleepers=()
bgs=()
cleanup() {
  local p
  for p in ${sleepers[@]+"${sleepers[@]}"} ${bgs[@]+"${bgs[@]}"}; do kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir "$tmp/stub"
cat >"$tmp/stub/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$STUB_LOG"
case "$1 $2" in
  "issue view")
    case " $STUB_ISSUES " in
      *" $3 "*)
        state=OPEN; case " ${STUB_CLOSED-} " in *" $3 "*) state=CLOSED ;; esac
        author=me; for p in ${STUB_AUTHORS-}; do [ "${p%%:*}" = "$3" ] && author="${p#*:}"; done
        who="{\"login\":\"$author\"}"; [ "$author" = null ] && who=null
        case " ${STUB_COMMENTS_FAIL-} " in *" $3 "*) case " $* " in *" author,comments "*) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;; esac ;; esac
        cs=""
        for p in ${STUB_COMMENTERS-}; do [ "${p%%:*}" = "$3" ] && cs="$cs${cs:+,}{\"author\":{\"login\":\"${p#*:}\"},\"body\":\"c\",\"createdAt\":\"2026-01-01T00:00:00Z\"}"; done
        printf '{"number":%s,"title":"Issue %s","body":"b","url":"https://github.com/acme/batch/issues/%s","state":"%s","labels":[],"issueType":null,"comments":[%s],"author":%s}\n' "$3" "$3" "$3" "$state" "$cs" "$who" ;;
      *) echo "GraphQL: Could not resolve to an issue or pull request with the number of $3." >&2; exit 1 ;;
    esac ;;
  "issue list") echo "${STUB_SEARCH-[]}" ;;
  "api user") echo "${STUB_LOGIN-me}" ;;
esac
exit 0
STUB
# The worker: logs <flag> TAB <session> TAB <cwd> TAB <prompt after --> (and its background-task ceiling, its
# permission flags, its --disallowedTools rules joined by | , its --settings value, whether that flag came right after
# --verbose, and its TENX_BATCH_PLAN_DIR) and prints
# $WORKER_OUT (else one text turn whose init reports the mode it was started in, after a SessionStart hook event as a
# real worker's log has), then waits $WORKER_SLEEP seconds as the same process (exit 143 on SIGTERM), or exits
# $WORKER_EXIT. Started in auto mode with $WORKER_MODE set, its init reports $WORKER_MODE instead and it waits for SIGTERM.
cat >"$tmp/stub/worker" <<'STUB'
#!/bin/bash
prompt="" flag="" session="" mode="" perm=() deny=() in="" settings=unset right=no
hook='{"type":"system","subtype":"hook_started","hook_event":"SessionStart"}'
while [ $# -gt 0 ]; do
  case "$1" in
    --) prompt="$2"; shift 2 ;;
    --session-id|--resume) flag="$1"; session="$2"; in=""; shift 2 ;;
    --permission-mode) mode="$2"; perm+=("$1" "$2"); in=perm; shift 2 ;;
    --allowedTools) perm+=("$1"); in=perm; shift ;;
    --disallowedTools) in=deny; shift ;;
    --verbose) [ "${2-}" = --settings ] && right=yes; in=""; shift ;;
    --settings) settings="$2"; in=""; shift 2 ;;
    -*) in=""; shift ;;
    *) case "$in" in perm) perm+=("$1") ;; deny) deny+=("$1") ;; esac; shift ;;
  esac
done
printf '%s\t%s\t%s\t%s\n' "$flag" "$session" "$PWD" "${prompt//$'\n'/ }" >>"$WORKER_LOG"
printf '%s\n' "${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS-unset}" >>"$WORKER_LOG.ceiling"
printf '%s\n' "${perm[*]}" >>"$WORKER_LOG.perm"
(IFS='|'; printf '%s\n' "${deny[*]}") >>"$WORKER_LOG.disallowed"
printf '%s\n' "$settings" >>"$WORKER_LOG.settings"
printf '%s\n' "$right" >>"$WORKER_LOG.afterverbose"
printf '%s\n' "${TENX_BATCH_PLAN_DIR-unset}" >>"$WORKER_LOG.plandir"
printf '%s\n' "${TENX_BATCH-unset}" >>"$WORKER_LOG.env"
# With $WORKER_SCRIPT=flow the worker also does what a real one would, then prints its usual turn: /10x:work writes a
# passing draft plan, or, once plan.md says approved, evidence and .worktrees/<id>; the approve reply sets
# `Status: approved`; /10x:close removes the worktree. A reply finds its ticket through the session it resumes.
if [ "${WORKER_SCRIPT:-}" = flow ]; then
  case "$prompt" in
    '/10x:work '*|'/10x:close '*) id="${prompt#* }"; [ "$flag" = --session-id ] && printf '%s %s\n' "$session" "$id" >>"$WORKER_LOG.sessions" ;;
    *) id="$(awk -v s="$session" '$1 == s { print $2 }' "$WORKER_LOG.sessions")" ;;
  esac
  case "$prompt" in
    '/10x:work '*)
      if grep -q '^Status: approved' ".10x/$id/plan.md" 2>/dev/null; then
        printf -- '- AC1 — met: x\n' >".10x/$id/evidence.md"; mkdir -p ".worktrees/$id"
      else
        printf '# %s\n\nStatus: draft\n\n## Acceptance criteria\n- AC1 — the change works\n\n## Approach\nOne change.\n\n## Files\n- `f-%s` — changed\n\n## Readers\n- `thing` — `grep -rn thing`\n  - no hits\n\n## Overlap\n- none\n\n## Tests\n| AC | Test file | Case |\n|---|---|---|\n| AC1 | `tests/x.sh` | `works` |\n' "$id" "$id" >".10x/$id/plan.md"
      fi ;;
    '/10x:close '*) rmdir ".worktrees/$id" ;;
    Approved.*) sed -i.bak 's/^Status: draft/Status: approved/' ".10x/$id/plan.md"; rm -f ".10x/$id/plan.md.bak" ;;
  esac
fi
if [ "$mode" = auto ] && [ -n "${WORKER_MODE:-}" ]; then
  printf '%s\n{"type":"system","subtype":"init","permissionMode":"%s"}\n' "$hook" "$WORKER_MODE"
  trap 'kill "$s" 2>/dev/null; exit 143' TERM INT
  sleep 300 & s=$!
  wait "$s"
  exit 0
fi
if [ -n "${WORKER_OUT:-}" ]; then cat "$WORKER_OUT"
else
  printf '%s\n{"type":"system","subtype":"init","permissionMode":"%s"}\n' "$hook" "$mode"
  printf '%s\n' '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"done"}]}}' \
    '{"type":"result","result":"done"}'
fi
if [ -n "${WORKER_SLEEP:-}" ]; then
  trap 'kill "$s" 2>/dev/null; exit 143' TERM INT
  sleep "$WORKER_SLEEP" & s=$!
  wait "$s"
fi
exit "${WORKER_EXIT:-0}"
STUB
chmod +x "$tmp/stub/gh" "$tmp/stub/worker"
export PATH="$tmp/stub:$BIN:$PATH" STUB_LOG="$tmp/stub.log" WORKER_LOG="$tmp/worker.log" STUB_ISSUES="5 6 7 8 9"
export TENX_BATCH_CLAUDE="$tmp/stub/worker"
unset CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS TENX_BATCH_PLAN_DIR TENX_BATCH CLAUDE_CONFIG_DIR
# The worker's write rules follow ZDOTDIR and XDG_CONFIG_HOME: the cases set them where they matter.
unset ZDOTDIR XDG_CONFIG_HOME

git -c init.defaultBranch=main init -q --bare "$tmp/origin.git"
git -c init.defaultBranch=main init -q "$tmp/repo"
cd "$tmp/repo" || exit 2
git config user.email t@t; git config user.name t
echo base >README.md; mkdir sub; echo x >sub/x.txt; echo 'export const b = 1' >sub/base.test.mjs
git add -A && git commit -qm init
git remote add origin "$tmp/origin.git" && git push -q -u origin main
# origin's repo is read from its URL; nothing in these cases fetches or pushes.
git remote set-url origin git@github.com:acme/batch.git
mkdir -p .claude
root="$(pwd -P)"
B=.10x/_batch
# state_dir — S as AC2 defines it: <base>/10x/<first 16 hex of sha256 of realpath(git common dir)>, canonical.
state_dir() {
  node -e '
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
  '
}
S="$(state_dir)"
SB="$S/batch"

# ---------------------------------------------------------------- helpers

reset() {
  local p
  for p in ${sleepers[@]+"${sleepers[@]}"} ${bgs[@]+"${bgs[@]}"}; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  sleepers=(); bgs=()
  rm -rf .10x .worktrees .git/10x-batch "$XDG_STATE_HOME"
  : >"$WORKER_LOG"; : >"$WORKER_LOG.perm"; : >"$WORKER_LOG.disallowed"; : >"$WORKER_LOG.plandir"; : >"$STUB_LOG"
  : >"$WORKER_LOG.settings"; : >"$WORKER_LOG.afterverbose"
  : >"$WORKER_LOG.env"; : >"$WORKER_LOG.sessions"
  echo '{"close":"local"}' >.claude/10x.json
}
# lp <seconds> [args...] — `10x-batch loop` bounded by <seconds> (killed then, LRC=124); LRC is its exit status, stdout
# is in $tmp/loop.out and stderr in $tmp/loop.err, both also in $tmp/out.
lp() {
  local limit=$1 p i rc
  shift
  10x-batch loop "$@" >"$tmp/loop.out" 2>"$tmp/loop.err" &
  p=$!
  for ((i = 0; i < limit * 10; i++)); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$p" 2>/dev/null; then kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; rc=124; else wait "$p"; rc=$?; fi
  cat "$tmp/loop.out" "$tmp/loop.err" >"$tmp/out"
  LRC=$rc
}
printed() { [ "$(cat "$tmp/loop.out")" = "$1" ] || { echo "        printed: $(cat "$tmp/loop.out") (want $1)"; false; }; }
finished() { [ "$LRC" -ne 124 ]; }
# snap — every file under .10x, .git and the state dir with its checksum.
snap() { find .10x .git "$XDG_STATE_HOME" -type f -print0 2>/dev/null | sort -z | xargs -0 cksum; }
# fetched <n> — an `issue view <n>` call that is not the author lookup.
fetched() { grep "^issue view $1 " "$STUB_LOG" | grep -v -- '--json author' | grep -q .; }
# The fixed reply of auto mode, byte for byte.
cat >"$tmp/fixed" <<'EOF'
Auto mode: no human answers this batch's questions. A question the ticket itself asks, and any product question — what the user gets, the outcome of an edge case, what counts as done — is a product question. If any question you asked is a product question, answer none of them: write their numbers, one per line, to `product-questions.md` in this ticket's `.10x/<id>/` directory, and stop. Otherwise answer every question with your own recommendation, record each in plan.md under `## Auto decisions`, one line per question (its number, the choice and why), and go on.
EOF
# A worker turn that asks a question and writes no plan.
cat >"$tmp/question.jsonl" <<'EOF'
{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"Which flag name should the CLI use, --fast or --quick?"}]}}
{"type":"result","result":"Which flag name should the CLI use, --fast or --quick?"}
EOF
begin() { CASE="$1"; cfail=0; }
# need <what> <command...> — one check of the current case; prints the last output when it fails.
need() {
  local what=$1; shift
  "$@" && return 0
  cfail=1; echo "      not: $what"
  [ -s "$tmp/out" ] && sed 's/^/        /' "$tmp/out"
  return 0
}
end() { [ "$cfail" = 0 ] && ok "$CASE" || bad "$CASE"; }
not() { ! "$@"; }
vb() { 10x-batch "$@" >"$tmp/out" 2>&1; }
exits() { local want=$1; shift; vb "$@"; [ $? -eq "$want" ]; } # <exit> <args...>
has() { grep -qF -- "$1" "$tmp/out"; }
line() { grep -qxF -- "$1" "$tmp/out"; }
acts() { grep -E '^(plan|implement|close|answer) |^done$' "$tmp/out" | tr '\n' ',' | sed 's/,$//'; }
acts_are() { vb status && [ "$(acts)" = "$1" ] || { echo "        actions: $(acts) (want $1)"; false; }; }
phase() { vb status >/dev/null; grep "^| [0-9]* | $1 |" "$B/board.md" | awk -F' [|] ' '{ print $3 }'; }
phase_is() { local got; got="$(phase "$1")"; [ "$got" = "$2" ] || { echo "        $1 is $got (want $2)"; false; }; }
ticket() { local id; for id in "$@"; do mkdir -p ".10x/$id"; echo "# $id" >".10x/$id/ticket.md"; done; }
# plan_md <id> <status> [<file>...] — a plan that passes 10x-plan-check, binding <file>s.
plan_md() {
  local id=$1 st=$2 f; shift 2
  {
    printf '# %s\n\nStatus: %s\n\n## Acceptance criteria\n- AC1 — the change works\n\n## Approach\nOne change.\n\n## Files\n' "$id" "$st"
    for f in "$@"; do printf -- '- `%s` — changed\n' "$f"; done
    printf '\n## Readers\n- `thing` — `grep -rn thing`\n  - no hits\n\n## Overlap\n- none\n\n## Tests\n| AC | Test file | Case |\n|---|---|---|\n| AC1 | `tests/x.sh` | `works` |\n'
  } >".10x/$id/plan.md"
}
# row <id> <kind> <session_kind> <exit | open:<pid>> — a run record written by hand.
row() {
  local f="$SB/$1/runs.tsv" n
  mkdir -p "$SB/$1"
  [ -f "$f" ] || printf 'n\tkind\tsession\tsession_kind\tstart\tend\texit\tpid\n' >"$f"
  n=$(($(wc -l <"$f")))
  if [[ $4 == open:* ]]; then printf '%s\t%s\ts-%s-%s\t%s\t1\t\t\t%s\n' "$n" "$2" "$1" "$n" "$3" "${4#open:}" >>"$f"
  else printf '%s\t%s\ts-%s-%s\t%s\t1\t2\t%s\t1\n' "$n" "$2" "$1" "$n" "$3" "$4" >>"$f"; fi
}
evidence() { local id=$1; shift; printf '%s\n' "$@" >".10x/$id/evidence.md"; }
# approve_plan <id> [<file>...] — the user approves a draft (10x-batch approve), then the worker marks it approved.
approve_plan() {
  local id=$1; shift
  plan_md "$id" draft "$@"; 10x-batch approve "$id" >/dev/null; rm -f "$B/$id/reply.md"
  plan_md "$id" approved "$@"
}
approved() { local id=$1; shift; row "$id" plan plan 0; approve_plan "$id" "$@"; }
implemented() { approved "$@"; row "$1" implement implement 0; evidence "$1" "- AC1 — met: \`bash tests/x.sh\`"; mkdir -p ".worktrees/$1"; }
sleeper() { sleep 300 >/dev/null 2>&1 & sleepers+=($!); SLEEPER=$!; }
# run_bg <id> <kind> — 10x-batch run in the background with a worker that sleeps; waits until its row is open.
run_bg() {
  local _
  WORKER_SLEEP=300 10x-batch run "$1" "$2" >"$tmp/bg.out" 2>&1 &
  BG=$!; bgs+=("$BG")
  for _ in $(seq 1 100); do
    awk -F'\t' 'NR > 1 && $6 == "" && $8 != "" { f = 1 } END { exit !f }' "$SB/$1/runs.tsv" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}
field() { awk -F'\t' -v n="$2" -v c="$3" 'NR == n + 1 { print $c }' "$SB/$1/runs.tsv"; } # <id> <run n> <column>
# roadmap <row>... — a .10x/roadmap.md holding <row>s and the three sections.
roadmap() {
  mkdir -p .10x
  { printf '# Roadmap\n\n| Version | Contents | Why this order | State |\n|---|---|---|---|\n'; printf '%s\n' "$@"
    printf '\n## Not yet assigned\n- later idea\n\n## Later\n\n## Decided against\n- milestones — never\n'; } >.10x/roadmap.md
}
landed() { implemented "$@"; row "$1" close close 0; rmdir ".worktrees/$1"; } # <id> <file>...

# ---------------------------------------------------------------- init

reset; ticket t1
begin "init: an argument with no ticket exits 2 naming it, no board, no worker"
need "exit 2" exits 2 init t1 nope 404 https://github.com/other/r/issues/5 gh-6 'bad/id'
need "names nope" has "10x-batch: no ticket: nope (no .10x/nope/ticket.md)"
need "names 404 with gh's message" has "10x-batch: no ticket: 404 (10x-ticket: GraphQL: Could not resolve"
need "names a URL of another repo" has "10x-batch: no ticket: https://github.com/other/r/issues/5 (not an issue of origin's repo acme/batch)"
need "names an invalid id" has "10x-batch: no ticket: bad/id ("
need "does not name the good ones" not has "no ticket: t1"
need "does not name gh-6" not has "no ticket: gh-6"
need "no _batch" test ! -e "$B"
need "no gh-404 left behind" test ! -e .10x/gh-404
need "no worker" test ! -s "$WORKER_LOG"
STUB_SEARCH='[]' vb init t1 --search "label:none"
need "a search with no match exits 2" test $? -eq 2
need "names the search" has '10x-batch: no ticket: --search "label:none" (no open issue matches)'
need "still no _batch" test ! -e "$B"
need "two searches are a usage error" exits 2 init --search a --search b
end

reset; ticket t1
mkdir -p .10x/gh-5 && echo "kept" >.10x/gh-5/ticket.md
begin "init: gh ids, a number, a search and an existing id resolve"
STUB_SEARCH='[{"number":9},{"number":5}]' vb init gh-5 6 '#7' https://github.com/acme/batch/issues/8 t1 gh-5 --search "label:batch"
need "exit 0" test $? -eq 0
need "tickets in intake order, deduplicated" test "$(tr '\n' ' ' <"$SB/tickets")" = "gh-5 gh-6 gh-7 gh-8 t1 gh-9 "
need "an existing ticket.md is fetched again" grep -qx '# Issue 5' .10x/gh-5/ticket.md
need "gh-5 is fetched" fetched 5
need "the others are fetched" grep -qx '# Issue 9' .10x/gh-9/ticket.md
need "#7 and the URL are fetched" eval 'grep -qx "# Issue 7" .10x/gh-7/ticket.md && grep -qx "# Issue 8" .10x/gh-8/ticket.md'
need "the search is pinned to origin's repo" grep -qxF 'issue list --repo github.com/acme/batch --state open --search label:batch --json number --limit 100' "$STUB_LOG"
need "the board is written" test -f "$B/board.md"
need "every ticket can plan" test "$(acts)" = "plan gh-5,plan gh-6,plan gh-7,plan gh-8,plan t1,plan gh-9"
need "no worker" test ! -s "$WORKER_LOG"
end

reset; ticket t1 v3
roadmap '| v1 | first `t1`; second `gh-5`; use `md-check.js` | base | Planned |' '| v3 | x `t1` | y | Planned |'
begin "init: a roadmap version resolves to its row's ticket ids"
need "a ticket id wins over a version of that name" eval 'exits 0 init v3 && test "$(cat "$SB/tickets")" = v3 && test ! -e "$SB/versions"'
vb drop v3
need "exit 0" exits 0 init v1 t1
need "its ids, deduplicated with the other arguments" test "$(tr '\n' ' ' <"$SB/tickets")" = "t1 gh-5 "
need "gh-5 is fetched like any argument" grep -qx '# Issue 5' .10x/gh-5/ticket.md
need "the version is recorded" test "$(cat "$SB/versions")" = v1
need "no closed ids" test ! -e "$SB/versions.closed"
need "an unknown name is still no ticket" eval 'exits 2 init v9 && has "10x-batch: no ticket: v9 (no .10x/v9/ticket.md)"'
end

reset
roadmap '| v1 | first `t1` | base | Planned |' '| v2 | an idea; another | later | Planned |'
begin "init: a roadmap version with no ticket ids exits 2"
need "exit 2" exits 2 init v2
need "names the way to make them" line "10x-batch: version v2 has no ticket ids: run /10x:roadmap tickets v2"
need "no _batch" test ! -e "$B"
roadmap '| v2 | an idea | | Planned |'
need "a roadmap that fails its check exits 2" exits 2 init v2
need "naming the fault" has "10x-batch: no ticket: v2 (.10x/roadmap.md:5: version v2 has an empty Why this order)"
end

reset
roadmap '| v1 | a `gh-5`; b `gh-6`; c `gh-7` | base | Planned |'
begin "init: a version leaves out its closed issues and counts them as landed"
STUB_CLOSED="6 7" vb init v1
need "exit 0" test $? -eq 0
need "only the open issue is batched" test "$(cat "$SB/tickets")" = gh-5
need "the closed ones are recorded" test "$(tr '\n' ' ' <"$SB/versions.closed")" = "gh-6 gh-7 "
need "their state was asked of origin's repo" grep -qxF 'issue view 6 --repo github.com/acme/batch --json state' "$STUB_LOG"
need "a closed issue is not fetched" test ! -e .10x/gh-6
need "not done while gh-5 is open" eval 'vb status && not has "roadmap: " && grep -qF "| Planned |" .10x/roadmap.md'
landed gh-5 a
need "done once gh-5 landed" eval 'vb status && line "roadmap: v1 Done $(date +%Y-%m-%d)"'
end

reset; ticket t1 t2
roadmap '| v1 | a `t1`; b `t2`; c `gh-5` | base | Planned |'
printf 'landed on main at abc1234\n' >.10x/t1/landed
mkdir -p .10x/gh-5 && printf 'landed on main at abc1234\n' >.10x/gh-5/landed
begin "init: a version leaves out its landed tickets and counts them as landed"
need "exit 0" exits 0 init v1
need "only the open ticket is queued" test "$(cat "$SB/tickets")" = t2
need "the landed ones are recorded" test "$(tr '\n' ' ' <"$SB/versions.closed")" = "t1 gh-5 "
need "no issue view for the landed gh ticket" not grep -q '^issue view 5 ' "$STUB_LOG"
need "not done while t2 is open" eval 'not has "roadmap: " && grep -qF "| Planned |" .10x/roadmap.md'
end

reset; ticket t1 t2
roadmap '| v1 | a `t1`; b `t2` | base | Planned |'
printf 'landed on main at abc1234\n' >.10x/t1/landed
printf 'landed on main at abc1234\n' >.10x/t2/landed
begin "init: a version whose tickets all landed reads Done <date>"
today="$(date +%Y-%m-%d)"
need "exit 0" exits 0 init v1
need "prints it" line "roadmap: v1 Done $today"
need "v1 reads Done <date>" grep -qxF "| v1 | a \`t1\`; b \`t2\` | base | Done $today |" .10x/roadmap.md
end

reset; ticket t1 t2
roadmap '| v1 | a `t1`; b `t2` | base | Planned |'
printf 'landed on main at abc1234\n' >.10x/t1/landed
begin "init: a landed ticket named directly is queued again"
need "init t1 exits 0" exits 0 init t1
need "t1 is queued" test "$(cat "$SB/tickets")" = t1
vb drop t1
need "init t1 v1 exits 0" exits 0 init t1 v1
need "t1 and t2 are queued" test "$(tr '\n' ' ' <"$SB/tickets")" = "t1 t2 "
need "t1 is not counted as landed" not grep -qx t1 "$SB/versions.closed"
vb drop t1; vb drop t2
need "init v1 t1 exits 0" exits 0 init v1 t1
need "t1 is queued whatever the order" test "$(tr '\n' ' ' <"$SB/tickets")" = "t2 t1 "
need "t1 is still not counted as landed" not grep -qx t1 "$SB/versions.closed"
end

reset; ticket t1 t2
roadmap '| v1 | a `t1`; b `t2` | base | Planned |'
git remote set-url origin "$tmp/origin.git"
10x-worktree add t1 --no-setup >"$tmp/wt.out" 2>&1
10x-worktree rm t1 >>"$tmp/wt.out" 2>&1
git remote set-url origin git@github.com:acme/batch.git
begin "init: a version keeps a ticket whose worktree was removed with no commits"
need "no landed record for t1" eval 'test ! -e .10x/t1/landed || { cat "$tmp/wt.out"; false; }'
need "exit 0" exits 0 init v1
need "t1 and t2 are queued" test "$(tr '\n' ' ' <"$SB/tickets")" = "t1 t2 "
need "t1 is not counted as landed" not grep -qx t1 "$SB/versions.closed"
end

reset; ticket t1 t2
roadmap '| v1 | a `t1`; b `t2` | base | Planned |' '| v2 | c `t1` | after | Planned |'
cp .10x/roadmap.md "$tmp/before.md"
begin "status: a version whose tickets all landed reads Done <date>"
vb init v1
landed t1 a; landed t2 b
today="$(date +%Y-%m-%d)"
need "status exits 0" exits 0 status
need "prints it" line "roadmap: v1 Done $today"
need "v1 reads Done <date>" grep -qxF "| v1 | a \`t1\`; b \`t2\` | base | Done $today |" .10x/roadmap.md
need "nothing else changes" test "$(diff "$tmp/before.md" .10x/roadmap.md | grep -c '^[<>]')" = 2
need "not v2, which is not in the batch" grep -qxF '| v2 | c `t1` | after | Planned |' .10x/roadmap.md
sed -i.bak "s/Done $today/Done 2020-01-01/" .10x/roadmap.md; rm .10x/roadmap.md.bak
need "the date never moves" eval 'vb status && not has "roadmap: " && grep -qF "| Done 2020-01-01 |" .10x/roadmap.md'
roadmap '| v2 | c `t1` | after | Planned |'
need "a version whose row has gone is skipped" eval 'vb status && not has "roadmap: " && grep -qxF "| v2 | c \`t1\` | after | Planned |" .10x/roadmap.md'
end

reset; ticket t1 t2
roadmap '| v1 | a `t1`; b `t2` | base | Planned |'
begin "status: a version with a ticket not landed keeps its state"
vb init v1
landed t1 a
row t2 plan plan 1
need "status exits 0" exits 0 status
need "prints no roadmap line" not has "roadmap: "
need "v1 keeps its state" grep -qxF '| v1 | a `t1`; b `t2` | base | Planned |' .10x/roadmap.md
end

reset; ticket t1
begin "init: --auto records auto, without it default, and the board shows the mode"
need "init --auto exits 0" exits 0 init --auto t1
need "mode holds auto" test "$(cat "$SB/mode")" = auto
need "the file is the word and a newline" test "$(wc -c <"$SB/mode" | tr -d ' ')" = 5
need "board line 1" test "$(sed -n 1p "$B/board.md")" = "# Batch board"
need "then a blank line" test -z "$(sed -n 2p "$B/board.md")"
need "then mode: auto" test "$(sed -n 3p "$B/board.md")" = "mode: auto"
need "then a blank line, then the table" eval 'test -z "$(sed -n 4p "$B/board.md")" && test "$(sed -n 5p "$B/board.md")" = "| # | Ticket | Phase | Session | Outcome | Evidence |"'
need "status prints mode: auto" eval 'vb status && line "mode: auto"'
need "a repeated --auto is the same flag" eval 'vb drop t1 && exits 0 init --auto --auto t1 && test "$(cat "$SB/mode")" = auto'
vb drop t1
need "init without --auto exits 0" exits 0 init t1
need "mode holds default" test "$(cat "$SB/mode")" = default
need "status prints mode: default" eval 'vb status && line "mode: default"'
need "the board says default" test "$(sed -n 3p "$B/board.md")" = "mode: default"
vb drop t1
need "--search takes --auto as its query" eval 'STUB_SEARCH="[{\"number\":5}]" exits 0 init --search --auto && test "$(cat "$SB/mode")" = default && test "$(cat "$SB/tickets")" = gh-5'
echo "junk" >"$SB/mode"
need "anything but auto reads as default" eval 'vb status && line "mode: default"'
rm -f "$SB/mode"
need "a batch with no mode file is default" eval 'vb status && line "mode: default"'
end

reset; ticket t1
roadmap '| v1 | a `gh-5`; b `gh-6` | base | Planned |'
begin "init: a stranger's issue refuses the whole batch"
for m in default auto; do
  fl=(); [ "$m" = auto ] && fl=(--auto)
  rm -rf "$B" .10x/gh-5 .10x/gh-6
  STUB_AUTHORS="6:other" vb init ${fl[@]+"${fl[@]}"} gh-5 t1 gh-6
  need "$m: an argument exits 2" test $? -eq 2
  need "$m: names the issue and its author" line "10x-batch: not your issue: gh-6 (author other)"
  need "$m: not wrapped in no ticket" not has "no ticket: gh-6"
  need "$m: does not name the issue that is mine" not has "gh-5"
  need "$m: nothing under _batch" test ! -e "$B"
  need "$m: the stranger's ticket.md is deleted again" test ! -e .10x/gh-6
  rm -rf "$B" .10x/gh-5 .10x/gh-6
  STUB_SEARCH='[{"number":5},{"number":6}]' STUB_AUTHORS="6:other" vb init ${fl[@]+"${fl[@]}"} --search "label:batch"
  need "$m: a search exits 2" test $? -eq 2
  need "$m: a search names it" has "10x-batch: not your issue: gh-6 (author other)"
  need "$m: a search writes nothing under _batch" test ! -e "$B"
  need "$m: a search leaves no ticket" test ! -e .10x/gh-6
  rm -rf "$B" .10x/gh-5 .10x/gh-6
  STUB_AUTHORS="6:other" vb init ${fl[@]+"${fl[@]}"} v1
  need "$m: a roadmap version exits 2" test $? -eq 2
  need "$m: a version names it" has "10x-batch: not your issue: gh-6 (author other)"
  need "$m: a version writes nothing under _batch" test ! -e "$B"
  rm -rf "$B" .10x/gh-5 .10x/gh-6
  mkdir -p .10x/gh-6 && echo kept >.10x/gh-6/ticket.md
  STUB_AUTHORS="6:other" vb init ${fl[@]+"${fl[@]}"} t1 gh-6
  need "$m: an existing ticket.md exits 2" test $? -eq 2
  need "$m: an existing ticket.md is checked too" has "10x-batch: not your issue: gh-6 (author other)"
  need "$m: it writes nothing under _batch" test ! -e "$B"
  need "$m: and the existing ticket stays" test "$(cat .10x/gh-6/ticket.md)" = kept
  rm -rf .10x/gh-6
done
STUB_AUTHORS="6:null" vb init gh-6
need "an issue with no author is unknown" has "10x-batch: not your issue: gh-6 (author unknown)"
end

reset; ticket t1
begin "init: only your own issues and ticket files are batched"
for m in default auto; do
  fl=(); [ "$m" = auto ] && fl=(--auto)
  rm -rf "$B" .10x/gh-5 .10x/gh-6
  vb init ${fl[@]+"${fl[@]}"} gh-5 t1 gh-6
  need "$m: exit 0" test $? -eq 0
  need "$m: all three are batched" test "$(tr '\n' ' ' <"$SB/tickets")" = "gh-5 t1 gh-6 "
  need "$m: the mode is recorded" test "$(cat "$SB/mode")" = "$m"
done
rm -rf "$B"; : >"$STUB_LOG"
need "ticket files alone call no gh" eval 'exits 0 init --auto t1 && test ! -s "$STUB_LOG"'
rm -rf "$B"
need "logins compare case-insensitively" eval 'STUB_LOGIN=ME exits 0 init --auto gh-5'
end

# ---------------------------------------------------------------- board

reset; ticket t1 t2 t3
begin "board: one row per ticket with id, phase, session, outcome, evidence and a Needs the human list"
vb init t3 t1 t2
need "starts empty" grep -qxF -- '- none' "$B/board.md"
need "header" test "$(sed -n 1p "$B/board.md")" = "# Batch board"
need "column header" grep -qxF '| # | Ticket | Phase | Session | Outcome | Evidence |' "$B/board.md"
need "queued rows in intake order" test "$(grep '^| [0-9]' "$B/board.md" | tr -d '\n')" = "| 1 | t3 | queued | — | — | — || 2 | t1 | queued | — | — | — || 3 | t2 | queued | — | — | — |"
vb run t3 plan
plan_md t3 draft
row t1 plan plan 1
rm "$B/board.md"; vb status
s3="$(field t3 1 3)"
need "a waiting row" grep -qxF "| 1 | t3 | waiting | $s3 | — | .10x/_batch/t3/turn.md |" "$B/board.md"
need "a failed row" grep -qxF "| 2 | t1 | failed | s-t1-1 | failed | run 01 (plan) exited 1 |" "$B/board.md"
need "Needs the human: waiting" grep -qxF -- "- t3 — waiting, plan approvable: .10x/_batch/t3/turn.md" "$B/board.md"
need "Needs the human: failed" grep -qxF -- "- t1 — failed: run 01 (plan) exited 1" "$B/board.md"
need "status prints the board" has "| 3 | t2 | queued | — | — | — |"
rm "$B/board.md"; vb drop t2
need "drop rewrites it" grep -qxF "| 3 | t2 | dropped | — | dropped | dropped by the user |" "$B/board.md"
rm "$B/board.md"; echo "ok" >"$B/t3/reply.md"
need "t3's reply runs in the background" run_bg t3 reply
need "the board shows it running in its session at once" grep -qF "| 1 | t3 | planning | $s3 | — |" "$B/board.md"
kill -TERM "$BG"; wait "$BG"
rm "$B/board.md"; echo "ok" >"$B/t3/reply.md"; vb run t3 reply
need "run rewrites it" test -f "$B/board.md"
need "run prints the phase and the board" eval 'line "phase: waiting" && line "board: $root/.10x/_batch/board.md"'
end

reset; ticket t1 t2 t3
begin "board: an auto-approved ticket shows auto-approved with its hash"
vb init --auto t1 t2 t3
approved t1 a; approved t2 b
h="$(sed 's/^Status:.*$/Status:/' .10x/t1/plan.md | shasum -a 256 | cut -d' ' -f1)"
printf '%s\n' "$h" >"$SB/t1/auto-approved"
vb status
need "the approved row reads auto-approved (sha256 <12 hex>)" grep -qxF "| 1 | t1 | approved | $(field t1 1 3) | — | auto-approved (sha256 ${h:0:12}) |" "$B/board.md"
need "a ticket you approved shows none" not grep -q "| t2 |.*auto-approved" "$B/board.md"
need "t2's row is as before" grep -qxF "| 2 | t2 | approved | $(field t2 1 3) | — | — |" "$B/board.md"
row t1 implement implement 0; evidence t1 "- AC1 — met: x"; mkdir -p .worktrees/t1
row t1 close close 0; rmdir .worktrees/t1
vb status
need "a landed row keeps it, first" grep -qxF "| 1 | t1 | landed | $(field t1 3 3) | landed | auto-approved (sha256 ${h:0:12}); landed on main at $(git rev-parse --short main) |" "$B/board.md"
touch "$SB/t1/dropped"
vb status
need "a dropped ticket shows none" grep -qxF "| 1 | t1 | dropped | $(field t1 3 3) | dropped | dropped by the user |" "$B/board.md"
row t3 plan plan 0; plan_md t3 draft c; echo "q" >"$B/t3/turn.md"
printf '%s\n' "0123456789abcdef0123456789abcdef" >"$SB/t3/auto-approved"
vb status
need "it shows under Needs the human too" grep -qxF -- "- t3 — waiting, plan approvable: auto-approved (sha256 0123456789ab); .10x/_batch/t3/turn.md" "$B/board.md"
end

# ---------------------------------------------------------------- run, reply and rounds

reset; ticket t1 t2
begin "run: every worker starts in auto mode with no --allowedTools"
vb init t1 t2
TENX_BATCH_PLAN_DIR=/elsewhere vb run t1 plan
echo "go" >"$B/t1/reply.md"; vb run t1 reply
approve_plan t1 a; TENX_BATCH_PLAN_DIR=/elsewhere vb run t1 implement
evidence t1 "- AC1 — met: x"; mkdir -p .worktrees/t1
echo "go on" >"$B/t1/reply.md"; vb run t1 reply
TENX_BATCH_PLAN_DIR=/elsewhere vb run t1 close
need "five runs" test "$(wc -l <"$WORKER_LOG.perm" | tr -d ' ')" = 5
need "each in auto mode with no other permission flag" test "$(sort -u "$WORKER_LOG.perm")" = "--permission-mode auto"
need "no --allowedTools" not grep -qF -- --allowedTools "$WORKER_LOG.perm"
need "no fallback" eval 'test -z "$(find "$B/t1" -name "*-fallback")" && test "$(wc -l <"$SB/t1/runs.tsv" | tr -d " ")" = 6'
need "the plan and plan-reply runs get the ticket dir, implement and close no variable" \
  test "$(tr '\n' ' ' <"$WORKER_LOG.plandir")" = "$root/.10x/t1 $root/.10x/t1 unset unset unset "
end

reset; ticket t1 t2
begin "run: every worker has TENX_BATCH=1"
vb init t1 t2
vb run t1 plan
echo "go" >"$B/t1/reply.md"; vb run t1 reply
approve_plan t1 a; vb run t1 implement
evidence t1 "- AC1 — met: x"; mkdir -p .worktrees/t1
echo "go on" >"$B/t1/reply.md"; vb run t1 reply
vb run t1 close
need "five runs" test "$(wc -l <"$WORKER_LOG.env" | tr -d ' ')" = 5
need "each saw TENX_BATCH=1" test "$(sort -u "$WORKER_LOG.env")" = 1
end

reset
begin "run: an issue that is no longer yours is refused"
vb init gh-5
for k in plan reply implement close; do
  STUB_AUTHORS="5:other" vb run gh-5 "$k"
  need "$k: exit 2" test $? -eq 2
  need "$k: names the issue and its author" line "10x-batch: not your issue: gh-5 (author other)"
done
need "no worker started" test ! -s "$WORKER_LOG"
need "no run recorded" test ! -e "$SB/gh-5/runs.tsv"
STUB_AUTHORS="5:other" lp 30
need "loop finished" finished
need "loop reports it failed with the line as evidence" \
  printed '{"items":[{"id":"gh-5","need":"failed","evidence":"10x-batch: not your issue: gh-5 (author other)"}]}'
need "still no worker" test ! -s "$WORKER_LOG"
end

reset; ticket t1
begin "TENX_BATCH: a worker cannot init, run, drop, approve or loop"
vb init t1
row t1 plan plan 0; plan_md t1 draft a
before="$(snap)"
for c in "init t1" "run t1 plan" "drop t1" "approve t1" "loop"; do
  # shellcheck disable=SC2086  # the words of $c are the arguments
  TENX_BATCH=1 vb $c
  need "$c: exit 2" test $? -eq 2
  need "$c: the refusal line" line "10x-batch: refused inside a batch worker"
  need "$c: nothing changed under .10x or the git dir" test "$(snap)" = "$before"
done
need "no worker started" test ! -s "$WORKER_LOG"
need "status still works" eval 'TENX_BATCH=1 exits 0 status'
end

reset; ticket t1 t2
begin "run: a worker whose init is not auto is stopped and run again in today's mode"
vb init t1 t2
WORKER_MODE=default vb run t1 plan
need "exit 0" test $? -eq 0
need "prints the phase of the rerun" line "phase: waiting"
need "runs.tsv keeps both plan runs" test "$(field t1 1 2)/$(field t1 2 2)" = plan/plan
need "the stopped run exited 143, the rerun 0" test "$(field t1 1 7)/$(field t1 2 7)" = 143/0
need "the rerun is a new session" test "$(field t1 2 3)" != "$(field t1 1 3)"
need "a plan rerun: default with Edit under the ticket dir" \
  test "$(sed -n 2p "$WORKER_LOG.perm")" = "--permission-mode default --allowedTools Edit(.10x/t1/**)"
need "its worker still gets the ticket dir" test "$(sed -n 2p "$WORKER_LOG.plandir")" = "$root/.10x/t1"
echo "go" >"$B/t1/reply.md"
WORKER_MODE=default vb run t1 reply
need "a reply: auto, then the plan session's mode" eval 'test "$(sed -n 3p "$WORKER_LOG.perm")" = "--permission-mode auto" &&
  test "$(sed -n 4p "$WORKER_LOG.perm")" = "--permission-mode default --allowedTools Edit(.10x/t1/**)"'
need "a reply rerun resumes the same session" test "$(field t1 3 3)/$(field t1 4 3)/$(field t1 4 2)" = "$(field t1 2 3)/$(field t1 2 3)/reply"
need "with the same reply" eval 'test "$(sed -n 4p "$WORKER_LOG" | cut -f1,4)" = "$(printf -- "--resume\tgo ")" && test "$(cat "$B/t1/04-reply.md")" = go'
approve_plan t1 a
WORKER_MODE=default vb run t1 implement
need "implement: auto, then acceptEdits" eval 'test "$(sed -n 5p "$WORKER_LOG.perm")" = "--permission-mode auto" &&
  test "$(sed -n 6p "$WORKER_LOG.perm")" = "--permission-mode acceptEdits"'
need "two implement runs, two sessions" eval 'test "$(field t1 5 2)/$(field t1 6 2)" = implement/implement && test "$(field t1 5 3)" != "$(field t1 6 3)"'
evidence t1 "- AC1 — met: x"; mkdir -p .worktrees/t1
WORKER_MODE=default vb run t1 close
need "close: auto, then acceptEdits" eval 'test "$(sed -n 7p "$WORKER_LOG.perm")" = "--permission-mode auto" &&
  test "$(sed -n 8p "$WORKER_LOG.perm")" = "--permission-mode acceptEdits"'
need "two close runs" test "$(field t1 7 2)/$(field t1 8 2)/$(field t1 7 7)" = close/close/143
need "implement and close reruns get no ticket dir" test "$(sed -n '5,8p' "$WORKER_LOG.plandir" | tr '\n' ' ')" = "unset unset unset unset "
need "a rerun is never checked again" test "$(wc -l <"$WORKER_LOG.perm" | tr -d ' ')" = 8
end

reset; ticket t1 t2
begin "run: every worker is denied the commands that always ask"
want=""
for c in "10x-land issue" "10x-land comment" "10x-land advisory" "10x-batch approve" "10x-batch init" "10x-batch accept-green" \
  "10x-security set" "10x-security remove" "10x-security ticket"; do
  want+="${want:+|}Bash($c:*)|Bash($c *)"
done
edits="Edit(/$S/**)|Edit(/$root/.claude/settings.json)|Edit(/$root/.claude/settings.local.json)|Edit(/$HOME/.claude/settings.json)|Edit(/$HOME/.claude/settings.local.json)"
# rules <lines> — each line's rules sorted, the lines made unique: the order of the rules within a run is not the case's concern.
rules() { local l; while IFS= read -r l; do printf '%s\n' "$l" | tr '|' '\n' | sort | tr '\n' ' '; echo; done <<<"$1" | sort -u; }
# write_rules [<zdot>] [<worktree dir>] — the Edit rules on the files a process outside the sandbox runs, joined by |:
# the git common dir, every worktree's .git file, .envrc, the zsh files of <zdot> (default the real home) and the
# home's .zshenv, the bash, git, ssh and login-agent files of the real home, the plugin root, and the real path of
# each of them whose real path differs (a symlink at it or at any ancestor; a dangling link followed to what it names).
# real_of <path> — <path> with its deepest existing ancestor resolved through realpath and the rest appended; a
# dangling link, at <path> or at that ancestor, followed to what it names.
real_of() {
  node -e '
    const fs = require("fs"), path = require("path")
    let p = process.argv[1]
    for (let hops = 0; hops < 40; hops++) {
      const rest = []; let cur = p
      while (!fs.lstatSync(cur, { throwIfNoEntry: false })) { rest.unshift(path.basename(cur)); cur = path.dirname(cur) }
      try { p = path.join(fs.realpathSync(cur), ...rest); break } catch {
        if (!fs.lstatSync(cur).isSymbolicLink()) break
        p = path.join(path.resolve(path.dirname(cur), fs.readlinkSync(cur)), ...rest)
      }
    }
    console.log(p)' "$1"
}
write_rules() {
  local home plug zdot wt p r out=() seen="|"
  home="$(cd "$HOME" && pwd -P)"; plug="$(cd "$BIN/.." && pwd -P)"
  zdot="${1:-$home}"; wt="${2:-$root/.worktrees}"
  for p in "$root/.git/**" "$wt/*/.git" "$root/.envrc" "$zdot/.zshrc" "$zdot/.zshenv" "$zdot/.zprofile" "$zdot/.zlogin" \
    "$home/.zshenv" "$home/.bashrc" "$home/.bash_profile" "$home/.bash_login" "$home/.profile" "$home/.gitconfig" \
    "$home/.config/git/**" "$home/.ssh/config" "$home/Library/LaunchAgents/**" "$home/.config/systemd/user/**" \
    "$home/.config/autostart/**" "$plug/**"; do
    out+=("$p")
    [ "$p" = "$wt/*/.git" ] && continue
    r="$(real_of "${p%/\*\*}")"
    if [ "$r" != "${p%/\*\*}" ]; then [ "$p" = "${p%/\*\*}" ] && out+=("$r") || out+=("$r/**"); fi
  done
  for p in "${out[@]}"; do
    case "$seen" in *"|Edit(/$p)|"*) ;; *) seen+="Edit(/$p)|" ;; esac
  done
  seen="${seen#|}"; printf '%s' "${seen%|}"
}
vb init t1 t2
WORKER_MODE=default vb run t1 plan
echo "go" >"$B/t1/reply.md"; vb run t1 reply
approve_plan t1 a
WORKER_MODE=default vb run t1 implement
evidence t1 "- AC1 — met: x"; mkdir -p .worktrees/t1
vb run t1 close
need "six runs: plan and its fallback, reply, implement and its fallback, close" test "$(wc -l <"$WORKER_LOG.disallowed" | tr -d ' ')" = 6
need "each run gets every rule, the Edit rules on the state dir and settings files, and the write rules" test "$(rules "$(cat "$WORKER_LOG.disallowed")")" = "$(rules "$want|$edits|$(write_rules)")"
need "the permission flags are unchanged" test "$(tr '\n' ',' <"$WORKER_LOG.perm")" = \
  "--permission-mode auto,--permission-mode default --allowedTools Edit(.10x/t1/**),--permission-mode auto,--permission-mode auto,--permission-mode acceptEdits,--permission-mode auto,"
end

begin "run: with CLAUDE_CONFIG_DIR set, every worker is also denied Edit of its two settings files"
# <value>=<directory it resolves to>: absolute, empty (the main checkout) and relative (under the main checkout).
for vd in "$tmp/cfg=$tmp/cfg" "=$root" "cfg=$root/cfg"; do
  reset; ticket t1
  export CLAUDE_CONFIG_DIR="${vd%%=*}"; d="${vd#*=}"
  vb init t1
  vb run t1 plan
  need "exit 0 with CLAUDE_CONFIG_DIR='$CLAUDE_CONFIG_DIR'" test $? -eq 0
  need "with CLAUDE_CONFIG_DIR='$CLAUDE_CONFIG_DIR', the rules gain $d's two settings files" \
    test "$(rules "$(head -1 "$WORKER_LOG.disallowed")")" = \
    "$(rules "$want|$edits|Edit(/$d/settings.json)|Edit(/$d/settings.local.json)|$(write_rules)")"
done
unset CLAUDE_CONFIG_DIR
reset; ticket t1
vb init t1
vb run t1 plan
need "exit 0 with CLAUDE_CONFIG_DIR unset" test $? -eq 0
need "unset, the rules are unchanged" test "$(rules "$(head -1 "$WORKER_LOG.disallowed")")" = "$(rules "$want|$edits|$(write_rules)")"
end

# denies <rule> — the first run's --disallowedTools holds <rule> exactly.
denies() { head -1 "$WORKER_LOG.disallowed" | tr '|' '\n' | grep -qxF -- "$1"; }

reset; ticket t1
begin "run: a symlinked or dangling settings path is denied where it points"
# ~/.claude is a link to hreal, CLAUDE_CONFIG_DIR a link to cfgreal, whose settings.local.json is a dangling link.
mkdir -p "$tmp/h" "$tmp/hreal" "$tmp/cfgreal"; ln -s "$tmp/hreal" "$tmp/h/.claude"
ln -s "$tmp/cfgreal" "$tmp/cfglink"; ln -s "$tmp/gone/s.json" "$tmp/cfgreal/settings.local.json"
HOME="$tmp/h" CLAUDE_CONFIG_DIR="$tmp/cfglink" vb init t1
HOME="$tmp/h" CLAUDE_CONFIG_DIR="$tmp/cfglink" vb run t1 plan
need "exit 0" test $? -eq 0
for r in "$tmp/h/.claude/settings.json" "$tmp/hreal/settings.json" "$tmp/h/.claude/settings.local.json" \
  "$tmp/hreal/settings.local.json" "$tmp/cfglink/settings.json" "$tmp/cfgreal/settings.json" \
  "$tmp/cfglink/settings.local.json" "$tmp/gone/s.json"; do
  need "denies $r" denies "Edit(/$r)"
done
need "each rule once" test -z "$(head -1 "$WORKER_LOG.disallowed" | tr '|' '\n' | sort | uniq -d)"
rm -rf "${tmp:?}/h" "${tmp:?}/hreal" "${tmp:?}/cfgreal" "${tmp:?}/cfglink"
end

reset; ticket t1
echo '{"close":"local","worktreeDir":"wt"}' >.claude/10x.json
begin "run: the write rules follow worktreeDir and the git common dir"
vb init t1
vb run t1 plan
need "exit 0" test $? -eq 0
need "the repository's real git common dir" denies "Edit(/$root/.git/**)"
need "every worktree's .git file under worktreeDir" denies "Edit(/$root/wt/*/.git)"
need "not under the default worktree dir" not denies "Edit(/$root/.worktrees/*/.git)"
need "the full rule set" test "$(rules "$(cat "$WORKER_LOG.disallowed")")" = "$(rules "$want|$edits|$(write_rules "" "$root/wt")")"
end

reset; ticket t1
begin 'run: the zsh rules follow ZDOTDIR and still deny $HOME/.zshenv'
home="$(cd "$HOME" && pwd -P)"
vb init t1
ZDOTDIR="$tmp/zdot" vb run t1 plan
need "exit 0" test $? -eq 0
for f in .zshrc .zshenv .zprofile .zlogin; do need "ZDOTDIR's $f" denies "Edit(/$tmp/zdot/$f)"; done
need "the home's .zshenv, read before ZDOTDIR is set" denies "Edit(/$home/.zshenv)"
need "not the home's .zshrc" not denies "Edit(/$home/.zshrc)"
need "the full rule set" test "$(rules "$(cat "$WORKER_LOG.disallowed")")" = "$(rules "$want|$edits|$(write_rules "$tmp/zdot")")"
end

reset; ticket t1
begin 'run: a symlinked or dangling startup file is denied with its target'
mkdir -p "$tmp/zd" "$tmp/zt"; echo x >"$tmp/zt/rc"
ln -sf "$tmp/zt/rc" "$tmp/zd/.zshrc"; ln -sf "$tmp/zt/missing" "$tmp/zd/.zshenv"
vb init t1
ZDOTDIR="$tmp/zd" vb run t1 plan
need "exit 0" test $? -eq 0
need "the symlinked .zshrc" denies "Edit(/$tmp/zd/.zshrc)"
need "and its target" denies "Edit(/$tmp/zt/rc)"
need "the dangling .zshenv" denies "Edit(/$tmp/zd/.zshenv)"
need "and the path its link names" denies "Edit(/$tmp/zt/missing)"
need "the full rule set" test "$(rules "$(cat "$WORKER_LOG.disallowed")")" = "$(rules "$want|$edits|$(write_rules "$tmp/zd")")"
end

reset; ticket t1
begin 'run: a startup file under a dangling symlinked directory is denied where the link points'
ln -sfn "$tmp/zgone" "$tmp/zl"
vb init t1
ZDOTDIR="$tmp/zl/sub" vb run t1 plan
need "exit 0" test $? -eq 0
for f in .zshrc .zshenv .zprofile .zlogin; do need "$f where the dangling link points" denies "Edit(/$tmp/zgone/sub/$f)"; done
need "the full rule set" test "$(rules "$(cat "$WORKER_LOG.disallowed")")" = "$(rules "$want|$edits|$(write_rules "$tmp/zgone/sub")")"
end

reset; ticket t1
vb init t1
git remote set-url origin "$tmp/origin.git"
10x-worktree add t1 --no-setup >"$tmp/wt.out" 2>&1
git remote set-url origin git@github.com:acme/batch.git
wt1="$root/.worktrees/t1"
mkdir -p "$wt1/src"
echo 'export const a = 1' >"$wt1/src/a.test.mjs"; echo 'export const impl = 1' >"$wt1/src/impl.mjs"
git -C "$wt1" add -A && git -C "$wt1" commit -qm "feat: a"
begin "accept-green: records file, blob and reason under the state dir"
vb accept-green t1 src/a.test.mjs "portability only
no new behaviour"
need "exit 0 and the accepted line" eval '[ "$(cat "$tmp/out")" = "accepted: t1 src/a.test.mjs blob $(git -C "$wt1" rev-parse HEAD:src/a.test.mjs | cut -c1-12)" ]'
need "the record holds the entry, newlines flattened" test "$(cat "$SB/t1/accepted-green.md" 2>/dev/null)" = "$(printf '## Accepted 1\n- file: src/a.test.mjs\n- blob: %s\n- reason: portability only no new behaviour' "$(git -C "$wt1" rev-parse HEAD:src/a.test.mjs)")"
need "nothing written under the ticket dir" test ! -e .10x/t1/accepted-green.md
end

begin "accept-green: refuses a file the branch does not change as a test"
rm -f "$SB/t1/accepted-green.md"
need "a non-test file: exit 2" exits 2 accept-green t1 src/impl.mjs "r"
need "a non-test file at the base: exit 2" exits 2 accept-green t1 README.md "r"
need "a test file the branch does not change: exit 2" exits 2 accept-green t1 sub/base.test.mjs "r"
need "a file that does not exist: exit 2" exits 2 accept-green t1 src/none.test.mjs "r"
need "no record" test ! -e "$SB/t1/accepted-green.md"
end

begin "accept-green: refuses an empty reason"
need "empty: exit 2" exits 2 accept-green t1 src/a.test.mjs ""
need "blank: exit 2" exits 2 accept-green t1 src/a.test.mjs "  "
need "no record" test ! -e "$SB/t1/accepted-green.md"
end

begin "accept-green: refuses a ticket not in the batch"
need "exit 2" exits 2 accept-green t9 src/a.test.mjs "r"
need "no record" test ! -e "$SB/t9/accepted-green.md"
end

begin "accept-green: refused inside a batch worker"
before="$(snap)"
TENX_BATCH=1 vb accept-green t1 src/a.test.mjs "r"
need "exit 2" test $? -eq 2
need "the refusal line" line "10x-batch: refused inside a batch worker"
need "nothing changed" test "$(snap)" = "$before"
end

begin "accept-green is in every run's disallowed rules"
vb run t1 plan
need "both rules on the run" eval 'tr "|" "\n" <"$WORKER_LOG.disallowed" | grep -qxF "Bash(10x-batch accept-green:*)" && tr "|" "\n" <"$WORKER_LOG.disallowed" | grep -qxF "Bash(10x-batch accept-green *)"'
end

reset; ticket t1
begin "TENX_BATCH: every command a worker is denied refuses inside a batch worker"
vb init t1
vb run t1 plan
denied="$(tr '|' '\n' <"$WORKER_LOG.disallowed" | sed -n 's/^Bash(\(.*\) \*)$/\1/p' | sort -u)"
need "at least one denied command" test -n "$denied"
snap >"$tmp/deny.before"; : >"$STUB_LOG"
while IFS=' ' read -r script sub; do
  TENX_BATCH=1 "$BIN/$script" "$sub" x >"$tmp/out" 2>&1; rc=$?
  need "$script $sub: exit 2" test "$rc" = 2
  need "$script $sub: refused inside a batch worker" grep -q ': refused inside a batch worker$' "$tmp/out"
done <<<"$denied"
snap >"$tmp/deny.after"
need "nothing under .10x or .git changed" cmp -s "$tmp/deny.before" "$tmp/deny.after"
need "no gh call" test ! -s "$STUB_LOG"
end

reset; ticket t1 t2
begin "board: a fallback run shows auto mode unavailable"
vb init t1 t2
WORKER_MODE=default vb run t1 plan
need "the rerun's mode is recorded" test "$(cat "$B/t1/02-fallback")" = default
need "on the ticket's row" grep -qxF "| 1 | t1 | waiting | $(field t1 2 3) | — | .10x/_batch/t1/turn.md; auto mode unavailable: ran in default |" "$B/board.md"
vb run t2 plan
need "not when init reports auto" eval 'grep -qxF "| 2 | t2 | waiting | $(field t2 1 3) | — | .10x/_batch/t2/turn.md |" "$B/board.md" && test ! -e "$B/t2/01-fallback"'
approve_plan t1 a
WORKER_MODE=default vb run t1 implement
evidence t1 "- AC1 — met: x"; mkdir -p .worktrees/t1
need "an implement fallback ran in acceptEdits" eval 'vb status && grep -qxF "| 1 | t1 | implemented | $(field t1 4 3) | — | .10x/_batch/t1/turn.md; auto mode unavailable: ran in acceptEdits |" "$B/board.md"'
end

reset; ticket t1 t2
begin "run: turn.md holds every assistant text of the run"
vb init t1 t2
cat >"$tmp/turn.jsonl" <<'EOF'
{"type":"system","subtype":"init"}
{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"First question?"},{"type":"tool_use","id":"u1","name":"Bash","input":{"command":"ls"}}]}}
{"type":"assistant","parent_tool_use_id":"u9","message":{"content":[{"type":"text","text":"a subagent's text"}]}}
{"type":"result","result":"First question?"}
{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"Second, after a wake."}]}}
{"type":"result","result":"Second, after a wake."}
EOF
WORKER_OUT="$tmp/turn.jsonl" vb run t1 plan
need "exit 0" test $? -eq 0
need "every top-level text, in order" test "$(cat "$B/t1/turn.md")" = "$(printf 'First question?\n\nSecond, after a wake.')"
need "the stream-json log is kept" cmp -s "$tmp/turn.jsonl" "$B/t1/01-plan.jsonl"
need "no denials" test -f "$B/t1/01-denials.tsv" -a ! -s "$B/t1/01-denials.tsv"
echo "go on" >"$B/t1/reply.md"; vb run t1 reply
need "the next run overwrites it" test "$(cat "$B/t1/turn.md")" = "done"
need "the worker waits for its background tasks" test "$(tail -n 1 "$WORKER_LOG.ceiling")" = 0
echo "again" >"$B/t1/reply.md"; CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=900000 vb run t1 reply
need "a ceiling the user set is kept" test "$(tail -n 1 "$WORKER_LOG.ceiling")" = 900000
end

reset; ticket t1 t2
begin "run reply: resumes the latest session with the ticket's own reply.md"
vb init t1 t2
vb run t1 plan; vb run t2 plan
plan_md t1 draft
need "no reply.md is refused" exits 2 run t1 reply
need "names the missing reply" has "no reply at .10x/_batch/t1/reply.md"
echo "answer for t1" >"$B/t1/reply.md"; echo "answer for t2" >"$B/t2/reply.md"
(cd sub && 10x-batch run t1 reply >"$tmp/out" 2>&1)
need "exit 0" test $? -eq 0
s1="$(field t1 1 3)"
need "resumes t1's session from the main checkout with t1's reply" test "$(tail -n 1 "$WORKER_LOG")" = "$(printf -- '--resume\t%s\t%s\tanswer for t1 ' "$s1" "$root")"
need "the reply is moved to 02-reply.md" eval 'test ! -e "$B/t1/reply.md" && test "$(cat "$B/t1/02-reply.md")" = "answer for t1"'
need "t2's reply stays" test "$(cat "$B/t2/reply.md")" = "answer for t2"
need "the record: reply, same session, session kind plan, exit 0" test "$(cut -f1-4,7 "$SB/t1/runs.tsv" | sed -n 3p)" = "$(printf '2\treply\t%s\tplan\t0' "$s1")"
need "the header" test "$(head -n 1 "$SB/t1/runs.tsv")" = "$(printf 'n\tkind\tsession\tsession_kind\tstart\tend\texit\tpid')"
need "a plan run starts a new session" test "$(sed -n 1p "$WORKER_LOG" | cut -f1,4)" = "$(printf -- '--session-id\t/10x:work t1')"
sed -i.bak "s/$s1/--dangerously-skip-permissions/" "$SB/t1/runs.tsv"; rm "$SB/t1/runs.tsv.bak"
echo "again" >"$B/t1/reply.md"
need "a session that is not a uuid is refused" exits 2 run t1 reply
need "names it" has "its latest session '--dangerously-skip-permissions' is not a session id"
end

reset; ticket t1
begin "run reply: the reply is passed after --, and one starting with / is refused"
vb init t1
vb run t1 plan
printf -- '- go with A\n' >"$B/t1/reply.md"
need "a reply starting with - runs" exits 0 run t1 reply
need "the worker got it as the prompt" test "$(tail -n 1 "$WORKER_LOG" | cut -f4)" = "- go with A "
printf '  /10x:close t1\n' >"$B/t1/reply.md"
need "a reply starting with / is refused" exits 2 run t1 reply
need "names why" has "reply t1 refused: .10x/_batch/t1/reply.md starts with '/'"
need "no worker started for it" test "$(wc -l <"$WORKER_LOG" | tr -d ' ')" = 2
end

reset; ticket t1 t2 t3
begin "run reply: refused while a plan run of its round is open; one round's replies run together"
vb init t1 t2 t3
approved t3 x; row t3 implement implement 0; evidence t3 "- AC1 — asked: Which flag name?"; mkdir -p .worktrees/t3
need "t2 plans in the background" run_bg t2 plan
vb run t1 plan
echo "answer" >"$B/t1/reply.md"
need "the reply is refused while t2, started before t1's run ended, plans" exits 2 run t1 reply
need "names the open planning run" has "t2 still planning"
need "the reply stays" test -f "$B/t1/reply.md"
need "no answer for t1 yet; an implement question at once" acts_are "answer t3"
kill -TERM "$BG"; wait "$BG"
need "the killed run forwards the signal and records it" test "$(field t2 1 7)" = 143
echo "answer for t2" >"$B/t2/reply.md"
need "t1's reply runs in the background once the round has ended" run_bg t1 reply
need "t2's reply of the same round runs while it does" exits 0 run t2 reply
need "the next round waits for both" acts_are "answer t3"
end

reset; ticket t1 t2 t3 t4
begin "status: approvable only for a draft that passes plan-check"
vb init t4 t1 t2 t3
for t in t1 t2 t3 t4; do row "$t" plan plan 0; done
plan_md t1 draft
plan_md t2 draft; sed -i.bak '/^## Overlap/,/^- none/d' .10x/t2/plan.md
approve_plan t4
need "t1 approvable, t2 and t3 answers, t4 implements" acts_are "answer t1 approvable,answer t2,answer t3,implement t4"
end

reset; ticket t1 t2
begin "status: an approved ticket implements while another is still planning"
vb init t1 t2
vb run t1 plan; approve_plan t1
need "t2 plans in the background" run_bg t2 plan
need "t1 can implement" acts_are "implement t1"
need "run implement starts" exits 0 run t1 implement
need "in a new session with /10x:work" test "$(tail -n 1 "$WORKER_LOG" | cut -f1,4)" = "$(printf -- '--session-id\t/10x:work t1')"
need "a session other than the plan's" test "$(field t1 2 3)" != "$(field t1 1 3)"
need "recorded as an implement run" test "$(field t1 2 2)/$(field t1 2 4)" = implement/implement
need "t2 still planning" phase_is t2 planning
end

if ps -o command= -p $$ >/dev/null 2>&1; then
reset; ticket t1 t2
begin "drop: stops the running worker, marks dropped, never scheduled again"
vb init t1 t2
approved t1 a
need "t1 implements in the background" run_bg t1 implement
wpid="$(field t1 2 8)"
need "drop exits 0" exits 0 drop t1
wait "$BG"
need "the worker is stopped" not kill -0 "$wpid" 2>/dev/null
need "its run is recorded as killed" test "$(field t1 2 7)" = 143
need "the marker" test -f "$SB/t1/dropped"
need "the row is dropped" phase_is t1 dropped
need "t1 is never scheduled" acts_are "plan t2"
sleeper; row t2 plan plan "open:$SLEEPER"
need "drop of a run whose pid is not its worker" exits 0 drop t2
need "leaves that process alone" kill -0 "$SLEEPER"
kill "$SLEEPER"; wait "$SLEEPER" 2>/dev/null; rm "$SB/t2/runs.tsv" "$SB/t2/dropped"
need "run plan refused" exits 2 run t1 plan
need "run implement refused" exits 2 run t1 implement
need "drop of a queued ticket" exits 0 drop t2
need "nothing left to schedule" acts_are "done"
need "a settled batch is archived by the next init" exits 0 init t2
need "into _batch.<stamp>" eval 'ls -d .10x/_batch.2* >/dev/null 2>&1 && test "$(cat "$SB/tickets")" = t2'
approved t2 a
need "t2 implements in the background" run_bg t2 implement
need "init refuses an unsettled batch" exits 2 init t1
need "naming its tickets" has "has unsettled tickets: t2 (implementing)"
end
else
  echo "skip: drop — ps is not permitted here"
fi

reset; ticket t1 t2
begin "approve: records the plan's hash under the git dir, and approved needs a matching record"
vb init t1 t2
row t1 plan plan 0; plan_md t1 draft a; row t2 plan plan 0
need "a ticket with no approvable plan is refused" exits 2 approve t2
need "names why" has "approve t2 refused: t2 is waiting and its plan.md is not a draft that passes 10x-plan-check"
need "approve exits 0" exits 0 approve t1
need "it names the plan it approved, with its hash" grep -qE '^plan: \.10x/t1/plan\.md sha256 [0-9a-f]{12}$' "$tmp/out"
need "the record is in the state dir, outside .10x and the git dir" test -s "$S/t1.approved"
need "it writes the approve reply" grep -qF 'Approved. Set `Status: approved` in plan.md and stop' "$B/t1/reply.md"
plan_md t1 approved a
need "approved once the worker marks it" phase_is t1 approved
plan_md t2 approved b
need "a plan that approves itself fails" phase_is t2 failed
need "naming it" grep -qF "| t2 | failed | s-t2-1 | failed | plan.md says approved, but no approval of yours matches it (10x-batch approve t2) |" "$B/board.md"
plan_md t1 approved a c
need "a plan changed after approval fails" phase_is t1 failed
need "neither implements" acts_are "done"
need "a ticket batched again" exits 0 init t1
row t1 plan plan 0
plan_md t1 approved a
need "needs a new approval for the plan approved before" eval 'test ! -e $S/t1.approved && phase_is t1 failed'
end

# ---------------------------------------------------------------- schedule

reset; ticket t1 t2 t3
begin "schedule: at most batch.parallel implement runs, default 1"
vb init t1 t2 t3
approved t1 a; approved t2 b; approved t3 c
need "default 1" acts_are "implement t1"
need "t2 refused" exits 2 run t2 implement
echo '{"close":"local","batch":{"parallel":2}}' >.claude/10x.json
need "parallel 2" acts_are "implement t1,implement t2"
sleeper; row t1 implement implement "open:$SLEEPER"
need "one open, one more" acts_are "implement t2"
need "t3 refused" exits 2 run t3 implement
echo '{"close":"local","batch":{"parallel":1}}' >.claude/10x.json
need "parallel 1 with one open" acts_are ""
need "t2 refused while t1 implements" exits 2 run t2 implement
need "names the cap" has "batch.parallel is 1 and t1 (implementing) holds the slots"
for v in 0 '"2"' 1.5 -1; do
  echo "{\"batch\":{\"parallel\":$v}}" >.claude/10x.json
  need "parallel $v is refused" exits 2 status
  need "parallel $v is named" has "10x-batch: batch.parallel must be an integer ≥ 1"
done
end

reset; ticket t1 t2 t3
begin "schedule: a ticket sharing a Files path waits for the earlier one to land"
echo '{"close":"local","batch":{"parallel":3}}' >.claude/10x.json
vb init t1 t2 t3
approved t1 src/a.js; approved t2 ./src/; approved t3 docs/x.md
need "t1 and t3, not t2" acts_are "implement t1,implement t3"
need "t2 refused" exits 2 run t2 implement
need "names the shared path" has "t2 shares src/ with t1 (approved)"
row t1 implement implement 0; evidence t1 "- AC1 — met: x"; mkdir -p .worktrees/t1
need "still waiting while t1 is implemented" acts_are "implement t3,close t1"
row t1 close close 0; rmdir .worktrees/t1
need "t2 implements once t1 landed" acts_are "implement t2,implement t3"
end

reset; ticket t1 t2 t3
begin "run close: refused while another close runs or an earlier ticket is unsettled"
vb init t1 t2 t3
approved t1 a; implemented t2 b
need "no close while t1 is approved" acts_are "plan t3,implement t1"
need "t2 refused" exits 2 run t2 close
need "names the earlier ticket" has "the earlier ticket t1 is approved"
row t1 implement implement 0; evidence t1 "- AC1 — met: x"; mkdir -p .worktrees/t1
need "the first implemented closes" acts_are "plan t3,close t1"
need "t2 still refused" exits 2 run t2 close
row t1 close close 0; rmdir .worktrees/t1
implemented t3 c; sleeper; row t3 close close "open:$SLEEPER"
need "no close while t3 closes" acts_are ""
need "t2 refused while t3 closes" exits 2 run t2 close
need "names the running close" has "t3 is closing"
kill "$SLEEPER"; wait "$SLEEPER" 2>/dev/null
need "t2 closes once nothing closes" exits 0 run t2 close
need "with /10x:close" test "$(tail -n 1 "$WORKER_LOG" | cut -f1,4)" = "$(printf -- '--session-id\t/10x:close t2')"
end

reset; ticket t1 t2
begin "schedule: a waiting implement session keeps its batch.parallel slot"
vb init t1 t2
approved t1 a; row t1 implement implement 0; evidence t1 "- AC1 — asked: Which flag name?"; mkdir -p .worktrees/t1
approved t2 b
need "t1 waits on a question, t2 does not implement" acts_are "answer t1"
need "t2 refused" exits 2 run t2 implement
need "names t1's slot" has "batch.parallel is 1 and t1 (waiting) holds the slots"
echo '{"close":"local","batch":{"parallel":2}}' >.claude/10x.json
need "a second slot lets t2 implement" acts_are "answer t1,implement t2"
end

reset; ticket t1 t2 t3
begin "schedule: implement waits until every earlier unsettled ticket has its Files"
echo '{"close":"local","batch":{"parallel":3}}' >.claude/10x.json
vb init t1 t2 t3
row t1 plan plan 0
approved t2 b
need "t1 has no plan: t2 waits" acts_are "plan t3,answer t1"
need "t2 refused" exits 2 run t2 implement
need "names t1" has "implement t2 refused: t1 (waiting) has no plan with ## Files yet"
plan_md t1 draft a
need "t1's Files known: t2 implements" acts_are "plan t3,answer t1 approvable,implement t2"
end

reset; ticket t1 t2
begin "schedule: an approved ticket sharing Files with a later one that implemented first is held until it lands"
vb init t1 t2
approved t1 a b
implemented t2 b
need "t1 held" phase_is t1 held
need "with why" grep -qxF -- "- t1 — held: shares b with t2 (implemented), which implemented first" "$B/board.md"
need "t2 closes; t1 does not implement" acts_are "close t2"
row t2 close close 0; rmdir .worktrees/t2
need "t1 implements once t2 landed" acts_are "implement t1"
end

# ---------------------------------------------------------------- failed and held

reset; ticket t1 t2 t3 t4 t5 t6 t7
begin "failed: non-zero exit, a FAIL gate, an open criterion or a close that did not land"
vb init t1 t2 t3 t4 t5 t6 t7
WORKER_EXIT=3 vb run t1 plan
need "exit 0 whatever the worker's exit" test $? -eq 0
vb drop t2
approved t3 x; row t3 implement implement 0; evidence t3 "- AC1 — met: x"; mkdir -p .worktrees/t3 .10x/t3/verify
{ printf '%-28s %-6s %6s  %s\n' gate result secs log "node --check x" pass 0 a.log "npm test" FAIL 3 b.log
  printf '  │ FAIL in the log tail\n'; } >.10x/t3/verify/summary.txt
approved t4 y; row t4 implement implement 0; evidence t4 "- AC1 — pending"; mkdir -p .worktrees/t4
implemented t5 z; row t5 close close 0
sleeper; row t7 plan plan "open:$SLEEPER"; kill "$SLEEPER"; wait "$SLEEPER" 2>/dev/null
vb status
need "exit" grep -qF "| 1 | t1 | failed | $(field t1 1 3) | failed | run 01 (plan) exited 3 |" "$B/board.md"
need "FAIL gate" grep -qF "| t3 | failed | s-t3-2 | failed | gate FAIL: npm test |" "$B/board.md"
need "open criterion" grep -qF "| t4 | failed | s-t4-2 | failed | open criterion: AC1 — pending |" "$B/board.md"
need "close did not land" grep -qF "| t5 | failed | s-t5-3 | failed | close did not land |" "$B/board.md"
need "a run whose pid is gone" grep -qF "| t7 | failed | s-t7-1 | failed | run 01 (plan) ended without an exit code |" "$B/board.md"
need "each under Needs the human" test "$(grep -c '^- t[1-7] — failed: ' "$B/board.md")" = 5
need "the others stay schedulable" acts_are "plan t6"
end

reset; ticket t1 t2
begin "waiting: an asked line with a criterion still pending"
vb init t1 t2
approved t1 a; row t1 implement implement 0; evidence t1 "- AC1 — pending" "- asked: Keep the old name?"; mkdir -p .worktrees/t1
echo 'Keep the old name?' >"$B/t1/turn.md"
# t2's plan has two criteria: AC2 is asked while AC1 is still pending.
two_ac() { plan_md t2 "$1" b; awk '{ print } /^- AC1 — the change works$/ { print "- AC2 — the old name is kept" } /^\| AC1 \|/ { print "| AC2 | `tests/x.sh` | `keeps` |" }' .10x/t2/plan.md >"$tmp/plan" && cp "$tmp/plan" .10x/t2/plan.md; }
row t2 plan plan 0; two_ac draft; 10x-batch approve t2 >/dev/null; rm -f "$B/t2/reply.md"; two_ac approved
row t2 implement implement 0; evidence t2 "- AC1 — pending" "- AC2 — asked: Keep the old name?"; mkdir -p .worktrees/t2
echo 'Keep the old name?' >"$B/t2/turn.md"
need "a free asked line: waiting" phase_is t1 waiting
need "an asked criterion: waiting" phase_is t2 waiting
need "the evidence is its question and its turn.md" grep -qxF "| 1 | t1 | waiting | $(field t1 2 3) | — | Keep the old name?; .10x/_batch/t1/turn.md |" "$B/board.md"
need "and t2's" grep -qF "| t2 | waiting | $(field t2 2 3) | — | Keep the old name?; .10x/_batch/t2/turn.md |" "$B/board.md"
end

# relock_md <id> <ruling> [<reason>] — a relock.md with one entry; an approved one has a commit line.
relock_md() {
  { printf '# Relocks\n\n## Relock 1\n- reason: %s\n- ruling: %s\n' "${3:-the test expects the old flag}" "$2"
    case "$2" in [Aa]pproved*) printf -- '- commit: abc1234\n' ;; esac; } >".10x/$1/relock.md"
}

reset; ticket t1 t2
begin "board: a rejected relock waits with its question"
vb init t1 t2
approved t1 a; row t1 implement implement 0; mkdir -p .worktrees/t1
relock_md t1 "rejected — the change drops what AC1 requires"
evidence t1 "- AC1 — met: x" "- asked: The arbiter rejected the relock of tests/x.sh: keep the test or change AC1?"
echo 'Relock rejected.' >"$B/t1/turn.md"
need "waiting" phase_is t1 waiting
need "the question in the evidence" grep -qxF "| 1 | t1 | waiting | $(field t1 2 3) | — | The arbiter rejected the relock of tests/x.sh: keep the test or change AC1?; .10x/_batch/t1/turn.md |" "$B/board.md"
need "and under Needs the human" grep -qxF -- "- t1 — waiting: The arbiter rejected the relock of tests/x.sh: keep the test or change AC1?; .10x/_batch/t1/turn.md" "$B/board.md"
need "a rejected relock is not relocked" not grep -qF "relocked" "$B/board.md"
evidence t1 "- AC1 — asked: Keep the test or change AC1?"; vb status
need "an asked criterion's question too" grep -qF "| t1 | waiting | $(field t1 2 3) | — | Keep the test or change AC1?; .10x/_batch/t1/turn.md |" "$B/board.md"
row t2 plan plan 0; plan_md t2 draft b; echo 'Which name?' >"$B/t2/turn.md"
evidence t2 "- asked: not an implement session"; vb status
need "a plan session's evidence stays its turn.md" grep -qF "| t2 | waiting | $(field t2 1 3) | — | .10x/_batch/t2/turn.md |" "$B/board.md"
end

reset; ticket t1 t2 t3
begin "board: an approved relock shows relocked with its reason"
vb init t1 t2 t3
implemented t1 a
relock_md t1 "APPROVED: the fixture's date was wrong" "the fixture's date was a Sunday"
need "implemented" phase_is t1 implemented
need "relocked in the evidence" grep -qxF "| 1 | t1 | implemented | $(field t1 2 3) | — | relocked: the fixture's date was a Sunday |" "$B/board.md"
need "and under Needs the human" grep -qxF -- "- t1 — relocked: the fixture's date was a Sunday" "$B/board.md"
approved t2 b; row t2 implement implement 0; mkdir -p .worktrees/t2
relock_md t2 "approved — a typo in the expected output" "the expected output had a typo"
evidence t2 "- AC1 — met: x" "- asked: Keep the old name?"; vb status
need "a waiting and relocked row" grep -qxF "| 2 | t2 | waiting | $(field t2 2 3) | — | Keep the old name?; relocked: the expected output had a typo |" "$B/board.md"
need "gets the waiting line" grep -qxF -- "- t2 — waiting: Keep the old name?; relocked: the expected output had a typo" "$B/board.md"
need "and the relocked line" grep -qxF -- "- t2 — relocked: the expected output had a typo" "$B/board.md"
landed t3 c
relock_md t3 "approved - the regex was anchored wrong" "the regex was anchored wrong"; vb status
need "a landed row keeps relocked in its evidence" grep -qF "| t3 | landed | $(field t3 3 3) | landed | landed on main at $(git rev-parse --short main); relocked: the regex was anchored wrong |" "$B/board.md"
need "but is not under Needs the human" not grep -qF -- "- t3 — relocked" "$B/board.md"
end

reset; ticket t1 t2
begin "denial: a run that exits 0 is judged by its files, its denials shown as evidence"
vb init t1 t2
cat >"$tmp/denied.jsonl" <<'EOF'
{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"Drafted."}]}}
{"type":"result","result":"Drafted.","permission_denials":[{"tool_name":"Bash","tool_use_id":"u1","tool_input":{"command":"git fetch"}},{"tool_name":"Bash","tool_use_id":"u2","tool_input":{"command":"node --test"}}]}
EOF
WORKER_OUT="$tmp/denied.jsonl" vb run t1 plan
need "the denials are recorded" test "$(cat "$B/t1/01-denials.tsv")" = "$(printf 'Bash\tgit fetch\nBash\tnode --test')"
plan_md t1 draft a
need "not failed: waiting on its draft" phase_is t1 waiting
need "approvable" acts_are "plan t2,answer t1 approvable"
need "the denials in the evidence" grep -qxF "| 1 | t1 | waiting | $(field t1 1 3) | — | .10x/_batch/t1/turn.md; run 01 (plan) denied: git fetch; node --test |" "$B/board.md"
need "and under Needs the human" grep -qxF -- "- t1 — waiting, plan approvable: .10x/_batch/t1/turn.md; run 01 (plan) denied: git fetch; node --test" "$B/board.md"
row t2 plan plan 0; approve_plan t2 b; row t2 implement implement 0; evidence t2 "- AC1 — met: x"; mkdir -p .worktrees/t2
printf 'Bash\tgit push\n' >"$B/t2/02-denials.tsv"
need "an implemented ticket with a denial stays implemented" phase_is t2 implemented
need "its denial is listed for the human" grep -qxF -- "- t2 — implemented: run 02 (implement) denied: git push" "$B/board.md"
end

reset; ticket t1 t2 t3 t4
begin "held: a later ticket sharing a Files path with a failed one"
vb init t1 t2 t3 t4
approved t2 src/a.js lib/b.js
approved t3 lib/
approved t4 docs/
approved t1 src/a.js; row t1 implement implement 1
need "t2 held" phase_is t2 held
need "t3 held behind the held t2" phase_is t3 held
need "with why" grep -qxF -- "- t2 — held: shares src/a.js with t1 (failed)" "$B/board.md"
need "held behind held" grep -qxF -- "- t3 — held: shares lib/ with t2 (held)" "$B/board.md"
need "an unrelated ticket implements" acts_are "implement t4"
need "a held ticket is refused" exits 2 run t2 implement
end

# ---------------------------------------------------------------- phases

reset; ticket t1
begin "phase: derived from the ticket files and run records"
vb init t1
need "queued" phase_is t1 queued
sleeper; row t1 plan plan "open:$SLEEPER"
need "planning while the worker lives" phase_is t1 planning
kill "$SLEEPER"; wait "$SLEEPER" 2>/dev/null
rm "$SB/t1/runs.tsv"; row t1 plan plan 0
need "waiting with no plan" phase_is t1 waiting
plan_md t1 draft
need "waiting with a draft" phase_is t1 waiting
plan_md t1 approved docs/
need "failed while plan.md says approved without your approval" phase_is t1 failed
approve_plan t1 docs/
need "approved" phase_is t1 approved
row t1 implement implement 0; mkdir -p .worktrees/t1
need "failed without evidence" phase_is t1 failed
evidence t1 "- AC1 — met: \`bash tests/x.sh\`"
need "implemented" phase_is t1 implemented
evidence t1 "- AC1 — met: x" "- asked: Keep the old name?"
need "waiting on a question" phase_is t1 waiting
evidence t1 "- AC1 — met: x"
mkdir -p .10x/t1/verify; printf '%-28s %-6s %6s  %s\n' gate result secs log tests FAIL 1 l >.10x/t1/verify/summary.txt
need "failed on a FAIL gate" phase_is t1 failed
printf '%-28s %-6s %6s  %s\n' gate result secs log tests pass 1 l >.10x/t1/verify/summary.txt
need "implemented again" phase_is t1 implemented
row t1 close close 0
need "failed while the worktree stays" phase_is t1 failed
rmdir .worktrees/t1
need "landed once it is gone" phase_is t1 landed
need "landed on the base at its sha" grep -qF "| landed | landed on main at $(git rev-parse --short main) |" "$B/board.md"
echo "landed on main at abc1234" >"$B/t1/03-landed"
need "where its close run left it, not the base's tip" eval 'phase_is t1 landed && grep -qF "| landed | landed on main at abc1234 |" "$B/board.md"'
touch "$SB/t1/dropped"
need "dropped" phase_is t1 dropped
end

# ---------------------------------------------------------------- loop

reset; ticket t1
begin "loop: an auto planning worker on a question gets the fixed reply and none of its turn"
vb init --auto t1
WORKER_OUT="$tmp/question.jsonl" lp 90
need "loop finished" finished
need "the worker's turn is its question" grep -qF "Which flag name" "$B/t1/turn.md"
for n in 02 03 04; do
  need "reply $n is the fixed reply byte for byte" cmp -s "$tmp/fixed" "$B/t1/$n-reply.md"
  need "reply $n holds none of the turn" not grep -qF "Which flag name" "$B/t1/$n-reply.md"
done
need "no reply.md is left" test ! -e "$B/t1/reply.md"
end

reset; ticket t1
begin "loop: an auto draft that passes plan-check is approved, implemented and closed"
vb init --auto t1
WORKER_SCRIPT=flow lp 90
need "loop finished" finished
need "t1 landed" phase_is t1 landed
h="$(sed 's/^Status:.*$/Status:/' .10x/t1/plan.md | shasum -a 256 | cut -d' ' -f1)"
need "the approval record matches the plan's hash" test "$(cat "$S/t1.approved")" = "$h"
need "auto-approved holds the hash" test "$(cat "$SB/t1/auto-approved")" = "$h"
need "plan, approve reply, implement and close, in one loop run" test "$(sed 1d "$SB/t1/runs.tsv" | cut -f2 | tr '\n' ' ')" = "plan reply implement close "
need "the reply was the approve reply" eval 'grep -qF "Approved. Set \`Status: approved\` in plan.md" "$B/t1/02-reply.md"'
need "the board says how it was approved" grep -qF "auto-approved (sha256 ${h:0:12})" "$B/board.md"
end

reset; ticket t1 t2
echo "a comment" >.10x/t1/comment.md
echo 1 >.10x/t2/product-questions.md
begin "loop: comment.md or product-questions.md stops auto approval"
vb init --auto t1 t2
WORKER_SCRIPT=flow lp 90
need "loop finished" finished
need "both are approve items, with their turn as evidence" \
  printed '{"items":[{"id":"t1","need":"approve","evidence":".10x/_batch/t1/turn.md"},{"id":"t2","need":"approve","evidence":".10x/_batch/t2/turn.md"}]}'
need "no approval record" test ! -e "$S/t1.approved" -a ! -e "$S/t2.approved"
need "no auto-approved" test ! -e "$SB/t1/auto-approved" -a ! -e "$SB/t2/auto-approved"
need "no reply" test ! -e "$B/t1/reply.md" -a ! -e "$B/t2/reply.md"
need "both wait on their plan" eval 'phase_is t1 waiting && phase_is t2 waiting'
end

reset
begin "loop: a comment by someone else on the issue stops auto approval"
vb init --auto gh-6 gh-5 gh-7
STUB_COMMENTERS="5:me 5:other 6:me 6:ME" STUB_COMMENTS_FAIL="7" WORKER_SCRIPT=flow lp 120
need "loop finished" finished
need "gh-5 (a stranger's comment) and gh-7 (comments unknown) are approve items" \
  printed '{"items":[{"id":"gh-5","need":"approve","evidence":".10x/_batch/gh-5/turn.md"},{"id":"gh-7","need":"approve","evidence":".10x/_batch/gh-7/turn.md"}]}'
need "no approval record for them" test ! -e "$S/gh-5.approved" -a ! -e "$S/gh-7.approved"
need "no auto-approved for them" test ! -e "$SB/gh-5/auto-approved" -a ! -e "$SB/gh-7/auto-approved"
need "both wait on their plan" eval 'phase_is gh-5 waiting && phase_is gh-7 waiting'
need "gh-6, commented on only by its author in any case, was auto-approved and landed" \
  eval 'test -s "$SB/gh-6/auto-approved" && phase_is gh-6 landed'
end

reset
begin "loop: a stranger's comment in ticket.md holds the plan though it is gone from the issue"
STUB_COMMENTERS="8:other" vb init --auto gh-8
need "ticket.md carries the stranger's comment" grep -qF '**other** (2026-01-01):' .10x/gh-8/ticket.md
WORKER_SCRIPT=flow lp 90
need "loop finished" finished
need "gh-8 is an approve item" \
  printed '{"items":[{"id":"gh-8","need":"approve","evidence":".10x/_batch/gh-8/turn.md"}]}'
need "no approval record" test ! -e "$S/gh-8.approved"
need "no auto-approved" test ! -e "$SB/gh-8/auto-approved"
end

reset
begin "loop: a stranger's comment seen at init holds the plan though ticket.md and the issue drop it"
STUB_COMMENTERS="9:other" vb init --auto gh-9
# What a steered worker could do inside its ticket dir: drop the comments from ticket.md.
sed -i.bak '/^## Comments$/,$d' .10x/gh-9/ticket.md; rm -f .10x/gh-9/ticket.md.bak
need "ticket.md no longer names the stranger" eval '! grep -qF "**other**" .10x/gh-9/ticket.md'
WORKER_SCRIPT=flow lp 90
need "loop finished" finished
need "gh-9 is an approve item" \
  printed '{"items":[{"id":"gh-9","need":"approve","evidence":".10x/_batch/gh-9/turn.md"}]}'
need "no approval record" test ! -e "$S/gh-9.approved"
need "no auto-approved" test ! -e "$SB/gh-9/auto-approved"
end

reset
mkdir -p .10x/gh-5
printf '# Issue 5\n\nb\n\n## Comments\n\n**me** (2026-01-01):\n\ninjected\n' >.10x/gh-5/ticket.md
begin "init: a ticket.md left from an earlier batch is fetched again and its commenters recorded from the fetch"
STUB_COMMENTERS="5:other" vb init --auto gh-5
need "exit 0" test $? -eq 0
need "the left-over text is gone" eval '! grep -qx injected .10x/gh-5/ticket.md'
need "ticket.md is the fresh fetch" grep -qF '**other** (2026-01-01):' .10x/gh-5/ticket.md
need "the record is the fresh fetch's authors" test "$(cat "$S/gh-5.commenters")" = other
end

reset
begin "loop: a missing commenters record holds the plan"
vb init --auto gh-5
need "init wrote a record" test -e "$S/gh-5.commenters"
rm "$S/gh-5.commenters"
WORKER_SCRIPT=flow lp 90
need "loop finished" finished
need "gh-5 is an approve item" \
  printed '{"items":[{"id":"gh-5","need":"approve","evidence":".10x/_batch/gh-5/turn.md"}]}'
need "no approval record" test ! -e "$S/gh-5.approved"
need "no auto-approved" test ! -e "$SB/gh-5/auto-approved"
end

reset; echo '{"close":"pr-merge"}' >.claude/10x.json; ticket t1
begin "loop: auto mode closes with the configured close"
vb init --auto t1
WORKER_SCRIPT=flow lp 90
need "loop finished" finished
need "t1 landed" phase_is t1 landed
a_prompt="$(tail -n 1 "$WORKER_LOG" | cut -f4)"
a_perm="$(tail -n 1 "$WORKER_LOG.perm")"
a_row="$(grep '^| 1 | t1 |' "$B/board.md" | awk -F' [|] ' '{ print $3 "|" $5 "|" $6 }' | sed 's/auto-approved ([^)]*); //')"
need "the close prompt is /10x:close t1" test "$a_prompt" = "/10x:close t1"
reset; echo '{"close":"pr-merge"}' >.claude/10x.json; ticket t1
vb init t1
WORKER_SCRIPT=flow lp 90
vb approve t1
WORKER_SCRIPT=flow lp 90
need "default mode landed t1 too" phase_is t1 landed
need "the same worker prompt" test "$(tail -n 1 "$WORKER_LOG" | cut -f4)" = "$a_prompt"
need "the same permission flags" test "$(tail -n 1 "$WORKER_LOG.perm")" = "$a_perm"
need "the same board row but for the auto-approved item" test "$(grep '^| 1 | t1 |' "$B/board.md" | awk -F' [|] ' '{ print $3 "|" $5 "|" $6 }')" = "$a_row"
end

reset; ticket t1 t2
begin "loop: two auto tickets land and print done"
vb init --auto t1 t2
WORKER_SCRIPT=flow lp 120
need "exit 0" test "$LRC" -eq 0
need "exactly one JSON line" printed '{"items":[{"need":"done"}]}'
need "nothing on stderr" test ! -s "$tmp/loop.err"
need "both landed" eval 'phase_is t1 landed && phase_is t2 landed'
end

reset; ticket t1
begin "loop: default mode never replies or approves"
vb init t1
lp 60
need "loop finished" finished
need "the first waiting ticket is an answer item" \
  printed '{"items":[{"id":"t1","need":"answer","evidence":".10x/_batch/t1/turn.md"}]}'
need "no reply.md" test ! -e "$B/t1/reply.md"
need "no reply was sent" test "$(wc -l <"$SB/t1/runs.tsv" | tr -d ' ')" = 2
reset; ticket t1
vb init t1
WORKER_SCRIPT=flow lp 60
need "loop finished again" finished
need "an approvable plan is an approve item" \
  printed '{"items":[{"id":"t1","need":"approve","evidence":".10x/_batch/t1/turn.md"}]}'
need "no reply.md for it" test ! -e "$B/t1/reply.md"
need "no approval record" test ! -e "$S/t1.approved"
need "no auto-approved" test ! -e "$SB/t1/auto-approved"
end

reset; ticket t1
begin "loop: a reply.md the human wrote is sent in both modes"
for m in default auto; do
  fl=(); [ "$m" = auto ] && fl=(--auto)
  reset; ticket t1
  vb init ${fl[@]+"${fl[@]}"} t1
  WORKER_OUT="$tmp/question.jsonl" lp 90
  need "$m: first loop finished" finished
  need "$m: it stops on an answer item" has '"id":"t1","need":"answer"'
  runs_before="$(wc -l <"$SB/t1/runs.tsv" | tr -d ' ')"
  printf 'Use --fast.' >"$B/t1/reply.md"
  WORKER_OUT="$tmp/question.jsonl" lp 90
  need "$m: second loop finished" finished
  need "$m: one more run" test "$(wc -l <"$SB/t1/runs.tsv" | tr -d ' ')" = $((runs_before + 1))
  last="$(printf '%02d' "$runs_before")"
  need "$m: the reply landed in <nn>-reply.md byte for byte" eval "printf 'Use --fast.' | cmp -s - \"$B/t1/$last-reply.md\""
  need "$m: it was sent to the worker" test "$(tail -n 1 "$WORKER_LOG" | cut -f1,4)" = "$(printf -- '--resume\tUse --fast.')"
  need "$m: reply.md was consumed" test ! -e "$B/t1/reply.md"
done
end

reset; ticket t1
begin "loop: stopped, its runs go on and the next loop waits on them"
vb init t1
WORKER_SLEEP=8 10x-batch loop >"$tmp/loop1.out" 2>&1 &
L1=$!; bgs+=("$L1")
for _ in $(seq 1 50); do [ -n "$(field t1 1 8 2>/dev/null)" ] && break; sleep 0.1; done
wpid="$(field t1 1 8 2>/dev/null)"
need "the first loop started a run" test -n "$wpid"
kill -TERM "$L1" 2>/dev/null; wait "$L1" 2>/dev/null
if [ -n "$wpid" ]; then
  sleepers+=("$wpid")
  need "the worker outlives the loop's SIGTERM" kill -0 "$wpid"
  10x-batch loop >"$tmp/loop2.out" 2>&1 &
  L2=$!; bgs+=("$L2")
  sleep 1
  need "a new loop keeps waiting on a run it did not start" kill -0 "$L2"
  for _ in $(seq 1 200); do [ -n "$(field t1 1 7)" ] && break; sleep 0.1; done
  ended=$SECONDS
  for _ in $(seq 1 150); do kill -0 "$L2" 2>/dev/null || break; sleep 0.1; done
  need "it acts within 10 seconds of the run's end" test $((SECONDS - ended)) -le 12
  need "the second loop is gone" not kill -0 "$L2"
  wait "$L2" 2>/dev/null
  need "it reports the ticket" grep -qF '"id":"t1","need":"answer"' "$tmp/loop2.out"
fi
end

reset; ticket t0 t1 t2
begin "loop: a denied run with no other need is a denied item"
vb init t0 t1 t2
row t0 plan plan 0; echo q >"$B/t0/turn.md"
implemented t1 b; printf 'Bash\tgit push\n' >"$B/t1/02-denials.tsv"
landed t2 c; printf 'Bash\tgit push\n' >"$B/t2/03-denials.tsv"
lp 30
need "loop finished" finished
need "t0 answers; t1 is denied with the board's evidence; a landed ticket is no item" \
  printed '{"items":[{"id":"t0","need":"answer","evidence":".10x/_batch/t0/turn.md"},{"id":"t1","need":"denied","evidence":"run 02 (implement) denied: git push"}]}'
end

reset; ticket t1
begin "loop: a fourth question stop or a comment.md is an answer item"
vb init --auto t1
WORKER_OUT="$tmp/question.jsonl" lp 90
need "loop finished" finished
need "three fixed replies and a fourth stop make four runs" test "$(wc -l <"$SB/t1/runs.tsv" | tr -d ' ')" = 5
need "the fourth stop is an answer item" printed '{"items":[{"id":"t1","need":"answer","evidence":".10x/_batch/t1/turn.md"}]}'
need "no reply.md for it" test ! -e "$B/t1/reply.md"
need "no fourth fixed reply" test ! -e "$B/t1/05-reply.md"
reset; ticket t1
echo "a comment" >.10x/t1/comment.md
vb init --auto t1
WORKER_OUT="$tmp/question.jsonl" lp 60
need "loop finished with a comment.md" finished
need "a comment.md ticket is an answer item" printed '{"items":[{"id":"t1","need":"answer","evidence":".10x/_batch/t1/turn.md"}]}'
need "no fixed reply is written or sent" eval 'test ! -e "$B/t1/reply.md" && test "$(wc -l <"$SB/t1/runs.tsv" | tr -d " ")" = 2'
end

# ---------------------------------------------------------------- the state dir

# mode_of <path> — the permission string of a directory, as `ls -ld` prints it.
mode_of() { find "$1" -maxdepth 0 -type d -perm 0700 | grep -q . && echo drwx------ || echo "not 0700: $1"; }

reset; ticket t1
begin "records: approve, init and loop keep .approved and .commenters in the state dir and ignore the old location"
vb init gh-5 t1
need "init writes gh-5.commenters in the state dir" test -e "$S/gh-5.commenters"
need "S and S/batch are 0700" eval '[ "$(mode_of "$S")" = drwx------ ] && [ "$(mode_of "$SB")" = drwx------ ]'
vb run t1 plan
need "S/batch/<id> is 0700" test "$(mode_of "$SB/t1")" = drwx------
row t1 plan plan 0; plan_md t1 draft a
need "approve exits 0" exits 0 approve t1
need "approve writes t1.approved in the state dir" test -s "$S/t1.approved"
need "nothing under <git common dir>/10x-batch" test ! -e .git/10x-batch
plan_md t1 approved a
need "approved with the record in the state dir" phase_is t1 approved
mkdir -p .git/10x-batch; cp "$S/t1.approved" .git/10x-batch/t1.approved; rm "$S/t1.approved"
need "a copy at the old location does not approve" phase_is t1 failed
reset; ticket t1
vb init --auto gh-5
mkdir -p .git/10x-batch; cp "$S/gh-5.commenters" .git/10x-batch/gh-5.commenters; rm "$S/gh-5.commenters"
WORKER_SCRIPT=flow lp 90
need "loop finished" finished
need "a commenters record at the old location does not release the plan" \
  printed '{"items":[{"id":"gh-5","need":"approve","evidence":".10x/_batch/gh-5/turn.md"}]}'
reset; ticket t1
vb init --auto t1
WORKER_SCRIPT=flow lp 90
need "loop finished again" finished
need "loop writes t1.approved in the state dir" test -s "$S/t1.approved"
need "and nothing at the old location" test ! -e .git/10x-batch
reset; ticket t1
mkdir -p "$S" "$tmp/elsewhere"; ln -s "$tmp/elsewhere" "$SB"
need "a symlink at S/batch is refused" exits 2 init t1
need "naming it" has "$SB is a symlink"
rm "$SB"; vb init t1
rm -rf "$SB/t1"; ln -s "$tmp/elsewhere" "$SB/t1"
need "a symlink at S/batch/<id> is refused" exits 2 run t1 plan
need "naming it" has "$SB/t1 is a symlink"
end

# allow <settings file> <path> — a settings file whose sandbox.filesystem.allowWrite is [<path>].
allow() { mkdir -p "$(dirname "$1")"; printf '{"sandbox":{"filesystem":{"allowWrite":["%s"]}}}\n' "$2" >"$1"; }
# refused <XDG_STATE_HOME> <inside> [<HOME>] — the five commands exit 2 with the state dir naming <inside>, and create nothing.
refused() {
  local c want rc
  want="10x-batch: state dir $(XDG_STATE_HOME=$1 state_dir) is inside $2"
  for c in "init t1" "run t1 plan" "drop t1" "approve t1" "loop"; do
    # shellcheck disable=SC2086  # the words of $c are the arguments
    HOME="${3:-$HOME}" XDG_STATE_HOME="$1" vb $c; rc=$?
    need "$c: exit 2 for $1" test "$rc" = 2
    need "$c: names the state dir and what it is inside" line "$want"
  done
  need "nothing created under $1" test ! -e "$1"
}

reset; ticket t1
git worktree add -q "$tmp/wt" -b wtb
begin "records: refuses a state dir inside the checkout, a worktree, a sandbox-writable path or a settings allowWrite"
refused "$root/xs" "$root"
refused "$tmp/wt/xs" "$tmp/wt"
refused "$TMPDIR/xs" "$TMPDIR"
refused "$tmp/home/.npm/xs" "$tmp/home/.npm" "$tmp/home"
allow .claude/settings.json "$tmp/a1"; allow .claude/settings.local.json "$tmp/a2"
allow "$tmp/home/.claude/settings.json" "$tmp/a3"; allow "$tmp/home/.claude/settings.local.json" "$tmp/a4"
for n in 1 2 3 4; do refused "$tmp/a$n/xs" "$tmp/a$n" "$tmp/home"; done
XDG_STATE_HOME="$root/xs" vb status
need "status runs without the check" not has "state dir"
rm -f .claude/settings.json .claude/settings.local.json; rm -rf "${tmp:?}/home"
git worktree remove --force "$tmp/wt"; git branch -qD wtb
end

reset; ticket t1
begin "records: refuses a state dir inside an allowWrite of the CLAUDE_CONFIG_DIR settings files"
allow "$tmp/cfg/settings.json" "$tmp/a5"; allow "$tmp/cfg/settings.local.json" "$tmp/a6"
for n in 5 6; do CLAUDE_CONFIG_DIR="$tmp/cfg" refused "$tmp/a$n/xs" "$tmp/a$n"; done
allow "$root/settings.json" "$tmp/a7"
CLAUDE_CONFIG_DIR="" refused "$tmp/a7/xs" "$tmp/a7"
rm -f "$root/settings.json"; rm -rf "${tmp:?}/cfg"
end

reset; ticket t1
begin "records: with CLAUDE_CONFIG_DIR set, an allowWrite in ~/.claude/settings.json still refuses"
allow "$tmp/home/.claude/settings.json" "$tmp/a3"
CLAUDE_CONFIG_DIR="$tmp/cfg" refused "$tmp/a3/xs" "$tmp/a3" "$tmp/home"
rm -rf "${tmp:?}/home"
end

reset; ticket t1 t2 t3
roadmap '| v1 | a `t1`; b `t2`; c `t3` | base | Planned |'
printf 'landed on main at abc1234\n' >.10x/t3/landed
begin "records: tickets, mode, versions, runs.tsv, auto-approved and dropped live in the state dir and copies at the old paths are ignored"
vb init v1
for f in tickets mode versions versions.closed; do
  need "$f is in S/batch" test -s "$SB/$f"
  need "$f is not under .10x/_batch" test ! -e "$B/$f"
done
vb run t1 plan
need "runs.tsv is in S/batch/<id>" test -s "$SB/t1/runs.tsv"
need "runs.tsv is not under .10x/_batch" test ! -e "$B/t1/runs.tsv"
vb drop t2
need "dropped is in S/batch/<id>" test -f "$SB/t2/dropped"
need "dropped is not under .10x/_batch" test ! -e "$B/t2/dropped"
rm "$SB/t2/dropped"
mkdir -p "$B/t2"; touch "$B/t2/dropped"
printf 'n\tkind\tsession\tsession_kind\tstart\tend\texit\tpid\n1\timplement\ts-t2-1\timplement\t1\t2\t0\t1\n' >"$B/t2/runs.tsv"
need "a dropped marker and a runs.tsv at the old path are ignored" phase_is t2 queued
printf 't1\n' >"$B/tickets"
need "a tickets file at the old path is ignored" acts_are "plan t2,answer t1"
printf 'auto\n' >"$B/mode"
need "a mode file at the old path is ignored" eval 'vb status && line "mode: default"'
approved t1 a
printf '%s\n' 0123456789abcdef0123456789abcdef >"$B/t1/auto-approved"
vb status
need "an auto-approved file at the old path is ignored" not grep -qF "auto-approved" "$B/board.md"
printf '%s\n' 0123456789abcdef0123456789abcdef >"$SB/t1/auto-approved"
vb status
need "an auto-approved file in the state dir shows" grep -qF "auto-approved (sha256 0123456789ab)" "$B/board.md"
end

reset; ticket t1 t2
begin "init: archives the state dir's batch with the board's stamp and refuses a batch from before the state dir"
vb init t1; vb drop t1
need "init of a new batch exits 0" exits 0 init t2
arch="$(ls -d .10x/_batch.2* 2>/dev/null)"
stamp="${arch#.10x/_batch.}"
need "one archive of .10x/_batch" test "$(printf '%s\n' "$arch" | wc -l | tr -d ' ')" = 1
need "the state dir's batch is archived under the same stamp" test "$(cat "$S/batch.$stamp/tickets")" = t1
need "the new batch is t2 in the state dir" test "$(cat "$SB/tickets")" = t2
reset; ticket t1
mkdir -p "$B"; echo t1 >"$B/tickets"
need "a batch from before the state dir is refused" exits 2 init t1
need "naming what to do" line "10x-batch: .10x/_batch is a batch from before the state dir; finish it with the previous version, or move it away"
need "nothing archived" eval 'test -z "$(ls -d .10x/_batch.2* 2>/dev/null)" && test "$(cat "$B/tickets")" = t1'
need "nothing written to the state dir" test ! -e "$SB/tickets"
end

reset; ticket t1 t2
begin "run: plan, reply, implement, close and fallback runs carry the sandbox settings and deny Edit on the state dir and settings files"
want="$(node -e '
  const os = require("os"), path = require("path")
  const h = (x) => path.join(os.homedir(), x)
  console.log(JSON.stringify({ sandbox: { enabled: true, allowUnsandboxedCommands: false, failIfUnavailable: true, enableWeakerNetworkIsolation: true,
    filesystem: { allowWrite: [os.tmpdir(), h(".npm"), h("Library/pnpm"), h("Library/Caches"), h(".cache"), h("Library/Developer"), "/dev/stdout", "/dev/fd"] },
    network: { allowedDomains: ["*"], allowLocalBinding: true } } }))
')"
vb init t1 t2
WORKER_MODE=default vb run t1 plan
echo "go" >"$B/t1/reply.md"; vb run t1 reply
approve_plan t1 a
WORKER_MODE=default vb run t1 implement
evidence t1 "- AC1 — met: x"; mkdir -p .worktrees/t1
vb run t1 close
need "six runs, the two fallbacks among them" test "$(wc -l <"$WORKER_LOG.settings" | tr -d ' ')" = 6
need "every run has the same --settings, byte for byte" test "$(sort -u "$WORKER_LOG.settings")" = "$want"
need "no run lacks the flag" not grep -qx unset "$WORKER_LOG.settings"
need "the flag comes right after --verbose in every run" test "$(sort -u "$WORKER_LOG.afterverbose")" = yes
need "the tmp dir is the conductor's" grep -qF -- "\"allowWrite\":[\"$TMPDIR\"," "$WORKER_LOG.settings"
end

reset; ticket t1
printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":0,"errors":["Sandbox required but unavailable"],"startup_failure_reason":"sandbox_required_unavailable"}' >"$tmp/sandbox.jsonl"
printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"startup_failure_reason":"sandbox_required_unavailable_x"}' >"$tmp/other-reason.jsonl"
begin "run: a worker whose sandbox is unavailable fails its ticket once, with no fallback, in loop too"
for m in default auto; do
  fl=(); [ "$m" = auto ] && fl=(--auto)
  reset; ticket t1
  vb init ${fl[@]+"${fl[@]}"} t1
  WORKER_OUT="$tmp/sandbox.jsonl" WORKER_EXIT=1 vb run t1 plan
  need "$m: 01-sandbox holds unavailable" test "$(cat "$B/t1/01-sandbox")" = unavailable
  need "$m: one run, no retry" test "$(wc -l <"$WORKER_LOG" | tr -d ' ')/$(wc -l <"$SB/t1/runs.tsv" | tr -d ' ')" = 1/2
  need "$m: no fallback" test -z "$(find "$B/t1" -name '*-fallback')"
  need "$m: the row is failed with sandbox unavailable" grep -qF "| 1 | t1 | failed | $(field t1 1 3) | failed | sandbox unavailable |" "$B/board.md"
  need "$m: under Needs the human" grep -qxF -- "- t1 — failed: sandbox unavailable" "$B/board.md"
  need "$m: not as an exit" not grep -qF "exited 1" "$B/board.md"
  reset; ticket t1
  vb init ${fl[@]+"${fl[@]}"} t1
  WORKER_MODE=default WORKER_OUT="$tmp/sandbox.jsonl" WORKER_EXIT=1 vb run t1 plan
  need "$m: a fallback run is checked the same way: 02-sandbox" test "$(cat "$B/t1/02-sandbox" 2>/dev/null)" = unavailable
  need "$m: two runs and no third" test "$(wc -l <"$SB/t1/runs.tsv" | tr -d ' ')" = 3
  need "$m: failed with sandbox unavailable" grep -qF "| t1 | failed | $(field t1 2 3) | failed | sandbox unavailable |" "$B/board.md"
  reset; ticket t1
  vb init ${fl[@]+"${fl[@]}"} t1
  WORKER_OUT="$tmp/sandbox.jsonl" WORKER_EXIT=1 lp 60
  need "$m: loop finished" finished
  need "$m: loop reports it as a failed item" printed '{"items":[{"id":"t1","need":"failed","evidence":"sandbox unavailable"}]}'
  need "$m: loop started the worker once" test "$(wc -l <"$WORKER_LOG" | tr -d ' ')" = 1
done
reset; ticket t1
vb init t1
WORKER_OUT="$tmp/other-reason.jsonl" WORKER_EXIT=1 vb run t1 plan
need "another startup_failure_reason is an ordinary exit" eval 'test ! -e "$B/t1/01-sandbox" && grep -qF "run 01 (plan) exited 1" "$B/board.md"'
end

[ "$fail" -eq 0 ] && echo "batch: all cases pass"
exit "$fail"
