#!/bin/bash
# End-to-end scenarios for /10x:open, /10x:work, /10x:close, /10x:batch and /10x:roadmap: real `claude -p` runs against throwaway repos,
# a github.com origin backed by a local bare repo, and a fake gh. See README.md.
#
#   bash tests/e2e/run.sh [<scenario>...]
#
# Scenario ids (case-sensitive): 1-14, O1-O3, F1-F2, W1-W9, C1-C3, B1-B6, R1-R5. Prints one line per scenario, in that order,
#   <pass|FAIL>  <id>  <flow seconds>s  <reason>        (the reason only on FAIL)
# then `total <seconds>s`. Exit 0 when all pass, 1 when any fails, 2 for an unknown id or a missing prerequisite.
# TENX_E2E_PLUGIN names the plugin under test (default: this repo); TENX_E2E_CLAUDE the claude binary.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
# shellcheck source=scenarios.sh
source "$HERE/scenarios.sh"

SELECTED=""
if [ $# -eq 0 ]; then
  SELECTED="$ALL_IDS"
else
  for a in "$@"; do
    case " $ALL_IDS " in
      *" $a "*) SELECTED="$SELECTED $a" ;;
      *) echo "run.sh: unknown scenario id '$a' (known: $ALL_IDS)" >&2; exit 2 ;;
    esac
  done
fi
e2e_prereqs || exit 2

RESULTS="$(mktemp -d)"
START="$(date +%s)"

run_flow() {
  local flow="$1" start fn dir cost=0 c
  FLOW_ROOT="$(mktemp -d)"
  FLOW_ROOT="$(cd "$FLOW_ROOT" && pwd -P)"
  : >"$FLOW_ROOT/runs"
  start="$(date +%s)"
  fn="flow_${flow//-/_}"
  echo "== $flow" >&2
  ( FLOW="$flow"; "$fn" )
  echo $(($(date +%s) - start)) >"$RESULTS/_time.$flow"
  while IFS= read -r dir; do
    use_run "$dir"
    c="$(run_stats | jq -r '.cost')"
    cost="$(awk -v a="$cost" -v b="$c" 'BEGIN { print a + b }')"
  done <"$FLOW_ROOT/runs"
  echo "$cost" >"$RESULTS/_cost.$flow"
  if [ -f "$FLOW_ROOT/notes" ]; then sort -u "$FLOW_ROOT/notes" | sed 's/^/   /' >&2; fi
  if grep -q '^FAIL' "$RESULTS"/*."$flow" 2>/dev/null; then
    echo "   $flow failed; its runs are kept in $FLOW_ROOT" >&2
  else
    rm -r "$FLOW_ROOT"
  fi
}

for flow in $FLOWS; do
  [ -n "$(flow_ids "$flow")" ] || continue
  run_flow "$flow"
done

fail=0
for id in $ALL_IDS; do
  is_selected "$id" || continue
  status=pass; reason=""; secs=0; nb=0
  for b in $(bindings "$id"); do nb=$((nb + 1)); done
  for b in $(bindings "$id"); do
    f="${b%%:*}"
    secs=$((secs + $(cat "$RESULTS/_time.$f" 2>/dev/null || echo 0)))
    if [ -f "$RESULTS/$id.$f" ]; then
      IFS=$'\t' read -r st why <"$RESULTS/$id.$f"
    else
      st=FAIL; why="flow $f recorded no result"
    fi
    if [ "$st" != pass ]; then
      status=FAIL
      if [ "$nb" -gt 1 ]; then why="$f: $why"; fi
      reason="${reason:+$reason; }$why"
    fi
  done
  if [ "$status" = pass ]; then
    printf 'pass  %s  %ss\n' "$id" "$secs"
  else
    fail=1
    printf 'FAIL  %s  %ss  %s\n' "$id" "$secs" "$reason"
  fi
done
echo "total $(($(date +%s) - START))s"
cost="$(cat "$RESULTS"/_cost.* 2>/dev/null | awk '{ s += $1 } END { printf "%.2f", s }')"
echo "cost \$${cost:-0.00} (sum of the stream-json result lines)" >&2
rm -r "$RESULTS"
exit "$fail"
