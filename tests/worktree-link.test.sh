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

# git resolves a link file's raw bytes, node the decoded string: a byte that is not UTF-8 (\xff, decoded to U+FFFD)
# could name another directory for each, so the guard refuses it.
printf '%s/\xff/../.git\n' "$tmp/repo" >"$admin/commondir"
10x-land check A >"$tmp/out" 2>&1; rc=$?
printf 'gitdir: %s/.git/worktrees/\xff/../A\n' "$tmp/repo" >"$wt/.git"
10x-worktree path A >"$tmp/out2" 2>&1; rc2=$?
restore
[ "$rc" -eq 2 ] && grep -qF "$admin/commondir is not valid UTF-8" "$tmp/out" && [ "$rc2" -eq 2 ] && grep -qF "$wt/.git is not valid UTF-8" "$tmp/out2" &&
  ok "a commondir or .git file that is not valid UTF-8 is refused" ||
  { bad "a commondir or .git file that is not valid UTF-8 is refused (exit $rc, $rc2)"; cat "$tmp/out" "$tmp/out2"; }

rm "$wt/l"
10x-land check A >"$tmp/out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -qxF "clean: $wt" "$tmp/out" &&
  ok "the worktree with its own links restored is clean" || { bad "the worktree with its own links restored is clean (exit $rc)"; cat "$tmp/out"; }

# The race: a git shim redirects <admin>/commondir to the planted $tmp/x/.git right before it execs the real git, after
# the link-file check has passed. 10x must then pin git so the planted core.fsmonitor never runs.
real_git="$(command -v git)"
mkdir "$tmp/shim"
cat >"$tmp/shim/git" <<'STUB'
#!/bin/bash
prev=""
for a in "$@"; do
  [ "$prev" = -C ] && [ "$a" = "$SHIM_WT" ] && printf '%s\n' "$SHIM_EVIL" >"$SHIM_ADMIN/commondir"
  prev="$a"
done
exec "$SHIM_REAL_GIT" "$@"
STUB
chmod +x "$tmp/shim/git"
# raced <worktree> <admin> <10x command...> — runs it with the shim first on PATH, aimed at <worktree>
raced() {
  local w=$1 a=$2; shift 2
  SHIM_WT="$w" SHIM_ADMIN="$a" SHIM_EVIL="$tmp/x/.git" SHIM_REAL_GIT="$real_git" PATH="$tmp/shim:$PATH" "$@"
}

raced "$wt" "$admin" 10x-land check A >"$tmp/out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -qxF "clean: $wt" "$tmp/out" && [ ! -e "$marker" ] &&
  ok "10x-land check runs no planted fsmonitor when commondir is redirected after the check" ||
  { bad "10x-land check runs no planted fsmonitor when commondir is redirected after the check (exit $rc)"; cat "$tmp/out"; }
restore

raced "$wt" "$admin" 10x-worktree list >"$tmp/out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -q '^A ' "$tmp/out" && [ ! -e "$marker" ] &&
  ok "10x-worktree list runs no planted fsmonitor when commondir is redirected after the check" ||
  { bad "10x-worktree list runs no planted fsmonitor when commondir is redirected after the check (exit $rc)"; cat "$tmp/out"; }
restore

10x-worktree add B --no-setup >/dev/null || { echo "worktree add B failed"; exit 2; }
wtb="$tmp/repo/.worktrees/B"; adminb="$tmp/repo/.git/worktrees/B"
# Pinned git still reads refs through commondir, so the planted git dir holds B's branch, as it holds A's.
refb="$(git -C "$wtb" symbolic-ref HEAD)"; mkdir -p "$(dirname "$tmp/x/.git/$refb")"
git -C "$wtb" rev-parse HEAD >"$tmp/x/.git/$refb"
raced "$wtb" "$adminb" 10x-worktree rm B >"$tmp/out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -qF "removed: $wtb" "$tmp/out" && [ ! -e "$wtb" ] && [ ! -e "$marker" ] &&
  ok "10x-worktree rm removes the worktree and runs no planted fsmonitor when commondir is redirected after the check" ||
  { bad "10x-worktree rm removes the worktree and runs no planted fsmonitor when commondir is redirected after the check (exit $rc)"; cat "$tmp/out"; }
restore

# AC2: a script sourcing lib.sh cannot run git on a directory it has not checked.
printf '%s\n' "$tmp/x/.git" >"$admin/commondir"
( cd "$tmp/repo" && . "$ROOT_DIR/scripts/lib.sh" && git -C "$wt" status --porcelain ) >"$tmp/out" 2>&1; rc=$?
[ "$rc" -eq 2 ] && grep -qF "refusing to run git in $wt: " "$tmp/out" && [ ! -e "$marker" ] &&
  ok "git -C on an unchecked worktree is checked first and refused when redirected" ||
  { bad "git -C on an unchecked worktree is checked first and refused when redirected (exit $rc)"; cat "$tmp/out"; }
restore

exit "$fail"
