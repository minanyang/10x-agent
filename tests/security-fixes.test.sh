#!/bin/bash
# Regression cases for gh-1's review round 1: `10x-land push` checks the branch's commit messages for security entries
# before anything is pushed (F2/S2), and the grant hook never allows `10x-security set` or `remove` on its own (S1).
# Also: no 10x script runs git in a ticket worktree whose .git file or admin directory was redirected, where a planted
# config's core.fsmonitor would run as the user.
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

# A ticket worktree whose .git file or admin directory was redirected: no 10x script runs git in it. Its own repository,
# so P1 above stays untampered. The planted directory carries a config whose core.fsmonitor touches a marker, and the
# repository's objects, refs and HEAD, so git gets far enough to refresh the index.
git -c init.defaultBranch=main init -q "$tmp/fx/repo"
cd "$tmp/fx/repo" || exit 2
git config user.email t@t; git config user.name t
echo base >README.md && git add -A && git commit -qm init
10x-worktree add A --no-setup >/dev/null && 10x-worktree add B --no-setup >/dev/null || { echo "worktree add failed"; exit 2; }
fx="$(pwd -P)"
admin="$fx/.git/worktrees/A"
evil="$tmp/fx/evil"; marker="$tmp/fx/PWNED"
mkdir -p "$evil" && cp -R .git/objects .git/refs .git/HEAD "$evil/"
printf '[core]\n\trepositoryformatversion = 0\n\tfsmonitor = "touch %s"\n' "$marker" >"$evil/config"
cp "$admin/commondir" "$tmp/fx/commondir.orig"; cp "$fx/.worktrees/A/.git" "$tmp/fx/dotgit.orig"
redirect() { printf '%s\n' "$evil" >"$admin/commondir"; }
restore() { cp "$tmp/fx/commondir.orig" "$admin/commondir"; cp "$tmp/fx/dotgit.orig" "$fx/.worktrees/A/.git"; rm -f "$marker"; }
refused() { grep -qF "refusing to run git in $fx/.worktrees/A: " "$tmp/out" && grep -qF "$1" "$tmp/out"; } # <file named>

redirect
10x-land check A >"$tmp/out" 2>&1; rc=$?
[ "$rc" -eq 2 ] && refused "$admin/commondir" && [ ! -e "$marker" ] &&
  ok "10x-land check refuses a worktree whose commondir is redirected, and runs no planted fsmonitor" ||
  { bad "10x-land check refuses a worktree whose commondir is redirected, and runs no planted fsmonitor (exit $rc)"; cat "$tmp/out"; }
restore

printf 'gitdir: %s\n' "$evil" >"$fx/.worktrees/A/.git"
10x-worktree path A >"$tmp/out" 2>&1; rc=$?
[ "$rc" -eq 2 ] && refused "$fx/.worktrees/A/.git" &&
  ok "10x-worktree path refuses a worktree whose .git file leaves the admin dir" ||
  { bad "10x-worktree path refuses a worktree whose .git file leaves the admin dir (exit $rc)"; cat "$tmp/out"; }
restore

redirect; echo dirty >"$fx/.worktrees/A/dirty.txt"
10x-worktree rm A >"$tmp/out" 2>&1; rc=$?
[ "$rc" -eq 2 ] && refused "$admin/commondir" && [ ! -e "$marker" ] && [ -e "$fx/.worktrees/A/.git" ] &&
  ok "10x-worktree rm refuses before git worktree remove runs the planted command" ||
  { bad "10x-worktree rm refuses before git worktree remove runs the planted command (exit $rc)"; cat "$tmp/out"; }
rm -f "$fx/.worktrees/A/dirty.txt"; restore

redirect
10x-worktree list >"$tmp/out" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -qF "skipped: refusing to run git in $fx/.worktrees/A: " "$tmp/out" && grep -qE '^B +feat/B ' "$tmp/out" &&
  ! grep -qE '^A ' "$tmp/out" && [ ! -e "$marker" ] &&
  ok "10x-worktree list skips a redirected worktree, lists the others and exits 1" ||
  { bad "10x-worktree list skips a redirected worktree, lists the others and exits 1 (exit $rc)"; cat "$tmp/out"; }
restore

out="$(10x-worktree path A 2>&1)"; rc=$?
10x-land check A >"$tmp/out" 2>&1; rc2=$?
[ "$rc" -eq 0 ] && [ "$out" = "$fx/.worktrees/A" ] && [ "$rc2" -eq 0 ] && grep -qxF "clean: $fx/.worktrees/A" "$tmp/out" &&
  ok "an untampered worktree still resolves, and 10x-land check reports it clean" ||
  { bad "an untampered worktree still resolves, and 10x-land check reports it clean (exit $rc, $rc2)"; printf '%s\n' "$out"; cat "$tmp/out"; }

exit "$fail"
