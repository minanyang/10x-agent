#!/bin/bash
# Unit cases for bin/10x-security (add, set, remove) on a throwaway repository with an origin. The cases start with
# nothing in .git/info/exclude beyond git's own comments: 10x-security must exclude .10x/ itself before it writes.
# shellcheck disable=SC2015,SC2016,SC2154,SC2329  # `cond && ok || bad` is safe: ok always returns 0; `$cmd` below is literal snippet text; $FP_<name> is set by mkrec's printf -v; helpers run through need
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
sed -e 's/^- audit fingerprint:$/- audit fingerprint: audit-7f3a/' -e 's|^- not seen in:$|- not seen in: audit/run-8, audit/run-9|' "$S" >"$tmp/edited.md"
cp "$tmp/edited.md" "$S"
cp "$S" "$tmp/before.md"
need "T2 sees it" exits 0 add T2 "$root/.10x/T2/out.json"
need "audit fingerprint kept" field_is "$FP1" "audit fingerprint" audit-7f3a
need "not seen in kept" field_is "$FP1" "not seen in" "audit/run-8, audit/run-9"
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
sed -e 's/^- audit fingerprint:$/- audit fingerprint: audit-7f3a/' -e 's|^- not seen in:$|- not seen in: audit/run-8, audit/run-9|' "$S" >"$tmp/edited.md"
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

# ---------------------------------------------------------------- audit: fixtures

# The sink files are committed, so only .10x/ is ever untracked.
mkdir -p src
printf '#!/bin/sh\n    eval "$cmd"\necho done\n' >src/a.sh
printf 'cat "$p"\n' >src/b.sh
printf 'rm -rf "$d"\n' >src/c.sh
git add -A && git commit -qm "audit fixtures"

# HOME with the security-audit skill installed (as a symlink, the way the Skills CLI may install it) and one without.
home="$tmp/home"
mkdir -p "$tmp/skillsrc/security-audit" "$home/.claude/skills" "$tmp/nohome"
echo '# security-audit' >"$tmp/skillsrc/security-audit/SKILL.md"
ln -s "$tmp/skillsrc/security-audit" "$home/.claude/skills/security-audit"

# frec <audit fp> <verdict> <title> <sink file> <sink line> [<severity>] — one findings.json record: an entrypoint at src/b.sh:1, then the sink.
frec() {
  local sev=''
  [ "$2" = confirmed ] && sev=",\"severity\":{\"overall_severity\":\"${6:-high}\"}"
  printf '{"verdict":"%s","fingerprint":"%s","title":"%s","trace":[{"kind":"entrypoint","file":"src/b.sh","line":1},{"kind":"sink","file":"%s","line":%s}]%s}' \
    "$2" "$1" "$3" "$4" "$5" "$sev"
}
# frej <audit fp> <title> — a rejected record.
frej() { printf '{"verdict":"rejected","fingerprint":"%s","title":"%s"}' "$1" "$2"; }
# run_ <n> <findings.json> <rules.json> <run-metadata.json> — .10x/audit/run-<n>/.
run_() {
  local d="$root/.10x/audit/run-$1"
  mkdir -p "$d" && printf '%s\n' "$2" >"$d/findings.json" && printf '%s\n' "$3" >"$d/rules.json" && printf '%s\n' "$4" >"$d/run-metadata.json"
}
RULES='{"cf:alpha":"command-injection","cf:beta":"path-traversal"}'
META_SRC='{"run_id":"run-1","scope_paths":["src"],"run_status":"complete"}'
META_ALL='{"run_id":"run-1","scope_paths":["."],"run_status":"complete"}'
FPA="$(exp_fp command-injection src/a.sh 'eval "$cmd"')"
FPB="$(exp_fp path-traversal src/b.sh 'cat "$p"')"
FPC="$(exp_fp command-injection src/c.sh 'rm -rf "$d"')"
ALPHA() { frec cf:alpha confirmed 'Eval of cmd' src/a.sh 2; }
BETA() { frec cf:beta needs_validation 'Read of p' src/b.sh 1; }
# snap — every path under .10x/ with its checksum, and the exclude file.
snap() { { find .10x | sort; find .10x .git/info/exclude -type f -exec cksum {} + | sort; } 2>&1; }

# ---------------------------------------------------------------- audit: prepare

reset
arr "$(r1)" | put T1 out.json
begin "prepare without the skill prints both install commands and writes nothing"
need "T1 adds" exits 0 add T1 "$root/.10x/T1/out.json"
: >.git/info/exclude
snap >"$tmp/snap.before"
HOME="$tmp/nohome" need "exit 1" exits 1 prepare
need "says the skill is not installed" has "10x-security: the security-audit skill is not installed; install it with one of:"
need "the project install command" line "npx skills add https://github.com/cloudflare/security-audit-skill --skill security-audit"
need "the global install command" line "npx skills add https://github.com/cloudflare/security-audit-skill --skill security-audit --global"
snap >"$tmp/snap.after"
need ".10x/ and the exclude file are unchanged" cmp -s "$tmp/snap.before" "$tmp/snap.after"
need "no .10x/audit" test ! -e .10x/audit
end

reset
mkdir -p .10x/audit/run-1 .10x/audit/run-3 .10x/audit/run-x
begin "prepare creates the run after the highest existing one"
HOME="$home" need "exit 0" exits 0 prepare
need "the skill line names the installed SKILL.md" grep -qE '^skill: /.*/security-audit/SKILL\.md$' "$tmp/out"
need "run: is run-4, then the earlier runs in order" test "$(grep -v '^skill: ' "$tmp/out")" = "$(printf 'run: %s\nprior: %s\nprior: %s' \
  "$root/.10x/audit/run-4" "$root/.10x/audit/run-1" "$root/.10x/audit/run-3")"
need "run-4 exists" test -d .10x/audit/run-4
need "git ignores it" git check-ignore -q .10x/audit/run-4/
HOME="$home" need "a second prepare takes run-5" exits 0 prepare
need "run-5" line "run: $root/.10x/audit/run-5"
end

reset
printf '!/.10x/\n' >.gitignore
begin "prepare refuses a run directory git does not ignore"
HOME="$home" need "exit 1" exits 1 prepare
need "says it is not ignored" has "10x-security: .10x/audit/run-1 is not ignored by git; the audit may write only to an ignored directory"
need "run-1 is not created" test ! -e .10x/audit/run-1
need ".10x/audit is not created" test ! -e .10x/audit
rm -f .gitignore
end

# ---------------------------------------------------------------- audit: import

reset; : >.git/info/exclude
run_ 1 "$(arr "$(ALPHA)" "$(BETA)" "$(frej cf:gamma 'Not real')")" "$RULES" "$META_SRC"
begin "import fingerprints confirmed and needs_validation records from the sink line"
need "exit 0" exits 0 import run-1
need "an added line per non-rejected record, then run_status" out_is "$(printf 'added: %s\nadded: %s\nrun_status: complete' "$FPA" "$FPB")"
need "two entries; the rejected record is skipped" test "$(entries)" = 2
need "fingerprint of the indented sink line equals the independent value" field_is "$FPA" rule command-injection
need "audit fingerprint" field_is "$FPA" "audit fingerprint" cf:alpha
need "verdict" field_is "$FPA" verdict confirmed
need "severity from overall_severity" field_is "$FPA" severity high
need "location is the sink's" field_is "$FPA" location src/a.sh:2
need "title" field_is "$FPA" title "Eval of cmd"
need "status" field_is "$FPA" status new
need "found in the run" field_is "$FPA" "found in" audit/run-1
need "trace is one line per entry, escaped" field_is "$FPA" trace 'entrypoint src/b.sh:1\nsink src/a.sh:2'
need "needs_validation: audit fingerprint" field_is "$FPB" "audit fingerprint" cf:beta
need "needs_validation: verdict" field_is "$FPB" verdict needs_validation
need "needs_validation: no severity" field_is "$FPB" severity ""
need "the rejected record is not in security.md" not grep -qF cf:gamma "$S"
end

reset; : >.git/info/exclude
arr "$(jrec confirmed command-injection src/c.sh 1 'rm -rf \"$d\"')" | put T1 out.json
run_ 1 "$(arr "$(ALPHA)" "$(BETA)")" "$RULES" "$META_SRC"
run_ 2 "$(arr "$(frec cf:alpha confirmed 'Renamed eval' src/b.sh 1 medium)" "$(frec cf:beta2 needs_validation 'Another read' src/b.sh 1)" \
  "$(frec cf:gamma2 confirmed 'Rm' src/c.sh 1)")" \
  '{"cf:alpha":"command-injection","cf:beta2":"path-traversal","cf:gamma2":"command-injection"}' '{"run_id":"run-2","scope_paths":["src"]}'
begin "import matches by audit fingerprint, then by 10x fingerprint"
need "T1 adds the entry import will match by 10x fingerprint" exits 0 add T1 "$root/.10x/T1/out.json"
need "run-1" exits 0 import run-1
need "accepted with a reason" exits 0 set audit/run-1 "$FPA" accepted "not reachable"
need "run-2" exits 0 import run-2
need "three seen lines (status kept), then run_status missing" out_is "$(printf 'seen: %s accepted\nseen: %s new\nseen: %s new\nrun_status: missing' "$FPA" "$FPB" "$FPC")"
need "no new entry" test "$(entries)" = 3
need "audit match: seen in the second run" field_is "$FPA" "seen in" audit/run-2
need "audit match: found in stays" field_is "$FPA" "found in" audit/run-1
need "audit match: status kept" field_is "$FPA" status accepted
need "audit match: reason kept" field_is "$FPA" reason "not reachable"
need "audit match: title kept" field_is "$FPA" title "Eval of cmd"
need "audit match: severity from the record" field_is "$FPA" severity medium
need "audit match: location from the record" field_is "$FPA" location src/b.sh:1
need "audit match: trace from the record" field_is "$FPA" trace 'entrypoint src/b.sh:1\nsink src/b.sh:1'
need "audit match: audit fingerprint kept" field_is "$FPA" "audit fingerprint" cf:alpha
need "10x match: seen in the second run" field_is "$FPB" "seen in" audit/run-2
need "10x match: a non-empty audit fingerprint is kept" field_is "$FPB" "audit fingerprint" cf:beta
need "10x match on an entry with no audit fingerprint: it is filled" field_is "$FPC" "audit fingerprint" cf:gamma2
need "10x match: seen in the second run" field_is "$FPC" "seen in" audit/run-2
need "10x match: found in stays the ticket" field_is "$FPC" "found in" T1
end

reset; : >.git/info/exclude
run_ 1 "$(arr "$(ALPHA)" "$(BETA)")" "$RULES" "$META_SRC"
begin "import of the same run twice is byte-identical"
need "first import" exits 0 import run-1
cp "$S" "$tmp/before.md"
need "second import" exits 0 import run-1
need "seen lines" out_is "$(printf 'seen: %s new\nseen: %s new\nrun_status: complete' "$FPA" "$FPB")"
need "security.md is byte-identical" cmp -s "$S" "$tmp/before.md"
end

reset; : >.git/info/exclude
arr "$(jrec confirmed command-injection src/c.sh 1 'rm -rf \"$d\"')" | put T1 out.json
begin "import refuses a run with a record that has no rule"
need "T1 adds" exits 0 add T1 "$root/.10x/T1/out.json"
cp "$S" "$tmp/before.md"
run_ 1 "$(arr "$(ALPHA)" "$(frec cf:nope confirmed 'Secret-title-nope' src/b.sh 1)")" "$RULES" "$META_SRC"
need "exit 2" exits 2 import run-1
need "names the record" has "findings[1]"
need "does not quote the title" not has "Secret-title-nope"
need "does not quote the Cloudflare fingerprint" not has "cf:nope"
need "security.md is unchanged, the good record is not written either" cmp -s "$S" "$tmp/before.md"
end

reset; : >.git/info/exclude
arr "$(jrec confirmed command-injection src/c.sh 1 'rm -rf \"$d\"')" | put T1 out.json
begin "import refuses a run whose sink line does not exist"
need "T1 adds" exits 0 add T1 "$root/.10x/T1/out.json"
cp "$S" "$tmp/before.md"
run_ 1 "$(arr "$(frec cf:alpha confirmed 'Secret-title-a' src/a.sh 4)")" "$RULES" "$META_SRC"
need "line 4 of a 3-line file: exit 2" exits 2 import run-1
need "names the record" has "findings[0]"
need "does not quote the title" not has "Secret-title-a"
run_ 2 "$(arr "$(ALPHA)" "$(frec cf:beta confirmed 'Secret-title-b' src/nope.sh 1)")" "$RULES" "$META_SRC"
need "a missing sink file: exit 2" exits 2 import run-2
need "names the record" has "findings[1]"
need "does not quote the title" not has "Secret-title-b"
need "security.md is unchanged" cmp -s "$S" "$tmp/before.md"
end

reset; : >.git/info/exclude
arr "$(jrec confirmed command-injection src/c.sh 1 'rm -rf \"$d\"')" | put T1 out.json
begin "import marks unmatched entries not seen only for a whole-repo scope"
need "T1 adds" exits 0 add T1 "$root/.10x/T1/out.json"
need "later" exits 0 set T1 "$FPC" later
run_ 1 "$(arr "$(ALPHA)")" "$RULES" "$META_ALL"
need "whole-repo import" exits 0 import run-1
need "added, then not seen, then run_status" out_is "$(printf 'added: %s\nnot seen: %s\nrun_status: complete' "$FPA" "$FPC")"
need "unmatched entry: not seen in the run" field_is "$FPC" "not seen in" audit/run-1
need "unmatched entry: status kept" field_is "$FPC" status later
need "the added entry is not marked" field_is "$FPA" "not seen in" ""
run_ 2 "$(arr "$(ALPHA)")" "$RULES" "$META_ALL"
need "second whole-repo import" exits 0 import run-2
need "earlier run ids stay" field_is "$FPC" "not seen in" "audit/run-1, audit/run-2"
need "a matched entry is not marked" field_is "$FPA" "not seen in" ""
cp "$S" "$tmp/before.md"
need "the same run again" exits 0 import run-2
need "the same run again changes nothing" cmp -s "$S" "$tmp/before.md"
run_ 3 "$(arr "$(ALPHA)")" "$RULES" '{"scope_paths":["src"],"run_status":"complete"}'
need "a path-scope import" exits 0 import run-3
need "a path scope marks nothing" field_is "$FPC" "not seen in" "audit/run-1, audit/run-2"
run_ 4 "$(arr "$(ALPHA)")" "$RULES" '{"scope_paths":["a..b"],"run_status":"complete"}'
need "a diff-scope import" exits 0 import run-4
need "a diff scope marks nothing" field_is "$FPC" "not seen in" "audit/run-1, audit/run-2"
end

# ---------------------------------------------------------------- audit: set, ticket

reset; : >.git/info/exclude
run_ 1 "$(arr "$(ALPHA)")" "$RULES" "$META_SRC"
begin "set accepts an audit run id and still needs a reason for accepted or rejected"
need "import" exits 0 import run-1
cp "$S" "$tmp/before.md"
need "accepted without a reason: exit 2" exits 2 set audit/run-1 "$FPA" accepted
need "rejected without a reason: exit 2" exits 2 set audit/run-1 "$FPA" rejected
need "nothing written" cmp -s "$S" "$tmp/before.md"
need "accepted with a reason" exits 0 set audit/run-1 "$FPA" accepted "not reachable"
need "status" field_is "$FPA" status accepted
need "reason" field_is "$FPA" reason "not reachable"
need "a run that neither found nor saw it: exit 2" exits 2 set audit/run-2 "$FPA" later
need "audit/run-0 is not a run id: exit 2" exits 2 set audit/run-0 "$FPA" later
need "later" exits 0 set audit/run-1 "$FPA" later
need "status later" field_is "$FPA" status later
need "remove accepts it too" exits 0 remove audit/run-1 "$FPA"
need "the entry is gone" test "$(entries)" = 0
end

# fake gh on PATH: logs every call and fails.
mkdir -p "$tmp/fakebin"
printf '#!/bin/sh\necho "$*" >>"%s"\nexit 1\n' "$tmp/gh.log" >"$tmp/fakebin/gh"
chmod +x "$tmp/fakebin/gh"
H8="${FPA#sha256:}"; H8="${H8:0:8}"

reset; : >.git/info/exclude
run_ 1 "$(arr "$(ALPHA)")" "$RULES" "$META_SRC"
begin "ticket writes a local ticket in both tickets modes and calls no gh"
need "import" exits 0 import run-1
: >"$tmp/gh.log"
mkdir -p .claude
printf '{"tickets":"github"}\n' >.claude/10x.json
PATH="$tmp/fakebin:$PATH" need "github mode: exit 0" exits 0 ticket "$FPA" "security-$H8"
need "github mode: prints the path" line "ticket: $root/.10x/security-$H8/ticket.md"
need "github mode: ticket.md written" test -s ".10x/security-$H8/ticket.md"
need "github mode: the slug is in seen in" field_is "$FPA" "seen in" "security-$H8"
printf '{"tickets":"files"}\n' >.claude/10x.json
PATH="$tmp/fakebin:$PATH" need "files mode: exit 0" exits 0 ticket "$FPA" security-00000000
need "files mode: prints the path" line "ticket: $root/.10x/security-00000000/ticket.md"
need "files mode: ticket.md written" test -s .10x/security-00000000/ticket.md
need "files mode: the slug is added to seen in" field_is "$FPA" "seen in" "security-$H8, security-00000000"
need "gh was never called" test ! -s "$tmp/gh.log"
rm -rf .claude
end

reset; : >.git/info/exclude
run_ 1 "$(arr "$(ALPHA)")" "$RULES" "$META_SRC"
begin "ticket names the entry only by its fingerprint"
need "import" exits 0 import run-1
need "ticket" exits 0 ticket "$FPA" "security-$H8"
printf '# Fix security entry %s\n\n## Context\nSecurity entry `%s` in `.10x/security.md` (title, location and trace are there). Found in `audit/run-1`.\n\n## Acceptance criteria\n- [ ] AC1 — Security entry `%s` is fixed, and removed from `security.md` once a full review round has no finding against it.\n' \
  "$H8" "$FPA" "$FPA" >"$tmp/ticket.want"
need "ticket.md is the documented text" test "$(cat ".10x/security-$H8/ticket.md")" = "$(cat "$tmp/ticket.want")"
need "no title" not grep -qF "Eval of cmd" ".10x/security-$H8/ticket.md"
need "no location" not grep -qF "src/a.sh" ".10x/security-$H8/ticket.md"
need "no trace" not grep -qF "entrypoint" ".10x/security-$H8/ticket.md"
end

reset; : >.git/info/exclude
run_ 1 "$(arr "$(ALPHA)")" "$RULES" "$META_SRC"
begin "ticket refuses an existing ticket dir and the slugs drafts and audit"
need "import" exits 0 import run-1
mkdir .10x/taken
cp "$S" "$tmp/before.md"
need "an existing .10x/<slug>/: exit 2" exits 2 ticket "$FPA" taken
need "it holds no ticket.md" test ! -e .10x/taken/ticket.md
need "drafts: exit 2" exits 2 ticket "$FPA" drafts
need "drafts: the reserved wording" has "slug 'drafts' is reserved for .10x/drafts/"
need "audit: exit 2" exits 2 ticket "$FPA" audit
need "audit: the reserved wording" has "slug 'audit' is reserved for .10x/audit/"
need "audit: no ticket.md in .10x/audit" test ! -e .10x/audit/ticket.md
need "gh-7: exit 2" exits 2 ticket "$FPA" gh-7
need "an invalid slug: exit 2" exits 2 ticket "$FPA" Bad_Slug
need "an unknown fingerprint: exit 2" exits 2 ticket "sha256:$(printf '0%.0s' {1..64})" some-slug
need "it created no dir" test ! -e .10x/some-slug
need "security.md is unchanged by every refusal" cmp -s "$S" "$tmp/before.md"
end

# ---------------------------------------------------------------- list --plannable

# mkrec <name> <verdict> <severity> <path> <line> — adds one entry found in T1; its fingerprint lands in $FP_<name>.
mkrec() {
  local rec
  rec="$(jrec "$2" "$RULE" "$4" "$5" "go_$1")"
  [ -z "$3" ] || rec="$(printf '%s' "$rec" | sed "s/\"severity\":\"high\"/\"severity\":\"$3\"/")"
  arr "$rec" | put T1 "$1.json"
  sec add T1 "$root/.10x/T1/$1.json"
  printf -v "FP_$1" '%s' "$(sed 's/^added: //' "$tmp/out")"
}

reset; : >.git/info/exclude
mkrec la confirmed medium lib/la.sh 1
mkrec lb confirmed high lib/lb.sh 1
mkrec lnew confirmed high lib/lnew.sh 1
mkrec lfix confirmed high lib/lfix.sh 1
mkrec lacc confirmed high lib/lacc.sh 1
mkrec lrej confirmed high lib/lrej.sh 1
mkrec lnv needs_validation '' lib/lnv.sh 1
mkrec lplan confirmed critical lib/lplan.sh 1
begin "list --plannable prints confirmed later entries not yet in the roadmap"
for n in la lb lnv lplan; do v="FP_$n"; sec set T1 "${!v}" later; done
sec set T1 "$FP_lfix" fix-now
sec set T1 "$FP_lacc" accepted "not reachable"
sec set T1 "$FP_lrej" rejected "a false positive"
printf '# Roadmap\n\n## Later\n- Fix lplan (security %s)\n' "$FP_lplan" >.10x/roadmap.md
need "exit 0" exits 0 list --plannable
need "only the confirmed later entries outside the roadmap, in file order" out_is "$(printf '%s medium later Finding in lib/la.sh\n%s high later Finding in lib/lb.sh' "$FP_la" "$FP_lb")"
printf '# Roadmap\n\n## Later\n- Fix la (security %s)\n- Fix lb (security %s)\n- Fix lplan (security %s)\n' "$FP_la" "$FP_lb" "$FP_lplan" >.10x/roadmap.md
need "every candidate planned: exit 0" exits 0 list --plannable
need "prints nothing" out_is ""
need "list without --plannable is a usage refusal" exits 2 list
end

# ---------------------------------------------------------------- route

# A tagged history: lib/rel.sh and lib/mv.sh are in v1.0.0; lib/new.sh comes after it, and lib/mv.sh's first line moves to the end.
mkdir -p lib
printf 'one\ntwo\nthree\nfour\nfive\n' >lib/rel.sh
printf '%s\n' 'the first line of the moved file with plenty of alphanumeric text' second third fourth fifth >lib/mv.sh
git add -A && git commit -qm "release files" && git tag v1.0.0
printf 'a\nb\nc\n' >lib/new.sh
{ tail -n +2 lib/mv.sh; head -n 1 lib/mv.sh; } >lib/mv.tmp && mv lib/mv.tmp lib/mv.sh
git add -A && git commit -qm "after the release"
NEW7="$(git log -1 --format=%H -- lib/new.sh | cut -c1-7)"
git remote set-url origin git@github.com:acme/sec.git

# fake gh on PATH: `repo view` answers $STUB_VIS (gh fails when it is empty), every call is logged, anything else fails.
mkdir -p "$tmp/visbin"
printf '#!/bin/sh\necho "$*" >>"%s"\n[ "$1 $2" = "repo view" ] && [ -n "${STUB_VIS-}" ] && { echo "$STUB_VIS"; exit 0; }\nexit 1\n' "$tmp/vis.log" >"$tmp/visbin/gh"
chmod +x "$tmp/visbin/gh"
# route_as <visibility> <fingerprint> — route with the fake gh (an empty visibility makes gh fail); the exit code is route's.
route_as() { STUB_VIS="$1" PATH="$tmp/visbin:$PATH" sec route "$2"; }
# routes <visibility> <fingerprint> <line> — route exits 0 and prints exactly <line>.
routes() { route_as "$1" "$2" && out_is "$3"; }
# route_exits <want> <visibility> <fingerprint>
route_exits() { local want=$1; shift; route_as "$@"; [ $? -eq "$want" ]; }

reset; : >.git/info/exclude; : >"$tmp/vis.log"
mkrec rh confirmed high lib/rel.sh 2
mkrec rm confirmed medium lib/rel.sh 3
mkrec rc confirmed critical lib/mv.sh 5
mkrec rl confirmed low lib/gone.sh 1
mkrec ri confirmed informational lib/gone.sh 1
mkrec rn needs_validation '' lib/gone.sh 1
mkrec ru confirmed high lib/new.sh 2
mkrec rs confirmed high lib/rel.sh 99
mkrec rf confirmed high lib/gone.sh 1

begin "route: ticket with tickets files"
mkdir -p .claude
printf '{"tickets":"files"}\n' >.claude/10x.json
need "files mode: exit 0 with the one line" routes PUBLIC "$FP_rh" "route: ticket — tickets: files"
need "no gh call" test ! -s "$tmp/vis.log"
printf '{"tickets":"github"}\n' >.claude/10x.json
need "github mode reads the visibility" routes PRIVATE "$FP_rh" "route: issue — repo is PRIVATE"
printf '{"tickets":null}\n' >.claude/10x.json
need "a null value follows the github.com origin" routes PRIVATE "$FP_rh" "route: issue — repo is PRIVATE"
rm -rf .claude
end

begin "route: issue for a private or internal repo"
: >"$tmp/vis.log"
need "PRIVATE" routes PRIVATE "$FP_rh" "route: issue — repo is PRIVATE"
need "INTERNAL" routes INTERNAL "$FP_rh" "route: issue — repo is INTERNAL"
need "even for an entry that would be an advisory in a public repo" routes PRIVATE "$FP_rc" "route: issue — repo is PRIVATE"
need "gh was asked for the origin repo's visibility" grep -qxF "repo view github.com/acme/sec --json visibility --jq .visibility" "$tmp/vis.log"
end

begin "route: advisory for a released medium or worse entry in a public repo"
need "high" routes PUBLIC "$FP_rh" "route: advisory — PUBLIC, confirmed high, released in v1.0.0"
need "medium" routes PUBLIC "$FP_rm" "route: advisory — PUBLIC, confirmed medium, released in v1.0.0"
need "a line moved after the release keeps its released commit" routes PUBLIC "$FP_rc" "route: advisory — PUBLIC, confirmed critical, released in v1.0.0"
end

begin "route: issue for a low, unreleased or untagged entry in a public repo"
need "low, with no blame (its file is gone)" routes PUBLIC "$FP_rl" "route: issue — PUBLIC, low"
need "informational" routes PUBLIC "$FP_ri" "route: issue — PUBLIC, informational"
need "needs_validation" routes PUBLIC "$FP_rn" "route: issue — PUBLIC, needs_validation"
need "unreleased: the blamed commit is in no tag" routes PUBLIC "$FP_ru" "route: issue — PUBLIC, unreleased ($NEW7 is in no tag)"
git tag -d v1.0.0 >/dev/null
need "no tag, with no blame (a stale line is not an error here)" routes PUBLIC "$FP_rs" "route: issue — PUBLIC, no tag"
git tag v1.0.0 HEAD~1
end

begin "route refuses an unknown fingerprint and a location line gone at HEAD"
ZERO="sha256:$(printf '0%.0s' {1..64})"
need "an unknown fingerprint: exit 2" route_exits 2 PUBLIC "$ZERO"
need "names it" has "no security entry $ZERO"
need "a line past the end of the file: exit 2" route_exits 2 PUBLIC "$FP_rs"
need "names the line and the file" has "location line 99 of lib/rel.sh no longer exists at HEAD"
need "a missing file: exit 2" route_exits 2 PUBLIC "$FP_rf"
need "names the line and the file" has "location line 1 of lib/gone.sh no longer exists at HEAD"
need "an unreadable visibility: exit 2" route_exits 2 "" "$FP_rh"
need "an unknown visibility: exit 2" route_exits 2 WEIRD "$FP_rh"
mkdir -p .claude
printf '{"tickets":"github"}\n' >.claude/10x.json
git remote set-url origin https://gitlab.example.com/acme/sec.git
need "an origin that is not github.com: exit 2" route_exits 2 PUBLIC "$FP_rh"
need "says so" has "route needs a github.com origin"
git remote remove origin
need "no origin: exit 2" route_exits 2 PUBLIC "$FP_rh"
need "says so" has "route needs origin to read the repo's visibility"
git remote add origin git@github.com:acme/sec.git
mkdir -p .claude
printf '{"tickets":"gitlab"}\n' >.claude/10x.json
need "an unknown tickets value: exit 2" route_exits 2 PUBLIC "$FP_rh"
rm -rf .claude
end

begin "list and route leave security.md byte-identical"
cp "$S" "$tmp/before.md"
sec list --plannable
for fp in "$FP_rh" "$FP_rm" "$FP_rc" "$FP_rl" "$FP_ru" "$FP_rs" "$ZERO"; do
  route_as PUBLIC "$fp"; route_as PRIVATE "$fp"
done
need "security.md is unchanged" cmp -s "$S" "$tmp/before.md"
end
git remote set-url origin "$tmp/origin.git"

reset; : >.git/info/exclude
mkrec ta confirmed high lib/ta.sh 1
mkrec tb confirmed high lib/tb.sh 1
begin "set and remove accept a ticket whose header names the fingerprint"
printf '# Fix security entry x\nSecurity: %s\n\n## Context\nx\n' "$FP_tb" | put TK2 ticket.md
printf '# Fix security entry x\nSecurity: %s\n\n## Context\nx\n' "$FP_ta" | put TKREAL real.md
mkdir -p .10x/TK3 && ln -s "$root/.10x/TKREAL/real.md" .10x/TK3/ticket.md
printf '# Fix security entry x\nSecurity: %s\n\n## Context\nx\n' "$FP_ta" | put TK ticket.md
cp "$S" "$tmp/before.md"
need "a ticket naming another fingerprint: set refused" exits 2 set TK2 "$FP_ta" later
need "a ticket naming another fingerprint: remove refused" exits 2 remove TK2 "$FP_ta"
need "a symlinked ticket.md: set refused" exits 2 set TK3 "$FP_ta" later
need "a symlinked ticket.md: remove refused" exits 2 remove TK3 "$FP_ta"
need "an id with no ticket.md: refused" exits 2 set TK9 "$FP_ta" later
need "nothing written by the refusals" cmp -s "$S" "$tmp/before.md"
need "set through the ticket header" exits 0 set TK "$FP_ta" later
need "status later" field_is "$FP_ta" status later
need "found in is still T1" field_is "$FP_ta" "found in" T1
need "seen in is untouched" field_is "$FP_ta" "seen in" ""
need "remove through the ticket header" exits 0 remove TK "$FP_ta"
need "one entry left" test "$(entries)" = 1
end

# ---------------------------------------------------------------- git status

rm -rf .10x; : >.git/info/exclude
begin "prepare and import leave git status clean"
need "before: clean" test -z "$(git status --porcelain)"
HOME="$home" need "prepare" exits 0 prepare
need "prepare made run-1" line "run: $root/.10x/audit/run-1"
need "git status is empty after prepare" test -z "$(git status --porcelain)"
run_ 1 "$(arr "$(ALPHA)" "$(BETA)")" "$RULES" "$META_SRC"
need "import" exits 0 import run-1
need "git status is empty after import" test -z "$(git status --porcelain)"
end

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
