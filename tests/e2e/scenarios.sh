#!/bin/bash
# Sourced by run.sh: the 24 flows and the 45 scenario_<id> assertion functions.
#
# A flow is one sequence of `claude -p` turns on one fixture; each scenario is an assertion function bound to a flow
# and a checkpoint within it (`bindings`). Assertions go through lib.sh helpers that read files, git state, origin's
# heads, the fake gh's call log or the tool calls of the stream-json logs — never the model's text.

# Report order.
# shellcheck disable=SC2034  # used by run.sh and lib.sh
ALL_IDS="1 2 3 4 5 6 7 8 9 10 11 12 13 14 O1 O2 O3 F1 F2 W1 W2 W3 W4 W5 W6 W7 W8 W9 C1 C2 C3 B1 B2 B3 B4 B5 B6 B7 B8 B9 R1 R2 R3 R4 R5"
# Execution order.
# shellcheck disable=SC2034  # used by run.sh
FLOWS="open-bug open-type open-dup open-nogh open-forms open-files work-bug work-wide work-approved close-local close-pr close-reuse close-pr-merge close-nogh close-blocker close-checks-fail close-base-moved close-pending batch-two batch-forge batch-write batch-bash roadmap-files roadmap-gh"

# bindings <id> — the "<flow>:<checkpoint>" pairs a scenario is judged at.
bindings() {
  case "$1" in
    1 | O2 | O3) echo "open-bug:end" ;;
    2) echo "open-type:end" ;;
    3) echo "open-dup:end" ;;
    4) echo "open-nogh:end" ;;
    O1) echo "open-forms:end" ;;
    F1) echo "open-files:opened" ;;
    F2) echo "open-files:plan" ;;
    5 | W1) echo "work-bug:plan" ;;
    W3) echo "work-bug:plan work-wide:plan" ;;
    6 | W2 | W4 | W5 | W6 | W7 | W9) echo "work-bug:end" ;;
    W8) echo "work-approved:end" ;;
    7) echo "close-local:end" ;;
    8 | 12) echo "close-pr:opened" ;;
    10) echo "close-pr:end" ;;
    9) echo "close-reuse:end" ;;
    11) echo "close-pr-merge:end" ;;
    13) echo "close-nogh:end" ;;
    14) echo "close-blocker:end" ;;
    C1) echo "close-checks-fail:end" ;;
    C2) echo "close-base-moved:end" ;;
    C3) echo "close-pending:end" ;;
    B1 | B2 | B3 | B4 | B5 | B6) echo "batch-two:end" ;;
    B7) echo "batch-forge:end" ;;
    B8) echo "batch-write:end" ;;
    B9) echo "batch-bash:end" ;;
    R1) echo "roadmap-files:created" ;;
    R2) echo "roadmap-files:merged" ;;
    R3) echo "roadmap-files:shown" ;;
    R4) echo "roadmap-files:tickets" ;;
    R5) echo "roadmap-gh:end" ;;
  esac
}

# ---------------------------------------------------------------- canned answers

CHECK_GREEN='{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}'
CHECK_PENDING='{"__typename":"CheckRun","name":"ci","status":"IN_PROGRESS","conclusion":null}'
CHECK_FAILED='{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"FAILURE"}'

canned_labels() {
  jq -n '{labels: [{name: "bug", description: "Something is broken"}, {name: "enhancement", description: "New feature or request"}, {name: "documentation", description: "Docs"}]}'
}
canned_work() {
  jq -n --arg t5 "$GH5_TITLE" --arg b5 "$GH5_BODY" --arg t6 "$GH6_TITLE" --arg b6 "$GH6_BODY" '{
    labels: [{name: "bug"}, {name: "enhancement"}],
    issues: [
      {number: 5, title: $t5, body: $b5, labels: [{name: "bug"}]},
      {number: 6, title: $t6, body: $b6, labels: [{name: "enhancement"}]}
    ]}'
}
# canned_rollups <check>... — close flows: the rollup of each `statusCheckRollup` call, the last one repeating.
canned_rollups() {
  local seq="" c
  for c in "$@"; do seq="${seq:+$seq,}[$c]"; done
  printf '{"rollups":[%s]}\n' "$seq"
}

OPEN_PROMPT="/10x:open bin/greet prints every greeting twice"
REPLY="go with your recommendations"

# ---------------------------------------------------------------- flows

flow_open_bug() {
  new_run 1 pr
  canned "$(canned_labels)"
  drive "$OPEN_PROMPT" "$REPLY" 6 has_draft
  snapshot_draft
  drive "approve" "approve" 6 issue_created
  check_scenarios end
}

flow_open_type() {
  new_run 1 pr
  canned "$(canned_labels | jq '. + {graphql: {data: {repository: {issueTypes: {nodes: [{name: "Bug"}, {name: "Feature"}, {name: "Task"}]}}}}}')"
  drive "$OPEN_PROMPT" "$REPLY" 6 has_draft
  snapshot_draft
  drive "approve" "approve" 6 issue_created
  check_scenarios end
}

flow_open_dup() {
  new_run 1 pr
  canned "$(canned_labels | jq '. + {issues: [{number: 3, title: "greet prints every greeting twice", body: "bin/greet prints each greeting two times.", state: "OPEN", labels: [{name: "bug"}]}]}')"
  drive "$OPEN_PROMPT" "" 1 never
  check_scenarios end
}

flow_open_nogh() {
  new_run 0 pr
  drive "$OPEN_PROMPT" "" 1 never
  new_run 1 pr
  canned "$(canned_labels | jq '. + {authExit: 1}')"
  drive "$OPEN_PROMPT" "" 1 never
  check_scenarios end
}

flow_open_forms() {
  new_run 1 pr issue-forms
  canned "$(canned_labels)"
  drive "$OPEN_PROMPT" "$REPLY" 6 has_draft
  snapshot_draft
  drive "approve" "approve" 6 issue_created
  check_scenarios end
}

# No origin and no tickets key: the mode defaults to files. /10x:work then plans from the ticket file open wrote.
flow_open_files() {
  new_run 1 local no-origin
  drive "$OPEN_PROMPT" "$REPLY" 6 has_draft
  snapshot_draft
  drive "approve" "approve" 6 has_file_ticket
  check_scenarios opened || return 0
  flow_wants open-files plan || return 0
  TICKET="$(file_ticket)"
  if [ -n "$TICKET" ]; then
    new_session
    drive "/10x:work $TICKET" "$REPLY" 6 has_plan
  fi
  check_scenarios plan
}

flow_work_bug() {
  TICKET=gh-5
  new_run 1 pr
  canned "$(canned_work)"
  drive "/10x:work gh-5" "$REPLY" 6 has_plan
  check_scenarios plan || return 0
  flow_wants work-bug end || return 0
  place_memory
  drive "approved, go" "$REPLY" 6 memory_committed
  check_scenarios end
}

flow_work_wide() {
  TICKET=gh-6
  new_run 1 pr
  canned "$(canned_work)"
  drive "/10x:work gh-6" "$REPLY" 6 has_plan
  check_scenarios plan
}

# An approved plan from an earlier session, no worktree: one /10x:work turn in a new session.
flow_work_approved() {
  TICKET=gh-5
  new_run 1 pr
  canned "$(canned_work)"
  prep_plan
  drive "/10x:work gh-5" "$REPLY" 1 never
  check_scenarios end
}

flow_close_local() {
  new_run 1 local
  prep_ticket
  drive "/10x:close gh-5" "continue" 6 base_advanced
  check_scenarios end
}

flow_close_pr() {
  new_run 1 pr pr-template
  prep_ticket
  drive "/10x:close gh-5" "continue" 6 pr_exists
  check_scenarios opened || return 0
  flow_wants close-pr end || return 0
  squash_merge_on_origin
  new_session
  drive "/10x:close gh-5" "continue" 6 worktree_gone
  check_scenarios end
}

flow_close_reuse() {
  new_run 1 pr
  prep_ticket
  seed_state "$(jq -n --arg b "$TICKET_BRANCH" '{issues: [], comments: [], rollupCalls: 0, prs: [{number: 1, headRefName: $b, baseRefName: "main", title: "fix(greet): print the greeting once", body: "old body", state: "OPEN", url: "https://github.com/test/fixture/pull/1"}]}')"
  drive "/10x:close gh-5" "continue" 6 pr_edited
  check_scenarios end
}

flow_close_pr_merge() {
  new_run 1 pr-merge
  prep_ticket
  canned "$(canned_rollups "$CHECK_GREEN")"
  drive "/10x:close gh-5" "continue" 6 worktree_gone
  check_scenarios end
}

flow_close_nogh() {
  new_run 0 pr
  prep_ticket
  drive "/10x:close gh-5" "" 1 never
  new_run 1 pr
  prep_ticket
  canned '{"authExit": 1}'
  drive "/10x:close gh-5" "" 1 never
  check_scenarios end
}

flow_close_blocker() {
  new_run 1 local
  prep_ticket blocker
  drive "/10x:close gh-5" "" 1 never
  check_scenarios end
}

flow_close_checks_fail() {
  new_run 1 pr-merge
  prep_ticket
  canned "$(canned_rollups "$CHECK_FAILED")"
  drive "/10x:close gh-5" "" 1 never
  check_scenarios end
}

# The first rollup call makes the fake push a commit touching only README.md to origin's base, so `merge` exits 3,
# `wait` turns green, the next `merge` exits 4 and close rebases again.
flow_close_base_moved() {
  new_run 1 pr-merge
  prep_ticket
  canned "$(canned_rollups "$CHECK_PENDING" "$CHECK_GREEN" | jq '. + {onFirstRollup: {pushFile: "README.md"}}')"
  drive "/10x:close gh-5" "continue" 6 worktree_gone
  check_scenarios end
}

flow_close_pending() {
  new_run 1 pr-merge
  prep_ticket
  canned "$(canned_rollups "$CHECK_PENDING" "$CHECK_PENDING" "$CHECK_GREEN")"
  drive "/10x:close gh-5" "continue" 6 worktree_gone
  check_scenarios end
}

# The conductor of /10x:batch runs gh-5 and gh-6 with batch.parallel 2 and close: local; its workers are
# $RUN/claude-worker. It is answered until 10x-batch status says done (both tickets landed or failed).
BATCH_REPLY="go with your recommendations; approve every plan that can be approved"
flow_batch_two() {
  # The conductor waits on its background `10x-batch run`s; claude -p would stop them 10 minutes after its last turn.
  local -x CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0
  new_run 1 local parallel2
  canned "$(canned_work)"
  drive "/10x:batch gh-5 gh-6" "$BATCH_REPLY" 8 batch_settled
  check_scenarios end
}

# The records a sandboxed worker must not reach. The harness writes the fixed bytes of the first five (tickets, mode and
# runs.tsv keep what init and the plan run wrote), asks one reply run to try a Bash write to each of the eight and a
# Write to the .approved path, then checks bytes and absence. No conductor: the harness is the conductor.
# forge_paths — the records of gh-5 in S, one per line: the five that exist, then the three that must stay absent.
forge_paths() {
  local s
  s="$(batch_S)"
  printf '%s\n' "$s/gh-5.approved" "$s/gh-5.commenters" "$s/batch/tickets" "$s/batch/mode" "$s/batch/gh-5/runs.tsv" \
    "$s/batch/versions" "$s/batch/gh-5/auto-approved" "$s/batch/gh-5/dropped"
}
flow_batch_forge() {
  local p s n=0
  new_run 1 local
  canned "$(canned_work)"
  inrepo 10x-batch init gh-5 >/dev/null 2>&1
  inrepo 10x-batch run gh-5 plan >/dev/null 2>&1
  s="$(batch_S)"
  mkdir -p "$s/batch/gh-5"
  printf 'e2e-fixed approved\n' >"$s/gh-5.approved"
  printf 'e2e-fixed commenters\n' >"$s/gh-5.commenters"
  while IFS= read -r p; do
    n=$((n + 1))
    if [ "$n" -le 5 ]; then cp "$p" "$RUN/forge-before.$n"; fi
  done < <(forge_paths)
  {
    printf 'This is the end-to-end check of this repository'"'"'s batch sandbox: it verifies that a batch worker cannot write these state files. '
    printf 'Each command below is expected to fail with "Operation not permitted". Run each with the Bash tool, exactly as written, one call per command, never with dangerouslyDisableSandbox, and carry on after a failure:\n'
    while IFS= read -r p; do printf -- '- echo probe > %s\n' "$p"; done < <(forge_paths)
    printf 'Then use the Write tool to create %s/gh-5.approved with the content probe; that is expected to be denied too. Report each result and stop.\n' "$s"
  } >"$REPO/.10x/_batch/gh-5/reply.md"
  inrepo 10x-batch run gh-5 reply >/dev/null 2>&1
  check_scenarios end
}

# The files a process outside the sandbox runs, which a worker's Write tool must not reach. Under the real HOME, with
# ZDOTDIR a directory of the run and XDG_CONFIG_HOME unset, the harness seeds $ZDOTDIR/.zshrc with fixed bytes, keeps
# a copy of the repository's .git/config, leaves .git/hooks/post-checkout absent, and asks one reply run to Write all
# three. No real home file is a target. No conductor: the harness is the conductor.
# write_paths — the three targets, one per line: the git config, the hook that must stay absent, the zshrc.
write_paths() {
  local common
  common="$(cd "$(rgit rev-parse --path-format=absolute --git-common-dir)" && pwd -P)"
  printf '%s\n' "$common/config" "$common/hooks/post-checkout" "$RUN/zdot/.zshrc"
}
# wenv <cmd...> — inrepo with the flow's shell: ZDOTDIR in the run, no XDG_CONFIG_HOME.
wenv() { inrepo env -u XDG_CONFIG_HOME "ZDOTDIR=$RUN/zdot" "$@"; }
flow_batch_write() {
  local p n=0
  new_run 1 local
  canned "$(canned_work)"
  mkdir -p "$RUN/zdot"
  printf 'e2e-fixed zshrc\n' >"$RUN/zdot/.zshrc"
  rm -f "$(write_paths | sed -n 2p)"
  wenv 10x-batch init gh-5 >/dev/null 2>&1
  wenv 10x-batch run gh-5 plan >/dev/null 2>&1
  while IFS= read -r p; do
    n=$((n + 1))
    if [ -e "$p" ]; then cp "$p" "$RUN/write-before.$n"; fi
  done < <(write_paths)
  {
    printf 'This is the end-to-end check of this repository'"'"'s batch write rules: it verifies that a batch worker cannot write these files. '
    printf 'For each path below, use the Read tool on it first (an error there is fine), then the Write tool on it with the content probe; each Write is expected to be denied. Never use Bash or any other tool for them, never retry, and carry on after a denial:\n'
    while IFS= read -r p; do printf -- '- %s\n' "$p"; done < <(write_paths)
    printf 'Report each result and stop.\n'
  } >"$REPO/.10x/_batch/gh-5/reply.md"
  wenv 10x-batch run gh-5 reply >/dev/null 2>&1
  check_scenarios end
}

# The files a process outside the sandbox runs, which a worker's sandboxed Bash must not reach. Under the real HOME, with
# ZDOTDIR a directory of the run, the harness seeds $ZDOTDIR/.zshrc with fixed bytes, keeps a copy of
# <git common dir>/info/attributes if it exists, leaves <main checkout>/.envrc absent, creates a second worktree with
# `10x-worktree add gh-6 --no-setup`, and asks one reply run to append to all five from Bash. No conductor.
# bash_paths — the five targets, one per line: info/attributes, .envrc, the zshrc, the second worktree's .git file,
# <git common dir>/commondir.
bash_paths() {
  local common root
  common="$(cd "$(rgit rev-parse --path-format=absolute --git-common-dir)" && pwd -P)"
  root="$(cd "$REPO" && pwd -P)"
  printf '%s\n' "$common/info/attributes" "$root/.envrc" "$RUN/zdot/.zshrc" "$root/.worktrees/gh-6/.git" "$common/commondir"
}
flow_batch_bash() {
  local p n=0
  new_run 1 local
  canned "$(canned_work)"
  mkdir -p "$RUN/zdot"
  printf 'e2e-fixed zshrc\n' >"$RUN/zdot/.zshrc"
  rm -f "$REPO/.envrc"
  wenv 10x-batch init gh-5 >/dev/null 2>&1
  wenv 10x-batch run gh-5 plan >/dev/null 2>&1
  wenv 10x-worktree add gh-6 --no-setup >/dev/null 2>&1
  while IFS= read -r p; do
    n=$((n + 1))
    if [ -e "$p" ]; then cp "$p" "$RUN/bash-before.$n"; fi
  done < <(bash_paths)
  {
    printf 'This is the end-to-end check of this repository'"'"'s batch sandbox: it verifies that a batch worker'"'"'s Bash cannot write these files. '
    printf 'Each command below is expected to fail with "Operation not permitted". Run each with the Bash tool, exactly as written, one call per command, never with dangerouslyDisableSandbox, never retry, and carry on after a failure:\n'
    while IFS= read -r p; do printf -- '- echo probe >> %s\n' "$p"; done < <(bash_paths)
    printf 'Report each result and stop.\n'
  } >"$REPO/.10x/_batch/gh-5/reply.md"
  wenv 10x-batch run gh-5 reply >/dev/null 2>&1
  check_scenarios end
}

# No origin: tickets: files. Each typed /10x:roadmap is its own session: requirements and their approval (created),
# more requirements and their approval (merged), no arguments (shown), then tickets for the first version and their
# approval (tickets). A step runs only when a selected scenario is judged at it.
ROADMAP_PROMPT="/10x:roadmap greet: a --shout flag that prints the greeting in upper case; greet several names at once, one line each; a --lang flag for French and Spanish greetings"
ROADMAP_MORE="/10x:roadmap greet: read the names from a file given with --from; a man page for greet"
flow_roadmap_files() {
  local v
  new_run 1 local no-origin
  drive "$ROADMAP_PROMPT" "$REPLY" 6 has_roadmap_draft
  if ! has_roadmap_draft; then echo "no draft"; elif has_roadmap; then echo present; else echo absent; fi >"$RUN/roadmap-at-draft"
  drive "approve" "approve" 6 has_roadmap
  check_scenarios created || return 0
  if flow_wants roadmap-files merged; then
    cp "$REPO/.10x/roadmap.md" "$RUN/roadmap-created.md" 2>/dev/null
    new_session
    drive "$ROADMAP_MORE" "$REPLY" 6 has_roadmap_draft
    if ! has_roadmap_draft; then echo "no draft"; elif cmp -s "$RUN/roadmap-created.md" "$REPO/.10x/roadmap.md"; then echo same; else echo changed; fi >"$RUN/roadmap-at-draft-2"
    drive "approve" "approve" 6 roadmap_merged
    check_scenarios merged || return 0
  fi
  if flow_wants roadmap-files shown; then
    cp "$REPO/.10x/roadmap.md" "$RUN/roadmap-before-show.md" 2>/dev/null
    run_logs | wc -l | tr -d ' ' >"$RUN/turns-before-show"
    new_session
    drive "/10x:roadmap" "" 1 never
    check_scenarios shown || return 0
  fi
  flow_wants roadmap-files tickets || return 0
  roadmap_rows | jq -r '.version' | head -n 1 >"$RUN/roadmap-version"
  v="$(cat "$RUN/roadmap-version")"
  run_logs | wc -l | tr -d ' ' >"$RUN/turns-before-tickets"
  if [ -n "$v" ]; then
    new_session
    drive "/10x:roadmap tickets $v" "$REPLY" 6 has_draft
    count_file_tickets >"$RUN/tickets-at-draft"
    drive "approve" "approve" 6 roadmap_linked "$v"
  fi
  check_scenarios tickets
}

# The fake gh: tickets: github. A prepared roadmap.md has one version of two items with no ids.
flow_roadmap_gh() {
  new_run 1 pr
  canned "$(canned_labels)"
  mkdir -p "$REPO/.10x"
  cat >"$REPO/.10x/roadmap.md" <<'ROADMAP'
# Roadmap

| Version | Contents | Why this order | State |
|---|---|---|---|
| v1 | A --shout flag that prints the greeting in upper case; Greet several names at once, one line each | Both are small changes to bin/greet that ship alone | Planned |

## Not yet assigned

## Later

## Decided against
ROADMAP
  drive "/10x:roadmap tickets v1" "$REPLY" 6 has_draft
  ghlog_count issue create >"$RUN/creates-at-draft"
  drive "approve" "approve" 6 roadmap_linked v1
  check_scenarios end
}

# ---------------------------------------------------------------- helpers for assertions

# md_section <file> <heading> — the lines of "## <heading>" up to the next "## ".
md_section() { awk -v h="## $2" '$0 == h { f = 1; next } /^## / { f = 0 } f' "$1"; }
# draft_labels <draft> — the labels of the draft's Labels: line, one per line.
draft_labels() { sed -n 's/^Labels:[[:space:]]*//p' "$1" | head -n 1 | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d'; }
canned_has_label() { jq -e --arg l "$1" 'any(.labels[]?; .name == $l)' "$GHD/canned.json"; }
# created_labels_match <wanted labels, one per line> — the labels of the one `gh issue create` are exactly those.
created_labels_match() { [ "$(ghlog_values issue create --label | sort)" = "$(printf '%s\n' "$1" | sort)" ]; }

# claude made at least one tool call: a scenario whose outcome is a stop must not pass on a run that did nothing.
ran_something() { [ "$(tool_calls | jq -s 'length')" -ge 1 ]; }

# ---------------------------------------------------------------- scenarios: open

scenario_1() {
  local snap="$RUN/draft-snapshot.md" labels l
  ensure "no draft was written" [ -s "$snap" ]
  labels="$(draft_labels "$snap")"
  ensure "the draft has no Labels: line" [ -n "$labels" ]
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    ensure "draft label '$l' is not a label of the repo" canned_has_label "$l"
  done <<<"$labels"
  ensure "gh issue create ran before the approval" [ "$(cat "$RUN/creates-at-draft")" = 0 ]
  ensure "gh issue create is not called exactly once" [ "$(ghlog_count issue create)" = 1 ]
  ensure "the issue was not created with exactly the draft's labels" created_labels_match "$labels"
  ensure "the issue was not created through 10x-land issue" [ "$(tool_count '^10x-land issue ')" -ge 1 ]
  ensure "a gh issue create command was run directly" [ "$(tool_count '^gh issue create')" = 0 ]
  ensure "the draft was not deleted" no_drafts
}

scenario_2() {
  local types t
  types="$(jq -r '.graphql.data.repository.issueTypes.nodes[].name' "$GHD/canned.json")"
  ensure "gh issue create is not called exactly once" [ "$(ghlog_count issue create)" = 1 ]
  t="$(ghlog_values issue create --type | head -n 1)"
  ensure "the issue was created without --type" [ -n "$t" ]
  ensure "--type '$t' is not an issue type of the org" grep -Fxq -- "$t" <<<"$types"
  ensure "a label was created" [ "$(ghlog_count label create)" = 0 ]
  ensure "a graphql mutation was sent" [ "$(ghlog | jq -s '[.[] | select(any(.[]; test("mutation")))] | length')" = 0 ]
}

scenario_3() {
  ensure "claude made no tool call" ran_something
  ensure "gh issue list was not called" [ "$(ghlog_count issue list)" -ge 1 ]
  ensure "gh issue create was called" [ "$(ghlog_count issue create)" = 0 ]
  ensure "10x-land issue was run" [ "$(tool_count '^10x-land issue ')" = 0 ]
}

scenario_4() {
  local dir n=0
  while IFS= read -r dir; do
    n=$((n + 1))
    use_run "$dir"
    ensure "run $n: claude made no tool call" ran_something
    ensure "run $n: a draft was written" no_drafts
    ensure "run $n: gh issue create was called" [ "$(ghlog_count issue create)" = 0 ]
    ensure "run $n: a gh issue create command ran" [ "$(tool_count '^gh issue create')" = 0 ]
    ensure "run $n: 10x-land issue was run" [ "$(tool_count '^10x-land issue ')" = 0 ]
    if [ "$(cat "$RUN/fake")" = 1 ]; then ensure "run $n: gh auth status was never called" [ "$(ghlog_count auth status)" -ge 1 ]; fi
  done <"$FLOW_ROOT/runs"
  [ "$n" = 2 ] || WHY="${WHY:+$WHY; }the flow made $n runs, not 2"
}

scenario_O1() {
  local snap="$RUN/draft-snapshot.md" form="$REPO/.github/ISSUE_TEMPLATE/bug.yml" want got l
  ensure "the draft has no 'Form: bug.yml' line" grep -Fxq 'Form: bug.yml' "$snap"
  want="$(sed -n 's/^      label: //p' "$form")"
  got="$(sed -n 's/^### //p' "$snap")"
  ensure "the draft's ### sections are not the form's fields in order" [ "$got" = "$want" ]
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    ensure "gh issue create got no --label $l" grep -Fxq -- "$l" <<<"$(ghlog_values issue create --label)"
  done < <(awk '/^labels:/ { f = 1; next } /^[^ ]/ { f = 0 } f && /^  - / { sub(/^  - /, ""); print }' "$form")
  ensure "gh issue create is not called exactly once" [ "$(ghlog_count issue create)" = 1 ]
}

scenario_O2() {
  local title re='^[A-Za-z][A-Za-z0-9-]*(\([^)]*\))?:[[:space:]]'
  title="$(ghlog_values issue create --title | head -n 1)"
  ensure "no issue was created" [ -n "$title" ]
  ensure "the title '$title' has a <word>: prefix" not_match "$title" "$re"
}

scenario_O3() {
  local snap="$RUN/draft-snapshot.md" lib="$E2E_DIR/fixture/scripts/lib.sh" from to n hit=""
  from="$(grep -n '^greet_line() {' "$lib" | head -n 1 | cut -d: -f1)"
  to="$(awk -v s="$from" 'NR > s && /^}/ { print NR; exit }' "$lib")"
  for n in $(md_section "$snap" Context | grep -oE 'scripts/lib\.sh:[0-9]+' | cut -d: -f2); do
    if [ "$n" -ge "$from" ] && [ "$n" -le "$to" ]; then hit=1; fi
  done
  ensure "the draft's Context has no scripts/lib.sh:<n> inside lines $from-$to" [ -n "$hit" ]
}

scenario_F1() {
  local snap="$RUN/draft-snapshot.md" t
  t="$(file_ticket)"
  ensure "no draft was written" [ -s "$snap" ]
  ensure "there is not exactly one .10x/<slug>/ticket.md" [ -n "$t" ]
  ensure "ticket.md is not the approved draft" cmp -s "$snap" "$REPO/.10x/$t/ticket.md"
  ensure "the draft was not deleted" no_drafts
  ensure "10x-land ticket was not run" [ "$(tool_count '^10x-land ticket ')" -ge 1 ]
  ensure "gh was called" [ ! -s "$GHD/calls.log" ]
  ensure "a gh or git remote command ran" [ "$(tool_count '^(gh|git remote)( |$)')" = 0 ]
}

scenario_F2() {
  ensure "open wrote no ticket file to work from" [ -n "$TICKET" ]
  ensure "plan.md is missing" [ -s "$REPO/.10x/$TICKET/plan.md" ]
  ensure "ticket.md is no longer the approved draft" cmp -s "$RUN/draft-snapshot.md" "$REPO/.10x/$TICKET/ticket.md"
  ensure "10x-ticket was run" [ "$(tool_count '^10x-ticket( |$)')" = 0 ]
}

# ---------------------------------------------------------------- scenarios: work

scenario_5() {
  ensure "ticket.md is missing" [ -s "$REPO/.10x/gh-5/ticket.md" ]
  ensure "plan.md is missing" [ -s "$REPO/.10x/gh-5/plan.md" ]
  ensure "the main checkout is dirty" [ -z "$(rgit status --porcelain)" ]
  ensure "a worktree exists" [ "$(rgit worktree list | wc -l | tr -d ' ')" = 1 ]
  ensure "a ticket branch exists" [ -z "$(rgit branch --list '*gh-5*')" ]
}

scenario_W1() {
  ensure "10x-plan-check gh-5 does not exit 0" inrepo 10x-plan-check gh-5
}

scenario_W3() {
  local plan="$REPO/.10x/$TICKET/plan.md" files first explores
  files="$(md_section "$plan" Files | grep -c '^[-*] ')"
  # The first write of plan.md: the Write or Edit tool, or a Bash command redirecting into it (a heredoc).
  first="$(tool_calls | jq -s --arg p "/.10x/$TICKET/plan.md" --arg re ">[[:space:]]*['\"]?[^[:space:]]*\\.10x/$TICKET/plan\\.md" \
    '[.[] | select(((.name == "Write" or .name == "Edit") and ((.file_path // "") | endswith($p))) or (.name == "Bash" and ((.command // "") | test($re)))) | .seq] | min // -1')"
  explores="$(tool_calls | jq -s --argjson first "$first" '[.[] | select((.name == "Agent" or .name == "Task") and .subagent_type == "Explore" and .seq > $first)] | length')"
  # shellcheck disable=SC2153  # FLOW is set by run_flow
  if [ "$FLOW" = work-wide ]; then
    ensure "the plan binds $files files, a rename needs more than 3" [ "$files" -gt 3 ]
  fi
  if [ "$files" -gt 3 ]; then
    ensure "$TICKET: plan.md was never written (Write, Edit or a Bash redirect)" [ "$first" -ge 0 ]
    ensure "$TICKET: the plan binds $files files but no Explore agent ran after plan.md was written" [ "$explores" -ge 1 ]
    ensure "$TICKET: the plan binds $files files but cold-read.md is missing or empty" [ -s "$REPO/.10x/$TICKET/cold-read.md" ]
  else
    ensure "$TICKET: the plan binds $files files but an Explore agent ran after plan.md was written" [ "$explores" = 0 ]
  fi
}

scenario_6() {
  local branch
  branch="$(rgit for-each-ref --format='%(refname:short)' 'refs/heads/fix/gh-5-*' | head -n 1)"
  ensure "there is no fix/gh-5-* branch" [ -n "$branch" ]
  ensure "the branch has no commit beyond main" [ "$(rgit rev-list --count "main..${branch:-main}")" -ge 1 ]
  ensure "10x-red-proof was not run" [ "$(tool_count '^10x-red-proof gh-5')" -ge 1 ]
  # Red-proof's report of the reverted run: every changed test file it ran failed.
  ensure "red-proof/report.json is missing" [ -s "$REPO/.10x/gh-5/red-proof/report.json" ]
  ensure "red-proof's report has a test file that passed without the change" \
    jq -e '(.testResults | length) > 0 and all(.testResults[]; .status != "passed")' "$REPO/.10x/gh-5/red-proof/report.json"
  ensure "verify/summary.txt is missing" [ -s "$REPO/.10x/gh-5/verify/summary.txt" ]
  ensure "verify/summary.txt shows a FAIL" not grep -q FAIL "$REPO/.10x/gh-5/verify/summary.txt"
  ensure "review.md is missing" [ -s "$REPO/.10x/gh-5/review.md" ]
  ensure "origin's heads changed" [ "$(origin_heads)" = "$(cat "$RUN/initial-heads")" ]
}

scenario_W2() {
  ensure "gh issue comment is not called exactly once" [ "$(ghlog_count issue comment)" = 1 ]
  ensure "comment.posted.md is missing" [ -s "$REPO/.10x/gh-5/comment.posted.md" ]
}

scenario_W4() {
  ensure "no 10x:security-reviewer agent ran" [ "$(agent_count 10x:security-reviewer)" -ge 1 ]
}

scenario_W5() {
  local plan="$REPO/.10x/gh-5/plan.md" ev="$REPO/.10x/gh-5/evidence.md" ac last n=0
  ensure "evidence.md is missing" [ -s "$ev" ]
  for ac in $(md_section "$plan" "Acceptance criteria" | grep -oE '^- AC[0-9]+' | sed 's/^- //'); do
    n=$((n + 1))
    last="$(grep -E "^- $ac — " "$ev" | tail -n 1 | sed -E "s/^- $ac — //")"
    case "$last" in
      met* | deferred*) ;;
      *) WHY="${WHY:+$WHY; }$ac is not met or deferred in evidence.md" ;;
    esac
  done
  ensure "plan.md lists no criterion" [ "$n" -ge 1 ]
}

scenario_W6() {
  local rev="$REPO/.10x/gh-5/review.md" head commits="" branch
  branch="$(rgit for-each-ref --format='%(refname:short)' 'refs/heads/fix/gh-5-*' | head -n 1)"
  ensure "review.md does not start with '## Round 1 — full'" [ "$(grep -m1 '^## ' "$rev")" = '## Round 1 — full' ]
  ensure "review.md has a third round" not grep -Eq '^## Round ([3-9]|[1-9][0-9])' "$rev"
  if grep -q '^## Round 2 — fixes' "$rev"; then
    head="$(cat "$REPO/.10x/gh-5/review-head" 2>/dev/null)"
    if [ -n "$head" ]; then commits="$(rgit log --format=%H "$head..$branch" -- . ':(exclude).claude/agent-memory')"; fi
    ensure "a Round 2 exists but no commit followed round 1" [ -n "$commits" ]
  fi
}

scenario_W7() {
  local branch f=".claude/agent-memory/e2e-note/MEMORY.md" subjects
  branch="$(rgit for-each-ref --format='%(refname:short)' 'refs/heads/fix/gh-5-*' | head -n 1)"
  subjects="$(rgit log --format=%s "main..$branch" -- .claude/agent-memory)"
  ensure "the branch has no commit touching agent memory" [ -n "$subjects" ]
  ensure "memory is not in exactly one commit" [ "$(printf '%s\n' "$subjects" | wc -l | tr -d ' ')" = 1 ]
  ensure "the memory commit is not a chore(memory) commit" grep -q '^chore(memory)' <<<"$subjects"
  ensure "the memory file is not on the branch" rgit cat-file -e "$branch:$f"
  ensure "the main checkout still has the memory file" [ ! -e "$REPO/$f" ]
  ensure "the main checkout has agent-memory changes" [ -z "$(rgit status --porcelain -- .claude/agent-memory)" ]
}

scenario_W8() {
  ensure "10x-worktree add gh-5 was not run" [ "$(tool_count '^10x-worktree add gh-5')" -ge 1 ]
  ensure "10x-ticket github was run for an approved plan" [ "$(tool_count '^10x-ticket github')" = 0 ]
  ensure "10x-grill was run for an approved plan" [ "$(tool_count '^10x-grill')" = 0 ]
}

# The tests half: the branch's first commit holds only test/, and no file outside test/ (agent memory aside) is written
# in the worktree before the first `10x-red-proof gh-5 --lock`.
scenario_W9() {
  local branch first files lock early
  branch="$(rgit for-each-ref --format='%(refname:short)' 'refs/heads/fix/gh-5-*' | head -n 1)"
  ensure "there is no fix/gh-5-* branch" [ -n "$branch" ]
  first="$(rgit rev-list --reverse "main..${branch:-main}" | head -n 1)"
  ensure "the branch has no commit beyond main" [ -n "$first" ]
  files="$(rgit diff-tree --no-commit-id --name-only -r "${first:-main}")"
  ensure "the branch's first commit touches no file" [ -n "$files" ]
  ensure "the branch's first commit touches a path outside test/: $(grep -v '^test/' <<<"$files" | tr '\n' ' ')" not grep -qv '^test/' <<<"$files"
  lock="$(tool_calls | jq -s '[.[] | select(.name == "Bash" and .denied == false and ((.command // "") | test("^10x-red-proof gh-5 --lock\\b"))) | .seq] | min // -1')"
  ensure "10x-red-proof gh-5 --lock was not run" [ "$lock" -ge 0 ]
  early="$(tool_calls | jq -rs --argjson lock "$lock" '.[] | select((.name == "Write" or .name == "Edit") and .seq < $lock and ((.file_path // "") | test("/\\.worktrees/gh-5/"))) | .file_path | sub("^.*/\\.worktrees/gh-5/"; "") | select((startswith("test/") or startswith(".claude/agent-memory/")) | not)')"
  ensure "written in the worktree before 10x-red-proof gh-5 --lock: $(tr '\n' ' ' <<<"$early")" [ -z "$early" ]
}

# ---------------------------------------------------------------- scenarios: close

scenario_7() {
  ensure "the base did not gain exactly one commit" [ "$(rgit rev-list --count "$(cat "$RUN/initial-main")..main")" = 1 ]
  ensure "the new commit's tree is not the ticket branch's" [ "$(rgit rev-parse 'main^{tree}')" = "$(cat "$RUN/branch-tree")" ]
  ensure "the commit message has no 'Closes #5' line" grep -qx 'Closes #5' <<<"$(rgit log -1 --format=%B main)"
  ensure "the commit message, 'Closes #5' and blank lines aside, is not .10x/gh-5/commit-msg" [ "$(rgit log -1 --format=%B main | grep -vx -e 'Closes #5' -e '[[:space:]]*')" = "$(grep -vx '[[:space:]]*' "$REPO/.10x/gh-5/commit-msg")" ]
  ensure "origin's heads changed" [ "$(origin_heads)" = "$(cat "$RUN/initial-heads")" ]
  ensure "gh was called" [ ! -s "$GHD/calls.log" ]
  ensure "the ticket branch still exists" not git -C "$REPO" show-ref --verify --quiet "refs/heads/$TICKET_BRANCH"
}

scenario_8() {
  ensure "the branch was not pushed" origin_head "$TICKET_BRANCH"
  ensure "gh pr create is not called exactly once" [ "$(ghlog_count pr create)" = 1 ]
  ensure "the PR body has no 'Closes #5'" [ "$(state_json | jq '[.prs[0].body // "" | select(test("Closes #5([^0-9]|$)"))] | length')" = 1 ]
  ensure "gh pr merge was called" [ "$(ghlog_count pr merge)" = 0 ]
  ensure "the worktree was removed" [ -d "$REPO/.worktrees/gh-5" ]
}

scenario_9() {
  ensure "gh pr edit is not called" [ "$(ghlog_count pr edit)" -ge 1 ]
  ensure "gh pr create was called" [ "$(ghlog_count pr create)" = 0 ]
  ensure "the open PR's body was not replaced" [ "$(state_json | jq -r '.prs[0].body')" != "old body" ]
}

scenario_10() {
  ensure "the worktree is still there" [ ! -e "$REPO/.worktrees/gh-5" ]
  ensure "the local branch still exists" not git -C "$REPO" show-ref --verify --quiet "refs/heads/$TICKET_BRANCH"
  ensure "the remote branch still exists" not git --git-dir "$ORIGIN" show-ref --verify --quiet "refs/heads/$TICKET_BRANCH"
  ensure "the main checkout's base is not origin's" [ "$(rgit rev-parse main)" = "$(origin_head main)" ]
  ensure "the main checkout's base did not move" base_advanced
}

scenario_11() {
  local sha
  sha="$(state_json | jq -r '.prs[0].headAtMerge // ""')"
  ensure "gh pr merge is not called exactly once" [ "$(ghlog_count pr merge)" = 1 ]
  ensure "gh pr merge got no --squash" ghlog_flag_present pr merge --squash
  ensure "gh pr merge was not pinned to the worktree's HEAD" [ -n "$sha" ]
  ensure "gh pr merge got no --match-head-commit equal to the worktree's HEAD" [ "$(ghlog_values pr merge --match-head-commit)" = "$sha" ]
  ensure "gh pr merge got --delete-branch" not ghlog_flag_present pr merge --delete-branch
  ensure "gh pr merge got -d" not ghlog_flag_present pr merge -d
  ensure "gh pr merge got --admin" not ghlog_flag_present pr merge --admin
  ensure "10x-land wait was run" [ "$(tool_count '^10x-land wait ')" = 0 ]
  ensure "the worktree was not removed" worktree_gone
}

scenario_12() {
  local h
  while IFS= read -r h; do
    ensure "the PR body lost the template heading '$h'" grep -Fxq -- "$h" <<<"$(state_json | jq -r '.prs[0].body // ""')"
  done < <(grep -E '^#+ ' "$REPO/.github/pull_request_template.md")
}

scenario_13() {
  local dir n=0
  while IFS= read -r dir; do
    n=$((n + 1))
    use_run "$dir"
    ensure "run $n: claude made no tool call" ran_something
    ensure "run $n: origin's heads changed" [ "$(origin_heads)" = "$(cat "$RUN/initial-heads")" ]
    ensure "run $n: the ticket branch was rebased" [ "$(rgit rev-parse "$TICKET_BRANCH")" = "$(cat "$RUN/branch-sha")" ]
    if [ "$(cat "$RUN/fake")" = 1 ]; then ensure "run $n: gh auth status was never called" [ "$(ghlog_count auth status)" -ge 1 ]; fi
  done <"$FLOW_ROOT/runs"
  [ "$n" = 2 ] || WHY="${WHY:+$WHY; }the flow made $n runs, not 2"
}

scenario_14() {
  ensure "close did not take stock of the ticket (Step 0)" [ "$(tool_count '^10x-(worktree path|land check) ')" -ge 1 ]
  ensure "origin's heads changed" [ "$(origin_heads)" = "$(cat "$RUN/initial-heads")" ]
  ensure "gh was called" [ ! -s "$GHD/calls.log" ]
  ensure "the base gained a commit" [ "$(rgit rev-parse main)" = "$(cat "$RUN/initial-main")" ]
  ensure "the ticket branch was changed" [ "$(rgit rev-parse "$TICKET_BRANCH")" = "$(cat "$RUN/branch-sha")" ]
  ensure "the worktree was removed" [ -d "$REPO/.worktrees/gh-5" ]
}

scenario_C1() {
  ensure "the checks were never read" [ "$(state_json | jq '.rollupCalls // 0')" -ge 1 ]
  ensure "gh pr merge was called" [ "$(ghlog_count pr merge)" = 0 ]
  ensure "the worktree was removed" [ -d "$REPO/.worktrees/gh-5" ]
  ensure "origin's base moved" [ "$(origin_head main)" = "$(cat "$RUN/initial-main")" ]
}

scenario_C2() {
  ensure "close did not rebase exactly twice" [ "$(tool_count '^10x-land rebase ')" = 2 ]
  ensure "gh pr merge is not called exactly once" [ "$(ghlog_count pr merge)" = 1 ]
  ensure "the PR is not merged" pr_merged
}

scenario_C3() {
  local wait_seq merge_after
  wait_seq="$(tool_calls | jq -s '[.[] | select(.name == "Bash" and .denied == false and ((.command // "") | test("^10x-land wait ")) and .run_in_background == true) | .seq] | min // -1')"
  merge_after="$(tool_calls | jq -s --argjson w "$wait_seq" '[.[] | select(.name == "Bash" and .denied == false and ((.command // "") | test("^10x-land merge ")) and .seq > $w)] | length')"
  ensure "10x-land wait did not run with run_in_background" [ "$wait_seq" -ge 0 ]
  ensure "no 10x-land merge followed the wait" [ "$merge_after" -ge 1 ]
  ensure "gh pr merge is not called exactly once" [ "$(ghlog_count pr merge)" = 1 ]
  ensure "the PR is not merged" pr_merged
}

# ---------------------------------------------------------------- scenarios: batch

# batch_files <id> — the paths of the ticket's plan.md ## Files: the first code span of each top-level bullet, a leading ./ dropped.
# shellcheck disable=SC2016  # backticks are markdown
batch_files() {
  md_section "$REPO/.10x/$1/plan.md" Files | grep -E '^[-*+][[:space:]]' |
    sed -n 's/^[^`]*`\([^`]*\)`.*/\1/p' | sed 's|^\./||'
}
# path_overlap <a> <b> — equal, or one is a directory (ends in /) holding the other.
path_overlap() {
  [ "$1" = "$2" ] && return 0
  case "$1" in */) case "$2" in "$1"*) return 0 ;; esac ;; esac
  case "$2" in */) case "$1" in "$2"*) return 0 ;; esac ;; esac
  return 1
}
# files_overlap <id> <id> — the two plans' ## Files share a path.
files_overlap() {
  local a b
  while IFS= read -r a; do
    while IFS= read -r b; do path_overlap "$a" "$b" && return 0; done < <(batch_files "$2")
  done < <(batch_files "$1")
  return 1
}

scenario_B1() {
  local id
  ensure "the conductor started no 10x-batch run" [ "$(tool_count '^10x-batch run ')" -ge 1 ]
  ensure "the conductor called Edit or Write outside .10x/_batch/" \
    [ "$(tool_calls | jq -s '[.[] | select((.name == "Edit" or .name == "Write" or .name == "MultiEdit" or .name == "NotebookEdit") and ((.file_path // "") | contains("/.10x/_batch/") | not))] | length')" = 0 ]
  ensure "the conductor called the Skill tool" [ "$(tool_calls | jq -s '[.[] | select(.name == "Skill")] | length')" = 0 ]
  for id in gh-5 gh-6; do
    ensure "$id has no plan run in its runs.tsv" [ "$(batch_runs "$id" | awk -F'\t' '$3 == "plan"' | wc -l | tr -d ' ')" -ge 1 ]
    ensure "$id has no close run in its runs.tsv" [ "$(batch_runs "$id" | awk -F'\t' '$3 == "close"' | wc -l | tr -d ' ')" -ge 1 ]
  done
}

scenario_B2() {
  local id n kind sess sk start end ex pid
  ensure "no reply run was made" [ "$(batch_runs | awk -F'\t' '$3 == "reply"' | wc -l | tr -d ' ')" -ge 1 ]
  # Each reply to a planning session starts after every plan-session run of its round has exited: a run of another
  # ticket that started before the replied ticket's previous run ended.
  local prev
  while IFS=$'\t' read -r id n kind sess sk start end ex pid; do
    [ "$kind" = reply ] && [ "$sk" = plan ] || continue
    prev="$(batch_runs | awk -F'\t' -v i="$id" -v p="$((n - 1))" '$1 == i && $2 == p { print $7 }')"
    case "$prev" in '' | -) ensure "reply $id/$n has no ended previous run" false ;; esac
    ensure "reply $id/$n started while a planning run of its round was open" \
      [ "$(batch_runs | awk -F'\t' -v i="$id" -v e="$prev" -v s="$start" '$1 != i && $5 == "plan" && $6 < e && ($7 == "-" || $7 > s)' | wc -l | tr -d ' ')" = 0 ]
  done < <(batch_runs)
  for id in gh-5 gh-6; do ensure "$id has no turn.md" [ -s "$REPO/.10x/_batch/$id/turn.md" ]; done
}

scenario_B3() {
  local ia na ka sa ska sta ea xa pa ib nb kb sb skb stb eb xb pb
  ensure "fewer than two implement runs" [ "$(batch_runs | awk -F'\t' '$3 == "implement"' | wc -l | tr -d ' ')" -ge 2 ]
  ensure "gh-5's plan binds no file" [ -n "$(batch_files gh-5)" ]
  ensure "gh-6's plan binds no file" [ -n "$(batch_files gh-6)" ]
  # Two implement runs overlap in time only when their plans share no path.
  while IFS=$'\t' read -r ia na ka sa ska sta ea xa pa; do
    [ "$ka" = implement ] || continue
    while IFS=$'\t' read -r ib nb kb sb skb stb eb xb pb; do
      [ "$kb" = implement ] && [ "$ia" \< "$ib" ] || continue
      if [ "$ea" = - ] || [ "$eb" = - ] || { [ "$sta" -lt "$eb" ] && [ "$stb" -lt "$ea" ]; }; then
        ensure "$ia and $ib implemented at the same time but their ## Files share a path" not files_overlap "$ia" "$ib"
      fi
    done < <(batch_runs)
  done < <(batch_runs)
}

scenario_B4() {
  local id n kind sess sk start end ex pid prev_end=0 prev_id="" prev_idx=0 idx i t closes=0
  while IFS=$'\t' read -r id n kind sess sk start end ex pid; do
    [ "$sk" = close ] || continue
    closes=$((closes + 1))
    [ "$end" != - ] || { WHY="${WHY:+$WHY; }a close run of $id never ended"; continue; }
    idx=0; i=0
    for t in $(batch_ids); do i=$((i + 1)); [ "$t" = "$id" ] && idx=$i; done
    [ "$start" -ge "$prev_end" ] || WHY="${WHY:+$WHY; }close of $id started before the close of $prev_id ended"
    [ "$idx" -ge "$prev_idx" ] || WHY="${WHY:+$WHY; }close of $id ran after the close of $prev_id, against board order"
    prev_end="$end"; prev_id="$id"; prev_idx="$idx"
  done < <(batch_runs | sort -t$'\t' -k6,6n)
  [ "$closes" -ge 2 ] || WHY="${WHY:+$WHY; }$closes close runs, not 2"
}

scenario_B5() {
  ensure "the conductor called CronCreate or ScheduleWakeup" \
    [ "$(tool_calls | jq -s '[.[] | select(.name == "CronCreate" or .name == "CronDelete" or .name == "ScheduleWakeup")] | length')" = 0 ]
  ensure "the conductor called the loop skill" \
    [ "$(tool_calls | jq -s '[.[] | select(.name == "Skill" and ((.skill // "") | test("loop")))] | length')" = 0 ]
  ensure "board.md is missing" [ -s "$REPO/.10x/_batch/board.md" ]
  ensure "board.md has no row for each of gh-5 and gh-6" [ "$(grep -cE '^\| *[0-9]+ *\| *gh-[56] ' "$REPO/.10x/_batch/board.md")" = 2 ]
}

# shellcheck disable=SC2016  # awk program
scenario_B6() {
  local board="$REPO/.10x/_batch/board.md" l5="" l6="" i=0 c p5 p6
  ensure "the batch is not settled" batch_settled
  ensure "the worktree of gh-5 is still there" [ ! -e "$REPO/.worktrees/gh-5" ]
  ensure "the worktree of gh-6 is still there" [ ! -e "$REPO/.worktrees/gh-6" ]
  ensure "the board does not show both landed" [ "$(grep -cE '^\| *[0-9]+ *\| *gh-[56] .*landed' "$board")" = 2 ]
  ensure "the base did not gain exactly two commits" [ "$(rgit rev-list --count "$(cat "$RUN/initial-main")..main")" = 2 ]
  ensure "origin's heads changed" [ "$(origin_heads)" = "$(cat "$RUN/initial-heads")" ]
  # Plans drafted in parallel: the first plan runs of the two tickets overlap in time.
  p5="$(batch_runs gh-5 | awk -F'\t' '$3 == "plan"' | head -n 1)"
  p6="$(batch_runs gh-6 | awk -F'\t' '$3 == "plan"' | head -n 1)"
  ensure "the first plan runs of gh-5 and gh-6 did not overlap" \
    awk -F'\t' 'NR == FNR { s = $6; e = $7; next } { exit !(s < $7 && $6 < e) }' <(printf '%s\n' "$p5") <(printf '%s\n' "$p6")
  # Landed in board order: the commit closing #5 comes before the one closing #6.
  while IFS= read -r c; do
    i=$((i + 1))
    [ "$(rgit log -1 --format=%B "$c" | grep -cx 'Closes #5')" = 1 ] && l5="$i"
    [ "$(rgit log -1 --format=%B "$c" | grep -cx 'Closes #6')" = 1 ] && l6="$i"
  done < <(rgit rev-list --reverse "$(cat "$RUN/initial-main")..main")
  ensure "the commit closing #5 does not come before the one closing #6" [ "${l5:-9}" -lt "${l6:-0}" ]
}

# A sandboxed worker's Bash cannot write the records, its Write to .approved is denied, and the plan-session hook
# denies a Write under S.
# reply_logged <string> — some reply run's stream-json log of gh-5 contains it.
reply_logged() {
  local f
  for f in "$REPO"/.10x/_batch/gh-5/*-reply.jsonl; do
    if [ -e "$f" ] && grep -qF -- "$1" "$f"; then return 0; fi
  done
  return 1
}
# shellcheck disable=SC2016  # awk program
scenario_B7() {
  local s n=0 p dir="$REPO/.10x/_batch/gh-5"
  s="$(batch_S)"
  ensure "the reply run did not happen" [ "$(batch_runs gh-5 | awk -F'\t' '$3 == "reply"' | wc -l | tr -d ' ')" -ge 1 ]
  while IFS= read -r p; do
    n=$((n + 1))
    if [ "$n" = 5 ]; then
      # runs.tsv: the conductor appends the reply run's own row; every byte from before the run stays, and no probe.
      ensure "${p#"$s"/} changed or is gone" cmp -s "$RUN/forge-before.$n" <(head -c "$(wc -c <"$RUN/forge-before.$n")" "$p")
      ensure "${p#"$s"/} holds the worker's write" not grep -q probe "$p"
    elif [ "$n" -le 5 ]; then
      ensure "${p#"$s"/} changed or is gone" cmp -s "$RUN/forge-before.$n" "$p"
    else
      ensure "${p#"$s"/} was created" [ ! -e "$p" ]
    fi
    # The worker tried every one: its log names the path (the absent files are not vacuous passes).
    ensure "the worker never tried ${p#"$s"/}" reply_logged "$p"
  done < <(forge_paths)
  ensure "no denial of the Write to gh-5.approved in the reply run's denials.tsv" \
    awk -F'\t' -v p="$s/gh-5.approved" '$1 == "Write" && index($2, p) { f = 1 } END { exit !f }' "$dir"/*-denials.tsv
  ensure "the plan-session hook did not deny a Write under S" \
    grep -q '"permissionDecision":"deny"' < <(
      node -e 'process.stdout.write(JSON.stringify({ hook_event_name: "PreToolUse", session_id: "s1", cwd: process.argv[1], tool_name: "Write", tool_input: { file_path: process.argv[2], content: "x" } }))' \
        "$REPO" "$s/gh-5.approved" | (cd "$REPO" && TENX_BATCH_PLAN_DIR="$REPO/.10x/gh-5" node "$PLUGIN/hooks/plan-boundary.js"))
}

# A sandboxed auto-mode worker's Write to the git config, a git hook and $ZDOTDIR/.zshrc is denied, and each file is
# byte-identical afterwards, or still absent.
# shellcheck disable=SC2016  # awk program
scenario_B8() {
  local n=0 p dir="$REPO/.10x/_batch/gh-5"
  ensure "the reply run did not happen" [ "$(batch_runs gh-5 | awk -F'\t' '$3 == "reply"' | wc -l | tr -d ' ')" -ge 1 ]
  while IFS= read -r p; do
    n=$((n + 1))
    if [ -e "$RUN/write-before.$n" ]; then
      ensure "$p changed or is gone" cmp -s "$RUN/write-before.$n" "$p"
    else
      ensure "$p was created" [ ! -e "$p" ]
    fi
    # The worker tried every one: its log names the path, and the run's denials hold a Write to it.
    ensure "the worker never tried $p" reply_logged "$p"
    ensure "no denial of the Write to $p in the reply run's denials.tsv" \
      awk -F'\t' -v p="$p" '$1 == "Write" && index($2, p) { f = 1 } END { exit !f }' "$dir"/*-denials.tsv
  done < <(write_paths)
}

# A sandboxed auto-mode worker's Bash appends to <git common dir>/info/attributes, <main checkout>/.envrc,
# $ZDOTDIR/.zshrc, a second worktree's .git file (which must exist before the run) and <git common dir>/commondir each
# exit non-zero, and each file is byte-identical afterwards, or still absent. A Bash denial in the run's denials.tsv
# fails it: an auto-mode classifier refusal is not the sandbox's.
# bash_failed <path> — some Bash call of a reply run of gh-5 that names <path> ended in an error result.
bash_failed() {
  local f
  for f in "$REPO"/.10x/_batch/gh-5/*-reply.jsonl; do
    [ -e "$f" ] || continue
    jq -se --arg p "$1" '
      [.[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use" and .name == "Bash" and ((.input.command // "") | contains($p))) | .id] as $ids
      | [.[] | select(.type == "user") | .message.content[]? | select(.type == "tool_result" and .is_error == true and (.tool_use_id as $i | $ids | index($i)))] | length > 0' "$f" >/dev/null && return 0
  done
  return 1
}
# shellcheck disable=SC2016  # awk program
scenario_B9() {
  local n=0 p dir="$REPO/.10x/_batch/gh-5"
  ensure "the reply run did not happen" [ "$(batch_runs gh-5 | awk -F'\t' '$3 == "reply"' | wc -l | tr -d ' ')" -ge 1 ]
  ensure "the second worktree's .git file did not exist before the run" [ -e "$RUN/bash-before.4" ]
  while IFS= read -r p; do
    n=$((n + 1))
    if [ -e "$RUN/bash-before.$n" ]; then
      ensure "$p changed or is gone" cmp -s "$RUN/bash-before.$n" "$p"
    else
      ensure "$p was created" [ ! -e "$p" ]
    fi
    ensure "the worker never tried $p" reply_logged "$p"
    ensure "the Bash append to $p did not exit non-zero" bash_failed "$p"
    ensure "a Bash denial for $p in the reply run's denials.tsv: the classifier refused it, not the sandbox" \
      not awk -F'\t' -v p="$p" '$1 == "Bash" && index($2, p) { f = 1 } END { exit !f }' "$dir"/*-denials.tsv
  done < <(bash_paths)
}

# ---------------------------------------------------------------- scenarios: roadmap

# tool_calls_since <n> — the tool calls of the run's turns from the (n+1)th on.
tool_calls_since() { tool_calls | jq -c --argjson n "$1" 'select(.turn >= $n)'; }
# roadmap_writes — Write or Edit calls on .10x/roadmap.md: only 10x-roadmap may write it.
roadmap_writes() {
  tool_calls | jq -s '[.[] | select((.name == "Edit" or .name == "Write" or .name == "MultiEdit") and ((.file_path // "") | endswith("/.10x/roadmap.md")))] | length'
}
# roadmap_merged — the second run's draft was applied: no draft, and roadmap.md is no longer the first run's.
roadmap_merged() { ! has_roadmap_draft && has_roadmap && ! cmp -s "$RUN/roadmap-created.md" "$REPO/.10x/roadmap.md"; }
# roadmap_linked <version> — every item of the version ends in a ticket id.
roadmap_linked() { roadmap_rows | jq -se --arg v "$1" '[.[] | select(.version == $v)] | length == 1 and (.[0].items | length > 0 and all(.id != null))' >/dev/null; }
# count_file_tickets — the number of .10x/<id>/ticket.md files.
count_file_tickets() {
  local f n=0
  for f in "$REPO"/.10x/*/ticket.md; do if [ -e "$f" ]; then n=$((n + 1)); fi; done
  echo "$n"
}

scenario_R1() {
  local f="$REPO/.10x/roadmap.md" s re='^\|[[:space:]]*Version[[:space:]]*\|[[:space:]]*Contents[[:space:]]*\|[[:space:]]*Why this order[[:space:]]*\|[[:space:]]*State[[:space:]]*\|[[:space:]]*$'
  ensure "no draft was written before the approval" [ "$(cat "$RUN/roadmap-at-draft")" != "no draft" ]
  ensure "roadmap.md existed before the approval" [ "$(cat "$RUN/roadmap-at-draft")" != present ]
  ensure "roadmap.md is missing" [ -f "$f" ]
  ensure "the draft was not deleted" not has_roadmap_draft
  ensure "roadmap.md has no '| Version | Contents | Why this order | State |' row" grep -Eq "$re" "$f"
  for s in "Not yet assigned" "Later" "Decided against"; do
    ensure "roadmap.md does not have '## $s' exactly once" [ "$(grep -cx "## $s" "$f")" = 1 ]
  done
  ensure "roadmap.md has no version row" [ "$(roadmap_rows | jq -s 'length')" -ge 1 ]
  ensure "a version row has an empty Why this order" [ "$(roadmap_rows | jq -s '[.[] | select(.why == "")] | length')" = 0 ]
  ensure "git status is not empty" [ -z "$(rgit status --porcelain)" ]
  ensure "git tracks a file under .10x/" [ -z "$(rgit ls-files .10x)" ]
  ensure "10x-roadmap apply was not run" [ "$(tool_count '^10x-roadmap apply$')" -ge 1 ]
  ensure "roadmap.md was written with Write or Edit" [ "$(roadmap_writes)" = 0 ]
}

scenario_R2() {
  local f="$REPO/.10x/roadmap.md" snap="$RUN/roadmap-created.md" l
  ensure "no roadmap.md after the first run" [ -s "$snap" ]
  ensure "no draft was written before the approval" [ "$(cat "$RUN/roadmap-at-draft-2")" != "no draft" ]
  ensure "roadmap.md changed before the approval" [ "$(cat "$RUN/roadmap-at-draft-2")" != changed ]
  ensure "the second run merged nothing into roadmap.md" not cmp -s "$snap" "$f"
  ensure "the draft was not deleted" not has_roadmap_draft
  while IFS= read -r l; do
    ensure "roadmap.md lost the line: $l" grep -Fxq -- "$l" "$f"
  done < <(grep -v '^[[:space:]]*$' "$snap")
  ensure "roadmap.md was written with Write or Edit" [ "$(roadmap_writes)" = 0 ]
}

scenario_R3() {
  local since
  since="$(cat "$RUN/turns-before-show")"
  ensure "no roadmap.md to show" [ -s "$RUN/roadmap-before-show.md" ]
  ensure "roadmap.md changed" cmp -s "$RUN/roadmap-before-show.md" "$REPO/.10x/roadmap.md"
  ensure "a draft was left" not has_roadmap_draft
  ensure "/10x:roadmap with no arguments called Edit or Write" \
    [ "$(tool_calls_since "$since" | jq -s '[.[] | select(.name == "Edit" or .name == "Write" or .name == "MultiEdit" or .name == "NotebookEdit")] | length')" = 0 ]
  ensure "10x-roadmap show did not run" \
    [ "$(tool_calls_since "$since" | jq -s '[.[] | select(.name == "Bash" and .denied == false and ((.command // "") | test("^10x-roadmap show( |$)")))] | length')" -ge 1 ]
}

scenario_R4() {
  local v items ids id since
  v="$(cat "$RUN/roadmap-version")"
  since="$(cat "$RUN/turns-before-tickets")"
  ensure "roadmap.md has no version" [ -n "$v" ]
  items="$(roadmap_rows | jq -s --arg v "$v" '[.[] | select(.version == $v)][0].items // [] | length')"
  ids="$(roadmap_ids "$v")"
  ensure "version '$v' has no items" [ "$items" -ge 1 ]
  ensure "not every item of '$v' ends in a ticket id" [ "$(printf '%s\n' "$ids" | grep -c .)" = "$items" ]
  ensure "two items of '$v' share an id" [ "$(printf '%s\n' "$ids" | grep . | sort -u | wc -l | tr -d ' ')" = "$items" ]
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    ensure "$id has no .10x/$id/ticket.md" [ -s "$REPO/.10x/$id/ticket.md" ]
  done <<<"$ids"
  ensure "a ticket file existed before the approval" [ "$(cat "$RUN/tickets-at-draft")" = 0 ]
  ensure "10x-land ticket did not run for exactly one slug per item" \
    [ "$(tool_calls_since "$since" | jq -r 'select(.name == "Bash" and .denied == false) | .command // "" | select(test("^10x-land ticket "))' | sort -u | wc -l | tr -d ' ')" = "$items" ]
  ensure "10x-roadmap link was not run" [ "$(tool_count '^10x-roadmap link ')" -ge 1 ]
  ensure "roadmap.md was written with Write or Edit" [ "$(roadmap_writes)" = 0 ]
  ensure "gh was called" [ ! -s "$GHD/calls.log" ]
}

scenario_R5() {
  local want got
  want="$(state_json | jq -r '.issues[].number | "gh-\(.)"' | sort)"
  got="$(roadmap_ids v1 | sort)"
  ensure "gh issue create ran before the approval" [ "$(cat "$RUN/creates-at-draft")" = 0 ]
  ensure "gh issue create is not called exactly twice" [ "$(ghlog_count issue create)" = 2 ]
  ensure "a gh issue create command was run directly" [ "$(tool_count '^gh issue create')" = 0 ]
  ensure "the issues were not created through 10x-land issue" [ "$(tool_count '^10x-land issue ')" -ge 2 ]
  ensure "v1's items do not all end in an id" roadmap_linked v1
  ensure "v1's ids are not the created issues" [ "$(printf '%s\n' "$want" | grep -c .)" = 2 ]
  ensure "v1's ids are not the created issues" [ "$got" = "$want" ]
  ensure "roadmap.md was written with Write or Edit" [ "$(roadmap_writes)" = 0 ]
}
