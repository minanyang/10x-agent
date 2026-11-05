#!/bin/bash
# Unit cases for bin/10x-security (add, set, remove) on a throwaway repository with an origin. The cases start with
# nothing in .git/info/exclude beyond git's own comments: 10x-security must exclude .10x/ itself before it writes.
# shellcheck disable=SC2015,SC2016,SC2329  # `cond && ok || bad` is safe: ok always returns 0; `$cmd` below is literal snippet text; helpers run through need
set -uo pipefail
BIN="$(cd "$(dirname "$0")/.." && pwd)/bin"
fail=0
ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export PATH="$BIN:$PATH"

git -c init.defaultBranch=main init -q --bare "$tmp/origin.git"
git -c init.defaultBranch=main init -q "$tmp/repo"
cd "$tmp/repo" || exit 2
git config user.email t@t; git config user.name t
echo base >README.md && git add -A && git commit -qm init
git remote add origin "$tmp/origin.git" && git push -q -u origin main
root="$(pwd -P)"
S=.10x/security.md

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
sec() { 10x-security "$@" >"$tmp/out" 2>&1; }
exits() { local want=$1; shift; sec "$@"; [ $? -eq "$want" ]; } # <exit> <args...>
has() { grep -qF -- "$1" "$tmp/out"; }
line() { grep -qxF -- "$1" "$tmp/out"; }
out_is() { [ "$(cat "$tmp/out")" = "$1" ] || { echo "        got: $(cat "$tmp/out")"; false; }; }

# put <id> <name> — stdin becomes .10x/<id>/<name>.
put() { mkdir -p "$root/.10x/$1" && cat >"$root/.10x/$1/$2"; }
# add_ <id> [<name>] — 10x-security add of .10x/<id>/<name> (out.json).
add_() { sec add "$1" "$root/.10x/$1/${2:-out.json}"; }
# jrec <verdict> <rule> <path> <line> <snippet> — one record as JSON; the snippet is already JSON-escaped.
jrec() {
  local sev=',"severity":"high"'
  [ "$1" = confirmed ] || sev=''
  printf '{"verdict":"%s","rule":"%s","title":"Finding in %s","path":"%s","line":%s,"snippet":"%s","trace":"argv reaches the sink"%s}' \
    "$1" "$2" "$3" "$3" "$4" "$5" "$sev"
}
# arr <record>... — a JSON array.
arr() {
  local first=1 r
  printf '['
  for r in "$@"; do [ "$first" = 1 ] || printf ','; first=0; printf '%s' "$r"; done
  printf ']\n'
}
# exp_fp <rule> <path> <snippet> — the fingerprint, computed here and not by 10x-security.
exp_fp() { printf 'sha256:%s' "$(printf '%s\n%s\n%s' "$1" "$2" "$3" | shasum -a 256 | cut -d' ' -f1)"; }
# field <fingerprint> <name> — the value of `- <name>:` in that entry.
field() {
  awk -v fp="$1" -v key="$2" '
    $0 == "## " fp { on = 1; next }
    /^## / { on = 0 }
    on && index($0, "- " key ":") == 1 { v = substr($0, length(key) + 4); sub(/^ /, "", v); print v; exit }
  ' "$S"
}
entries() { grep -c '^## ' "$S"; }
field_is() { [ "$(field "$1" "$2")" = "$3" ] || { echo "        $2 of $1: '$(field "$1" "$2")', want '$3'"; false; }; }

RULE=command-injection
P1=bin/deploy.sh
SNIP='eval "$cmd"'
JSNIP='eval \"$cmd\"'
FP1="$(exp_fp "$RULE" "$P1" "$SNIP")"
FP2="$(exp_fp "$RULE" lib/run.sh "$SNIP")"
r1() { jrec confirmed "$RULE" "$P1" 12 "$JSNIP"; }
r2() { jrec confirmed "$RULE" lib/run.sh 30 "$JSNIP"; }

# ---------------------------------------------------------------- add

reset; : >.git/info/exclude
arr "$(r1)" | put T1 out.json
begin "add appends a new entry with every field"
need "exit 0" exits 0 add T1 "$root/.10x/T1/out.json" # the fixture is a regular file inside .10x/T1/
need "prints added: and the fingerprint" out_is "added: $FP1"
{
  printf '# Security entries\n\n## %s\n' "$FP1"
  printf '%s\n' '- title: Finding in bin/deploy.sh' '- verdict: confirmed' '- severity: high' "- rule: $RULE" '- location: bin/deploy.sh:12' \
    '- trace: argv reaches the sink' '- status: new' '- reason:' '- found in: T1' '- seen in:' '- audit fingerprint:' '- not seen in:'
} >"$tmp/want.md"
need "security.md is exactly the documented layout" cmp -s "$S" "$tmp/want.md"
end

reset
arr "$(r1)" | put T1 out.json
arr "$(jrec confirmed "$RULE" "$P1" 40 "$JSNIP")" | put T2 out.json
begin "add of a known fingerprint adds the id to seen in"
need "T1 adds" exits 0 add T1 "$root/.10x/T1/out.json"
need "T2 sees the same fingerprint" exits 0 add T2 "$root/.10x/T2/out.json"
need "prints seen: and the fingerprint" out_is "seen: $FP1"
need "still one entry" test "$(entries)" = 1
need "seen in is T2" field_is "$FP1" "seen in" T2
need "found in is still T1" field_is "$FP1" "found in" T1
need "location is the first sighting's" field_is "$FP1" location "$P1:12"
need "T2 again" exits 0 add T2 "$root/.10x/T2/out.json"
need "seen in does not repeat T2" field_is "$FP1" "seen in" T2
need "T1 again" exits 0 add T1 "$root/.10x/T1/out.json"
need "the found-in id is not added to seen in" field_is "$FP1" "seen in" T2
arr "$(r1)" | put T3 out.json
need "T3" exits 0 add T3 "$root/.10x/T3/out.json"
need "seen in lists T2 then T3" field_is "$FP1" "seen in" "T2, T3"
arr "$(r1)" "$(r1)" | put T4 out.json
need "two records with one fingerprint in one file" exits 0 add T4 "$root/.10x/T4/out.json"
need "the second is seen, not added" out_is "$(printf 'seen: %s\nseen: %s' "$FP1" "$FP1")"
need "still one entry" test "$(entries)" = 1
end

reset
arr "$(r1)" | put T1 out.json
arr "$(jrec confirmed "$RULE" "$P1" 40 "$JSNIP")" | put T2 out.json
begin "add leaves audit fingerprint and not seen in byte-identical"
need "T1 adds" exits 0 add T1 "$root/.10x/T1/out.json"
sed -e 's/^- audit fingerprint:$/- audit fingerprint: audit-7f3a/' -e 's/^- not seen in:$/- not seen in: T8, T9/' "$S" >"$tmp/edited.md"
cp "$tmp/edited.md" "$S"
cp "$S" "$tmp/before.md"
need "T2 sees it" exits 0 add T2 "$root/.10x/T2/out.json"
need "audit fingerprint kept" field_is "$FP1" "audit fingerprint" audit-7f3a
need "not seen in kept" field_is "$FP1" "not seen in" "T8, T9"
need "only the seen in line changed" test "$(diff "$tmp/before.md" "$S" | grep '^[<>]')" = "$(printf '%s\n%s' '< - seen in:' '> - seen in: T2')"
end

# ---------------------------------------------------------------- fingerprint

reset
begin "fingerprint ignores line and indentation"
arr "$(r1)" | put T1 out.json
need "the first sighting" exits 0 add T1 "$root/.10x/T1/out.json"
need "its fingerprint is the independent sha256" out_is "added: $FP1"
arr "$(jrec confirmed "$RULE" "$P1" 99 '    eval\n\t\"$cmd\"  ')" | put T2 out.json
need "another line, other indentation, a newline inside" exits 0 add T2 "$root/.10x/T2/out.json"
need "the same fingerprint" out_is "seen: $FP1"
need "one entry" test "$(entries)" = 1
end

reset
begin "fingerprint changes with rule, path or snippet"
arr "$(r1)" "$(jrec confirmed path-traversal "$P1" 12 "$JSNIP")" "$(jrec confirmed "$RULE" lib/run.sh 12 "$JSNIP")" \
  "$(jrec confirmed "$RULE" "$P1" 12 'eval \"$other\"')" | put T1 out.json
need "four records" exits 0 add T1 "$root/.10x/T1/out.json"
need "each has its own fingerprint" out_is "$(printf 'added: %s\nadded: %s\nadded: %s\nadded: %s' "$FP1" \
  "$(exp_fp path-traversal "$P1" "$SNIP")" "$(exp_fp "$RULE" lib/run.sh "$SNIP")" "$(exp_fp "$RULE" "$P1" 'eval "$other"')")"
need "four entries" test "$(entries)" = 4
end

reset
begin "fingerprint matches Cloudflare's pattern"
arr "$(r1)" "$(jrec needs_validation path-traversal 'src/a b@2/x+y.js' 3 'read(p)')" | put T1 out.json
need "exit 0" exits 0 add T1 "$root/.10x/T1/out.json"
fps="$(grep '^## ' "$S" | sed 's/^## //')"
need "two fingerprints" test "$(printf '%s\n' "$fps" | wc -l | tr -d ' ')" = 2
need "each matches ^[A-Za-z0-9][A-Za-z0-9._:/@+-]*\$" test -z "$(printf '%s\n' "$fps" | grep -vE '^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$')"
need "each is sha256: and 64 lowercase hex" test -z "$(printf '%s\n' "$fps" | grep -vE '^sha256:[0-9a-f]{64}$')"
need "the first is the independent value" test "$(printf '%s\n' "$fps" | head -n 1)" = "$FP1"
end

# ---------------------------------------------------------------- refusals of add

# drop <json array> <key> — the array with <key> deleted from its second record.
drop() { node -e 'const a = JSON.parse(process.argv[1]); delete a[1][process.argv[2]]; process.stdout.write(JSON.stringify(a))' "$1" "$2"; }

reset
begin "add refuses a record missing a field"
two="$(arr "$(r1)" "$(r2)")"
for f in verdict rule title path line snippet trace severity; do
  drop "$two" "$f" | put T1 bad.json
  need "$f missing: exit 2" exits 2 add T1 "$root/.10x/T1/bad.json"
  need "$f missing: names the record and the field" has "10x-security: records[1]: $f"
  need "$f missing: nothing written" test ! -e "$S"
done
end

reset
begin "add refuses severity on needs_validation"
nv="$(jrec needs_validation path-traversal "$P1" 5 'read(p)')"
arr "${nv%\}},\"severity\":\"high\"}" | put T1 bad.json
need "a severity: exit 2" exits 2 add T1 "$root/.10x/T1/bad.json"
need "names the record and the field" has "10x-security: records[0]: severity"
arr "${nv%\}},\"severity\":null}" | put T1 bad.json
need "a null severity: exit 2" exits 2 add T1 "$root/.10x/T1/bad.json"
need "names the record and the field" has "10x-security: records[0]: severity"
need "nothing written" test ! -e "$S"
arr "$nv" | put T1 ok.json
need "without a severity key it is accepted" exits 0 add T1 "$root/.10x/T1/ok.json"
need "severity is empty" field_is "$(exp_fp path-traversal "$P1" 'read(p)')" severity ""
need "verdict is needs_validation" field_is "$(exp_fp path-traversal "$P1" 'read(p)')" verdict needs_validation
end

reset
begin "refused add leaves security.md unchanged"
arr "$(r1)" | put T1 out.json
need "T1 adds" exits 0 add T1 "$root/.10x/T1/out.json"
cp "$S" "$tmp/before.md"
{ arr "$(r2)" | sed 's/\]$//'; printf ',{"verdict":"confirmed"}]\n'; } | put T2 bad.json
need "a good record then a bad one: exit 2" exits 2 add T2 "$root/.10x/T2/bad.json"
need "names the bad record" has "records[1]:"
need "the good record is not written either" cmp -s "$S" "$tmp/before.md"
end

# ---------------------------------------------------------------- set

reset
arr "$(r1)" | put T1 out.json
begin "set records each of the four statuses"
need "T1 adds" exits 0 add T1 "$root/.10x/T1/out.json"
need "later" exits 0 set T1 "$FP1" later
need "status later" field_is "$FP1" status later
need "no reason" field_is "$FP1" reason ""
need "accepted with a reason" exits 0 set T1 "$FP1" accepted "not reachable from outside"
need "status accepted" field_is "$FP1" status accepted
need "reason kept" field_is "$FP1" reason "not reachable from outside"
need "rejected with a reason" exits 0 set T1 "$FP1" rejected "a false positive"
need "status rejected" field_is "$FP1" status rejected
need "reason replaced" field_is "$FP1" reason "a false positive"
need "fix-now clears the reason" exits 0 set T1 "$FP1" fix-now
need "status fix-now" field_is "$FP1" status fix-now
need "reason cleared" field_is "$FP1" reason ""
need "the current status again is allowed" exits 0 set T1 "$FP1" fix-now
end

reset
arr "$(r1)" | put T1 out.json
begin "set refuses accepted or rejected without a reason"
need "T1 adds" exits 0 add T1 "$root/.10x/T1/out.json"
cp "$S" "$tmp/before.md"
need "accepted: exit 2" exits 2 set T1 "$FP1" accepted
need "accepted: says 10x-security" has "10x-security: "
need "rejected: exit 2" exits 2 set T1 "$FP1" rejected
need "new is not a status to set" exits 2 set T1 "$FP1" new
need "an unknown status" exits 2 set T1 "$FP1" "done"
need "nothing written" cmp -s "$S" "$tmp/before.md"
end

reset
arr "$(r1)" | put T1 out.json
begin "set refuses an unknown fingerprint"
need "T1 adds" exits 0 add T1 "$root/.10x/T1/out.json"
cp "$S" "$tmp/before.md"
need "exit 2" exits 2 set T1 "sha256:$(printf '0%.0s' {1..64})" later
need "10x-security refusal" has "10x-security: "
need "nothing written" cmp -s "$S" "$tmp/before.md"
end

reset
arr "$(r1)" | put T1 out.json
arr "$(jrec confirmed "$RULE" "$P1" 40 "$JSNIP")" | put T2 out.json
begin "set refuses an entry of another ticket"
need "T1 adds" exits 0 add T1 "$root/.10x/T1/out.json"
cp "$S" "$tmp/before.md"
need "T3 is in neither found in nor seen in: exit 2" exits 2 set T3 "$FP1" later
need "nothing written" cmp -s "$S" "$tmp/before.md"
need "T2 has not seen it yet: exit 2" exits 2 set T2 "$FP1" later
need "T2 sees it" exits 0 add T2 "$root/.10x/T2/out.json"
need "seen in counts: exit 0" exits 0 set T2 "$FP1" later
need "status later" field_is "$FP1" status later
need "remove by T3 is refused too" exits 2 remove T3 "$FP1"
need "the entry is still there" test "$(entries)" = 1
end

reset
arr "$(r1)" "$(r2)" | put T1 out.json
begin "set changes only status and reason"
need "T1 adds" exits 0 add T1 "$root/.10x/T1/out.json"
sed -e 's/^- audit fingerprint:$/- audit fingerprint: audit-7f3a/' -e 's/^- not seen in:$/- not seen in: T8, T9/' "$S" >"$tmp/edited.md"
cp "$tmp/edited.md" "$S"
cp "$S" "$tmp/before.md"
need "set exit 0" exits 0 set T1 "$FP1" accepted "not reachable"
need "only status and reason changed" test "$(diff "$tmp/before.md" "$S" | grep '^[<>]')" = "$(printf '%s\n' \
  '< - status: new' '< - reason:' '> - status: accepted' '> - reason: not reachable')"
end

# ---------------------------------------------------------------- remove

reset
arr "$(r2)" | put T1 only2.json
begin "remove deletes one entry"
need "only the second record" exits 0 add T1 "$root/.10x/T1/only2.json"
cp "$S" "$tmp/only2.md"
reset
arr "$(r1)" "$(r2)" | put T1 out.json
need "both records" exits 0 add T1 "$root/.10x/T1/out.json"
need "two entries" test "$(entries)" = 2
need "remove the first" exits 0 remove T1 "$FP1"
need "one entry left" test "$(entries)" = 1
need "it is the second, byte for byte" cmp -s "$S" "$tmp/only2.md"
need "an unknown fingerprint is refused" exits 2 remove T1 "$FP1"
need "another ticket is refused" exits 2 remove T9 "$FP2"
need "the second is still there" test "$(entries)" = 1
end

# ---------------------------------------------------------------- git status

reset; : >.git/info/exclude
arr "$(r1)" | put T1 out.json
begin "add and set leave git status clean"
need "before: .10x/ shows as untracked" test -n "$(git status --porcelain)"
need "add" exits 0 add T1 "$root/.10x/T1/out.json"
need "git status is empty after add" test -z "$(git status --porcelain)"
need "set" exits 0 set T1 "$FP1" later
need "git status is empty after set" test -z "$(git status --porcelain)"
need ".10x/ is excluded" grep -qxF '/.10x/' .git/info/exclude
need ".worktrees/ is excluded" grep -qxF '/.worktrees/' .git/info/exclude
need "security.md is not tracked" test -z "$(git ls-files .10x)"
end

[ "$fail" -eq 0 ] && echo "security: all cases pass"
exit "$fail"
