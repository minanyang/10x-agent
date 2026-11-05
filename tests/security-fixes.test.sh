#!/bin/bash
# Regression cases for gh-1's review round 1: `10x-land push` checks the branch's commit messages for security entries
# before anything is pushed (F2/S2), and the grant hook never allows `10x-security set` or `remove` on its own (S1).
# shellcheck disable=SC2015  # `cond && ok || bad` is safe: ok always returns 0
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT_DIR/bin:$PATH"
fail=0
ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }

tmp=$(mktemp -d)
trap 'rm -r "$tmp"' EXIT
git -c init.defaultBranch=main init -q --bare "$tmp/origin.git"
git -c init.defaultBranch=main init -q "$tmp/repo"
cd "$tmp/repo" || exit 2
git config user.email t@t; git config user.name t
echo base >README.md && git add -A && git commit -qm init
git remote add origin "$tmp/origin.git" && git push -q -u origin main
10x-worktree add P1 --no-setup >/dev/null || { echo "worktree add failed"; exit 2; }
wt="$(10x-worktree path P1)"
branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD)"
fp="sha256:$(printf '%064d' 1)"
{
  printf '# Security entries\n\n## %s\n' "$fp"
  printf '%s\n' '- title: Shell injection in deploy hook' '- verdict: confirmed' '- severity: high' '- rule: command-injection' \
    '- location: bin/deploy.sh:12' '- trace: reaches a shell' '- status: later' '- reason:' '- found in: P1' '- seen in:' \
    '- audit fingerprint:' '- not seen in:'
} >.10x/security.md
on_origin() { git ls-remote --exit-code --heads "$tmp/origin.git" "refs/heads/$branch" >/dev/null 2>&1; }

# push refuses a commit message naming a security entry, and pushes nothing
echo a >"$wt/a.txt"; git -C "$wt" add a.txt; git -C "$wt" commit -qm 'fix: harden bin/deploy.sh:12'
sha="$(git -C "$wt" rev-parse --short=7 HEAD)"
10x-land push P1 >"$tmp/out" 2>&1; rc=$?
[ "$rc" -eq 2 ] && grep -qF "commit $sha contains security entry $fp" "$tmp/out" && ! grep -qiE 'deploy|injection' "$tmp/out" && ! on_origin &&
  ok "push refuses a commit message naming a security entry" || { bad "push refuses a commit message naming a security entry (exit $rc)"; cat "$tmp/out"; }

# with the message reworded, push goes through
git -C "$wt" commit -q --amend -m 'fix: harden the hook'
10x-land push P1 >"$tmp/out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && on_origin && ok "push goes through once no commit names an entry" || { bad "push goes through once no commit names an entry (exit $rc)"; cat "$tmp/out"; }

# the grant hook never allows 10x-security set or remove, even on the session's own ticket; add still is
data="$tmp/plugin-data"; mkdir -p "$data/sessions"
printf '{"skills":{"work":{"confirmed":{"prompt_id":"p1","grants":["10x-security *"],"id":"gh-5"}}}}\n' >"$data/sessions/s1.json"
chmod 600 "$data/sessions/s1.json"
hook() { # <command> — the hook's stdout for a PreToolUse Bash call in session s1
  node -e 'process.stdout.write(JSON.stringify({ hook_event_name: "PreToolUse", tool_name: "Bash", session_id: "s1", tool_input: { command: process.argv[1] } }))' "$1" |
    CLAUDE_PLUGIN_DATA="$data" node "$ROOT_DIR/hooks/grant.js"
}
[ -n "$(hook "10x-security add gh-5 /r/.10x/gh-5/out-of-diff.json")" ] &&
  [ -z "$(hook "10x-security set gh-5 $fp later")" ] && [ -z "$(hook "10x-security remove gh-5 $fp")" ] &&
  ok "grant hook always asks for 10x-security set and remove" || bad "grant hook always asks for 10x-security set and remove"
[ -z "$(hook "10x-security  set gh-5 $fp later")" ] && [ -z "$(hook "$(printf '10x-security \tremove gh-5 %s' "$fp")")" ] &&
  ok "grant hook always asks for set and remove with extra whitespace" || bad "grant hook always asks for set and remove with extra whitespace"
# work grants only 10x-security add: set and remove are never granted by the skill either
front="$(sed -n '/^---$/,/^---$/p' "$ROOT_DIR/skills/work/SKILL.md")"
printf '%s\n' "$front" | grep -qxF '  - Bash(10x-security add *)' && ! printf '%s\n' "$front" | grep -qE '^  - Bash\(10x-security (\*|set|remove)' &&
  ok "work grants only 10x-security add" || bad "work grants only 10x-security add"

exit "$fail"
