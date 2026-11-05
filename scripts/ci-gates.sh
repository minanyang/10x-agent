#!/bin/bash
# Runs the gates .claude/10x.json declares, for CI: every gate even after one fails, each in its own
# ::group::, a result table to $GITHUB_STEP_SUMMARY (stdout when unset). Exits 1 if any gate failed.
#
#   scripts/ci-gates.sh [base-sha]
#
# With a base ref, the gates added and removed against .claude/10x.json at its merge-base are listed too.
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "$0")")/lib.sh"

base="${1:-}"
[ $# -le 1 ] || die "usage: ci-gates.sh [base-sha]"
cmds=()
while IFS= read -r c; do [ -n "$c" ] && cmds+=("$c"); done < <(cfg gates)
[ ${#cmds[@]} -gt 0 ] || die "no gates: set \"gates\" in .claude/10x.json"

summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
cd "$ROOT" || exit 2
rows=""; failed=0
for c in "${cmds[@]}"; do
  echo "::group::$c"
  t0=$(date +%s)
  bash -c "$c"
  code=$?
  secs=$(( $(date +%s) - t0 ))
  echo "::endgroup::"
  if [ $code -eq 0 ]; then res=pass; else res=FAIL; failed=1; fi
  rows="$rows| \`${c//|/\\|}\` | $res | $secs |"$'\n'
done

{
  printf '| gate | result | secs |\n|---|---|---|\n%s' "$rows"
  if [ -n "$base" ]; then
    base_cfg="$(mktemp)"
    fork="$(git merge-base "$base" HEAD 2>/dev/null)"
    { [ -n "$fork" ] && git show "$fork:.claude/10x.json" >"$base_cfg" 2>/dev/null; } || : >"$base_cfg"
    changes="$(gate_changes "$base_cfg" "$CONFIG")"
    rm -f "$base_cfg"
    [ -z "$changes" ] || printf '\ngates differ from the merge-base with %s:\n%s\n' "$base" "$changes"
  fi
} >>"$summary"
exit "$failed"
