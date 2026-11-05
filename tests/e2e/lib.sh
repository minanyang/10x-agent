#!/bin/bash
# Sourced by run.sh and scenarios.sh: fixtures, the environment, the `claude` driver and the assertion helpers.
#
# A flow is one or more runs. A run is a fresh directory holding origin.git (bare), repo/ (the fixture), gh/ (the
# fake gh's canned.json, state.json and calls.log), log/ (stream-json per turn), gitconfig and ghconfig/.
# Assertions read files, git state, origin's heads, gh/calls.log and the tool calls of log/ — never the model's text.
# Compatible with bash 3.2 (macOS): no associative arrays, no mapfile.

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN="${TENX_E2E_PLUGIN:-$(cd "$E2E_DIR/../.." && pwd -P)}"
TICKET_BRANCH="fix/gh-5-greet-twice"
ORIGIN_URL="git@github.com:test/fixture.git"
# What a user must allow: the commands the skills leave to the user. --settings works in an untrusted workspace,
# where .claude/settings.json is ignored.
E2E_SETTINGS='{"permissions":{"allow":["Bash(git -C * add *)","Bash(git -C * commit *)","Bash(10x-land issue *)","Bash(10x-land comment *)","Bash(10x-batch approve *)"]}}'

# `claude` is resolved before PATH is rewritten.
CLAUDE_BIN="${TENX_E2E_CLAUDE:-claude}"
case "$CLAUDE_BIN" in */*) ;; *) CLAUDE_BIN="$(type -P "$CLAUDE_BIN" || true)" ;; esac
ORIG_PATH="$PATH"

e2e_prereqs() {
  local v
  command -v jq >/dev/null 2>&1 || { echo "run.sh: jq is required" >&2; return 1; }
  command -v node >/dev/null 2>&1 || { echo "run.sh: node is required" >&2; return 1; }
  v="$(git --version 2>/dev/null | sed -E 's/^git version ([0-9]+)\.([0-9]+).*/\1 \2/')"
  # shellcheck disable=SC2086  # two numbers
  set -- $v
  # shellcheck disable=SC2015  # the else branch is the failure either way
  [ -n "${1:-}" ] && { [ "$1" -gt 2 ] || { [ "$1" -eq 2 ] && [ "${2:-0}" -ge 38 ]; }; } || { echo "run.sh: git >= 2.38 is required (merge-tree --write-tree), found '$(git --version 2>&1)'" >&2; return 1; }
  [ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ] || { echo "run.sh: claude is not installed (set TENX_E2E_CLAUDE)" >&2; return 1; }
}

# ---------------------------------------------------------------- environment

# build_path <with-fake 1|0> <shadow-dir> <fake-dir> — the PATH of a run: the fake gh (if any), the plugin's bin/, then
# the caller's PATH without plugin-cache entries, each directory holding a gh replaced by a shadow of all its other
# executables.
build_path() {
  local fake="$1" shadow="$2" fakedir="$3" out="" d n=0 f
  if [ "$fake" = 1 ]; then out="$fakedir"; fi
  out="${out:+$out:}$PLUGIN/bin"
  local IFS=:
  for d in $ORIG_PATH; do
    [ -n "$d" ] || continue
    case "$d" in */.claude/plugins/*) continue ;; esac
    if [ -e "$d/gh" ]; then
      n=$((n + 1)); mkdir -p "$shadow/$n"
      for f in "$d"/*; do
        [ -f "$f" ] && [ -x "$f" ] || continue
        [ "$(basename "$f")" = gh ] && continue
        ln -sf "$f" "$shadow/$n/$(basename "$f")"
      done
      d="$shadow/$n"
    fi
    out="$out:$d"
  done
  printf '%s\n' "$out"
}

# renv <cmd...> — run in the run's environment: the PATH above, an empty gh config, no gh tokens, the fake ssh.
renv() {
  env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GH_HOST -u GH_REPO -u E2E_GH_QUIET -u TENX_BATCH \
    "PATH=$E2E_PATH" "GH_CONFIG_DIR=$RUN/ghconfig" "GIT_CONFIG_GLOBAL=$RUN/gitconfig" \
    "GIT_SSH_COMMAND=$(printf '%q' "$E2E_DIR/bin/ssh")" "E2E_ORIGIN=$ORIGIN" "E2E_GH_DIR=$GHD" \
    "TENX_WAIT_INTERVAL=1" "GIT_TERMINAL_PROMPT=0" "TENX_BATCH_CLAUDE=$RUN/claude-worker" "$@"
}
inrepo() { (cd "$REPO" && renv "$@"); }
rgit() { renv git -C "$REPO" "$@"; }

# use_run <dir> — make an earlier run of the flow the current one.
use_run() {
  RUN="$1"; REPO="$RUN/repo"; ORIGIN="$RUN/origin.git"; GHD="$RUN/gh"; LOGD="$RUN/log"
  E2E_PATH="$(cat "$RUN/path")"
}

# new_run <with-fake 1|0> <close mode> [pr-template] [issue-forms] [no-origin] [parallel2] — a fresh run: bare origin,
# fixture repo pushed to it. With no-origin the repo has no remote and nothing is pushed (origin.git stays empty).
# With parallel2 the config gets `batch: {parallel: 2}`. Every run has $RUN/claude-worker, the worker 10x-batch
# starts (TENX_BATCH_CLAUDE): the claude binary with the flags of turn().
new_run() {
  local fake="$1" mode="$2" tpl=0 forms=0 remote=1 par=0 a
  shift 2
  for a in "$@"; do case "$a" in pr-template) tpl=1 ;; issue-forms) forms=1 ;; no-origin) remote=0 ;; parallel2) par=2 ;; esac; done
  local dir
  dir="$(mktemp -d "$FLOW_ROOT/run.XXXXXX")"
  dir="$(cd "$dir" && pwd -P)"
  mkdir -p "$dir/gh" "$dir/log" "$dir/ghconfig" "$dir/fakebin" "$dir/shadow"
  ln -s "$E2E_DIR/bin/gh" "$dir/fakebin/gh"
  : >"$dir/gh/calls.log"
  echo '{}' >"$dir/gh/canned.json"
  echo "$fake" >"$dir/fake"
  build_path "$fake" "$dir/shadow" "$dir/fakebin" >"$dir/path"
  printf '[user]\n\tname = E2E\n\temail = e2e@example.com\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' >"$dir/gitconfig"
  echo "$dir" >>"$FLOW_ROOT/runs"
  use_run "$dir"
  SESSION=""
  renv git init -q --bare --initial-branch=main "$ORIGIN"
  mkdir "$REPO"
  cp -R "$E2E_DIR/fixture/." "$REPO/"
  [ "$tpl" = 1 ] || rm -f "$REPO/.github/pull_request_template.md"
  [ "$forms" = 1 ] || { [ ! -d "$REPO/.github/ISSUE_TEMPLATE" ] || rm -r "$REPO/.github/ISSUE_TEMPLATE"; }
  rmdir "$REPO/.github" 2>/dev/null || true
  mkdir -p "$REPO/.claude"
  jq -n --arg close "$mode" --argjson par "$par" \
    '{base: "main", gates: ["node --test"], close: $close} + (if $par > 0 then {batch: {parallel: $par}} else {} end)' >"$REPO/.claude/10x.json"
  # The worker: the flags of turn(), before 10x-batch's -p, output format, permission mode, session and
  # `-- <prompt>`.
  printf '#!/bin/bash\nexec %q --model sonnet --plugin-dir %q --setting-sources project --settings %q "$@"\n' \
    "$CLAUDE_BIN" "$PLUGIN" "$E2E_SETTINGS" >"$RUN/claude-worker"
  chmod +x "$RUN/claude-worker"
  renv git -C "$REPO" init -q --initial-branch=main
  rgit add -A
  rgit commit -q -m "chore: fixture"
  if [ "$remote" = 1 ]; then
    rgit remote add origin "$ORIGIN_URL"
    rgit push -q -u origin main
  fi
  rgit rev-parse main >"$RUN/initial-main"
  origin_heads >"$RUN/initial-heads"
}

canned() { printf '%s\n' "$1" >"$GHD/canned.json"; }
seed_state() { printf '%s\n' "$1" >"$GHD/state.json"; }

# ---------------------------------------------------------------- the claude driver

new_session() { SESSION=""; }

# preflight — what must hold before claude runs: no real gh on PATH, 10x-land from the plugin under test.
preflight() {
  local gh cl dir want
  [ ! -f "$RUN/preflight-err" ] || return 1
  gh="$(PATH="$E2E_PATH" type -P gh || true)"
  if [ "$(cat "$RUN/fake")" = 1 ]; then
    [ "$gh" = "$RUN/fakebin/gh" ] || { echo "gh resolves to '$gh', not the fake" >"$RUN/preflight-err"; return 1; }
  elif [ -n "$gh" ]; then
    echo "a gh is reachable on PATH ($gh) in a run without the fake" >"$RUN/preflight-err"; return 1
  fi
  cl="$(PATH="$E2E_PATH" type -P 10x-land || true)"
  want="$(cd "$PLUGIN/bin" 2>/dev/null && pwd -P || true)"
  dir=""
  [ -z "$cl" ] || dir="$(cd "$(dirname "$cl")" && pwd -P)"
  if [ -z "$want" ] || [ "$dir" != "$want" ]; then
    echo "10x-land resolves to '${cl:-nothing}', not into $PLUGIN/bin" >"$RUN/preflight-err"; return 1
  fi
}

# turn <prompt> — one `claude -p` turn: the first of a session creates it, later ones resume it.
turn() {
  local prompt="$1" n log
  preflight || return 0
  n="$(find "$LOGD" -name 'turn-*.jsonl' | wc -l | tr -d ' ')"
  log="$LOGD/turn-$(printf '%02d' $((n + 1))).jsonl"
  local sess=(--resume "$SESSION")
  if [ -z "$SESSION" ]; then
    SESSION="$(node -e 'console.log(crypto.randomUUID())')"
    sess=(--session-id "$SESSION")
  fi
  (cd "$REPO" && renv "$CLAUDE_BIN" -p "$prompt" --output-format stream-json --verbose --model sonnet \
    --plugin-dir "$PLUGIN" --setting-sources project --permission-mode acceptEdits \
    --settings "$E2E_SETTINGS" "${sess[@]}") >"$log" 2>"$log.err" </dev/null || true
}

# run_aborted — this run has a denial in the skills' scope or failed its preflight: more turns would only spend tokens.
run_aborted() {
  local tool cmd
  [ ! -f "$RUN/preflight-err" ] || return 0
  while IFS=$'\t' read -r tool cmd; do in_skill_scope "$tool" "$cmd" && return 0; done < <(run_denials)
  return 1
}

# drive <first prompt> <reply> <max turns> <predicate...> — one turn, then replies until the predicate holds.
drive() {
  local prompt="$1" reply="$2" max="$3" n=1
  shift 3
  turn "$prompt"
  while [ "$n" -lt "$max" ] && ! "$@" && ! run_aborted; do
    turn "$reply"; n=$((n + 1))
  done
}

never() { return 1; }

# ---------------------------------------------------------------- logs

run_logs() { # prints the run's turn logs, one per line
  local f
  for f in "$LOGD"/turn-*.jsonl; do if [ -e "$f" ]; then printf '%s\n' "$f"; fi; done
}
tool_calls() { # JSON lines: {turn, seq, name, command, skill, subagent_type, run_in_background, file_path, denied}
  local files=() f
  while IFS= read -r f; do files+=("$f"); done < <(run_logs)
  [ ${#files[@]} -gt 0 ] || return 0
  node "$E2E_DIR/toollog.js" calls "${files[@]}"
}
run_denials() {
  local files=() f
  while IFS= read -r f; do files+=("$f"); done < <(run_logs)
  [ ${#files[@]} -gt 0 ] || return 0
  node "$E2E_DIR/toollog.js" denials "${files[@]}"
}
run_stats() { # JSON {cost, ms}
  local files=() f
  while IFS= read -r f; do files+=("$f"); done < <(run_logs)
  [ ${#files[@]} -gt 0 ] || { echo '{"cost":0,"ms":0}'; return 0; }
  node "$E2E_DIR/toollog.js" stats "${files[@]}"
}
# tool_count <ERE> — executed (not denied) Bash commands matching the pattern.
tool_count() { tool_calls | jq -s --arg re "$1" '[.[] | select(.name == "Bash" and .denied == false and ((.command // "") | test($re)))] | length'; }
# agent_count <subagent_type> — Agent (formerly Task) calls of that type.
agent_count() { tool_calls | jq -s --arg t "$1" '[.[] | select((.name == "Agent" or .name == "Task") and .subagent_type == $t)] | length'; }

ghlog() { if [ -s "$GHD/calls.log" ]; then cat "$GHD/calls.log"; fi; }
ghlog_count() { ghlog | jq -s --arg a "$1" --arg b "$2" '[.[] | select(.[0] == $a and .[1] == $b)] | length'; }
# ghlog_values <sub> <sub2> <flag> — every value of the flag in calls of that kind, one per line.
ghlog_values() {
  ghlog | jq -r --arg a "$1" --arg b "$2" --arg f "$3" 'select(.[0] == $a and .[1] == $b) | . as $v | range(0; length) | select($v[.] == $f) | $v[. + 1]'
}
ghlog_flag_present() { # <sub> <sub2> <flag>
  [ "$(ghlog | jq -s --arg a "$1" --arg b "$2" --arg f "$3" '[.[] | select(.[0] == $a and .[1] == $b and any(.[]; . == $f))] | length')" -gt 0 ]
}
state_json() { if [ -s "$GHD/state.json" ]; then cat "$GHD/state.json"; else echo '{"issues":[],"comments":[],"prs":[]}'; fi; }

origin_heads() { git --git-dir "$ORIGIN" for-each-ref --format='%(refname) %(objectname)' refs/heads; }
origin_head() { git --git-dir "$ORIGIN" rev-parse --verify --quiet "refs/heads/$1"; }

# ---------------------------------------------------------------- flow-level failures

# skill_grants — the Bash grants of the plugin's skills and of E2E_SETTINGS, one pattern per line.
skill_grants() {
  { grep -h '^  - Bash(' "$PLUGIN"/skills/*/SKILL.md; jq -r '.permissions.allow[]' <<<"$E2E_SETTINGS"; } |
    sed -n 's/^ *- //; s/^Bash(\(.*\))$/\1/p'
}
# in_skill_scope <tool> <command> — a denial the skills own: any tool but Bash, a 10x-, gh or glab command, or a
# command a grant covers (it should have run). Anything else is the model's own look around, which a user may allow;
# so is a command chained with |, ; or &&, which the skills never run (one command per Bash call).
in_skill_scope() {
  local g
  [ "$1" = Bash ] || return 0
  case "$2" in *'|'* | *';'* | *'&&'*) return 1 ;; esac
  case "$2" in 10x-* | gh | "gh "* | glab | "glab "*) return 0 ;; esac
  while IFS= read -r g; do
    # shellcheck disable=SC2053  # the grant is a glob on purpose
    [[ "$2" == $g ]] && return 0
  done < <(skill_grants)
  return 1
}

# flow_failure — why every scenario of the flow fails, or nothing: a preflight failure, a denied command in the
# skills' scope, or an executed `gh <sub> <sub2>` the fake never saw (runs with the fake only). Other denials go to
# $FLOW_ROOT/notes, which run.sh prints on stderr.
flow_failure() {
  local why="" dir den n a b have cur="$RUN" tool cmd
  while IFS= read -r dir; do
    use_run "$dir"
    [ ! -f "$RUN/preflight-err" ] || why="${why:+$why; }$(cat "$RUN/preflight-err")"
    den=""
    while IFS=$'\t' read -r tool cmd; do
      [ -n "${tool:-}" ] || continue
      if in_skill_scope "$tool" "$cmd"; then den="${den:+$den; }$cmd"
      else printf 'note: %s denied (not the skill'"'"'s): %s\n' "$FLOW" "$cmd" >>"$FLOW_ROOT/notes"; fi
    done < <(run_denials)
    [ -z "$den" ] || why="${why:+$why; }permission denied: $den"
    [ "$(cat "$RUN/fake")" = 1 ] || continue
    while read -r n a b; do
      [ -n "${n:-}" ] || continue
      have="$(ghlog_count "$a" "$b")"
      [ "$n" -le "$have" ] || why="${why:+$why; }tool log has $n 'gh $a $b' calls, the fake gh saw $have"
    done < <(tool_calls | jq -r 'select(.name == "Bash" and .denied == false) | (.command // "") | select(test("^gh +[^ ]+ +[^ ]+")) | split(" ") | map(select(length > 0)) | "\(.[1]) \(.[2])"' | sort | uniq -c)
  done <"$FLOW_ROOT/runs"
  use_run "$cur"
  [ -z "$why" ] || printf '%s\n' "$why"
}

# ---------------------------------------------------------------- assertions

# ensure <what> <command...> — a failing command adds <what> to WHY.
ensure() {
  local what="$1"
  shift
  "$@" >/dev/null 2>&1 || WHY="${WHY:+$WHY; }$what"
}

record() { # <id> <status> <reason>
  printf '%s\t%s\n' "$2" "$3" >"$RESULTS/$1.$FLOW"
}

# Scenario ids bound to a flow and checkpoint (scenarios.sh's bindings) that are selected.
flow_ids() { # <flow> [checkpoint]
  local id b
  for id in $ALL_IDS; do
    is_selected "$id" || continue
    for b in $(bindings "$id"); do
      [ "${b%%:*}" = "$1" ] || continue
      [ -z "${2:-}" ] || [ "${b#*:}" = "$2" ] || continue
      printf '%s\n' "$id"
    done
  done
}
is_selected() { case " $SELECTED " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# check_scenarios <checkpoint> — a flow-level failure fails every selected scenario of the flow not judged at an
# earlier checkpoint and returns 1; else each scenario bound to the checkpoint is judged by its scenario_<id> function.
check_scenarios() {
  local why id
  why="$(flow_failure)"
  if [ -n "$why" ]; then
    for id in $(flow_ids "$FLOW"); do [ -f "$RESULTS/$id.$FLOW" ] || record "$id" FAIL "$why"; done
    return 1
  fi
  for id in $(flow_ids "$FLOW" "$1"); do
    WHY=""
    "scenario_$id" 2>>"$FLOW_ROOT/scenario.err" || true
    if [ -z "$WHY" ]; then record "$id" pass ""; else record "$id" FAIL "$WHY"; fi
  done
}
# flow_wants <flow> <checkpoint> — is a selected scenario bound there?
flow_wants() { [ -n "$(flow_ids "$1" "$2")" ]; }

# ---------------------------------------------------------------- prepared state and harness steps

# Writes a file under the ticket's .10x/ directory in the main checkout.
ticket_file() { # <id> <name>, content on stdin
  mkdir -p "$REPO/.10x/$1"
  cat >"$REPO/.10x/$1/$2"
}

# The two issues the work flows plan from; GH6's are used by scenarios.sh.
# shellcheck disable=SC2016,SC2034  # backticks are markdown; used by scenarios.sh
GH5_TITLE="greet prints the greeting twice"
# shellcheck disable=SC2016  # backticks are markdown
GH5_BODY='`bin/greet Ann` prints `Hello, Ann!` twice instead of once.

Open question for the author: when no name is given, should `greet` print `Hello, world!` or exit with a usage message?'
# shellcheck disable=SC2034  # used by scenarios.sh
GH6_TITLE="Rename greet_line to format_greeting"
# shellcheck disable=SC2016,SC2034  # backticks are markdown; used by scenarios.sh
GH6_BODY='Rename `greet_line` to `format_greeting` everywhere it is named: the code, the tests and the docs.'

# prep_plan — the state an approved plan leaves for a new /10x:work session: gh-5's ticket.md and approved plan.md,
# no worktree.
prep_plan() {
  inrepo 10x-worktree init gh-5 >/dev/null || { echo "prep: worktree init failed" >&2; return 1; }
  ticket_file gh-5 ticket.md <<TICKET
# $GH5_TITLE

- source: GitHub issue #5 (open)
- url: https://github.com/test/fixture/issues/5
- labels: bug

$GH5_BODY
TICKET
  ticket_file gh-5 plan.md <<'PLAN'
# gh-5 — greet prints the greeting twice

Status: approved

## Goal
`bin/greet` prints the greeting once.

## Acceptance criteria
- AC1 — `bin/greet Ann` prints exactly one line, `Hello, Ann!`.
- AC2 — A test covers it and fails without the fix.

## Approach
Drop the duplicated `printf` in `greet_line`.

## Files
- `scripts/lib.sh` — remove the second `printf`.
- `test/greet.test.mjs` — add a case.

## Readers
- `greet_line` — `grep -rn greet_line .`
  - `bin/greet:5` — calls it, unchanged.

## Tool behaviour relied on
none

## Overlap
- `origin/main` since the merge base: none — `git log --name-only HEAD..origin/main`.
- Other worktrees: none — `git worktree list`.
- Open PRs: none — `gh pr list`.

## Tests
| AC | Test file | Case |
|---|---|---|
| AC1 | `test/greet.test.mjs` | `prints the greeting once` |
| AC2 | `test/greet.test.mjs` | `prints the greeting once` |

## Assumptions
none

## Out of scope
Other greetings.
PLAN
}

# prep_ticket [blocker] — the state /10x:work leaves for /10x:close: worktree and branch with the fix committed,
# ticket.md and an approved plan.md (prep_plan), review.md, evidence.md.
prep_ticket() {
  local wt="$REPO/.worktrees/gh-5"
  inrepo 10x-worktree add gh-5 --type fix --slug greet-twice --no-setup >/dev/null || { echo "prep: worktree add failed" >&2; return 1; }
  cat >"$wt/scripts/lib.sh" <<'LIB'
#!/bin/bash
# Shared helpers for bin/greet. Sourced, never run.

# greet_line <name> — the line greet prints for <name>.
greet_line() {
  local name="$1"
  printf 'Hello, %s!\n' "$name"
}
LIB
  cat >>"$wt/test/greet.test.mjs" <<'TEST'

test('prints the greeting once', () => {
  assert.equal(greet('Ann'), 'Hello, Ann!\n')
})
TEST
  renv git -C "$wt" add -- scripts/lib.sh test/greet.test.mjs
  renv git -C "$wt" commit -q -m "fix(greet): print the greeting once"
  prep_plan || return 1
  if [ "${1:-}" = blocker ]; then
    ticket_file gh-5 review.md <<'REVIEW'
## Round 1 — full

Verdict: changes requested
Criteria: AC1, AC2

#### Finding 1 — blocker: `greet` still prints `Hello, !` for an empty name

`bin/greet ""` prints a greeting with no name; the fix must handle it.

### Plan checks

none
REVIEW
  else
    ticket_file gh-5 review.md <<'REVIEW'
## Round 1 — full

Verdict: approved
Criteria: AC1, AC2

No findings.

### Plan checks

none
REVIEW
  fi
  ticket_file gh-5 evidence.md <<'EVIDENCE'
- AC1 — met: `node --test` passes, `prints the greeting once`.
- AC2 — met: red-proof RED for `test/greet.test.mjs`.
EVIDENCE
  rgit rev-parse "$TICKET_BRANCH" >"$RUN/branch-sha"
  rgit rev-parse "$TICKET_BRANCH^{tree}" >"$RUN/branch-tree"
}

# squash_merge_on_origin — the harness merges the ticket's PR, as a human would; not in the fake's call log.
squash_merge_on_origin() {
  inrepo E2E_GH_QUIET=1 gh pr merge "$TICKET_BRANCH" --repo github.com/test/fixture --squash >/dev/null
}

# ---------------------------------------------------------------- checkpoint predicates and snapshots

has_draft() { compgen -G "$REPO/.10x/drafts/*.md" >/dev/null; }
snapshot_draft() {
  local f
  f="$(compgen -G "$REPO/.10x/drafts/*.md" | head -n 1)"
  [ -z "$f" ] || cp "$f" "$RUN/draft-snapshot.md"
  ghlog_count issue create >"$RUN/creates-at-draft"
}
no_drafts() { ! compgen -G "$REPO/.10x/drafts/*.md" >/dev/null; }
issue_created() { [ "$(ghlog_count issue create)" -ge 1 ]; }
# file_ticket — the slug of the one .10x/<slug>/ticket.md, drafts/ aside; nothing when there is none or several.
file_ticket() {
  local f slug="" n=0
  for f in "$REPO"/.10x/*/ticket.md; do
    [ -e "$f" ] || continue
    f="${f%/ticket.md}"
    [ "${f##*/}" != drafts ] || continue
    slug="${f##*/}"; n=$((n + 1))
  done
  [ "$n" = 1 ] && printf '%s\n' "$slug"
}
has_file_ticket() { [ -n "$(file_ticket)" ]; }
# has_plan — plan.md exists and, when it binds more than 3 files, so does its cold read.
has_plan() {
  local plan="$REPO/.10x/$TICKET/plan.md"
  [ -f "$plan" ] || return 1
  [ "$(md_section "$plan" Files | grep -c '^[-*] ')" -le 3 ] || [ -s "$REPO/.10x/$TICKET/cold-read.md" ]
}
pr_exists() { [ "$(state_json | jq '.prs | length')" -ge 1 ]; }
pr_merged() { [ "$(state_json | jq '[.prs[] | select(.state == "MERGED")] | length')" -ge 1 ]; }
pr_edited() { [ "$(ghlog_count pr edit)" -ge 1 ]; }
worktree_gone() { [ ! -e "$REPO/.worktrees/gh-5" ]; }
base_advanced() { [ "$(rgit rev-parse main)" != "$(cat "$RUN/initial-main")" ]; }
# Some branch of the ticket has a commit touching agent memory: the report's memory commit.
memory_committed() {
  local ref
  for ref in $(rgit for-each-ref --format='%(refname)' 'refs/heads/*/gh-5*'); do
    [ -n "$(rgit log --format=%H "main..$ref" -- .claude/agent-memory)" ] && return 0
  done
  return 1
}
place_memory() {
  mkdir -p "$REPO/.claude/agent-memory/e2e-note"
  printf -- '---\nname: e2e-note\n---\nA note an agent left in the main checkout.\n' >"$REPO/.claude/agent-memory/e2e-note/MEMORY.md"
}

has_roadmap_draft() { [ -f "$REPO/.10x/roadmap.draft.md" ]; }
has_roadmap() { [ -f "$REPO/.10x/roadmap.md" ]; }
# roadmap_rows — the version rows of .10x/roadmap.md, one JSON object each: {version, items: [{text, id}], why,
# state}. Rows follow the header `| Version | Contents | Why this order | State |` and its separator, split on unescaped
# |; Contents splits on "; " outside code spans; an item's id is its closing code span when that is gh-<n> or has
# .10x/<id>/ticket.md, else null.
# shellcheck disable=SC2016  # JavaScript, not shell
roadmap_rows() {
  [ -f "$REPO/.10x/roadmap.md" ] || return 0
  node -e '
const fs = require("fs"), path = require("path")
const repo = process.argv[1]
const cells = (line) => {
  let t = line.trim().replace(/^\|/, "")
  if (/[^\\]\|$/.test(t) || t === "|") t = t.slice(0, -1)
  const out = [""]
  for (let i = 0; i < t.length; i++) {
    if (t[i] === "\\" && t[i + 1] === "|") { out[out.length - 1] += "|"; i++ }
    else if (t[i] === "|") out.push("")
    else out[out.length - 1] += t[i]
  }
  return out.map((c) => c.trim())
}
const items = (s) => {
  const out = [""]
  let tick = 0
  for (let i = 0; i < s.length; i++) {
    if (s[i] === "`") {
      let n = 0
      while (s[i + n] === "`") n++
      tick = tick === 0 ? n : tick === n ? 0 : tick
      out[out.length - 1] += s.slice(i, i + n)
      i += n - 1
    } else if (!tick && s[i] === ";" && s[i + 1] === " ") { out.push(""); i++ }
    else out[out.length - 1] += s[i]
  }
  return out.map((x) => x.trim()).filter(Boolean).map((text) => {
    const m = /`+([^`]+?)`+$/.exec(text)
    const id = m && (/^gh-[0-9]+$/.test(m[1]) || fs.existsSync(path.join(repo, ".10x", m[1], "ticket.md"))) ? m[1] : null
    return { text, id }
  })
}
const lines = fs.readFileSync(path.join(repo, ".10x/roadmap.md"), "utf8").split("\n")
const at = lines.findIndex((l) => l.trim().startsWith("|") && cells(l).join("|") === "Version|Contents|Why this order|State")
if (at === -1) process.exit(0)
for (let k = at + 2; k < lines.length && lines[k].trim().startsWith("|"); k++) {
  const [version = "", contents = "", why = "", state = ""] = cells(lines[k])
  console.log(JSON.stringify({ version, items: items(contents), why, state }))
}
' "$REPO"
}
# roadmap_ids <version> — the ticket ids of that version's items, one per line, in item order.
roadmap_ids() { roadmap_rows | jq -r --arg v "$1" 'select(.version == $v) | .items[] | .id // empty'; }

# not <command...> — negation for ensure.
not() { ! "$@"; }
not_match() { ! [[ "$1" =~ $2 ]]; } # <string> <ERE>

# ---------------------------------------------------------------- batch: run records

# batch_ids — the batch's ticket ids in board order.
batch_ids() { if [ -f "$REPO/.10x/_batch/tickets" ]; then cat "$REPO/.10x/_batch/tickets"; fi; }
# batch_runs [<id>] — the rows of runs.tsv (header dropped) as tab-separated
# `<id> <n> <kind> <session> <session_kind> <start> <end> <exit> <pid>`, for one ticket or all in board order; an
# empty field (a run still open) is `-`.
batch_runs() {
  local id f
  for id in ${1:-$(batch_ids)}; do
    f="$REPO/.10x/_batch/$id/runs.tsv"
    [ -f "$f" ] || continue
    tail -n +2 "$f" | awk -F'\t' -v id="$id" 'BEGIN { OFS = "\t" } { for (i = 1; i <= NF; i++) if ($i == "") $i = "-"; print id, $0 }'
  done
}
# batch_settled — 10x-batch status ends with `done`: every ticket is landed, pr-open, failed, held or dropped.
batch_settled() { [ "$(inrepo 10x-batch status 2>/dev/null | tail -n 1)" = "done" ]; }
