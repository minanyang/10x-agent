#!/bin/bash
# Unit cases for bin/10x-roadmap on a throwaway repository whose .10x/ is excluded, as 10x-worktree init
# leaves it.
# shellcheck disable=SC2015,SC2016,SC2329  # `cond && ok || bad` is safe: ok always returns 0; backticks in patterns are literal Markdown; helpers run through need
set -uo pipefail
BIN="$(cd "$(dirname "$0")/.." && pwd)/bin"
fail=0
ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export PATH="$BIN:$PATH"

git -c init.defaultBranch=main init -q "$tmp/repo"
cd "$tmp/repo" || exit 2
git config user.email t@t; git config user.name t
echo base >README.md && git add -A && git commit -qm init
echo '/.10x/' >>.git/info/exclude
root="$(pwd -P)"
R=.10x/roadmap.md
D=.10x/roadmap.draft.md

reset() { rm -rf .10x; mkdir .10x; }
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
vr() { 10x-roadmap "$@" >"$tmp/out" 2>&1; }
exits() { local want=$1; shift; vr "$@"; [ $? -eq "$want" ]; } # <exit> <args...>
has() { grep -qF -- "$1" "$tmp/out"; }
line() { grep -qxF -- "$1" "$tmp/out"; }
out_is() { [ "$(cat "$tmp/out")" = "$1" ] || { echo "        got: $(cat "$tmp/out")"; false; }; }

# The roadmap the cases start from: two versions, an id on one item, a code span that is not an id, an escaped pipe,
# and an entry with a continuation line.
roadmap() {
  cat <<'EOF'
# Roadmap

| Version | Contents | Why this order | State |
|---|---|---|---|
| v1 | Roadmap skill `gh-77`; batch by version | Everything else builds on it | Done 2026-10-01 |
| v2 | use `md-check.js` sections; a \| pipe | Needs v1's parser | Planned |

## Not yet assigned
- Dates per version

## Later
- A committed ROADMAP.md
  once files mode links work

## Decided against
- GitHub milestones — 10x never creates them
EOF
}

# ---------------------------------------------------------------- check

reset; roadmap >"$D"
begin "check: a draft with the table and the three sections passes"
need "exit 0" exits 0 check
need "with no roadmap.md yet, only its ids as new" out_is "new id: v1 gh-77"
need "the draft stays" test -f "$D"
need "no roadmap.md" test ! -e "$R"
printf '| Version | Contents | Why this order | State |\n| :-- | --- | :-: | --: |\n\n## Decided against\n- x: y\n## Later\n## Not yet assigned\n## Other\n' >"$D"
need "zero rows, sections in any order, an extra section" exits 0 check
end

reset
begin "check: a draft missing the header or a section fails naming it"
roadmap | sed '/^| Version |/d' >"$D"
need "no header: exit 1" exits 1 check
need "names the header" has ".10x/roadmap.draft.md:1: no table header \`| Version | Contents | Why this order | State |\`"
roadmap | sed 's/^## Later$/## Someday/' >"$D"
need "no Later: exit 1" exits 1 check
need "names the section" line ".10x/roadmap.draft.md:1: no \`## Later\` section"
roadmap | sed 's/^|---|---|---|---|$/| x | y | z | w |/' >"$D"
need "no separator" eval 'exits 1 check && has ".10x/roadmap.draft.md:4: no separator row under the table header"'
{ roadmap; printf '\n## Later\n- again\n'; } >"$D"
need "a repeated section" eval 'exits 1 check && has ".10x/roadmap.draft.md:18: \`## Later\` appears again (first at line 11)"'
{ printf '## Later\n'; roadmap | sed '/^## Later$/d'; } >"$D"
need "a section before the table" eval 'exits 1 check && has ".10x/roadmap.draft.md:1: \`## Later\` comes before the table"'
roadmap | sed 's/^| v2 |/| v1 |/' >"$D"
need "a duplicate Version" eval 'exits 1 check && line ".10x/roadmap.draft.md:6: duplicate Version '"'v1'"' (first at line 5)"'
roadmap | sed 's/^| v2 |/| 2 |/' >"$D"
need "an all-digits Version" eval 'exits 1 check && has ".10x/roadmap.draft.md:6: Version '"'2'"' must match"'
roadmap | sed 's/^| v2 |/|  |/' >"$D"
need "an empty Version" eval 'exits 1 check && has ".10x/roadmap.draft.md:6: row has an empty Version"'
roadmap | sed 's/; a \\| pipe/; ; x/' >"$D"
need "an empty item" eval 'exits 1 check && has ".10x/roadmap.draft.md:6: version v2 has an empty item 2 in Contents"'
roadmap | sed 's/^- GitHub milestones — 10x never creates them$/- GitHub milestones/' >"$D"
need "a Decided against entry with no reason" eval 'exits 1 check && line ".10x/roadmap.draft.md:16: a \`## Decided against\` entry has no \` — <reason>\`"'
rm "$D"
need "no draft exits 2" exits 2 check
need "names it" line "10x-roadmap: no draft: .10x/roadmap.draft.md"
end

reset
begin "check: a row with an empty Why this order fails naming its version"
roadmap | sed 's/| Needs v1.s parser |/|   |/' >"$D"
need "exit 1" exits 1 check
need "names v2 and its line" line ".10x/roadmap.draft.md:6: version v2 has an empty Why this order"
need "nothing else" test "$(wc -l <"$tmp/out" | tr -d ' ')" = 1
end

reset; roadmap >"$R"
begin "check: lists each existing row and section entry the draft does not keep"
{
  printf '# Roadmap, reordered\n\n| Version | Contents | Why this order | State |\n|---|---|---|---|\n'
  printf '%s\n' '| v2 | use `md-check.js` sections; a \| pipe | Needs v1'"'"'s parser | Next |' \
    '| v1 | Roadmap skill `gh-77`; batch by version | Everything else builds on it | Done 2026-10-01 |' \
    '| v3 | Something new | After v2 | Planned |' '' '## Not yet assigned' '- A new idea' '' '## Later' '- A committed ROADMAP.md' \
    '  once files mode links are fixed' '- GitHub milestones — 10x never creates them' '' '## Decided against' '- x — y'
} >"$D"
need "exit 0" exits 0 check
need "each lost line, in roadmap.md's order" out_is "$(printf '%s\n' \
  'not kept: | v2 | use `md-check.js` sections; a \| pipe | Needs v1'"'"'s parser | Planned |' \
  'not kept: - Dates per version' 'not kept: - A committed ROADMAP.md' 'not kept:   once files mode links work' \
  'not kept: - GitHub milestones — 10x never creates them')"
need "roadmap.md untouched" cmp -s "$R" <(roadmap)
roadmap >"$D"
need "an unchanged draft keeps everything" eval 'exits 0 check && out_is ""'
{ roadmap; printf '%s\n' '- GitHub milestones — 10x never creates them'; } >"$tmp/twice"
cp "$tmp/twice" "$R"; roadmap >"$D"
need "a duplicate counts" eval 'exits 0 check && out_is "not kept: - GitHub milestones — 10x never creates them"'
end

reset; roadmap >"$R"
begin "check: lists each ticket id the draft adds to a row as new id"
mkdir .10x/local-one && echo '# Local one' >.10x/local-one/ticket.md
{ roadmap | sed 's/| v2 | use `md-check.js` sections; a \\| pipe |/| v2 | use `md-check.js` sections `gh-9`; a \\| pipe `local-one` |/'; } >"$D"
need "exit 0" exits 0 check
need "the two added ids, after the not kept line" out_is "$(printf '%s\n' \
  'not kept: | v2 | use `md-check.js` sections; a \| pipe | Needs v1'"'"'s parser | Planned |' \
  'new id: v2 gh-9' 'new id: v2 local-one')"
need "an id roadmap.md already has is not new" eval 'roadmap >"$D" && exits 0 check && out_is ""'
{ roadmap | sed 's/| v2 | use `md-check.js` sections; a \\| pipe |/| v2 | use `md-check.js` sections; a \\| pipe `gh-77` |/'; } >"$D"
need "an existing id added to another row is new there" eval 'exits 0 check && line "new id: v2 gh-77"'
end

# ---------------------------------------------------------------- apply

reset
begin "check: accepts a security item"
FPX="sha256:$(printf 'a%.0s' {1..64})"
roadmap | sed "s/^| v2 | use /| v2 | Fix the deploy hook (security $FPX); use /" >"$D"
need "exit 0" exits 0 check
need "the security item is no new id" out_is "new id: v1 gh-77"
need "apply writes it" exits 0 apply
need "show lists the item whole" eval 'exits 0 show v2 && line "  1. Fix the deploy hook (security '"$FPX"')"'
end

reset; roadmap >"$D"
begin "apply: writes the draft to .10x/roadmap.md and deletes the draft"
need "exit 0" exits 0 apply
need "prints its absolute path and the new id" out_is "$(printf '%s\n' "roadmap: $root/.10x/roadmap.md" "new id: v1 gh-77")"
need "the draft, byte for byte" cmp -s "$R" <(roadmap)
need "the draft is gone" test ! -e "$D"
roadmap | sed 's/| Planned |/| Next |/' >"$D"
need "a second apply" exits 0 apply
need "names what it did not keep" out_is "$(printf '%s\n' "roadmap: $root/.10x/roadmap.md" 'not kept: | v2 | use `md-check.js` sections; a \| pipe | Needs v1'"'"'s parser | Planned |')"
need "applied" grep -qF '| Next |' "$R"
need "no draft left: exit 2" exits 2 apply
end

reset; roadmap >"$R"
begin "apply: a failing draft leaves roadmap.md untouched"
roadmap | sed 's/| Needs v1.s parser |/|  |/' >"$D"
need "exit 1" exits 1 apply
need "names the fault" line ".10x/roadmap.draft.md:6: version v2 has an empty Why this order"
need "no roadmap: line" not has "roadmap: "
need "roadmap.md untouched" cmp -s "$R" <(roadmap)
need "the draft stays" test -f "$D"
end

reset; roadmap >"$D"
begin "apply: .10x/roadmap.md stays out of git status"
need "exit 0" exits 0 apply
need "git status is empty" test -z "$(git status --porcelain)"
need "not tracked" test -z "$(git ls-files .10x)"
need "ignored" test "$(git status --porcelain --ignored .10x)" = "!! .10x/"
end

# ---------------------------------------------------------------- show

reset
begin "show: lists each version with its items and state, and the next version"
need "no roadmap: exit 0" exits 0 show
need "says so" out_is "no roadmap: .10x/roadmap.md"
roadmap >"$R"
need "exit 0" exits 0 show
need "every version, its items and the next one" out_is "$(printf '%s\n' 'v1 — Done 2026-10-01' '  1. Roadmap skill `gh-77`' '  2. batch by version' \
  'v2 — Planned' '  1. use `md-check.js` sections' '  2. a | pipe' 'next: v2' 'audit: no tag — a diff-scope audit needs a previous release')"
need "one version" eval 'exits 0 show v2 && out_is "$(printf "%s\n" "v2 — Planned" "  1. use \`md-check.js\` sections" "  2. a | pipe")"'
need "an unknown version exits 2" exits 2 show v9
need "names it" line "10x-roadmap: no version v9 in .10x/roadmap.md"
roadmap | sed 's/| Planned |/| Done 2026-10-02 |/' >"$R"
need "next: none when all are done" eval 'exits 0 show && line "next: none"'
roadmap | sed 's/| Needs v1.s parser |/|  |/' >"$R"
need "a roadmap.md that fails check exits 2" exits 2 show
need "naming the fault" line "10x-roadmap: .10x/roadmap.md:6: version v2 has an empty Why this order"
end

reset; roadmap >"$R"
begin "show: suggests an audit since the last tag"
git tag v0.1.0
need "HEAD is the tag: exit 0" exits 0 show
need "no audit line" not has "audit:"
git commit -q --allow-empty -m "after the tag"
need "HEAD is ahead of the tag: exit 0" exits 0 show
need "the audit line ends the output, after next:" test "$(tail -n 2 "$tmp/out")" = "$(printf '%s\n%s' 'next: v2' 'audit: /10x:audit v0.1.0..HEAD')"
need "a version argument prints no audit line" eval 'exits 0 show v2 && ! has "audit:"'
git tag -d v0.1.0 >/dev/null
need "no tag: exit 0" exits 0 show
need "the no-tag line" line "audit: no tag — a diff-scope audit needs a previous release"
rm "$R"
need "no roadmap: exit 0" exits 0 show
need "no audit line without a roadmap" not has "audit:"
git reset -q --hard HEAD~1
end

reset; roadmap >"$R"
begin "show: writes nothing"
find .10x -exec touch -t 202001010000 {} +; touch "$tmp/stamp"
before="$(find .10x | sort)"
vr show; vr show v1; vr show v9
need "the same files" test "$before" = "$(find .10x | sort)"
need "none written since" test -z "$(find .10x -newer "$tmp/stamp")"
need "roadmap.md byte for byte" cmp -s "$R" <(roadmap)
end

# ---------------------------------------------------------------- link

reset; roadmap >"$R"; mkdir -p .10x/t9 && echo '# t9' >.10x/t9/ticket.md
begin "link: appends the id to the item and refuses an item that has one"
need "gh-<n>: exit 0" exits 0 link v2 2 gh-12
need "a files-mode id: exit 0" exits 0 link v2 1 t9
need "only that row changed" test "$(diff <(roadmap) "$R" | grep '^[<>]')" = "$(printf '%s\n' \
  '< | v2 | use `md-check.js` sections; a \| pipe | Needs v1'"'"'s parser | Planned |' \
  '> | v2 | use `md-check.js` sections `t9`; a \| pipe `gh-12` | Needs v1'"'"'s parser | Planned |')"
need "show lists the ids" eval 'exits 0 show v2 && line "  1. use \`md-check.js\` sections \`t9\`" && line "  2. a | pipe \`gh-12\`"'
cp "$R" "$tmp/linked"
need "an item with an id: exit 2" exits 2 link v2 2 gh-13
need "names it" line "10x-roadmap: item 2 of v2 already has gh-12"
need "an item with an id typed in the plan" exits 2 link v1 1 gh-13
need "an id with no ticket" exits 2 link v1 2 nope
need "names it" line "10x-roadmap: nope is neither gh-<n> nor an id with .10x/<id>/ticket.md"
need "an unknown version" exits 2 link v9 1 gh-13
need "an item out of range" exits 2 link v1 3 gh-13
need "a bad item number" exits 2 link v1 0 gh-13
need "nothing written" cmp -s "$R" "$tmp/linked"
mv "$R" "$tmp/real.md"; ln -s "$tmp/real.md" "$R"
need "a symlinked roadmap.md" exits 2 link v1 2 gh-13
need "names it" line "10x-roadmap: .10x/roadmap.md is a symlink"
rm "$R"; roadmap | sed 's/| Needs v1.s parser |/|  |/' >"$R"
need "a roadmap.md that fails check" exits 2 link v1 2 gh-13
end

reset
FPX="sha256:$(printf 'b%.0s' {1..64})"
roadmap | sed "s/^| v2 | use /| v2 | Fix the deploy hook (security $FPX); use /" >"$R"
mkdir -p .10x/security-bbbbbbbb && echo '# Fix security entry bbbbbbbb' >.10x/security-bbbbbbbb/ticket.md
begin "link: links an advisory ticket slug"
need "exit 0" exits 0 link v2 1 security-bbbbbbbb
need "the id follows the fingerprint, in backticks" eval 'exits 0 show v2 && line "  1. Fix the deploy hook (security '"$FPX"') \`security-bbbbbbbb\`"'
need "the roadmap still passes check" eval 'cp "$R" "$D" && exits 0 check'
end

[ "$fail" -eq 0 ] && echo "roadmap: all cases pass"
exit "$fail"
