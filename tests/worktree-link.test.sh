#!/bin/bash
# The worktree guard (scripts/worktree.js) resolves a ticket worktree's link files the way git does: a symlink is
# followed before the `..` after it, so `<wt>/l/../../../.git` names where git goes, not what the text folds to.
# shellcheck disable=SC2015  # `cond && ok || bad` is safe: ok always returns 0
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT_DIR/bin:$PATH"
fail=0
ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }

tmp=$(mktemp -d)
trap 'rm -r "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd -P)"
git -c init.defaultBranch=main init -q "$tmp/repo"
cd "$tmp/repo" || exit 2
git config user.email t@t; git config user.name t
echo base >README.md && git add -A && git commit -qm init
10x-worktree add A --no-setup >/dev/null || { echo "worktree add failed"; exit 2; }
wt="$tmp/repo/.worktrees/A"; admin="$tmp/repo/.git/worktrees/A"
# <wt>/l/../../.. folds to $tmp/repo as text; git, following l, lands in $tmp/x.
mkdir -p "$tmp/x/p/q/r"; ln -s "$tmp/x/p/q/r" "$wt/l"
via="$wt/l/../../.."
# The planted git dir git reaches through the link: a config whose core.fsmonitor touches a marker, the repository's
# objects, refs and HEAD, and a copy of the admin dir whose commondir points at it.
marker="$tmp/PWNED"
mkdir -p "$tmp/x/.git/worktrees"
cp -R .git/objects .git/refs .git/HEAD "$tmp/x/.git/"
printf '[core]\n\trepositoryformatversion = 0\n\tfsmonitor = "touch %s"\n' "$marker" >"$tmp/x/.git/config"
cp -R "$admin" "$tmp/x/.git/worktrees/A"; printf '%s\n' "$tmp/x/.git" >"$tmp/x/.git/worktrees/A/commondir"
cp "$admin/commondir" "$tmp/commondir.orig"; cp "$admin/gitdir" "$tmp/gitdir.orig"; cp "$wt/.git" "$tmp/dotgit.orig"
restore() { cp "$tmp/commondir.orig" "$admin/commondir"; cp "$tmp/gitdir.orig" "$admin/gitdir"; cp "$tmp/dotgit.orig" "$wt/.git"; rm -f "$marker"; }
check() { # <case> <file named> — 10x-land check refuses, names the file, and the planted fsmonitor never runs
  10x-land check A >"$tmp/out" 2>&1; rc=$?
  [ "$rc" -eq 2 ] && grep -qF "refusing to run git in $wt: " "$tmp/out" && grep -qF "$2" "$tmp/out" && [ ! -e "$marker" ] &&
    ok "$1" || { bad "$1 (exit $rc)"; cat "$tmp/out"; }
  restore
}

printf '%s/.git\n' "$via" >"$admin/commondir"
check "a commondir through a symlink and .. is refused, and runs no planted fsmonitor" "$admin/commondir"

printf 'gitdir: %s/.git/worktrees/A\n' "$via" >"$wt/.git"
check "a .git file through a symlink and .. is refused, and runs no planted fsmonitor" "$wt/.git"

printf '%s/.worktrees/A/.git\n' "$via" >"$admin/gitdir"
check "an admin gitdir through a symlink and .. is refused" "$admin/gitdir"

rm "$wt/l"
10x-land check A >"$tmp/out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -qxF "clean: $wt" "$tmp/out" &&
  ok "the worktree with its own links restored is clean" || { bad "the worktree with its own links restored is clean (exit $rc)"; cat "$tmp/out"; }

exit "$fail"
