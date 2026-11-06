#!/bin/bash
# End-to-end test of the bin/ scripts on a throwaway repository with an origin.
# shellcheck disable=SC2015,SC2016  # `cond && ok || bad` is safe: ok always returns 0; backticks in patterns are literal Markdown
set -uo pipefail
BIN="$(cd "$(dirname "$0")/.." && pwd)/bin"
export PATH="$BIN:$PATH"
unset TENX_BATCH # a batch worker's gates run this suite; the TENX_BATCH cases set it per call
fail=0
ok()   { echo "ok    $1"; }
bad()  { echo "FAIL  $1"; fail=1; }
expect() { # <description> <expected-exit> <command...>
  local d=$1 want=$2; shift 2
  "$@" >"$tmp/out" 2>&1; local got=$?
  if [ "$got" -eq "$want" ]; then ok "$d"; else bad "$d (want exit $want, got $got)"; sed 's/^/      /' "$tmp/out"; fi
}

tmp=$(mktemp -d)
trap 'rm -r "$tmp"' EXIT
git -c init.defaultBranch=main init -q --bare "$tmp/origin.git"
git -c init.defaultBranch=main init -q "$tmp/repo"
cd "$tmp/repo" || exit 2
git config user.email t@t; git config user.name t
cat >package.json <<'EOF'
{ "name": "fixture", "private": true, "scripts": { "test": "node --test" } }
EOF
mkdir src
echo 'export const add = (a, b) => a + b' >src/math.mjs
git add -A && git commit -qm "init"
git remote add origin "$tmp/origin.git" && git push -q -u origin main

# init: an invalid tickets value is refused before .10x/ or the exclude entries exist
mkdir -p .claude && echo '{"tickets":"gitlab"}' >.claude/10x.json
init_bad=0
for args in T0 ""; do
  # shellcheck disable=SC2086  # "" runs init without an id
  10x-worktree init $args >"$tmp/out" 2>&1; rc=$?
  { [ "$rc" -eq 2 ] && [ "$(head -n 1 "$tmp/out")" = "tickets: gitlab" ] && grep -qF "want github or files" "$tmp/out" &&
    [ ! -e .10x ] && ! grep -qxF '/.10x/' .git/info/exclude 2>/dev/null; } || { init_bad=1; cat "$tmp/out"; }
done
rm -r .claude
[ "$init_bad" = 0 ] && ok "init refuses an unknown tickets value and creates nothing" || bad "init refuses an unknown tickets value and creates nothing"
# init: .10x/ is excluded before anything is written there
expect "init with an id" 0 10x-worktree init T0
head -n 1 "$tmp/out" >"$tmp/init-id.first"
# out_is <expected> <real-path expected> — the output is one of the two forms of a path under $tmp (macOS: /var vs /private/var).
out_is() { [ "$(cat "$tmp/out")" = "$1" ] || [ "$(cat "$tmp/out")" = "$2" ]; }
rp="$(cd "$tmp/repo" && pwd -P)"
out_is "$(printf 'tickets: files\nticket dir: %s\nbase: main (origin/main)' "$tmp/repo/.10x/T0")" "$(printf 'tickets: files\nticket dir: %s\nbase: main (origin/main)' "$rp/.10x/T0")" \
  && ok "init prints the ticket dir and the base" || { bad "init prints the ticket dir and the base"; cat "$tmp/out"; }
echo plan >.10x/T0/plan.md
[ -z "$(git status --porcelain)" ] && ok "ticket files stay out of git before any worktree" || bad "ticket files stay out of git before any worktree"
[ ! -e .10x/drafts ] && ok "init <id> does not create drafts/" || bad "init <id> does not create drafts/"
expect "init without an id" 0 10x-worktree init
[ -d .10x/drafts ] && ok "init creates drafts/" || bad "init creates drafts/"
! grep -q '^ticket dir: \|^base: ' "$tmp/out" && ok "init without an id prints no ticket dir or base" || bad "init without an id prints no ticket dir or base"
grep -qxF 'forms: none' "$tmp/out" && ! grep -q '^form: ' "$tmp/out" && ok "init prints forms: none without issue forms" || bad "init prints forms: none without issue forms"
{ grep -qxF "drafts: $tmp/repo/.10x/drafts" "$tmp/out" || grep -qxF "drafts: $(cd "$tmp/repo" && pwd -P)/.10x/drafts" "$tmp/out"; } &&
  [ "$(sed -n 2p "$tmp/out")" = "$(grep '^drafts: ' "$tmp/out")" ] && ok "init prints the absolute drafts path" || bad "init prints the absolute drafts path"
[ "$(cat "$tmp/init-id.first")" = "tickets: files" ] && [ "$(head -n 1 "$tmp/out")" = "tickets: files" ] &&
  ok "init prints tickets: first, with and without an id" || { bad "init prints tickets: first, with and without an id"; cat "$tmp/init-id.first" "$tmp/out"; }
want_banned="banned: $(node -e 'const p = require("fs").readFileSync(process.argv[1], "utf8").split("\n").map((s) => s.trim()).filter((s) => s && s[0] !== "#"); console.log(JSON.stringify(p))' "$BIN/../references/banned-phrases.txt")"
[ "$(tail -1 "$tmp/out")" = "$want_banned" ] && grep -qF '"handle edge cases"' "$tmp/out" && ok "init prints the banned phrases" || { bad "init prints the banned phrases"; cat "$tmp/out"; }
expect "issue-form listing exits 2 without the banned file" 2 node "$BIN/../scripts/issue-form.js" "$tmp/repo" "$tmp/no-banned.txt"
grep -qF "$tmp/no-banned.txt is missing" "$tmp/out" && ok "issue-form listing names the missing banned file" || bad "issue-form listing names the missing banned file"
# init with forms: a temporary .github/ISSUE_TEMPLATE/, removed before anything else runs
it="$tmp/repo/.github/ISSUE_TEMPLATE"
mkdir -p "$it"
printf 'name: Bug report\ndescription: d\ntitle: "[Bug]: "\nlabels: [bug, "triage"]\nbody:\n  - type: markdown\n    attributes:\n      value: hi\n  - type: textarea\n    attributes:\n      label: What happens\n    validations:\n      required: true\n  - type: input\n    attributes:\n      label: Version, "commit"\n' >"$it/bug.yml"
printf 'labels: enhancement, docs\nbody:\n  - type: textarea\n    attributes:\n      label: Problem\n' >"$it/feat.yaml"
printf 'name: x\nbody:\n\t- type: textarea\n' >"$it/broken.yml"
printf 'name: x\nbody:\n  - type: textarea\n    attributes:\n      description: no label\n' >"$it/nolabel.yml"
printf 'title: |\n  multi\nbody:\n  - type: textarea\n    attributes:\n      label: X\n' >"$it/blocktitle.yml"
printf 'name: SECRET\nbody:\n  - type: textarea\n    attributes:\n      label: SECRET\n' >"$tmp/outside.yml"
ln -s "$tmp/outside.yml" "$it/link.yml"
printf 'blank_issues_enabled: false\n' >"$it/config.yml"
printf -- '---\nname: t\n---\n## Steps\n' >"$it/tpl.md"
ln -s "$tmp/outside.yml" "$it/linked.md"
expect "init with issue forms" 0 10x-worktree init
grep '^form' "$tmp/out" >"$tmp/forms"
printf '%s\n' \
  'form: blocktitle.yml error: "title is a block scalar"' \
  'form: broken.yml error: "line 3: tab indentation"' \
  'form: bug.yml name: "Bug report" labels: ["bug","triage"] title: "[Bug]: " required: ["What happens"] fields: ["What happens","Version, \"commit\""]' \
  'form: feat.yaml name: none labels: ["enhancement","docs"] title: none required: [] fields: ["Problem"]' \
  'form: link.yml error: "symlink or not a regular file"' \
  'form: nolabel.yml error: "a textarea field has no attributes.label"' >"$tmp/forms-want"
grep -E '^form: (bug\.yml|feat\.yaml) ' "$tmp/forms" | cmp -s - <(grep -E '^form: (bug\.yml|feat\.yaml) ' "$tmp/forms-want") &&
  ! grep -q 'config\.yml\|^forms: none' "$tmp/out" && ok "init lists each issue form with labels, title, required and fields" ||
  { bad "init lists each issue form with labels, title, required and fields"; diff "$tmp/forms-want" "$tmp/forms"; }
cmp -s "$tmp/forms" "$tmp/forms-want" && grep -qxF 'template: tpl.md' "$tmp/out" &&
  grep -qxF 'template: linked.md error: "symlink or not a regular file"' "$tmp/out" &&
  ok "init reports a form it cannot read and exits 0" || { bad "init reports a form it cannot read and exits 0"; diff "$tmp/forms-want" "$tmp/forms"; }
grep -qxF 'form: link.yml error: "symlink or not a regular file"' "$tmp/out" && ! grep -q SECRET "$tmp/out" &&
  ok "init never follows a symlinked form" || bad "init never follows a symlinked form"
rm -r "$tmp/repo/.github" "$tmp/outside.yml"
mkdir -p "$tmp/elsewhere/ISSUE_TEMPLATE"
printf 'name: SECRET\nbody:\n  - type: input\n    attributes:\n      label: X\n' >"$tmp/elsewhere/ISSUE_TEMPLATE/x.yml"
ln -s "$tmp/elsewhere" "$tmp/repo/.github"
expect "init with a symlinked .github" 0 10x-worktree init
grep -qxF 'forms: none' "$tmp/out" && ! grep -q SECRET "$tmp/out" &&
  ok "init never follows a symlinked .github" || bad "init never follows a symlinked .github"
rm "$tmp/repo/.github"; rm -r "$tmp/elsewhere"

# worktree
expect "worktree add" 0 10x-worktree add T1 --slug mul
# has_lines <id> <base line> — the output's first two lines are the ticket dir (either path form) and the base.
has_lines() {
  { [ "$(sed -n 1p "$tmp/out")" = "ticket dir: $tmp/repo/.10x/$1" ] || [ "$(sed -n 1p "$tmp/out")" = "ticket dir: $rp/.10x/$1" ]; } &&
    [ "$(sed -n 2p "$tmp/out")" = "$2" ]
}
has_lines T1 "base: main (origin/main)" && grep -q '^created: ' "$tmp/out" \
  && ok "add prints the ticket dir and the base when it creates the worktree" || { bad "add prints the ticket dir and the base when it creates the worktree"; cat "$tmp/out"; }
wt="$tmp/repo/.worktrees/T1"
[ -e "$wt/.git" ] && ok "worktree exists" || bad "worktree exists"
[ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" = feat/T1-mul ] && ok "branch name" || bad "branch name"
grep -qxF '/.10x/' .git/info/exclude && grep -qxF '/.worktrees/' .git/info/exclude && ok "excluded locally" || bad "excluded locally"
[ -z "$(git status --porcelain)" ] && ok "main checkout stays clean" || bad "main checkout stays clean"
[ -z "$(git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" ] && ok "new branch has no upstream" || bad "new branch has no upstream"
expect "worktree add is re-runnable" 0 10x-worktree add T1
has_lines T1 "base: main (origin/main)" && grep -q '^exists: ' "$tmp/out" \
  && ok "add prints the ticket dir and the base when the worktree exists" || { bad "add prints the ticket dir and the base when the worktree exists"; cat "$tmp/out"; }
git push -q origin main:release
mkdir -p .claude && echo '{"base":"release"}' >.claude/10x.json
expect "worktree add with a configured base" 0 10x-worktree add TB --no-setup
has_lines TB "base: release (origin/release)" && ok "add prints a configured base" || { bad "add prints a configured base"; cat "$tmp/out"; }
10x-worktree rm TB >/dev/null
rm -r .claude
git push -q origin --delete release
expect "worktree path" 0 10x-worktree path T1
expect "bad id rejected" 2 10x-worktree add "../x"

# a change with a real test
echo 'export const mul = (a, b) => a * b' >"$wt/src/mul.mjs"
cat >"$wt/src/mul.test.mjs" <<'EOF'
import { test } from 'node:test'
import assert from 'node:assert'
import { mul } from './mul.mjs'
test('mul', () => assert.equal(mul(2, 3), 6))
EOF
git -C "$wt" add -A && git -C "$wt" commit -qm "feat: add mul"

expect "verify passes" 0 10x-verify T1
grep -q '^test ' .10x/T1/verify/summary.txt && ok "verify ran package.json test" || bad "verify ran package.json test"
expect "red-proof: real test goes red" 0 10x-red-proof T1
grep -q '^RED ' "$tmp/out" && ok "red-proof reports RED" || bad "red-proof reports RED"
[ -z "$(git -C "$wt" status --porcelain)" ] && [ -f "$wt/src/mul.mjs" ] && ok "red-proof restored the tree" || bad "red-proof restored the tree"

# a test that does not test the change
cat >"$wt/src/noop.test.mjs" <<'EOF'
import { test } from 'node:test'
import assert from 'node:assert'
test('noop', () => assert.equal(1, 1))
EOF
echo 'export const sub = (a, b) => a - b' >"$wt/src/sub.mjs"
git -C "$wt" add -A && git -C "$wt" commit -qm "feat: add sub"
expect "red-proof: unrelated test stays green" 1 10x-red-proof T1
grep -q '^GREEN  src/noop.test.mjs' "$tmp/out" && ok "red-proof names the green file" || bad "red-proof names the green file"

echo dirty >"$wt/scratch.txt"
expect "red-proof refuses a dirty tree" 2 10x-red-proof T1
expect "verify passes on a dirty tree that stands still" 0 10x-verify T1
rm "$wt/scratch.txt"

# agent memory written into the worktree while red-proof runs is neither a dirty tree nor reverted
m1="$wt/.claude/agent-memory/10x-x"
mkdir -p "$m1" && echo committed >"$m1/kept.md" && git -C "$wt" add .claude && git -C "$wt" commit -qm "chore(memory): x"
echo edited >"$m1/kept.md"; echo new >"$m1/new.md"
expect "red-proof runs with uncommitted agent memory" 1 10x-red-proof T1
grep -q '^GREEN  src/noop.test.mjs' "$tmp/out" && [ "$(cat "$m1/kept.md")" = edited ] && [ -f "$m1/new.md" ] && ok "red-proof leaves agent memory alone" || bad "red-proof leaves agent memory alone"
git -C "$wt" checkout -q -- .claude/agent-memory; rm "$m1/new.md"

# a failing gate
echo 'export const mul = (a, b) => a + b' >"$wt/src/mul.mjs"
git -C "$wt" commit -qam "break mul"
expect "verify fails on a red test" 1 10x-verify T1
grep -q FAIL .10x/T1/verify/summary.txt && ok "summary shows FAIL" || bad "summary shows FAIL"
head=$(git -C "$wt" rev-parse HEAD)
expect "red-proof refuses a test that fails at HEAD" 2 10x-red-proof T1
grep -q 'src/mul.test.mjs: fails' "$tmp/out" && ok "red-proof names the file failing at HEAD" || bad "red-proof names the file failing at HEAD"
[ -z "$(git -C "$wt" status --porcelain)" ] && [ "$(git -C "$wt" rev-parse HEAD)" = "$head" ] && ok "tree untouched after the HEAD refusal" || bad "tree untouched after the HEAD refusal"

# a runner red-proof does not detect (mocha globals) falls through to node --test and cannot pass at HEAD
expect "worktree add T5" 0 10x-worktree add T5 --no-setup
wt5="$tmp/repo/.worktrees/T5"
echo 'export const div = (a, b) => a / b' >"$wt5/src/div.mjs"
cat >"$wt5/src/div.test.mjs" <<'EOF'
import assert from 'node:assert'
import { div } from './div.mjs'
describe('div', () => { it('divides', () => assert.equal(div(6, 3), 2)) })
EOF
git -C "$wt5" add -A && git -C "$wt5" commit -qm "feat: add div"
expect "red-proof refuses an unsupported runner" 2 10x-red-proof T5
grep -q 'src/div.test.mjs: fails' "$tmp/out" && ok "red-proof names the unsupported file" || bad "red-proof names the unsupported file"
[ -z "$(git -C "$wt5" status --porcelain)" ] && [ -f "$wt5/src/div.mjs" ] && ok "tree untouched for an unsupported runner" || bad "tree untouched for an unsupported runner"
expect "rm T5" 0 10x-worktree rm T5

# config gates
mkdir -p .claude
echo '{ "gates": ["true", "echo gate-two"] }' >.claude/10x.json
expect "verify uses configured gates" 0 10x-verify T1
grep -q 'gate-two' .10x/T1/verify/summary.txt && ok "configured gate listed" || bad "configured gate listed"
echo '{ "gates": ["touch moved.txt"] }' >.claude/10x.json
expect "verify fails when a gate moves the tree" 1 10x-verify T1
grep -q '^MOVED' .10x/T1/verify/summary.txt && ok "summary says MOVED" || bad "summary says MOVED"
rm "$wt/moved.txt"
echo '{ "gates": ["mkdir -p .claude/agent-memory/10x-y && echo n >.claude/agent-memory/10x-y/n.md"] }' >.claude/10x.json
expect "verify passes when a gate writes agent memory" 0 10x-verify T1
! grep -q '^MOVED' .10x/T1/verify/summary.txt && ok "agent memory does not move the tree" || bad "agent memory does not move the tree"
rm "$wt/.claude/agent-memory/10x-y/n.md"

# review packet
expect "review packet" 0 10x-review-packet T1
grep -q 'src/mul.mjs' .10x/T1/review-packet.md && [ -s .10x/T1/review.diff ] && ok "packet lists changes" || bad "packet lists changes"
grep -q 'gates already ran' .10x/T1/review-packet.md && ok "packet carries the verify summary" || bad "packet carries the verify summary"
[ "$(cat .10x/T1/review-head)" = "$(git -C "$wt" rev-parse HEAD)" ] && ok "packet records the reviewed head" || bad "packet records the reviewed head"

# fixes packet: only the commits since the reviewed head, with the last round's findings
expect "fixes packet refuses without review.md" 2 10x-review-packet T1 --fixes
printf '# T1 — review\n\n- [minor] unnumbered-finding\n' >.10x/T1/review.md
expect "fixes packet refuses a review.md without rounds" 2 10x-review-packet T1 --fixes
grep -q 'Round <n>' "$tmp/out" && ok "refusal names the round heading" || bad "refusal names the round heading"
printf '## Round 1 — full\n\nVerdict: x\n\n- [minor] round-one-finding\n\n### Fixes applied\n\n- round-one-account\n\n## Round 2 — fixes\n\nVerdict: y\n' >.10x/T1/review.md
expect "fixes packet refuses after a fixes round" 2 10x-review-packet T1 --fixes
grep -q 'already a fixes review' "$tmp/out" && ok "refusal says the fixes are not reviewed again" || bad "refusal says the fixes are not reviewed again"
printf '\n## Round 3 — full\n\nVerdict: z\nCriteria: AC1\n\n#### [minor] round-three-finding\n\n### Plan checks\n\nnone\n\n### Decisions\n\n- decision-three\n\n### Fixes applied\n\n- implementer-account\n\n#### nested-heading\n\nnested-fix-text\n' >>.10x/T1/review.md
expect "fixes packet with no fix commits" 3 10x-review-packet T1 --fixes
[ ! -e .10x/T1/fixes-packet.md ] && ok "no fixes packet without fix commits" || bad "no fixes packet without fix commits"
echo 'export const sq = (a) => a * a' >"$wt/src/sq.mjs"
mkdir -p "$wt/.claude/agent-memory/10x-y" && echo 'memory-note' >"$wt/.claude/agent-memory/10x-y/n.md"
git -C "$wt" add src/sq.mjs .claude/agent-memory && git -C "$wt" commit -qm "fix: add sq"
expect "fixes packet" 0 10x-review-packet T1 --fixes
grep -q 'src/sq.mjs' .10x/T1/fixes.diff && ! grep -q 'src/mul.mjs' .10x/T1/fixes.diff && ok "fixes diff holds only the fix commits" || bad "fixes diff holds only the fix commits"
fp=.10x/T1/fixes-packet.md
grep -q '^## Round 3 findings — what these commits respond to' "$fp" && grep -q 'round-three-finding' "$fp" && ! grep -qE 'round-one|unnumbered-finding' "$fp" && ok "fixes packet quotes only the last round" || bad "fixes packet quotes only the last round"
grep -q 'decision-three' "$fp" && ! grep -qE 'implementer-account|nested-heading|nested-fix-text' "$fp" && ok "fixes packet leaves out the round's Fixes applied and keeps its Decisions" || bad "fixes packet leaves out the round's Fixes applied and keeps its Decisions"
grep -qF -- '- range: round 3 reviewed up to' "$fp" && ok "fixes packet names the round" || bad "fixes packet names the round"
no_memory_section() { awk '/^## Agent memory/ { s = 1; next } /^## / { s = 0 } !s' "$1"; }
! grep -q 'agent-memory' .10x/T1/review.diff .10x/T1/fixes.diff && ! no_memory_section .10x/T1/review-packet.md | grep -q 'agent-memory' && ! no_memory_section "$fp" | grep -q 'agent-memory' && ok "packets leave agent memory out" || bad "packets leave agent memory out"
grep -q '10x-x/kept.md' .10x/T1/review-packet.md && grep -q '10x-y/n.md' "$fp" && ok "packets list the commits that touch agent memory" || bad "packets list the commits that touch agent memory"
grep -q 'src/mul.mjs' .10x/T1/review.diff && ok "full diff kept" || bad "full diff kept"
expect "packet rejects an unknown flag" 2 10x-review-packet T1 --nope
git -C "$wt" rev-parse HEAD >.10x/T1/review-head
git -C "$wt" commit -q --amend -m "fix: add sq (amended)"
expect "fixes packet off a rewritten history" 2 10x-review-packet T1 --fixes

# red-proof with a declared runner (no package.json), pre-review gates
expect "worktree add RP1" 0 10x-worktree add RP1 --no-setup
wtrp="$tmp/repo/.worktrees/RP1"
git -C "$wtrp" rm -q package.json
echo 'val() { echo 42; }' >"$wtrp/lib.sh"
mkdir "$wtrp/tests"
printf '%s\n' '. "$(dirname "$0")/../lib.sh"' '[ "$(val)" = 42 ]' >"$wtrp/tests/a.test.sh"
printf '%s\n' '[ 1 = 1 ]' >"$wtrp/tests/b.test.sh"
git -C "$wtrp" add -A && git -C "$wtrp" commit -qm "feat: val"
echo '{}' >.claude/10x.json
expect "red-proof: no package.json and no redProof is unsupported" 2 10x-red-proof RP1
grep -q 'redProof.command' "$tmp/out" && grep -q 'redProof.tests' "$tmp/out" && ok "unsupported message names redProof.command and redProof.tests" || bad "unsupported message names redProof.command and redProof.tests"
echo '{ "redProof": { "command": "bash {file}" } }' >.claude/10x.json
expect "red-proof: redProof.command without redProof.tests" 2 10x-red-proof RP1
grep -q 'redProof.tests' "$tmp/out" && ok "names the missing redProof.tests" || bad "names the missing redProof.tests"
echo '{ "redProof": { "command": "bash tests/a.test.sh", "tests": ["tests/*.test.sh"] } }' >.claude/10x.json
expect "red-proof: command without {file}" 2 10x-red-proof RP1
grep -q '{file} placeholder' "$tmp/out" && ok "names the missing {file}" || bad "names the missing {file}"
echo '{ "redProof": { "command": "bash {file}", "tests": ["tests/*.test.sh"] } }' >.claude/10x.json
expect "red-proof: shell tests, one stays green" 1 10x-red-proof RP1
grep -q '^RED    tests/a.test.sh' "$tmp/out" && ok "red-proof: shell test goes RED" || bad "red-proof: shell test goes RED"
grep -q '^GREEN  tests/b.test.sh' "$tmp/out" && ok "red-proof: shell test stays GREEN" || bad "red-proof: shell test stays GREEN"
[ -z "$(git -C "$wtrp" status --porcelain)" ] && [ -f "$wtrp/lib.sh" ] && ok "red-proof restored the tree (command mode)" || bad "red-proof restored the tree (command mode)"
git -C "$wtrp" rm -q tests/b.test.sh && git -C "$wtrp" commit -qm "test: drop b"
expect "red-proof: shell test goes RED" 0 10x-red-proof RP1
expect "rm RP1" 0 10x-worktree rm RP1

# 10x-test: node --test on the changed test files, or on the files given; the tree is left as it is
echo '{}' >.claude/10x.json
expect "worktree add VT" 0 10x-worktree add VT --no-setup
wtv="$tmp/repo/.worktrees/VT"
pass_test() { printf '%s\n' "import { test } from 'node:test'" "import assert from 'node:assert'" "test('ok', () => assert.equal(1, 1))" >"$1"; }
pass_test "$wtv/src/a.test.mjs"; echo 'export const c = 1' >"$wtv/src/c.mjs"
git -C "$wtv" add -A && git -C "$wtv" commit -qm "test: a"
pass_test "$wtv/src/s.test.mjs"; git -C "$wtv" add src/s.test.mjs
mkdir "$wtv/src/new"; pass_test "$wtv/src/new/u.test.mjs"
st_before="$(git -C "$wtv" status --porcelain)"
10x-test VT >"$tmp/out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(head -n 1 "$tmp/out")" = "VT · 10x-test · runner: node-test · 3 file(s)" ] &&
  [ "$(grep -E '^(pass|FAIL) ' "$tmp/out")" = "$(printf 'pass src/a.test.mjs\npass src/new/u.test.mjs\npass src/s.test.mjs')" ] &&
  [ "$(git -C "$wtv" status --porcelain)" = "$st_before" ] && [ ! -e .10x/VT/lock ] &&
  ok "10x-test: runs the changed and untracked test files" || { bad "10x-test: runs the changed and untracked test files"; cat "$tmp/out"; }
printf '%s\n' "import { test } from 'node:test'" "import assert from 'node:assert'" "test('no', () => assert.equal(1, 2))" >"$wtv/src/f.test.mjs"
10x-test VT >"$tmp/out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -qxF 'FAIL src/f.test.mjs' "$tmp/out" && grep -qxF 'pass src/a.test.mjs' "$tmp/out" &&
  ok "10x-test: a failing test exits 1" || { bad "10x-test: a failing test exits 1 (exit $rc)"; cat "$tmp/out"; }
rm "$wtv/src/f.test.mjs"
10x-test VT src/new/u.test.mjs src/c.mjs src/new/u.test.mjs >"$tmp/out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(head -n 1 "$tmp/out")" = "VT · 10x-test · runner: node-test · 2 file(s)" ] &&
  [ "$(grep -E '^(pass|FAIL) ' "$tmp/out")" = "$(printf 'pass src/new/u.test.mjs\npass src/c.mjs')" ] &&
  ok "10x-test: runs only the files given" || { bad "10x-test: runs only the files given"; cat "$tmp/out"; }
vt_out=0
for arg in ../VT/src/a.test.mjs src/../../x.test.mjs "$wtv/src/a.test.mjs" src/missing.test.mjs; do
  10x-test VT src/a.test.mjs "$arg" >"$tmp/out" 2>&1; rc=$?
  { [ "$rc" = 2 ] && grep -qF -- "$arg" "$tmp/out" && ! grep -q '^pass ' "$tmp/out"; } || { vt_out=1; echo "      $arg: exit $rc"; cat "$tmp/out"; }
done
[ "$vt_out" = 0 ] && ok "10x-test: refuses a path outside the worktree" || bad "10x-test: refuses a path outside the worktree"
expect "worktree add VT2" 0 10x-worktree add VT2 --no-setup
echo 'export const d = 1' >"$tmp/repo/.worktrees/VT2/src/d.mjs"
10x-test VT2 >"$tmp/out" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -qF 'VT2: no changed test file — name the files to run' "$tmp/out" &&
  ok "10x-test: no test file exits 2" || { bad "10x-test: no test file exits 2 (exit $rc)"; cat "$tmp/out"; }
rm "$tmp/repo/.worktrees/VT2/src/d.mjs"
expect "rm VT2" 0 10x-worktree rm VT2
mkdir .10x/VT/lock
10x-test VT src/a.test.mjs >"$tmp/out" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -qF "ticket VT's tree is in use by 10x-verify, 10x-red-proof or 10x-test" "$tmp/out" && ! grep -q '^pass ' "$tmp/out" && [ -d .10x/VT/lock ] &&
  ok "10x-test: refuses while the ticket lock is held" || { bad "10x-test: refuses while the ticket lock is held (exit $rc)"; cat "$tmp/out"; }
rmdir .10x/VT/lock
git -C "$wtv" rm -qf src/s.test.mjs; rm -r "$wtv/src/new"
expect "rm VT" 0 10x-worktree rm VT

# 10x-test with a declared runner: each changed file matching redProof.tests, through redProof.command
expect "worktree add VC" 0 10x-worktree add VC --no-setup
wtc="$tmp/repo/.worktrees/VC"
git -C "$wtc" rm -q package.json
mkdir "$wtc/tests"
printf '%s\n' '[ 1 = 1 ]' >"$wtc/tests/a.test.sh"
printf '%s\n' 'exit 0' >"$wtc/tests/helper.sh"
git -C "$wtc" add -A && git -C "$wtc" commit -qm "test: a"
printf '%s\n' 'echo b-ran; [ 1 = 2 ]' >"$wtc/tests/b test.test.sh"
echo '{ "redProof": { "command": "bash {file}", "tests": ["tests/*.test.sh"] } }' >.claude/10x.json
10x-test VC >"$tmp/out" 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(head -n 1 "$tmp/out")" = "VC · 10x-test · runner: custom · 2 file(s)" ] && grep -qxF 'b-ran' "$tmp/out" &&
  [ "$(grep -E '^(pass|FAIL) ' "$tmp/out")" = "$(printf 'pass tests/a.test.sh\nFAIL tests/b test.test.sh')" ] &&
  ok "10x-test: redProof.command runs each file" || { bad "10x-test: redProof.command runs each file (exit $rc)"; cat "$tmp/out"; }
rm "$wtc/tests/b test.test.sh"
expect "rm VC" 0 10x-worktree rm VC

git -C "$wt" rev-parse HEAD >.10x/T1/review-head
rh="$(cat .10x/T1/review-head)"
echo '{ "preReviewGates": ["echo gate-ran", "echo gate-broke-it; false"] }' >.claude/10x.json
rm -f .10x/T1/review-packet.md
expect "packet refused by a failing pre-review gate" 1 10x-review-packet T1
grep -q 'gate-broke-it; false' "$tmp/out" && grep -q '^gate-broke-it' "$tmp/out" && ok "refusal names the gate and tails its log" || bad "refusal names the gate and tails its log"
[ ! -e .10x/T1/review-packet.md ] && [ "$(cat .10x/T1/review-head)" = "$rh" ] && ok "no packet, review-head untouched" || bad "no packet, review-head untouched"
rm .10x/T1/review-head
expect "packet refused by a failing pre-review gate (no review-head written)" 1 10x-review-packet T1
[ ! -e .10x/T1/review-head ] && ok "no review-head written" || bad "no review-head written"
echo "$rh" >.10x/T1/review-head
git -C "$wt" commit -q --allow-empty -m "fix: empty"
rm -f .10x/T1/fixes-packet.md
expect "fixes packet refused by a failing pre-review gate" 1 10x-review-packet T1 --fixes
grep -q 'gate-broke-it; false' "$tmp/out" && [ ! -e .10x/T1/fixes-packet.md ] && ok "fixes: gate named, no packet" || bad "fixes: gate named, no packet"
echo '{ "preReviewGates": ["echo gate-ran"] }' >.claude/10x.json
expect "packet builds when the pre-review gate passes" 0 10x-review-packet T1
[ -s .10x/T1/review-packet.md ] && ok "packet written after the gate passed" || bad "packet written after the gate passed"

# packet: plan checks against the whole branch, and the security review line
mkdir -p skills/s skills/t bin hooks
printf -- '---\nname: s\nallowed-tools:\n  - Bash(tool-a *)\n---\n\n# S\n\nbody line\n' >skills/s/SKILL.md
printf -- '---\nname: t\ndescription: t\nallowed-tools: Bash(tool-c:*) Bash(git status:*)\n---\n\n# T\n' >skills/t/SKILL.md
printf '#!/bin/bash\n' | tee bin/tool-a bin/tool-b bin/tool-c >/dev/null
printf '{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "node \\"${CLAUDE_PLUGIN_ROOT}/hooks/h.js\\"" } ] } ] } }\n' >hooks/hooks.json
mkdir -p skills/u scripts
printf -- '---\nname: u\nallowed-tools: Bash(10x-land *)\n---\n\n# U\n' >skills/u/SKILL.md
cat >bin/10x-land <<'EOF'
#!/bin/bash
source "$(dirname "$(readlink -f "$0")")/../scripts/lib.sh"
source "$dir/dynamic.sh"
source "$(dirname "$0")/../../outside.sh"
EOF
echo 'source "$(dirname "$(readlink -f "$0")")/deep.sh"' >scripts/lib.sh
for f in scripts/deep.sh scripts/dynamic.sh scripts/other.sh scripts/md-check.js hooks/helper.js; do echo '# x' >"$f"; done
cat >hooks/h.js <<'EOF'
// h
require(path.join(__dirname, '..', 'scripts', 'md-check.js'))
require('./helper')
require('./missing')
require(p)
EOF
echo 'export const keptTerm = 1' >src/keep.mjs
echo '- oldTerm was renamed' >CHANGELOG.md
git add skills bin hooks scripts src/keep.mjs CHANGELOG.md && git commit -qm "chore: packet fixtures" && git push -q origin main
expect "worktree add PK" 0 10x-worktree add PK --no-setup
wpk="$tmp/repo/.worktrees/PK"
mkdir -p .10x/PK "$wpk/tests"
cat >.10x/PK/plan.md <<'EOF'
# PK — fixture

## Acceptance criteria
- AC1 — one
- AC2 — two
- AC3 — three

## Readers
- `keptTerm` — `grep -rn keptTerm .` (gone)
  - `src/keep.mjs:1` — renamed.
- `oldTerm` — `grep -rn oldTerm .` (gone)
  - `CHANGELOG.md:1` — history; stays.
- `newTerm` — `grep -rn newTerm .` (gone)
  - no hits
- `add` — `grep -rn add .`
  - `src/math.mjs:1` — stays.

## Tests
| AC | Test file | Case |
|---|---|---|
| AC1 | `tests/a.test.sh` | `case one` |
| AC2 | `tests/a.test.sh` | `case two` |
| AC3 | — | read the diff |
EOF
echo 'ok "case one"' >"$wpk/tests/a.test.sh"
echo 'export const newTerm = 2' >"$wpk/src/new.mjs"
git -C "$wpk" add -A && git -C "$wpk" commit -qm "feat: case one"
pk=.10x/PK/review-packet.md
plan_checks_in() { awk '/^## Plan checks/ { on = 1; next } on && /^## / { exit } on && NF' "$1"; }
expect "packet PK, round 1" 0 10x-review-packet PK
plan_checks_in "$pk" | grep -qxF -- '- test case `case two` (AC2) is not among the lines `tests/a.test.sh` adds' && ! plan_checks_in "$pk" | grep -q 'case one' &&
  ok "packet lists a test case missing from the diff" || { bad "packet lists a test case missing from the diff"; cat "$pk"; }
plan_checks_in "$pk" | grep -qxF -- '- gone term `keptTerm` still at `src/keep.mjs:1`' && ! plan_checks_in "$pk" | grep -qE 'newTerm|`add`' &&
  ok "packet lists a gone term still present" || { bad "packet lists a gone term still present"; cat "$pk"; }
plan_checks_in "$pk" | grep -q 'keptTerm' && ! plan_checks_in "$pk" | grep -q 'oldTerm' && ok "packet ignores a gone term in the changelog" || bad "packet ignores a gone term in the changelog"
! grep -q 'security review' "$pk" && ok "packet does not require security review otherwise" || bad "packet does not require security review otherwise"
echo 'ok "case two"' >>"$wpk/tests/a.test.sh"
echo 'export const kept = 1' >"$wpk/src/keep.mjs"
git -C "$wpk" commit -qam "feat: case two"
expect "packet PK, round 1 again" 0 10x-review-packet PK
[ "$(plan_checks_in "$pk")" = none ] && ok "packet lists no plan checks when all are met" || { bad "packet lists no plan checks when all are met"; cat "$pk"; }
printf '## Round 1 — full\n\nVerdict: x\n' >.10x/PK/review.md
echo 'export const fix = 1' >"$wpk/src/fix.mjs"
git -C "$wpk" add -A && git -C "$wpk" commit -qm "fix: fix"
expect "fixes packet PK" 0 10x-review-packet PK --fixes
! grep -q 'tests/a.test.sh' .10x/PK/fixes.diff && [ "$(plan_checks_in .10x/PK/fixes-packet.md)" = none ] &&
  ok "fixes packet checks the plan against the whole branch" || { bad "fixes packet checks the plan against the whole branch"; cat .10x/PK/fixes-packet.md; }
! grep -q 'security review' .10x/PK/fixes-packet.md && ok "fixes packet: no security review for src/ alone" || bad "fixes packet: no security review for src/ alone"
for b in tool-a tool-b tool-c; do echo '# changed' >>"$wpk/bin/$b"; done
git -C "$wpk" commit -qam "feat: tools"
expect "packet PK with bin changes" 0 10x-review-packet PK
sec() { grep '^- security review: required (' "$1"; }
sec "$pk" | grep -qF 'bin/tool-a is in the allowed-tools of skills/s/SKILL.md' && sec "$pk" | grep -qF 'bin/tool-c is in the allowed-tools of skills/t/SKILL.md' && ! sec "$pk" | grep -q 'tool-b' &&
  ok "packet requires security review for an allowed-tools script" || { bad "packet requires security review for an allowed-tools script"; cat "$pk"; }
fixes_after() { # <commit message> — mark HEAD reviewed, commit the worktree's changes, build the fixes packet
  git -C "$wpk" rev-parse HEAD >.10x/PK/review-head
  git -C "$wpk" commit -qam "$1"
  expect "fixes packet PK: $1" 0 10x-review-packet PK --fixes
}
echo '# changed' >>"$wpk/scripts/lib.sh"
fixes_after "fix: lib.sh"
[ "$(sec .10x/PK/fixes-packet.md)" = '- security review: required (scripts/lib.sh is loaded by bin/10x-land)' ] &&
  ok "packet requires security review for a file a granted script sources" || { bad "packet requires security review for a file a granted script sources"; cat .10x/PK/fixes-packet.md; }
echo '# changed' >>"$wpk/scripts/deep.sh"
fixes_after "fix: deep.sh"
! grep -q 'security review' .10x/PK/fixes-packet.md && ok "fixes packet: a file loaded by a loaded file needs no security review" || { bad "fixes packet: a file loaded by a loaded file needs no security review"; cat .10x/PK/fixes-packet.md; }
echo '# changed' >>"$wpk/scripts/dynamic.sh"
fixes_after "fix: dynamic.sh"
! grep -q 'security review' .10x/PK/fixes-packet.md && ok "packet ignores load paths it cannot resolve" || { bad "packet ignores load paths it cannot resolve"; cat .10x/PK/fixes-packet.md; }
echo '# changed' >>"$wpk/scripts/other.sh"
fixes_after "fix: other.sh"
! grep -q 'security review' .10x/PK/fixes-packet.md && ok "fixes packet: an unrelated scripts/ file needs no security review" || { bad "fixes packet: an unrelated scripts/ file needs no security review"; cat .10x/PK/fixes-packet.md; }
echo '# changed' >>"$wpk/scripts/md-check.js"
fixes_after "fix: md-check.js"
[ "$(sec .10x/PK/fixes-packet.md)" = '- security review: required (scripts/md-check.js is loaded by hooks/h.js)' ] &&
  ok "packet requires security review for a file a registered hook requires" || { bad "packet requires security review for a file a registered hook requires"; cat .10x/PK/fixes-packet.md; }
echo '# changed' >>"$wpk/hooks/helper.js"
fixes_after "fix: helper.js"
[ "$(sec .10x/PK/fixes-packet.md)" = '- security review: required (hooks/helper.js is loaded by hooks/h.js)' ] &&
  ok "packet resolves a relative require without its extension" || { bad "packet resolves a relative require without its extension"; cat .10x/PK/fixes-packet.md; }
printf -- '---\nname: s\nallowed-tools:\n  - Bash(tool-a *)\n---\n\n# S\n\nanother body line\n' >"$wpk/skills/s/SKILL.md"
fixes_after "docs: skill body"
! grep -q 'security review' .10x/PK/fixes-packet.md && ok "fixes packet: a skill body change needs no security review" || { bad "fixes packet: a skill body change needs no security review"; cat .10x/PK/fixes-packet.md; }
printf -- '---\nname: t\ndescription: t, changed\nallowed-tools: Bash(tool-c:*) Bash(git status:*)\n---\n\n# T\n' >"$wpk/skills/t/SKILL.md"
fixes_after "feat: skill frontmatter"
[ "$(sec .10x/PK/fixes-packet.md)" = '- security review: required (skills/t/SKILL.md: frontmatter changed)' ] &&
  ok "packet requires security review for a skill frontmatter change" || { bad "packet requires security review for a skill frontmatter change"; cat .10x/PK/fixes-packet.md; }
echo '// changed' >>"$wpk/hooks/h.js"
fixes_after "feat: hook script"
[ "$(sec .10x/PK/fixes-packet.md)" = '- security review: required (hooks/h.js is registered in hooks/hooks.json)' ] && h1=1 || h1=""
printf '{ "hooks": {} }\n' >"$wpk/hooks/hooks.json"
fixes_after "feat: hooks.json"
[ -n "$h1" ] && [ "$(sec .10x/PK/fixes-packet.md)" = '- security review: required (hooks/hooks.json changed)' ] &&
  ok "packet requires security review for a hook change" || { bad "packet requires security review for a hook change"; cat .10x/PK/fixes-packet.md; }
mkdir -p "$wpk/agents" && printf -- '---\nname: a\ntools: Read\n---\n\n# A\n' >"$wpk/agents/a.md" && git -C "$wpk" add agents/a.md
fixes_after "feat: agent"
printf -- '---\nname: a\ntools: Read, Bash\n---\n\n# A\n' >"$wpk/agents/a.md"
fixes_after "feat: agent tools"
[ "$(sec .10x/PK/fixes-packet.md)" = '- security review: required (agents/a.md: frontmatter changed)' ] &&
  ok "packet requires security review for an agent frontmatter change" || { bad "packet requires security review for an agent frontmatter change"; cat .10x/PK/fixes-packet.md; }
printf -- '\nanother body line\n' >>"$wpk/agents/a.md"
fixes_after "docs: agent body"
! grep -q 'security review' .10x/PK/fixes-packet.md && ok "fixes packet: an agent body change needs no security review" || { bad "fixes packet: an agent body change needs no security review"; cat .10x/PK/fixes-packet.md; }
expect "rm PK" 0 10x-worktree rm PK

# lock
mkdir .10x/T1/lock
expect "lock blocks a concurrent run" 2 10x-verify T1
rmdir .10x/T1/lock

# gates come from the ticket's worktree; changes against the base's list are reported
echo '{ "gates": ["echo gate-base", "echo gate-kept"] }' >.claude/10x.json
git add .claude/10x.json && git commit -qm "chore: gates" && git push -q origin main
expect "worktree add T7" 0 10x-worktree add T7 --no-setup
wt7="$tmp/repo/.worktrees/T7"
echo '{ "base": "nope", "gates": ["echo gate-kept", "echo gate-added"] }' >"$wt7/.claude/10x.json"
git -C "$wt7" commit -qam "chore: change gates"
expect "verify with the worktree's gates" 0 10x-verify T7
s7=.10x/T7/verify/summary.txt
grep -q '^echo gate-added ' "$s7" && ok "gate added in the worktree runs" || bad "gate added in the worktree runs"
! grep -q '^echo gate-base ' "$s7" && ok "gate removed in the worktree does not run" || bad "gate removed in the worktree does not run"
grep -qxF 'gates differ from origin/main:' "$s7" && ok "difference reported against the main checkout's base" || bad "difference reported against the main checkout's base"
grep -qxF '  + echo gate-added' "$s7" && grep -qxF '  - echo gate-base' "$s7" && ok "added and removed gates listed" || bad "added and removed gates listed"
! grep -q 'gate-kept' <(grep '^  [+-] ' "$s7") && ok "kept gate not listed" || bad "kept gate not listed"
echo '{ "gates": ["echo gate-base", "echo gate-kept", "echo gate-later"] }' >.claude/10x.json
git commit -qam "chore: base gains a gate" && git push -q origin main
expect "verify after the base gained a gate" 0 10x-verify T7
! grep -q 'gate-later' "$s7" && ok "gate added on the base after the cut not listed" || bad "gate added on the base after the cut not listed"
echo '{ "gates": ["echo gate-kept", "echo gate-base"] }' >"$wt7/.claude/10x.json"
git -C "$wt7" commit -qam "chore: reorder gates"
expect "verify with reordered gates" 0 10x-verify T7
! grep -q '^gates differ' "$s7" && ok "same gates in another order: no report" || bad "same gates in another order: no report"
expect "rm T7" 0 10x-worktree rm T7
git rm -q .claude/10x.json && git commit -qm "chore: drop gates" && git push -q origin main

# on 10x itself, verify lists the worktree's bin/ and scripts/ files that differ from the running copy
git -c init.defaultBranch=main init -q --bare "$tmp/self-origin.git"
git -c init.defaultBranch=main init -q "$tmp/self"
cd "$tmp/self" || exit 2
git config user.email t@t; git config user.name t
mkdir -p .claude-plugin .claude
echo '{ "name": "10x" }' >.claude-plugin/plugin.json
echo '{ "gates": ["echo gate-self"] }' >.claude/10x.json
cp -R "$BIN" bin && cp -R "$BIN/../scripts" scripts
git add -A && git commit -qm "init" && git remote add origin "$tmp/self-origin.git" && git push -q -u origin main
expect "worktree add on 10x itself" 0 10x-worktree add S1 --no-setup
wts="$tmp/self/.worktrees/S1"
ss=.10x/S1/verify/summary.txt
expect "verify with identical scripts" 0 10x-verify S1
! grep -q '^scripts differ' "$ss" && ok "identical scripts: no report" || bad "identical scripts: no report"
echo '# changed' >>"$wts/bin/10x-verify"; echo '# changed' >>"$wts/scripts/lib.sh"; echo '#!/bin/bash' >"$wts/bin/10x-extra"
git -C "$wts" add -A && git -C "$wts" commit -qm "feat: change scripts"
expect "verify with changed scripts" 0 10x-verify S1
grep -q '^scripts differ from the running copy (.*):$' "$ss" && ok "changed scripts reported" || bad "changed scripts reported"
[ "$(grep '^  [a-z]' "$ss")" = "$(printf '  bin/10x-extra\n  bin/10x-verify\n  scripts/lib.sh')" ] &&
  ok "changed, added and lib files listed, sorted" || { bad "changed, added and lib files listed, sorted"; cat "$ss"; }
grep -q '^echo gate-self .*pass' "$ss" && ok "gates still run with the report" || bad "gates still run with the report"
echo '{ "name": "other" }' >"$wts/.claude-plugin/plugin.json"
git -C "$wts" commit -qam "chore: another plugin"
expect "verify on another plugin" 0 10x-verify S1
! grep -q '^scripts differ' "$ss" && ok "another plugin's name: no report" || bad "another plugin's name: no report"
echo '{ broken' >"$wts/.claude-plugin/plugin.json"
git -C "$wts" commit -qam "chore: broken plugin.json"
expect "verify with a broken plugin.json" 0 10x-verify S1
! grep -q '^scripts differ' "$ss" && ok "broken plugin.json: no report" || bad "broken plugin.json: no report"
cd "$tmp/repo" || exit 2

# memory: agent memory from the main checkout and the worktree lands in one commit on the ticket branch
m=.claude/agent-memory/10x-a
mkdir -p "$m" && echo old >"$m/kept.md"
git add "$m" && git commit -qm "chore: memory" && git push -q origin main
expect "worktree add T8" 0 10x-worktree add T8 --no-setup
wt8="$tmp/repo/.worktrees/T8"
expect "memory: nothing to commit" 0 10x-worktree memory T8
grep -q 'no agent memory to commit' "$tmp/out" && [ "$(git -C "$wt8" rev-list --count HEAD)" = "$(git rev-list --count HEAD)" ] && ok "memory: no commit when nothing changed" || bad "memory: no commit when nothing changed"
echo new >"$m/new.md"; echo changed >"$m/kept.md"
mkdir -p "$wt8/.claude/agent-memory/10x-b" && echo wt >"$wt8/.claude/agent-memory/10x-b/MEMORY.md"
echo unrelated >"$wt8/unrelated.txt" && git -C "$wt8" add unrelated.txt
expect "memory: commit" 0 10x-worktree memory T8
git -C "$wt8" show --name-only --format= HEAD | sort >"$tmp/mem-files"
printf '%s\n' .claude/agent-memory/10x-a/kept.md .claude/agent-memory/10x-a/new.md .claude/agent-memory/10x-b/MEMORY.md >"$tmp/mem-want"
cmp -s "$tmp/mem-files" "$tmp/mem-want" && ok "memory: one commit with main checkout's and worktree's memory" || bad "memory: one commit with main checkout's and worktree's memory"
[ "$(git -C "$wt8" show HEAD:"$m/kept.md")" = changed ] && [ "$(git -C "$wt8" show HEAD:"$m/new.md")" = new ] && ok "memory: main checkout's content committed" || bad "memory: main checkout's content committed"
grep -qF "$m/new.md" "$tmp/out" && grep -qF "$m/kept.md" "$tmp/out" && grep -qF .claude/agent-memory/10x-b/MEMORY.md "$tmp/out" && ok "memory: committed paths printed" || bad "memory: committed paths printed"
[ -z "$(git status --porcelain -- .claude/agent-memory)" ] && [ ! -e "$m/new.md" ] && [ "$(cat "$m/kept.md")" = old ] && ok "memory: main checkout left clean" || bad "memory: main checkout left clean"
[ "$(git -C "$wt8" diff --cached --name-only)" = unrelated.txt ] && ok "memory: unrelated staged file left staged" || bad "memory: unrelated staged file left staged"
echo main-side >"$m/kept.md"; echo wt-side >"$wt8/$m/kept.md"
head8="$(git -C "$wt8" rev-parse HEAD)"
expect "memory: conflict stops" 2 10x-worktree memory T8
grep -qF "$m/kept.md" "$tmp/out" && [ "$(cat "$m/kept.md")" = main-side ] && [ "$(cat "$wt8/$m/kept.md")" = wt-side ] && [ "$(git -C "$wt8" rev-parse HEAD)" = "$head8" ] && ok "memory: conflict named, neither side touched, no commit" || bad "memory: conflict named, neither side touched, no commit"
git checkout -q -- "$m/kept.md"; git -C "$wt8" checkout -q -- "$m/kept.md"; git -C "$wt8" reset -q unrelated.txt; rm "$wt8/unrelated.txt"
echo secret >"$tmp/secret"; ln -s "$tmp/secret" "$m/link.md"
expect "memory: a symlink in the main checkout stops" 2 10x-worktree memory T8
grep -qF "$m/link.md" "$tmp/out" && [ -L "$m/link.md" ] && [ ! -e "$wt8/$m/link.md" ] && [ "$(git -C "$wt8" rev-parse HEAD)" = "$head8" ] && ok "memory: symlink named, nothing copied, no commit" || bad "memory: symlink named, nothing copied, no commit"
rm "$m/link.md"
mkdir "$tmp/outside" && ln -s "$tmp/outside" "$wt8/.claude/agent-memory/10x-c"
mkdir -p .claude/agent-memory/10x-c && echo x >.claude/agent-memory/10x-c/MEMORY.md
expect "memory: a symlinked directory in the worktree stops" 2 10x-worktree memory T8
[ -z "$(ls "$tmp/outside")" ] && [ -f .claude/agent-memory/10x-c/MEMORY.md ] && ok "memory: nothing written through the worktree's symlink" || bad "memory: nothing written through the worktree's symlink"
rm "$wt8/.claude/agent-memory/10x-c" .claude/agent-memory/10x-c/MEMORY.md; rmdir .claude/agent-memory/10x-c
echo branch-new >"$wt8/$m/kept.md" && git -C "$wt8" commit -qam "chore(memory): newer on the branch"
echo stale-edit >"$m/kept.md"
head8="$(git -C "$wt8" rev-parse HEAD)"
expect "memory: a main checkout copy edited from an older version stops" 2 10x-worktree memory T8
grep -qF "$m/kept.md" "$tmp/out" && [ "$(cat "$m/kept.md")" = stale-edit ] && [ "$(cat "$wt8/$m/kept.md")" = branch-new ] && [ "$(git -C "$wt8" rev-parse HEAD)" = "$head8" ] && ok "memory: newer branch copy kept, nothing moved" || bad "memory: newer branch copy kept, nothing moved"
git checkout -q -- "$m/kept.md"
expect "rm T8" 0 10x-worktree rm T8

# the tests half: red-proof --lock locks the tests ## Tests names; red-proof, the packet and check hold the lock
expect "worktree add TL" 0 10x-worktree add TL --no-setup
wtl="$tmp/repo/.worktrees/TL"
mkdir -p .10x/TL
printf '# TL — fixture\n\n## Tests\n| AC | Test file | Case |\n|---|---|---|\n| AC1 | `src/cube.test.mjs` | `cube` |\n| AC2 | — | read the diff |\n' >.10x/TL/plan.md
red_test() { # <file> [extra line] — a node:test file that fails until src/cube.mjs exports cube
  printf '%s\n' "import { test } from 'node:test'" "import assert from 'node:assert'" \
    "test('cube', async () => { const { cube } = await import('./cube.mjs'); assert.equal(cube(2), 8) })" ${2+"$2"} >"$wtl/$1"
}
commit_tl() { git -C "$wtl" add -A && git -C "$wtl" commit -qm "$1"; }
# refuses <case> <text> <args…> — 10x-red-proof exits 2 and its output names <text>
refuses() {
  local c=$1 want=$2; shift 2
  10x-red-proof "$@" >"$tmp/out" 2>&1; local rc=$?
  [ "$rc" = 2 ] && grep -qF -- "$want" "$tmp/out" && ok "$c" || { bad "$c (exit $rc)"; cat "$tmp/out"; }
}
red_test src/other.test.mjs; commit_tl "test: other"
refuses "red-proof --lock: refuses a Tests file the branch leaves out" src/cube.test.mjs TL --lock
red_test src/cube.test.mjs; echo 'export const cube = (a) => a ** 3' >"$wtl/src/cube.mjs"; commit_tl "wip: cube"
refuses "red-proof --lock: refuses a non-test file" src/cube.mjs TL --lock
git -C "$wtl" rm -q src/cube.mjs
echo '{ "name": "fixture", "private": true, "devDependencies": { "x": "1" } }' >"$wtl/package.json"; commit_tl "test: a dev dependency"
refuses "red-proof --lock: refuses package.json" 'not one: package.json' TL --lock
git -C "$wtl" checkout -q main -- package.json
mkdir -p "$wtl/src/fixtures" && echo x >"$wtl/src/fixtures/a"$'\n'"b.txt"; commit_tl "test: a fixture with a newline in its name"
refuses "red-proof --lock: refuses a path with a newline" 'a changed path has a control character' TL --lock
git -C "$wtl" rm -q "src/fixtures/a"$'\n'"b.txt"
printf '%s\n' "import { test } from 'node:test'" "test('nothing yet', () => {})" >"$wtl/src/cube.test.mjs"; commit_tl "test: a passing cube test"
refuses "red-proof --lock: refuses a test file that passes" 'src/cube.test.mjs: passes with no implementation' TL --lock
red_test src/cube.test.mjs "test('later', { skip: 'not yet' }, () => {})"; commit_tl "test: a skipped case"
refuses "red-proof --lock: refuses a test node --test reports skipped" 'src/cube.test.mjs: 1 test(s) skipped or todo' TL --lock
red_test src/cube.test.mjs "test.skip('later', () => {})"; commit_tl "test: an unconditional skip"
refuses "red-proof --lock: refuses an added unconditional skip" "src/cube.test.mjs: test.skip('later'" TL --lock
red_test src/cube.test.mjs; commit_tl "test: cube"
lockf="$(git -C "$wtl" rev-parse --absolute-git-dir)/10x-lock"
refuses "red-proof refuses to run without a lock when tdd is on" 'run the tests half first: 10x-red-proof TL --lock' TL
echo '{ "tdd": false }' >.claude/10x.json
10x-red-proof TL >"$tmp/out" 2>&1; rc=$?
10x-red-proof TL --lock >"$tmp/out2" 2>&1; rc2=$?
[ "$rc" = 0 ] && grep -q 'changes only tests' "$tmp/out" && [ "$rc2" = 2 ] && grep -q 'tdd is false' "$tmp/out2" && [ ! -e "$lockf" ] &&
  ok "tdd false: red-proof runs without a lock and refuses --lock" || { bad "tdd false: red-proof runs without a lock and refuses --lock ($rc, $rc2)"; cat "$tmp/out" "$tmp/out2"; }
rm .claude/10x.json
lock1="$(git -C "$wtl" rev-parse HEAD)"
10x-red-proof TL --lock >"$tmp/out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -qxF "locked 2 file(s) at $(git -C "$wtl" rev-parse --short HEAD)" "$tmp/out" &&
  [ "$(grep '^lock ' "$lockf")" = "lock $lock1" ] &&
  grep -qxF "file $(git -C "$wtl" rev-parse HEAD:src/cube.test.mjs) src/cube.test.mjs" "$lockf" &&
  grep -qxF "file $(git -C "$wtl" rev-parse HEAD:src/other.test.mjs) src/other.test.mjs" "$lockf" && [ "$(wc -l <"$lockf" | tr -d ' ')" = 3 ] &&
  ok "red-proof --lock: records the lock" || { bad "red-proof --lock: records the lock (exit $rc)"; cat "$tmp/out" "$lockf"; }
echo 'export const cube = (a) => a ** 3' >"$wtl/src/cube.mjs"; commit_tl "feat: cube"
expect "red-proof after the lock" 0 10x-red-proof TL
# a locked file changed outside a relock
cp "$wtl/src/cube.test.mjs" "$tmp/cube.locked"
echo '// edited' >>"$wtl/src/cube.test.mjs"; commit_tl "test: edit a locked test"
refuses "lock: red-proof refuses a changed locked file" 'locked file(s) changed since the lock: src/cube.test.mjs' TL
10x-review-packet TL >"$tmp/out" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -qF 'src/cube.test.mjs' "$tmp/out" && grep -qF 'run 10x-red-proof TL' "$tmp/out" && [ ! -e .10x/TL/review-packet.md ] &&
  ok "lock: review-packet refuses a changed locked file" || { bad "lock: review-packet refuses a changed locked file (exit $rc)"; cat "$tmp/out"; }
10x-land check TL >"$tmp/out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q '^clean: ' "$tmp/out" && [ "$(tail -n 1 "$tmp/out")" = 'locked test changed: src/cube.test.mjs' ] &&
  ok "lock: check refuses a changed locked file" || { bad "lock: check refuses a changed locked file (exit $rc)"; cat "$tmp/out"; }
cp "$tmp/cube.locked" "$wtl/src/cube.test.mjs"; commit_tl "test: undo the edit"
red_test src/extra.test.mjs; commit_tl "test: extra"
red_test src/extra.test.mjs "test('cube 3', async () => { const { cube } = await import('./cube.mjs'); assert.equal(cube(3), 27) })"; commit_tl "test: extra again"
10x-red-proof TL >"$tmp/out" 2>&1; rc=$?
10x-review-packet TL >"$tmp/out2" 2>&1; rc2=$?
10x-land check TL >"$tmp/out3" 2>&1; rc3=$?
[ "$rc" = 0 ] && grep -q '^RED    src/extra.test.mjs' "$tmp/out" && [ "$rc2" = 0 ] && [ "$rc3" = 0 ] && ! grep -q 'locked test changed' "$tmp/out3" &&
  ok "lock: an unlocked test may change and a new test file may be added" || { bad "lock: an unlocked test may change and a new test file may be added ($rc, $rc2, $rc3)"; cat "$tmp/out" "$tmp/out2" "$tmp/out3"; }
# relock: the locked test changes in one approved commit that red-proof re-proves
echo '// relock 1' >>"$wtl/src/cube.mjs"
red_test src/cube.test.mjs "test('cube 3', async () => { const { cube } = await import('./cube.mjs'); assert.equal(cube(3), 27) })"; commit_tl "test: relock with an implementation edit"
mixed="$(git -C "$wtl" rev-parse --short HEAD)"
refuses "relock: a missing entry is refused" 'src/cube.test.mjs' TL
printf '## Relock 1\n- reason: cube(3) is not covered\n- ruling: Rejected — it changes what AC1 requires\n' >.10x/TL/relock.md
refuses "relock: a rejected ruling is refused" 'relock 1 was rejected' TL
printf '\n## Relock 2\n- reason: cube(3) is not covered\n- ruling: approved — the test missed a case\n- commit: %s\n' "$mixed" >>.10x/TL/relock.md
refuses "relock: a commit touching an unlocked file is refused" 'changes files that are not locked: src/cube.mjs' TL
cp "$tmp/cube.locked" "$wtl/src/cube.test.mjs"; commit_tl "test: back to the lock"
red_test src/cube.test.mjs "test('cube 3 is 27', async () => { const { cube } = await import('./cube.mjs'); assert.equal(cube(3), 27) })"; commit_tl "test: relock"
relock2="$(git -C "$wtl" rev-parse HEAD)"
printf '## Relock 1\n- reason: cube(3) is not covered\n- ruling: Rejected — it changes what AC1 requires\n\n## Relock 2\n- reason: cube(3) is not covered\n- ruling: approved — the test missed a case\n- commit: %s\n' "${relock2:0:9}" >.10x/TL/relock.md
10x-red-proof TL >"$tmp/out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -qxF "relocked at $(git -C "$wtl" rev-parse --short HEAD)" "$tmp/out" &&
  [ "$(grep '^lock ' "$lockf")" = "$(printf 'lock %s\nlock %s' "$lock1" "$relock2")" ] &&
  grep -qxF "file $(git -C "$wtl" rev-parse HEAD:src/cube.test.mjs) src/cube.test.mjs" "$lockf" &&
  10x-land check TL >"$tmp/out2" 2>&1 &&
  ok "relock: an approved entry moves the lock" || { bad "relock: an approved entry moves the lock (exit $rc)"; cat "$tmp/out" "$lockf" "$tmp/out2"; }
expect "packet TL" 0 10x-review-packet TL
rl="$(awk '/^## Relocks/ { on = 1; next } on && /^## / { exit } on' .10x/TL/review-packet.md)"
[ "$(grep -n '^## Relocks' .10x/TL/review-packet.md | cut -d: -f1)" -gt "$(grep -n '^## Plan checks' .10x/TL/review-packet.md | cut -d: -f1)" ] &&
  printf '%s\n' "$rl" | grep -qxF '### Relock 1 — rejected' && printf '%s\n' "$rl" | grep -qxF -- '- ruling: Rejected — it changes what AC1 requires' &&
  printf '%s\n' "$rl" | grep -qxF '### Relock 2 — approved' && printf '%s\n' "$rl" | grep -qxF -- '- reason: cube(3) is not covered' &&
  printf '%s\n' "$rl" | grep -qxF '```diff' && printf '%s\n' "$rl" | grep -qF "+test('cube 3 is 27'" &&
  [ "$(printf '%s\n' "$rl" | grep -c '^```diff')" = 1 ] && ! printf '%s\n' "$rl" | grep -q 'src/cube.mjs' &&
  ok "review-packet lists each relock with its diff" || { bad "review-packet lists each relock with its diff"; cat .10x/TL/review-packet.md; }
rm .10x/TL/relock.md
expect "packet TL without relock.md" 0 10x-review-packet TL
[ "$(awk '/^## Relocks/ { on = 1; next } on && /^## / { exit } on && NF' .10x/TL/review-packet.md)" = none ] &&
  ok "review-packet: no relock.md lists none" || { bad "review-packet: no relock.md lists none"; cat .10x/TL/review-packet.md; }
expect "rm TL" 0 10x-worktree rm TL

# consecutive relocks: two wrong locked tests, each fixed by its own approved relock, accepted in one run
expect "worktree add TR" 0 10x-worktree add TR --no-setup
wtl="$tmp/repo/.worktrees/TR"; lockf="$(git -C "$wtl" rev-parse --absolute-git-dir)/10x-lock"
mkdir -p .10x/TR
printf '# TR — fixture\n\n## Tests\n| AC | Test file | Case |\n|---|---|---|\n| AC1 | `src/a.test.mjs` | `cube` |\n| AC2 | `src/b.test.mjs` | `cube` |\n' >.10x/TR/plan.md
cube_test() { # <file> <cube(3)>
  printf '%s\n' "import { test } from 'node:test'" "import assert from 'node:assert'" \
    "test('cube', async () => { const { cube } = await import('./cube.mjs'); assert.equal(cube(3), $2) })" >"$wtl/$1"
}
cube_test src/a.test.mjs 28; cube_test src/b.test.mjs 28
mkdir -p "$wtl/src/fixtures"; printf '%s\n' '```' one '```' >"$wtl/src/fixtures/doc.md"; echo q >"$wtl/src/fixtures/q\"uote.txt"
commit_tl "test: cube"
expect "red-proof --lock TR" 0 10x-red-proof TR --lock
grep -qxF "file $(git -C "$wtl" rev-parse 'HEAD:src/fixtures/q"uote.txt') src/fixtures/q\"uote.txt" "$lockf" &&
  10x-red-proof TR >"$tmp/out" 2>&1 &&
  ok "lock: a locked file whose name git quotes keeps its blob and is not changed" || { bad "lock: a locked file whose name git quotes keeps its blob and is not changed"; cat "$lockf" "$tmp/out"; }
lock0="$(git -C "$wtl" rev-parse HEAD)"
echo 'export const cube = (a) => a ** 3' >"$wtl/src/cube.mjs"; commit_tl "feat: cube"
cube_test src/a.test.mjs 27; printf '%s\n' '```' two '```' >"$wtl/src/fixtures/doc.md"; commit_tl "test: relock a"
ra="$(git -C "$wtl" rev-parse HEAD)"
cube_test src/b.test.mjs 27; commit_tl "test: relock b"
rb="$(git -C "$wtl" rev-parse HEAD)"
entry() { printf '## Relock %s\n- reason: %s\n- ruling: approved — the test expected the wrong cube\n- commit: %s\n\n' "$@"; } # <n> <reason> <commit>
entry 1 '' "$ra" >.10x/TR/relock.md
refuses "relock: an approved entry with no reason is refused" 'relock 1 has no reason' TR
{ entry 1 'cube(3) is 27' "$ra"; entry 2 'cube(3) is 27' "$rb"; } >.10x/TR/relock.md
10x-red-proof TR >"$tmp/out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -qxF "relocked at $(git -C "$wtl" rev-parse --short "$ra")" "$tmp/out" &&
  grep -qxF "relocked at $(git -C "$wtl" rev-parse --short "$rb")" "$tmp/out" &&
  [ "$(grep '^lock ' "$lockf")" = "$(printf 'lock %s\nlock %s\nlock %s' "$lock0" "$ra" "$rb")" ] &&
  grep -qxF "file $(git -C "$wtl" rev-parse "$rb:src/a.test.mjs") src/a.test.mjs" "$lockf" &&
  grep -qxF "file $(git -C "$wtl" rev-parse "$rb:src/b.test.mjs") src/b.test.mjs" "$lockf" &&
  ok "relock: two consecutive approved relocks are accepted in one run" || { bad "relock: two consecutive approved relocks are accepted in one run (exit $rc)"; cat "$tmp/out" "$lockf"; }
expect "packet TR" 0 10x-review-packet TR
awk '/^## Relocks/ { on = 1; next } on && /^## / { exit } on' .10x/TR/review-packet.md | awk '
  /^### Relock 1 — approved$/ { r = 1; next } /^### Relock 2/ { r = 0 }
  r && !open && /^````diff$/ { open = 1; next }
  r && open && !shut && /^ ```$/ { inside = 1 }
  r && open && /^````$/ { shut = 1; next }
  r && shut && /^Written by the implementer, not verified:$/ { label = 1 }
  r && label && /^- reason: cube\(3\) is 27$/ { reason = 1 }
  END { exit !(inside && shut && reason) }' &&
  ok "review-packet: a diff holding a \`\`\` line stays inside a longer fence, the reason below it" || { bad "review-packet: a diff holding a \`\`\` line stays inside a longer fence, the reason below it"; cat .10x/TR/review-packet.md; }
echo '// weaker' >>"$wtl/src/b.test.mjs"; echo '// more' >>"$wtl/src/cube.mjs"; commit_tl "feat: an implementation commit that edits a locked test"
echo '// relock' >>"$wtl/src/b.test.mjs"; commit_tl "test: relock b again"
entry 3 'b again' "$(git -C "$wtl" rev-parse HEAD)" >>.10x/TR/relock.md
refuses "relock: a locked file changed before the relock commit is refused" 'src/b.test.mjs changed before relock 3' TR
expect "rm TR" 0 10x-worktree rm TR

# remove
expect "rm keeps an unmerged branch" 0 10x-worktree rm T1
grep -q 'kept branch feat/T1-mul' "$tmp/out" && ok "unmerged branch kept" || bad "unmerged branch kept"
[ ! -e .10x/T1/landed ] && ok "rm writes no landed record when it keeps the branch" || bad "rm writes no landed record when it keeps the branch"
[ ! -e "$wt" ] && ok "worktree gone" || bad "worktree gone"

# a merged branch is deleted on rm (local fast-forward, base not pushed)
expect "worktree add T2" 0 10x-worktree add T2 --slug T2
[ "$(git -C "$tmp/repo/.worktrees/T2" rev-parse --abbrev-ref HEAD)" = feat/T2 ] && ok "slug equal to id is dropped" || bad "slug equal to id is dropped"
expect "worktree add T4" 0 10x-worktree add T4 --slug T4-helper --no-setup
[ "$(git -C "$tmp/repo/.worktrees/T4" rev-parse --abbrev-ref HEAD)" = feat/T4-helper ] && ok "slug starting with the id is not doubled" || bad "slug starting with the id is not doubled"
expect "rm T4" 0 10x-worktree rm T4
echo 'export const one = 1' >"$tmp/repo/.worktrees/T2/src/one.mjs"
git -C "$tmp/repo/.worktrees/T2" add -A && git -C "$tmp/repo/.worktrees/T2" commit -qm "feat: one"
git merge -q --ff-only feat/T2
rm -rf .10x/T2
expect "rm after a local merge" 0 10x-worktree rm T2
grep -q 'deleted branch feat/T2' "$tmp/out" && ok "merged branch deleted" || bad "merged branch deleted"
[ "$(cat .10x/T2/landed 2>/dev/null)" = "landed on main at $(git rev-parse --short origin/main)" ] && grep -q '^recorded: .*/\.10x/T2/landed$' "$tmp/out" &&
  ok "rm writes the landed record, creating .10x/<id>/, after a merge git sees" || { bad "rm writes the landed record, creating .10x/<id>/, after a merge git sees"; cat "$tmp/out"; }

# a squash-merged PR: git does not call the branch merged, but its changes are on origin/main
expect "worktree add T3" 0 10x-worktree add T3
wt3="$tmp/repo/.worktrees/T3"
printf 'export const two = 2\n' >"$wt3/src/two.mjs"
git -C "$wt3" add -A && git -C "$wt3" commit -qm "feat: two (1/2)"
printf 'export const two = 2\nexport const three = 3\n' >"$wt3/src/two.mjs"
git -C "$wt3" commit -qam "feat: two (2/2)"
git -C "$wt3" push -q origin feat/T3
git push -q origin main
git merge -q --squash feat/T3 && git commit -qm "feat: two (#3)" && git push -q origin main
expect "rm after a squash merge" 0 10x-worktree rm T3
grep -q 'deleted branch feat/T3 (its changes are on origin/main)' "$tmp/out" && ok "squash-merged branch deleted" || bad "squash-merged branch deleted"
[ -z "$(git ls-remote --heads origin feat/T3)" ] && ok "merged remote branch deleted" || bad "merged remote branch deleted"
[ "$(cat .10x/T3/landed 2>/dev/null)" = "landed on main at $(git rev-parse --short origin/main)" ] &&
  ok "pr-merge close records the landing for a file ticket" || { bad "pr-merge close records the landing for a file ticket"; cat "$tmp/out"; }

# a gh-<n> ticket squash-merged on origin, then sync-base and rm, as a pr-merge close runs them
expect "worktree add gh-3" 0 10x-worktree add gh-3 --no-setup
printf 'export const four = 4\n' >"$tmp/repo/.worktrees/gh-3/src/four.mjs"
git -C "$tmp/repo/.worktrees/gh-3" add -A && git -C "$tmp/repo/.worktrees/gh-3" commit -qm "feat: four"
git -C "$tmp/repo/.worktrees/gh-3" push -q origin feat/gh-3
git clone -q "$tmp/origin.git" "$tmp/merger"
git -C "$tmp/merger" -c user.email=t@t -c user.name=t merge -q --squash origin/feat/gh-3 >/dev/null &&
  git -C "$tmp/merger" -c user.email=t@t -c user.name=t commit -qm "feat: four (#3)" && git -C "$tmp/merger" push -q origin main
expect "sync-base after the gh-3 merge" 0 10x-worktree sync-base
expect "rm gh-3 after a squash merge on origin" 0 10x-worktree rm gh-3
[ "$(cat .10x/gh-3/landed 2>/dev/null)" = "landed on main at $(git rev-parse --short origin/main)" ] &&
  ok "pr-merge close records the landing for a gh ticket" || { bad "pr-merge close records the landing for a gh ticket"; cat "$tmp/out"; }

# a pr close leaves the PR open: the branch is pushed, not merged, and rm keeps it
expect "worktree add T9" 0 10x-worktree add T9 --no-setup
printf 'export const nine = 9\n' >"$tmp/repo/.worktrees/T9/src/nine.mjs"
git -C "$tmp/repo/.worktrees/T9" add -A && git -C "$tmp/repo/.worktrees/T9" commit -qm "feat: nine"
git -C "$tmp/repo/.worktrees/T9" push -q origin feat/T9
expect "rm T9 with an unmerged PR" 0 10x-worktree rm T9
grep -q 'kept branch feat/T9' "$tmp/out" && [ ! -e .10x/T9/landed ] &&
  ok "pr close with an unmerged PR leaves no landed record" || { bad "pr close with an unmerged PR leaves no landed record"; cat "$tmp/out"; }

# rm never forces: a worktree with uncommitted changes stays
expect "worktree add T6" 0 10x-worktree add T6 --no-setup
echo wip >"$tmp/repo/.worktrees/T6/wip.txt"
expect "rm refuses uncommitted changes" 2 10x-worktree rm T6
expect "rm --force is refused" 2 10x-worktree rm T6 --force
[ -e "$tmp/repo/.worktrees/T6/wip.txt" ] && ok "rm keeps the dirty worktree" || bad "rm keeps the dirty worktree"
rm "$tmp/repo/.worktrees/T6/wip.txt"
expect "rm T6" 0 10x-worktree rm T6

# 10x-land, on its own repo (origin path contains github.com so the host is detected)
mkdir -p "$tmp/github.com" "$tmp/stub"
git -c init.defaultBranch=main init -q --bare "$tmp/github.com/land.git"
git -c init.defaultBranch=main init -q "$tmp/land"
cd "$tmp/land" || exit 2
git config user.email t@t; git config user.name t
echo base >f.txt; echo one >g.txt
git add -A && git commit -qm "init"
git remote add origin "$tmp/github.com/land.git" && git push -q -u origin main
cat >"$tmp/stub/gh" <<'STUB'
#!/bin/bash
echo "$*" >>"$STUB_LOG"
# STUB_CHECKS_SEQ: a directory of rollups 1, 2, …, one per checks call, the last one repeated.
case "$*" in *headRefOid*)
  if [ -n "${STUB_CHECKS_SEQ-}" ]; then
    n=$(($(cat "$STUB_CHECKS_SEQ/n" 2>/dev/null || echo 0) + 1)); echo "$n" >"$STUB_CHECKS_SEQ/n"
    while [ ! -f "$STUB_CHECKS_SEQ/$n" ]; do n=$((n - 1)); done
    cat "$STUB_CHECKS_SEQ/$n"
  else echo "${STUB_CHECKS-}"; fi
  exit 0 ;;
*state,url,isCrossRepository*) echo "${STUB_STATE-}"; exit "${STUB_STATE_RC:-0}" ;;
esac
case "$1 $2" in
  "pr view"|"mr view") echo "${STUB_VIEW-}"; exit "${STUB_VIEW_RC:-0}" ;;
  "label list") printf '%s\n' "${STUB_LABELS-}" ;;
  "repo view") echo "${STUB_VIS-PUBLIC}"; exit "${STUB_VIS_RC:-0}" ;;
  "issue create")
    # STUB_BODY_COPY: where to keep the --body-file the issue was created with.
    prev=""; for a in "$@"; do [ "$prev" = --body-file ] && [ -n "${STUB_BODY_COPY-}" ] && cp "$a" "$STUB_BODY_COPY"; prev=$a; done
    exit "${STUB_CREATE_RC:-0}" ;;
  "api --hostname") case "$*" in *" graphql "*)
    none='{"data":{"repository":{"issueTypes":null}}}'; echo "${STUB_GRAPHQL-$none}"
    [ "${STUB_GRAPHQL_RC:-0}" = 0 ] || echo "gh: Could not resolve to a Repository" >&2; exit "${STUB_GRAPHQL_RC:-0}" ;;
  *security-advisories*)
    # STUB_ADV_COPY: where to keep the --input JSON the advisory was requested with.
    prev=""; for a in "$@"; do [ "$prev" = --input ] && [ -n "${STUB_ADV_COPY-}" ] && cp "$a" "$STUB_ADV_COPY"; prev=$a; done
    if [ "${STUB_ADV_RC:-0}" != 0 ]; then echo "gh: Resource not accessible by integration" >&2; exit "$STUB_ADV_RC"; fi
    echo '{"ghsa_id":"GHSA-abcd-efgh-ijkl","html_url":"https://github.com/acme/adv/security/advisories/GHSA-abcd-efgh-ijkl"}'; exit 0 ;; esac ;;
  "issue view") echo '{"number":7,"title":"T","body":"b","url":"https://github.com/acme/land/issues/7","state":"OPEN","labels":[],"issueType":null,"comments":[]}' ;;
esac
exit 0
STUB
cp "$tmp/stub/gh" "$tmp/stub/glab"; chmod +x "$tmp/stub/gh" "$tmp/stub/glab"
# merge fetches origin: an ssh origin (git@github.com:…) is served from the local bare repo.
printf '#!/bin/bash\nexec git upload-pack "%s"\n' "$tmp/github.com/land.git" >"$tmp/stub/ssh"; chmod +x "$tmp/stub/ssh"
export GIT_SSH_COMMAND="$tmp/stub/ssh"
export STUB_LOG="$tmp/stub.log"
10x-worktree add L1 --no-setup >/dev/null
lw="$tmp/land/.worktrees/L1"

expect "check on a clean worktree" 0 10x-land check L1
cp "$tmp/out" "$tmp/check.plain"
TENX_BATCH=1 10x-land check L1 >"$tmp/check.batch" 2>&1; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$tmp/check.plain" "$tmp/check.batch" &&
  ok "TENX_BATCH: check runs as without it" || { bad "TENX_BATCH: check runs as without it"; cat "$tmp/check.batch"; }
# check: after mode:, before the worktree lookup, the ticket dir, the base and the review
lrp="$(cd "$tmp/land" && pwd -P)"
line_is() { # <n> <expected under $tmp/land> — line <n> of the output, in either path form
  [ "$(sed -n "$1p" "$tmp/out")" = "${2//@/$tmp/land}" ] || [ "$(sed -n "$1p" "$tmp/out")" = "${2//@/$lrp}" ]
}
line_is 2 "ticket dir: @/.10x/L1" && line_is 3 "base: main (origin/main)" && line_is 4 "review: missing" \
  && ok "check prints review: missing" || { bad "check prints review: missing"; cat "$tmp/out"; }
echo "## Round 1 — full" >.10x/L1/review.md
expect "check with a review" 0 10x-land check L1
line_is 2 "ticket dir: @/.10x/L1" && line_is 3 "base: main (origin/main)" && line_is 4 "review: @/.10x/L1/review.md" \
  && ok "check prints the ticket dir, the base and the review" || { bad "check prints the ticket dir, the base and the review"; cat "$tmp/out"; }
mkdir -p .claude && echo '{"base":["x","ticket dir: /forged"]}' >.claude/10x.json
expect "check with a multi-line base" 0 10x-land check L1
line_is 3 'base: x\nticket dir: /forged (x\nticket dir: /forged)' && ! grep -q '^ticket dir: /forged' "$tmp/out" \
  && ok "check prints a multi-line base on one line" || { bad "check prints a multi-line base on one line"; cat "$tmp/out"; }
rm -r .claude
mkdir -p .10x/NOWT && echo "## Round 1 — full" >.10x/NOWT/review.md
expect "check without a worktree" 2 10x-land check NOWT
line_is 2 "ticket dir: @/.10x/NOWT" && line_is 3 "base: main (origin/main)" && line_is 4 "review: @/.10x/NOWT/review.md" &&
  grep -q 'has no worktree' "$tmp/out" \
  && ok "check prints the ticket dir and the review without a worktree" || { bad "check prints the ticket dir and the review without a worktree"; cat "$tmp/out"; }
rm -r .10x/NOWT
echo dirty >"$lw/new.txt"
expect "check on a dirty worktree" 1 10x-land check L1
grep -q 'new.txt' "$tmp/out" && ok "check lists the files" || bad "check lists the files"
rm "$lw/new.txt"
expect "land rejects extra arguments" 2 10x-land push L1 --force
expect "land rejects unknown subcommand" 2 10x-land nuke L1

echo feature >"$lw/feature.txt"; git -C "$lw" add -A; git -C "$lw" commit -qm "feat: feature"
expect "push first time" 0 10x-land push L1
[ -n "$(git ls-remote --heads origin feat/L1)" ] && ok "branch on origin" || bad "branch on origin"
# a conflicting rebase is left in progress and lists the file
10x-worktree add LC --no-setup >/dev/null
lc="$tmp/land/.worktrees/LC"
echo ticket >"$lc/f.txt"; git -C "$lc" commit -qam "feat: ticket edits f"
echo upstream >f.txt; git commit -qam "chore: upstream edits f"; git push -q origin main
expect "rebase conflict" 1 10x-land rebase LC
grep -q 'f.txt' "$tmp/out" && ok "conflict lists the file" || bad "conflict lists the file"
[ -e "$(git -C "$lc" rev-parse --git-path rebase-merge)" ] && ok "rebase left in progress" || bad "rebase left in progress"
git -C "$lc" rebase --abort
# the base moves, then the branch is rebased and pushed again
echo moved >>f.txt; git commit -qam "chore: move base"; git push -q origin main
expect "rebase onto the moved base" 0 10x-land rebase L1
git -C "$lw" merge-base --is-ancestor origin/main HEAD && ok "branch contains the new base" || bad "branch contains the new base"
# a fetch refspec that does not cover the base: rebase still lands on origin's current base
git config remote.origin.fetch '+refs/heads/none:refs/remotes/origin/none'
echo moved-again >>f.txt; git commit -qam "chore: move base again"; git push -q origin main
expect "rebase onto the moved base, fetch refspec not covering it" 0 10x-land rebase L1
git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git -C "$lw" merge-base --is-ancestor "$(git rev-parse main)" HEAD && ok "narrowed refspec: branch contains the new base" || bad "narrowed refspec: branch contains the new base"
expect "push after a rebase (lease)" 0 10x-land push L1
[ "$(git ls-remote --heads origin feat/L1 | cut -f1)" = "$(git -C "$lw" rev-parse HEAD)" ] && ok "origin has the rebased branch" || bad "origin has the rebased branch"
# a push URL naming another repo is refused before anything is pushed; the same repo in another form is not
git init -q --bare "$tmp/other.git"
echo more >"$lw/more.txt"; git -C "$lw" add -A; git -C "$lw" commit -qm "feat: more"
o_before="$(git ls-remote origin)"
git config remote.origin.pushurl "$tmp/other.git"
expect "push refuses a push URL to another repo" 2 10x-land push L1
grep -qF "$tmp/other.git" "$tmp/out" && grep -qF "$tmp/github.com/land.git" "$tmp/out" && ok "refusal names both URLs" || bad "refusal names both URLs"
[ "$(git ls-remote origin)" = "$o_before" ] && [ -z "$(git ls-remote "$tmp/other.git")" ] && ok "mismatched push URL left both repos untouched" || bad "mismatched push URL left both repos untouched"
git config remote.origin.pushurl "file://$tmp/github.com/land.git/"
expect "push allows the same repo in another form" 0 10x-land push L1
[ "$(git ls-remote --heads origin feat/L1 | cut -f1)" = "$(git -C "$lw" rev-parse HEAD)" ] && ok "pushed through the equivalent push URL" || bad "pushed through the equivalent push URL"
git config --unset remote.origin.pushurl
mkdir -p .claude && echo '{"base":"feat/L1"}' >.claude/10x.json
expect "push refuses the base branch" 2 10x-land push L1
rm -r .claude

# a branch name with a leading + (a forced refspec) is refused by push and squash, origin and base untouched
git -C "$tmp/land" branch '+feat/EVIL' main
git -C "$tmp/land" worktree add -q "$tmp/land/.worktrees/EVIL" '+feat/EVIL'
o_before="$(git ls-remote origin)"; b_before="$(git rev-parse main)"
expect "push refuses a +branch" 2 10x-land push EVIL
expect "squash refuses a +branch" 2 10x-land squash EVIL
[ "$(git ls-remote origin)" = "$o_before" ] && [ "$(git rev-parse main)" = "$b_before" ] && ok "+branch left origin and base untouched" || bad "+branch left origin and base untouched"
expect "add refuses a bad --type" 2 10x-worktree add L9 --type '+feat' --no-setup
expect "add refuses a bad --slug" 2 10x-worktree add L9 --slug 'a:b' --no-setup
expect "add refuses a slug with a slash" 2 10x-worktree add L9 --slug 'a/b' --no-setup

# merge: only `pr merge <branch> --squash`, only into the configured base, pinned to origin's repo, never a fork's PR
: >"$tmp/stub.log"
export PATH="$tmp/stub:$PATH"
git remote set-url origin git@github.com:acme/land.git
# check: in pr mode on github.com it prints the branch's PR; in local mode it never calls gh
STUB_STATE="MERGED https://github.com/acme/land/pull/1" expect "check prints a merged PR in pr mode" 0 10x-land check L1
grep -qxF 'pr: MERGED https://github.com/acme/land/pull/1' "$tmp/out" && ok "check prints the pr: line" || { bad "check prints the pr: line"; cat "$tmp/out"; }
grep -qxF 'pr view feat/L1 --repo github.com/acme/land --json state,url,isCrossRepository --jq select(.isCrossRepository | not) | .state + " " + .url' "$tmp/stub.log" && ok "check: gh pr view pinned to origin's repo" || bad "check: gh pr view pinned to origin's repo"
STUB_STATE_RC=1 expect "check prints no PR when gh finds none" 0 10x-land check L1
grep -qxF 'pr: none' "$tmp/out" && ok "check prints pr: none" || { bad "check prints pr: none"; cat "$tmp/out"; }
mkdir -p .claude && echo '{"close":"local"}' >.claude/10x.json
: >"$tmp/stub.log"
STUB_STATE="MERGED https://github.com/acme/land/pull/1" expect "check makes no gh call in local mode" 0 10x-land check L1
! grep -q '^pr:' "$tmp/out" && [ ! -s "$tmp/stub.log" ] && ok "local mode: no pr: line, no gh call" || bad "local mode: no pr: line, no gh call"
rm -r .claude
git remote set-url origin 'git@github.com:ac+me/land.git'
STUB_STATE="MERGED https://github.com/acme/land/pull/1" expect "check prints no PR when origin's repo cannot be derived" 0 10x-land check L1
grep -qxF 'pr: none' "$tmp/out" && [ ! -s "$tmp/stub.log" ] && ok "underivable repo: pr: none, no gh call" || { bad "underivable repo: pr: none, no gh call"; cat "$tmp/out" "$tmp/stub.log"; }
: >"$tmp/stub.log"
git remote set-url origin git@github.com:acme/land.git
# check: its first line is the configured close mode, in every mode, also on a dirty worktree and with no worktree
first_is() { [ "$(head -n 1 "$tmp/out")" = "$1" ] && ok "$2" || { bad "$2"; cat "$tmp/out"; }; }
STUB_STATE="OPEN https://github.com/acme/land/pull/1" expect "check prints mode: pr by default" 0 10x-land check L1
first_is "mode: pr" "default: first line is mode: pr"
mkdir -p .claude && echo '{"close":"pr"}' >.claude/10x.json
STUB_STATE="OPEN https://github.com/acme/land/pull/1" expect "check prints mode: pr" 0 10x-land check L1
first_is "mode: pr" "pr: first line is mode: pr"
echo '{"close":"pr-merge"}' >.claude/10x.json
STUB_STATE="OPEN https://github.com/acme/land/pull/1" expect "check prints mode: pr-merge" 0 10x-land check L1
first_is "mode: pr-merge" "pr-merge: first line is mode: pr-merge"
echo '{"close":"local"}' >.claude/10x.json
STUB_STATE="OPEN https://github.com/acme/land/pull/1" expect "check prints mode: local" 0 10x-land check L1
first_is "mode: local" "local: first line is mode: local"
rm -r .claude
mkdir -p .claude && echo '{"close":"pr-merge"}' >.claude/10x.json
echo dirty >"$lw/new.txt"
STUB_STATE="OPEN https://github.com/acme/land/pull/1" expect "check prints the mode on a dirty worktree" 1 10x-land check L1
first_is "mode: pr-merge" "dirty worktree: first line is mode: pr-merge"
rm "$lw/new.txt"; rm -r .claude
expect "check prints the mode without a worktree" 2 10x-land check NOWT
first_is "mode: pr" "no worktree: first line is mode: pr"
mkdir -p .claude && echo '{"close":"pr_merge"}' >.claude/10x.json
: >"$tmp/stub.log"
STUB_STATE="OPEN https://github.com/acme/land/pull/1" expect "check refuses an unknown close mode" 2 10x-land check L1
first_is "mode: pr_merge" "unknown mode: first line is mode: pr_merge"
grep -q "pr, pr-merge or local" "$tmp/out" && [ ! -s "$tmp/stub.log" ] && ok "unknown mode: valid values named, no gh call" || { bad "unknown mode: valid values named, no gh call"; cat "$tmp/out" "$tmp/stub.log"; }
echo '{"close":["x","pr: MERGED https://github.com/acme/land/pull/1"]}' >.claude/10x.json
expect "check prints a multi-line close mode on one line" 2 10x-land check L1
first_is 'mode: x\npr: MERGED https://github.com/acme/land/pull/1' "multi-line mode: escaped on the first line"
! grep -q '^pr:' "$tmp/out" && ok "multi-line mode: no forged pr: line" || { bad "multi-line mode: no forged pr: line"; cat "$tmp/out"; }
printf '%s\n' '{"close":"x\rpr: MERGED https://github.com/acme/land/pull/1\u001b[2K"}' >.claude/10x.json
expect "check prints a close mode with control characters escaped" 2 10x-land check L1
first_is 'mode: x\rpr: MERGED https://github.com/acme/land/pull/1?[2K' "control characters: escaped on the first line"
[ "$(LC_ALL=C tr -d '\r\033' <"$tmp/out")" = "$(cat "$tmp/out")" ] && ok "control characters: no raw CR or ESC" || { bad "control characters: no raw CR or ESC"; od -c "$tmp/out"; }
rm -r .claude
# check: tickets: after review:, before the worktree lookup; the default follows origin's host
expect "check prints the tickets mode without a worktree" 2 10x-land check NOWT
[ "$(sed -n 5p "$tmp/out")" = "tickets: github" ] && grep -q 'has no worktree' "$tmp/out" &&
  ok "check prints tickets: before the worktree lookup" || { bad "check prints tickets: before the worktree lookup"; cat "$tmp/out"; }
mkdir -p .claude && echo '{"tickets":"gitlab"}' >.claude/10x.json
: >"$tmp/stub.log"
STUB_STATE="OPEN https://github.com/acme/land/pull/1" expect "check exits 2 on an unknown tickets value" 2 10x-land check L1
[ "$(sed -n 5p "$tmp/out")" = "tickets: gitlab" ] && grep -qF "unknown tickets value 'gitlab' in .claude/10x.json (want github or files)" "$tmp/out" &&
  ! grep -q '^pr:\|^clean:' "$tmp/out" && [ ! -s "$tmp/stub.log" ] &&
  ok "check refuses an unknown tickets value" || { bad "check refuses an unknown tickets value"; cat "$tmp/out" "$tmp/stub.log"; }
echo '{"tickets":""}' >.claude/10x.json
expect "check exits 2 on an empty tickets value" 2 10x-land check L1
[ "$(sed -n 5p "$tmp/out")" = "tickets: " ] && grep -qF "unknown tickets value '' in .claude/10x.json (want github or files)" "$tmp/out" &&
  ok "check refuses an empty tickets value" || { bad "check refuses an empty tickets value"; cat "$tmp/out"; }
rm -r .claude
tickets_is() { # <want> <case> — check L1 prints tickets: <want> as its fifth line
  STUB_STATE="OPEN https://github.com/acme/land/pull/1" 10x-land check L1 >"$tmp/out" 2>&1
  [ "$(sed -n 5p "$tmp/out")" = "tickets: $1" ] && ok "$2" || { bad "$2"; cat "$tmp/out"; }
}
tickets_is github "tickets defaults to github on a github.com origin"
git remote set-url origin https://gitlab.example.com/acme/land.git
tickets_is files "tickets defaults to files on another host"
git remote set-url origin "$tmp/github.com/land.git"
tickets_is files "tickets defaults to files on a local-path origin"
git remote rename origin keep
tickets_is files "tickets defaults to files without an origin"
git remote rename keep origin; git remote set-url origin git@github.com:acme/land.git
combo_bad=0
mkdir -p .claude
for t in github files; do
  for c in pr pr-merge local; do
    printf '{"tickets":"%s","close":"%s"}\n' "$t" "$c" >.claude/10x.json
    STUB_STATE="OPEN https://github.com/acme/land/pull/1" 10x-land check L1 >"$tmp/out" 2>&1 &&
      [ "$(sed -n 1p "$tmp/out")" = "mode: $c" ] && [ "$(sed -n 5p "$tmp/out")" = "tickets: $t" ] || { combo_bad=1; echo "      tickets $t, close $c:"; cat "$tmp/out"; }
  done
done
rm -r .claude
[ "$combo_bad" = 0 ] && ok "check accepts every tickets and close combination" || bad "check accepts every tickets and close combination"

# security.md fixtures: an entry is written in the layout 10x-security writes. sec_entry <n> <verdict> <severity> <title> <location> <status> <found in> [<seen in> [<reason>]]
sec_fp() { printf 'sha256:%064d' "$1"; }
sec_entry() {
  printf '\n## %s\n- title: %s\n- verdict: %s\n- severity:%s\n- rule: command-injection\n- location: %s\n- trace: reaches a shell\n- status: %s\n- reason:%s\n- found in: %s\n- seen in:%s\n- audit fingerprint:\n- not seen in:\n' \
    "$(sec_fp "$1")" "$4" "$2" "${3:+ $3}" "$5" "$6" "${9:+ $9}" "$7" "${8:+ $8}"
}
# The one entry the disclosure cases use, whatever its status.
sec_disclosed() { { printf '# Security entries\n'; sec_entry 1 confirmed high 'Shell injection in deploy hook' bin/deploy.sh:12 later gh-1; } >"$tmp/land/.10x/security.md"; }
sec_fp1="$(sec_fp 1)"

# check with security.blockClose: confirmed entries found in or seen in L1, new or fix-now, at or above the level
sf="$tmp/land/.10x/security.md"
{
  printf '# Security entries\n'
  sec_entry 1 confirmed high 'Open high' src/a.js:1 new L1
  sec_entry 2 confirmed critical 'Seen critical' src/b.js:2 fix-now gh-30 'gh-31, L1'
  sec_entry 3 confirmed medium 'Below high' src/c.js:3 new L1
  sec_entry 4 confirmed high 'Later high' src/d.js:4 later L1
  sec_entry 5 confirmed high 'Accepted high' src/e.js:5 accepted L1 '' 'not reachable'
  sec_entry 6 needs_validation '' 'Unvalidated' src/f.js:6 new L1
  sec_entry 7 confirmed critical 'Other ticket' src/g.js:7 new gh-30
} >"$sf"
run_check() { STUB_STATE="OPEN https://github.com/acme/land/pull/1" 10x-land check L1 >"$tmp/out" 2>&1; }
# open_is <level> <entry numbers…> — check exits 1, prints security: <level> as line 6, and one security entry open: line per entry, after clean:
open_is() {
  local level=$1 n want=""; shift
  printf '{"security":{"blockClose":"%s"}}\n' "$level" >.claude/10x.json
  run_check; local rc=$?
  for n in "$@"; do want+="security entry open: $(sec_fp "$n")"$'\n'; done
  local c o
  c="$(grep -n '^clean: ' "$tmp/out" | head -n 1 | cut -d: -f1)"; o="$(grep -n '^security entry open: ' "$tmp/out" | head -n 1 | cut -d: -f1)"
  [ "$rc" -eq 1 ] && [ "$(sed -n 6p "$tmp/out")" = "security: $level" ] && [ "${c:-99}" -lt "${o:-0}" ] &&
    [ "$(grep '^security entry open: ' "$tmp/out" | sort)" = "$(printf '%s' "$want" | sort)" ]
}
mkdir -p .claude
open_is high 1 2 && open_is medium 1 2 3 && ok "check names open entries at or above security.blockClose" ||
  { bad "check names open entries at or above security.blockClose"; cat "$tmp/out"; }
rm -r .claude
off_is() { run_check; local rc=$?; [ "$rc" -eq 0 ] && [ "$(sed -n 6p "$tmp/out")" = "security: off" ] && ! grep -q 'security entry open' "$tmp/out"; }
# Without the key check never reads security.md, so a file that does not parse changes nothing either.
off_is && { printf 'not a security file\n' >"$sf"; off_is; } && ok "check ignores security.md without security.blockClose" ||
  { bad "check ignores security.md without security.blockClose"; cat "$tmp/out"; }
bad_block() { # <JSON value> <the value as check shows it>
  mkdir -p .claude; printf '{"security":{"blockClose":%s}}\n' "$1" >.claude/10x.json
  run_check; local rc=$?
  [ "$rc" -eq 2 ] && grep -qF "unknown security.blockClose '$2' in .claude/10x.json (want critical, high, medium, low or informational)" "$tmp/out"
}
bad_block '"High"' High && bad_block '""' '' && bad_block 5 5 && ok "check refuses an unknown security.blockClose" ||
  { bad "check refuses an unknown security.blockClose"; cat "$tmp/out"; }
rm -r .claude; rm -f "$sf"
: >"$tmp/stub.log"
STUB_VIEW="develop OPEN false" expect "merge refuses a PR into another base" 2 10x-land merge L1
! grep -q 'pr merge' "$tmp/stub.log" && ok "no merge call for a wrong base" || bad "no merge call for a wrong base"
STUB_VIEW="main OPEN true" expect "merge refuses a fork's PR" 2 10x-land merge L1
! grep -q 'pr merge' "$tmp/stub.log" && ok "no merge call for a fork's PR" || bad "no merge call for a fork's PR"
lwsha="$(git -C "$lw" rev-parse HEAD)"
checks() { printf '{"headRefOid":"%s","statusCheckRollup":%s}' "$lwsha" "$1"; }
STUB_CHECKS="$(checks '[]')"; export STUB_CHECKS
STUB_VIEW="main OPEN false" expect "merge" 0 10x-land merge L1
grep -qxF 'pr view feat/L1 --repo github.com/acme/land --json baseRefName,state,isCrossRepository --jq .baseRefName + " " + .state + " " + (.isCrossRepository | tostring)' "$tmp/stub.log" && ok "gh pr view pinned to origin's repo" || bad "gh pr view pinned to origin's repo"
grep -qxF 'pr merge feat/L1 --repo github.com/acme/land --squash --match-head-commit '"$lwsha" "$tmp/stub.log" && ok "gh called with pr merge <branch> --repo <o/r> --squash --match-head-commit <sha>" || bad "gh called with pr merge <branch> --repo <o/r> --squash --match-head-commit <sha>"
# merge: the PR's checks on the verified head must be green
merge_checks() { # <description> <exit> <rollup json> — the merge call is made only on exit 0
  : >"$tmp/stub.log"
  STUB_VIEW="main OPEN false" STUB_CHECKS="$(checks "$3")" expect "merge: $1" "$2" 10x-land merge L1
  if [ "$2" -eq 0 ]; then grep -q 'pr merge' "$tmp/stub.log" && ok "merge: $1: merge called" || bad "merge: $1: merge called"
  else ! grep -q 'pr merge' "$tmp/stub.log" && ok "merge: $1: no merge call" || bad "merge: $1: no merge call"; fi
}
merge_checks "all checks green" 0 '[{"__typename":"CheckRun","name":"gates (ubuntu-latest)","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","context":"legacy","state":"SUCCESS"}]'
merge_checks "a failed check" 2 '[{"__typename":"CheckRun","name":"gates (ubuntu-latest)","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"gates (macos-latest)","status":"COMPLETED","conclusion":"FAILURE"}]'
grep -q 'gates (macos-latest): FAILURE' "$tmp/out" && ok "merge: names the failed check" || bad "merge: names the failed check"
merge_checks "a check in progress" 3 '[{"__typename":"CheckRun","name":"gates (macos-latest)","status":"IN_PROGRESS","conclusion":""}]'
grep -q 'gates (macos-latest): IN_PROGRESS' "$tmp/out" && ok "merge: names the pending check" || bad "merge: names the pending check"
merge_checks "a pending status context" 3 '[{"__typename":"StatusContext","context":"legacy","state":"PENDING"}]'
grep -q 'legacy: PENDING' "$tmp/out" && ok "merge: names the pending context" || bad "merge: names the pending context"
merge_checks "a failed status context" 2 '[{"__typename":"StatusContext","context":"legacy","state":"ERROR"}]'
merge_checks "an expected status context" 3 '[{"__typename":"StatusContext","context":"legacy","state":"EXPECTED"}]'
merge_checks "a failed check while another runs" 2 '[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"CheckRun","name":"b","status":"QUEUED","conclusion":""}]'
grep -q 'a: FAILURE' "$tmp/out" && grep -q 'b: QUEUED' "$tmp/out" && ok "merge: names the failed and the pending check" || bad "merge: names the failed and the pending check"
merge_checks "neutral and skipped checks" 0 '[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"NEUTRAL"},{"__typename":"CheckRun","name":"b","status":"COMPLETED","conclusion":"SKIPPED"}]'
: >"$tmp/stub.log"
STUB_VIEW="main OPEN false" STUB_CHECKS='{"headRefOid":"0000000000000000000000000000000000000000","statusCheckRollup":[]}' expect "merge: PR head is not the worktree's HEAD" 2 10x-land merge L1
grep -q 'push first' "$tmp/out" && ! grep -q 'pr merge' "$tmp/stub.log" && ok "merge: says push first, no merge call" || bad "merge: says push first, no merge call"
merge_checks "no checks, no workflow file" 0 '[]'
mkdir -p "$lw/.github/workflows"
printf 'on:\n  pull_request:\n' >"$lw/.github/workflows/ci.yml"
git -C "$lw" add -A && git -C "$lw" commit -qm "ci: workflow"
lwsha="$(git -C "$lw" rev-parse HEAD)"
merge_checks "no checks, a pull_request workflow on the branch" 3 '[]'
grep -q 'still pending' "$tmp/out" && ok "merge: no checks yet is still pending" || bad "merge: no checks yet is still pending"
printf 'on:\n  push:\n' >"$lw/.github/workflows/ci.yml"
git -C "$lw" commit -qam "ci: push only"
lwsha="$(git -C "$lw" rev-parse HEAD)"
merge_checks "no checks, a workflow without pull_request" 0 '[]'
# a branch that drops the base's pull_request trigger is still pending
om="$(git -C "$lw" rev-parse origin/main)"
wf="$(printf 'on:\n  pull_request:\n' | git -C "$lw" hash-object -w --stdin)"
gh_tree="$(printf '100644 blob %s\tci.yml\n' "$wf" | git -C "$lw" mktree)"
gh_tree="$(printf '040000 tree %s\tworkflows\n' "$gh_tree" | git -C "$lw" mktree)"
base_tree="$( { git -C "$lw" ls-tree "$om"; printf '040000 tree %s\t.github\n' "$gh_tree"; } | git -C "$lw" mktree)"
lw_before="$(git -C "$lw" rev-parse HEAD)"
base_wf="$(git -C "$lw" commit-tree "$base_tree" -p "$om" -m "ci: base workflow")"
git -C "$lw" push -q "$tmp/github.com/land.git" "$base_wf:refs/heads/main"
git -C "$lw" reset -q --hard "$(git -C "$lw" commit-tree "$lw_before^{tree}" -p "$base_wf" -m "ci: push only")"
lwsha="$(git -C "$lw" rev-parse HEAD)"
merge_checks "no checks, the base's pull_request workflow dropped on the branch" 3 '[]'
# merge: origin/<base> moved since the rebase
other="$(git -C "$lw" commit-tree "$base_wf^{tree}" -p "$base_wf" -m "elsewhere")"
git -C "$lw" push -q "$tmp/github.com/land.git" "$other:refs/heads/main"
git config remote.origin.fetch '+refs/heads/none:refs/remotes/origin/none'
merge_checks "origin/main moved, fetch refspec not covering the base" 4 '[]'
git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
merge_checks "origin/main moved since the rebase" 4 '[]'
grep -q 'origin/main moved' "$tmp/out" && ok "merge: says the base moved" || bad "merge: says the base moved"
git -C "$lw" push -q -f "$tmp/github.com/land.git" "$om:refs/heads/main"
git -C "$lw" fetch -q origin
git -C "$lw" reset -q --hard "$lw_before"
lwsha="$lw_before"

# wait: polls the same rule until green, failed or the cap
wait_checks() { # <description> <exit> <rollup json> [env...]
  local d=$1 want=$2 r=$3; shift 3
  : >"$tmp/stub.log"
  STUB_VIEW="main OPEN false" STUB_CHECKS="$(checks "$r")" expect "wait: $d" "$want" env TENX_WAIT_INTERVAL=0 TENX_WAIT_CAP=0 "$@" 10x-land wait L1
}
wait_checks "all green" 0 '[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]'
wait_checks "a failed check" 1 '[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"FAILURE"}]'
grep -q 'a: FAILURE' "$tmp/out" && ok "wait: names the failed check" || bad "wait: names the failed check"
wait_checks "a failed check while another runs" 1 '[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"CheckRun","name":"b","status":"IN_PROGRESS","conclusion":""}]' TENX_WAIT_CAP=60
grep -q 'a: FAILURE' "$tmp/out" && ok "wait: stops on the first failure" || bad "wait: stops on the first failure"
wait_checks "pending past the cap" 1 '[{"__typename":"CheckRun","name":"gates (macos-latest)","status":"QUEUED","conclusion":""}]'
grep -q 'still pending after 0s' "$tmp/out" && grep -q 'gates (macos-latest): QUEUED' "$tmp/out" && ok "wait: names the checks still running at the cap" || bad "wait: names the checks still running at the cap"
: >"$tmp/stub.log"
STUB_VIEW="main OPEN false" STUB_CHECKS='{"headRefOid":"0000000000000000000000000000000000000000","statusCheckRollup":[]}' expect "wait: PR head is not the worktree's HEAD" 2 env TENX_WAIT_INTERVAL=0 TENX_WAIT_CAP=0 10x-land wait L1
grep -q 'push first' "$tmp/out" && ok "wait: says push first" || bad "wait: says push first"
STUB_VIEW="develop OPEN false" expect "wait refuses a PR into another base" 2 env TENX_WAIT_INTERVAL=0 10x-land wait L1
expect "wait refuses a non-number cap" 2 env TENX_WAIT_CAP=1m 10x-land wait L1
grep -qxF 'pr view feat/L1 --repo github.com/acme/land --json headRefOid,statusCheckRollup' "$tmp/stub.log" && ok "wait: pinned to origin's repo and the branch" || bad "wait: pinned to origin's repo and the branch"
seq_dir="$tmp/seq"; mkdir -p "$seq_dir"
checks '[{"__typename":"CheckRun","name":"a","status":"QUEUED","conclusion":""}]' >"$seq_dir/1"
checks '[{"__typename":"CheckRun","name":"a","status":"IN_PROGRESS","conclusion":""}]' >"$seq_dir/2"
checks '[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]' >"$seq_dir/3"
wait_checks "pending, then green" 0 '[]' TENX_WAIT_CAP=60 STUB_CHECKS_SEQ="$seq_dir"
[ "$(grep -c headRefOid "$tmp/stub.log")" -eq 3 ] && ok "wait: polled until green" || bad "wait: polled until green"
rm -r "$seq_dir"; mkdir -p "$seq_dir"
mkdir -p "$lw/.github/workflows"; printf 'on:\n  pull_request:\n' >"$lw/.github/workflows/ci.yml"
git -C "$lw" commit -qam "ci: pull_request"; lwsha="$(git -C "$lw" rev-parse HEAD)"
checks '[]' >"$seq_dir/1"; checks '[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]' >"$seq_dir/2"
wait_checks "no checks yet, then green" 0 '[]' TENX_WAIT_CAP=60 STUB_CHECKS_SEQ="$seq_dir"
wait_checks "no checks yet past the cap" 1 '[]'
grep -q 'no checks yet, but a workflow runs on pull_request' "$tmp/out" && ok "wait: names the missing checks at the cap" || bad "wait: names the missing checks at the cap"
git -C "$lw" reset -q --hard "$lw_before"; lwsha="$lw_before"
git remote set-url origin https://gitlab.example.com/grp/land.git
expect "wait refuses a GitLab origin" 2 10x-land wait L1
git remote set-url origin git@github.com:acme/land.git
STUB_CHECKS="$(checks '[]')"; export STUB_CHECKS

git remote set-url origin https://notgithub.com/acme/land.git
: >"$tmp/stub.log"
STUB_VIEW="main OPEN false" expect "merge refuses a host that only contains github.com" 2 10x-land merge L1
[ ! -s "$tmp/stub.log" ] && ok "no gh call for a look-alike host on merge" || bad "no gh call for a look-alike host on merge"
git remote set-url origin https://evil.example/x@github.com/acme/land.git
: >"$tmp/stub.log"
STUB_VIEW="main OPEN false" expect "merge refuses an @ in the path posing as the host" 2 10x-land merge L1
[ ! -s "$tmp/stub.log" ] && ok "no gh call for an @-spoofed host" || bad "no gh call for an @-spoofed host"
git remote set-url origin https://gitlab.example.com/grp/land.git
: >"$tmp/stub.log"
expect "merge via glab refuses an MR without project ids" 2 env STUB_VIEW='{"target_branch":"main","state":"opened"}' 10x-land merge L1
expect "merge via glab refuses a fork's MR" 2 env STUB_VIEW='{"target_branch":"main","state":"opened","source_project_id":2,"target_project_id":1}' 10x-land merge L1
! grep -q 'mr merge' "$tmp/stub.log" && ok "no glab merge call for a fork's MR" || bad "no glab merge call for a fork's MR"
expect "merge via glab" 0 env STUB_VIEW='{"target_branch":"main","state":"opened","source_project_id":1,"target_project_id":1}' 10x-land merge L1
grep -qxF 'mr view feat/L1 -R https://gitlab.example.com/grp/land --output json' "$tmp/stub.log" && ok "glab mr view pinned to origin's project" || bad "glab mr view pinned to origin's project"
grep -qxF 'mr merge feat/L1 -R https://gitlab.example.com/grp/land --squash --yes --sha '"$lwsha" "$tmp/stub.log" && ok "glab called with mr merge <branch> -R <url> --squash --yes --sha <sha>" || bad "glab called with mr merge <branch> -R <url> --squash --yes --sha <sha>"
git remote set-url origin "$tmp/github.com/land.git"

# pr / issue: argv is built from files under .10x/ and origin alone
land_log() { grep -qxF -- "$1" "$tmp/stub.log" && ok "$2" || { bad "$2"; cat "$tmp/stub.log"; }; }
mkdir -p "$tmp/land/.10x/L1" "$tmp/land/.10x/drafts"
td="$(cd "$tmp/land/.10x/L1" && pwd -P)"
git remote set-url origin git@github.com:acme/land.git
expect "pr refuses a missing title and body" 2 10x-land pr L1
printf 'feat: the feature\nignored second line\n' >"$td/pr-title"
expect "pr refuses a missing body" 2 10x-land pr L1
printf 'Closes #1\n' >"$td/pr-body.md"
: >"$tmp/stub.log"
STUB_VIEW_RC=1 expect "pr creates via gh" 0 10x-land pr L1
land_log "pr create --repo github.com/acme/land --base main --head feat/L1 --title feat: the feature --body-file $td/pr-body.md" "gh pr create argv"
: >"$tmp/stub.log"
STUB_VIEW="main OPEN false" expect "pr updates via gh" 0 10x-land pr L1
land_log "pr edit feat/L1 --repo github.com/acme/land --body-file $td/pr-body.md" "gh pr edit argv"
: >"$tmp/stub.log"
STUB_VIEW="develop OPEN false" expect "pr refuses an open PR into another base" 2 10x-land pr L1
! grep -qE 'pr (edit|create)' "$tmp/stub.log" && ok "no edit or create for a wrong base" || bad "no edit or create for a wrong base"
STUB_VIEW="main OPEN true" expect "pr refuses a fork's open PR" 2 10x-land pr L1
! grep -qE 'pr (edit|create)' "$tmp/stub.log" && ok "no edit or create for a fork's PR" || bad "no edit or create for a fork's PR"
STUB_VIEW="main MERGED false" STUB_STATE="MERGED https://github.com/acme/land/pull/1" expect "pr refuses a branch whose PR is merged" 2 10x-land pr L1
grep -qF 'https://github.com/acme/land/pull/1' "$tmp/out" && ok "merged-PR refusal names the URL" || { bad "merged-PR refusal names the URL"; cat "$tmp/out"; }
! grep -qE 'pr (edit|create)' "$tmp/stub.log" && ok "no edit or create for a merged PR" || bad "no edit or create for a merged PR"
# pr and merge refuse a push URL naming another repo; the same repo over https is allowed
git config remote.origin.pushurl https://github.com/evil/land.git
: >"$tmp/stub.log"
STUB_VIEW_RC=1 expect "pr refuses a push URL to another repo" 2 10x-land pr L1
STUB_VIEW="main OPEN false" expect "merge refuses a push URL to another repo" 2 10x-land merge L1
[ ! -s "$tmp/stub.log" ] && ok "no gh call with a mismatched push URL" || bad "no gh call with a mismatched push URL"
git config remote.origin.pushurl https://github.com/acme/land.git
STUB_VIEW_RC=1 expect "pr allows the same repo over https" 0 10x-land pr L1
land_log "pr create --repo github.com/acme/land --base main --head feat/L1 --title feat: the feature --body-file $td/pr-body.md" "gh pr create argv with an equivalent push URL"
git config --unset remote.origin.pushurl
git remote set-url origin https://gitlab.example.com/grp/sub/land.git
: >"$tmp/stub.log"
STUB_VIEW_RC=1 expect "pr creates via glab" 0 10x-land pr L1
land_log "mr create -R https://gitlab.example.com/grp/sub/land --target-branch main --source-branch feat/L1 --title feat: the feature --description Closes #1 --yes" "glab mr create argv"
: >"$tmp/stub.log"
STUB_VIEW='{"target_branch":"main","state":"opened","source_project_id":2,"target_project_id":1}' expect "pr refuses a fork's open MR" 2 10x-land pr L1
! grep -qE 'mr (update|create)' "$tmp/stub.log" && ok "no update or create for a fork's MR" || bad "no update or create for a fork's MR"
STUB_VIEW='{"target_branch":"main","state":"opened","source_project_id":1,"target_project_id":1}' expect "pr updates via glab" 0 10x-land pr L1
land_log "mr update feat/L1 -R https://gitlab.example.com/grp/sub/land --description Closes #1" "glab mr update argv"
git remote set-url origin git@github.com:acme/land.git
: >"$tmp/stub.log"
expect "pr rejects extra arguments" 2 10x-land pr L1 --fill
expect "pr rejects a bad id" 2 10x-land pr '../x'
: >"$td/pr-title"
expect "pr refuses an empty title" 2 10x-land pr L1
printf 'feat: the feature\n' >"$td/pr-title"
mv "$td/pr-body.md" "$tmp/real-body.md"; ln -s "$tmp/real-body.md" "$td/pr-body.md"
expect "pr refuses a symlinked body" 2 10x-land pr L1
[ ! -s "$tmp/stub.log" ] && ok "no call for refused pr" || bad "no call for refused pr"
rm "$td/pr-body.md"

# check names the worktree's PR/MR template; pr refuses a body lacking its ## headings (on PT, so L1 stays as is)
10x-worktree add PT --no-setup >/dev/null
pt="$tmp/land/.worktrees/PT"
put() { mkdir -p "$pt/$(dirname "$1")" && printf '## Summary\n\n## Test plan\n' >"$pt/$1"; }
commit_pt() { git -C "$pt" add -A && git -C "$pt" commit -q --allow-empty -m "$1"; }
clear_pt() {
  local p
  for p in .github .gitlab docs tdocs pull_request_template.md real.md; do
    [ ! -e "$pt/$p" ] && [ ! -L "$pt/$p" ] || rm -r "${pt:?}/$p"
  done
  commit_pt "chore: no template"
}
tpl_is() { [ "$(grep '^pr template:' "$tmp/out")" = "pr template: $1" ] && ok "$2" || { bad "$2"; cat "$tmp/out"; }; }
put .github/pull_request_template.md; commit_pt "docs: template"
expect "check names .github/pull_request_template.md" 0 10x-land check PT
tpl_is .github/pull_request_template.md "check: .github/pull_request_template.md"
put pull_request_template.md; commit_pt "docs: root template"
expect "check prefers .github/ over the root template" 0 10x-land check PT
tpl_is .github/pull_request_template.md "check: .github/ wins over the root"
clear_pt; put pull_request_template.md; commit_pt "docs: root template"
expect "check names a root pull_request_template.md" 0 10x-land check PT
tpl_is pull_request_template.md "check: root pull_request_template.md"
clear_pt; put docs/pull_request_template.md; commit_pt "docs: docs template"
expect "check names docs/pull_request_template.md" 0 10x-land check PT
tpl_is docs/pull_request_template.md "check: docs/pull_request_template.md"
clear_pt; put .github/PULL_REQUEST_TEMPLATE.md; commit_pt "docs: uppercase template"
expect "check names an uppercase PULL_REQUEST_TEMPLATE.md" 0 10x-land check PT
tpl_is .github/PULL_REQUEST_TEMPLATE.md "check: the spelling on disk"
clear_pt; put .github/PULL_REQUEST_TEMPLATE/bug.md; put .github/PULL_REQUEST_TEMPLATE/.hidden.md
put .github/PULL_REQUEST_TEMPLATE/notes.txt; put .github/PULL_REQUEST_TEMPLATE/sub/x.md; commit_pt "docs: one template in a dir"
expect "check names the one template in .github/PULL_REQUEST_TEMPLATE/" 0 10x-land check PT
tpl_is .github/PULL_REQUEST_TEMPLATE/bug.md "check: the one .md of the directory"
put .github/PULL_REQUEST_TEMPLATE/feature.MD; commit_pt "docs: two templates in a dir"
expect "check prints none for several templates in .github/PULL_REQUEST_TEMPLATE/" 0 10x-land check PT
tpl_is none "check: several templates in a directory"
clear_pt; put real.md; ln -s real.md "$pt/pull_request_template.md"; commit_pt "docs: symlinked template"
expect "check skips a symlinked template" 0 10x-land check PT
tpl_is none "check: a symlinked template does not count"
clear_pt; put real.md; ln -s real.md "$pt/pull_request_template.md"; put "pull_request_template.md"$'\n'
put tdocs/pull_request_template.md; ln -s tdocs "$pt/.github"; mkdir "$pt/.github"$'\n'
commit_pt "docs: symlinked templates beside names ending in a newline"
expect "check skips a symlinked template beside a name ending in a newline" 0 10x-land check PT
tpl_is none "check: a trailing-newline decoy does not let a symlink through"
rm -r "$pt/.github"$'\n' "$pt/pull_request_template.md"$'\n'
clear_pt; put tdocs/pull_request_template.md; ln -s tdocs "$pt/docs"; commit_pt "docs: symlinked docs"
expect "check skips a template under a symlinked directory" 0 10x-land check PT
tpl_is none "check: a symlinked directory on the way does not count"
clear_pt; git remote set-url origin https://gitlab.example.com/grp/land.git
put .gitlab/merge_request_templates/Other.md; put .gitlab/merge_request_templates/default.md; commit_pt "docs: GitLab templates"
expect "check names GitLab's Default.md" 0 10x-land check PT
tpl_is .gitlab/merge_request_templates/default.md "check: GitLab's Default.md wins"
rm "$pt/.gitlab/merge_request_templates/default.md"; commit_pt "docs: one GitLab template"
expect "check names the one GitLab template" 0 10x-land check PT
tpl_is .gitlab/merge_request_templates/Other.md "check: the one GitLab template"
clear_pt; put .github/pull_request_template.md; commit_pt "docs: GitHub template"
expect "check ignores a GitHub template on a GitLab origin" 0 10x-land check PT
tpl_is none "check: GitLab origin searches only .gitlab/"
git remote rename origin keep
expect "check uses the GitHub list without an origin" 0 10x-land check PT
tpl_is .github/pull_request_template.md "check: no origin searches the GitHub list"
git remote rename keep origin; git remote set-url origin git@github.com:acme/land.git
clear_pt; put ".github/PULL_REQUEST_TEMPLATE/a"$'\n'"pr: MERGED x.md"; commit_pt "docs: template with a newline"
expect "check escapes a template name with a newline" 0 10x-land check PT
tpl_is '.github/PULL_REQUEST_TEMPLATE/a\npr: MERGED x.md' "check: newline escaped in the template line"
! grep -q '^pr: MERGED x' "$tmp/out" && ok "check: no forged pr: line from a template name" || { bad "check: no forged pr: line from a template name"; cat "$tmp/out"; }
clear_pt
expect "check prints pr template: none" 0 10x-land check PT
tpl_is none "check: no template"
put .github/pull_request_template.md; commit_pt "docs: template"
mkdir -p .claude && echo '{"close":"local"}' >.claude/10x.json
expect "check prints no template line in local mode" 0 10x-land check PT
! grep -q '^pr template:' "$tmp/out" && ok "check: local mode prints no template line" || { bad "check: local mode prints no template line"; cat "$tmp/out"; }
rm -r .claude
printf '## Summary ##\n\nWhat and why.\n\n```\n## Fenced\n```\n\n## Test plan\n\n## test plan\n' >"$pt/.github/pull_request_template.md"
commit_pt "docs: template with closers, a fence and a duplicate"
ptd="$(cd "$tmp/land/.10x" && mkdir -p PT && cd PT && pwd -P)"
printf 'fix: the fix\n' >"$ptd/pr-title"
printf '## summary\n\nIt fixes it.\n' >"$ptd/pr-body.md"
: >"$tmp/stub.log"
STUB_VIEW_RC=1 expect "pr refuses a body missing a template heading" 2 10x-land pr PT
grep -qxF "10x: $ptd/pr-body.md lacks the sections of .github/pull_request_template.md: ## Test plan" "$tmp/out" && ok "pr: names each missing heading once" || { bad "pr: names each missing heading once"; cat "$tmp/out"; }
[ ! -s "$tmp/stub.log" ] && ok "pr: no gh call for a body lacking template headings" || { bad "pr: no gh call for a body lacking template headings"; cat "$tmp/stub.log"; }
printf '## Summary\n\nIt fixes it.\n\n## Test plan\n\nTests.\n' >"$ptd/pr-body.md"
STUB_VIEW_RC=1 expect "pr accepts a body with every template heading" 0 10x-land pr PT
grep -q '^pr create ' "$tmp/stub.log" && ok "pr: creates the PR once every heading is there" || { bad "pr: creates the PR once every heading is there"; cat "$tmp/stub.log"; }

printf '# Add the thing\nLabels: bug, ui\nType: Bug\n\n## Context\nbody\n\n## Acceptance criteria\n- [ ] AC1 — it exists\n' >"$tmp/land/.10x/drafts/thing.md"
STUB_LABELS=$'bug\nui\nother'
export STUB_LABELS
: >"$tmp/stub.log"
expect "issue create" 0 10x-land issue thing
grep -qE -- '^issue create --repo github.com/acme/land --title Add the thing --body-file .+ --label bug --label ui --type Bug$' "$tmp/stub.log" && ok "gh issue create argv" || bad "gh issue create argv"
[ ! -e "$tmp/land/.10x/drafts/thing.md" ] && ok "issue deletes the draft once the issue exists" || bad "issue deletes the draft once the issue exists"
printf '# Add the thing\nLabels: bug, ui\nType: Bug\n\n## Context\nbody\n\n## Acceptance criteria\n- [ ] AC1 — it exists\n' >"$tmp/land/.10x/drafts/thing.md"
: >"$tmp/stub.log"
STUB_CREATE_RC=1 expect "issue exits with gh's code when gh issue create fails" 1 10x-land issue thing
grep -q 'issue create' "$tmp/stub.log" && [ -f "$tmp/land/.10x/drafts/thing.md" ] && ok "issue keeps the draft when gh issue create fails" || bad "issue keeps the draft when gh issue create fails"
expect "issue rejects a path slug" 2 10x-land issue ../x
expect "issue rejects a slash slug" 2 10x-land issue a/b
expect "issue rejects extra arguments" 2 10x-land issue thing --label x
printf '# T\nLabels: bug, nope\n\nb\n\n## Acceptance criteria\n- [ ] AC1 — it exists\n' >"$tmp/land/.10x/drafts/bad.md"
: >"$tmp/stub.log"
expect "issue refuses an unknown label" 2 10x-land issue bad
! grep -q 'issue create' "$tmp/stub.log" && ok "no create call for an unknown label" || bad "no create call for an unknown label"
ln -s "$tmp/land/.10x/drafts/thing.md" "$tmp/land/.10x/drafts/link.md"
expect "issue refuses a symlinked draft" 2 10x-land issue link
printf '# T\nLabels:\n\nb\n\n## Acceptance criteria\n- [ ] AC1 — it exists\n' >"$tmp/land/.10x/drafts/nolabel.md"
: >"$tmp/stub.log"
expect "issue with an empty Labels: line" 0 10x-land issue nolabel
! grep -q -- '--label' "$tmp/stub.log" && ok "no --label for an empty Labels: line" || bad "no --label for an empty Labels: line"
mv "$tmp/land/.10x/drafts" "$tmp/drafts-elsewhere"; ln -s "$tmp/drafts-elsewhere" "$tmp/land/.10x/drafts"
expect "issue refuses a draft under a symlinked drafts dir" 2 10x-land issue thing
rm "$tmp/land/.10x/drafts"; mv "$tmp/drafts-elsewhere" "$tmp/land/.10x/drafts"
# issue: no-form drafts need numbered criteria and no banned phrase; forms add required sections
dr="$tmp/land/.10x/drafts"
refuse() { # <description> <expected text in the message> <slug>
  : >"$tmp/stub.log"
  expect "$1" 2 10x-land issue "$3"
  grep -qF -- "$2" "$tmp/out" && ok "$1: names '$2'" || { bad "$1: names '$2'"; cat "$tmp/out"; }
  ! grep -q 'issue create' "$tmp/stub.log" && ok "$1: no create call" || bad "$1: no create call"
}
printf '# T\n\n## Context\nb\n' >"$dr/nocrit.md"
refuse "issue refuses a draft without a criteria section" 'Acceptance criteria' nocrit
printf '# T\n\n## Acceptance criteria\nsome prose\n' >"$dr/nobox.md"
refuse "issue refuses a criteria section without a checkbox" 'no checkbox criterion' nobox
printf '# T\n\n## Acceptance criteria\n- [ ] AC1 — fine\n- [ ] it exists\n' >"$dr/noac.md"
refuse "issue refuses a criterion without AC<n>" 'line 5' noac
printf '# T\n\n## Acceptance criteria\n- [ ] AC1 it exists\n' >"$dr/nodash.md"
refuse "issue refuses AC<n> without a dash" 'line 4' nodash
printf '# T\n\n## Acceptance criteria\n- [ ] AC1 — a [ ] AC2 — b\n' >"$dr/two.md"
refuse "issue refuses two checkboxes on one line" 'two checkboxes' two
while IFS= read -r p; do
  case "$p" in ''|'#'*) continue ;; esac
  printf '# T\n\nIt is %s.\n\n## Acceptance criteria\n- [ ] AC1: ok\n' "$p" | tr '[:lower:]' '[:upper:]' | sed '1s/.*/# T/' >"$dr/banned.md"
  refuse "issue refuses the banned phrase '$p' in any case" "line 3: banned phrase \"$p\"" banned
done <"$BIN/../references/banned-phrases.txt"
printf '# T\n\n`handle edge cases` and\n```\netc.\n```\n\n## Acceptance criteria\n- [ ] AC1: ok\n- [ ] AC2 – ok\n- [x] AC3 - ok\n' >"$dr/code.md"
: >"$tmp/stub.log"
expect "issue ignores banned phrases in code and accepts every dash" 0 10x-land issue code
printf '# T\n\nappropriately, inappropriate, /etc/hosts and TBDs\n\n## Acceptance criteria\n- [ ] AC1: ok\n' >"$dr/word.md"
expect "issue matches banned phrases on word boundaries" 0 10x-land issue word
# ticket: tickets: files writes the draft under .10x/<slug>/ with no gh call; issue refuses that mode
mkdir -p .claude && echo '{"tickets":"files"}' >.claude/10x.json
: >"$tmp/stub.log"
expect "issue exits 2 in files mode" 2 10x-land issue thing
grep -qF "issue needs tickets: github, but this repo's tickets are files" "$tmp/out" && [ ! -s "$tmp/stub.log" ] && [ -f "$dr/thing.md" ] &&
  ok "issue refuses files mode before any gh call" || { bad "issue refuses files mode before any gh call"; cat "$tmp/out" "$tmp/stub.log"; }
printf '# Keep it local\n\n## Context\nbody\n\n## Acceptance criteria\n- [ ] AC1 — it exists\n' >"$dr/filed.md"
cp "$dr/filed.md" "$tmp/filed.want"
git remote rename origin keep
expect "ticket filed" 0 10x-land ticket filed
git remote rename keep origin
ftd="$(cd "$tmp/land/.10x" && pwd -P)/filed"
cmp -s "$ftd/ticket.md" "$tmp/filed.want" && [ ! -e "$dr/filed.md" ] && [ ! -s "$tmp/stub.log" ] &&
  { grep -qxF "ticket: $ftd/ticket.md" "$tmp/out" || grep -qxF "ticket: $tmp/land/.10x/filed/ticket.md" "$tmp/out"; } &&
  ok "ticket writes the draft to .10x/<slug>/ticket.md and deletes it" || { bad "ticket writes the draft to .10x/<slug>/ticket.md and deletes it"; cat "$tmp/out" "$tmp/stub.log"; }
printf '# Another\n\n## Acceptance criteria\n- [ ] AC1 — other\n' >"$dr/filed.md"
mkdir "$tmp/land/.10x/empty"; cp "$dr/filed.md" "$dr/empty.md"
expect "ticket exits 2 on an existing ticket dir" 2 10x-land ticket filed
grep -qF ".10x/filed/ already exists" "$tmp/out" && cmp -s "$ftd/ticket.md" "$tmp/filed.want" && [ -f "$dr/filed.md" ] &&
  ! 10x-land ticket empty >/dev/null 2>&1 && [ ! -e "$tmp/land/.10x/empty/ticket.md" ] && [ -f "$dr/empty.md" ] &&
  ok "ticket refuses an existing ticket dir" || { bad "ticket refuses an existing ticket dir"; cat "$tmp/out"; }
rm "$dr/filed.md" "$dr/empty.md"; rmdir "$tmp/land/.10x/empty"
checks_bad=0
for s in nocrit:'Acceptance criteria' nobox:'no checkbox criterion' noac:'line 5' nodash:'line 4' two:'two checkboxes' banned:'banned phrase'; do
  slug="${s%%:*}"; msg="${s#*:}"
  10x-land ticket "$slug" >"$tmp/out" 2>&1; rc=$?
  { [ "$rc" -eq 2 ] && grep -qF -- "$msg" "$tmp/out" && [ ! -e "$tmp/land/.10x/$slug" ] && [ -f "$dr/$slug.md" ]; } || { checks_bad=1; echo "      $slug:"; cat "$tmp/out"; }
done
[ ! -s "$tmp/stub.log" ] || checks_bad=1
[ "$checks_bad" = 0 ] && ok "ticket applies the checks of issue" || bad "ticket applies the checks of issue"
header_bad=0
for h in 'Labels: bug' 'Labels:' 'Type: Bug' 'Form: bug.yml'; do
  printf '# T\n%s\n\n## Acceptance criteria\n- [ ] AC1 — ok\n' "$h" >"$dr/hdr.md"
  10x-land ticket hdr >"$tmp/out" 2>&1; rc=$?
  { [ "$rc" -eq 2 ] && grep -qF "line 2: '$h' is a GitHub header line" "$tmp/out" && [ ! -e "$tmp/land/.10x/hdr" ]; } || { header_bad=1; echo "      $h:"; cat "$tmp/out"; }
done
rm "$dr/hdr.md"
[ "$header_bad" = 0 ] && ok "ticket refuses a GitHub header line" || bad "ticket refuses a GitHub header line"
sec_hdr="Security: sha256:$(printf 'a%.0s' {1..64})"
printf '# T\n%s\n\n## Context\nx\n\n## Acceptance criteria\n- [ ] AC1 — ok\n' "$sec_hdr" >"$dr/sechdr.md"
cp "$dr/sechdr.md" "$tmp/sechdr.want"
expect "ticket: accepts a Security header" 0 10x-land ticket sechdr
cmp -s "$tmp/land/.10x/sechdr/ticket.md" "$tmp/sechdr.want" && grep -qxF "$sec_hdr" "$tmp/land/.10x/sechdr/ticket.md" && [ ! -e "$dr/sechdr.md" ] &&
  ok "ticket keeps a Security header line" || { bad "ticket keeps a Security header line"; cat "$tmp/out"; }
printf '# T\n\n## Acceptance criteria\n- [ ] AC1 — ok\n' >"$dr/gh-7.md"; cp "$dr/gh-7.md" "$dr/drafts.md"
expect "ticket exits 2 on a gh-<n> slug" 2 10x-land ticket gh-7
grep -qF "slug 'gh-7' is the id of a GitHub issue ticket" "$tmp/out" && [ ! -e "$tmp/land/.10x/gh-7" ] && reserved=ok || reserved=bad
expect "ticket exits 2 on the drafts slug" 2 10x-land ticket drafts
grep -qF "slug 'drafts' is reserved" "$tmp/out" && [ -f "$dr/drafts.md" ] && [ "$reserved" = ok ] &&
  ok "ticket refuses a gh-<n> or drafts slug" || { bad "ticket refuses a gh-<n> or drafts slug"; cat "$tmp/out"; }
rm "$dr/gh-7.md" "$dr/drafts.md"
printf '# T\n\n## Acceptance criteria\n- [ ] AC1 — ok\n' >"$dr/audit.md"
expect "ticket exits 2 on the audit slug" 2 10x-land ticket audit
grep -qF "slug 'audit' is reserved for .10x/audit/" "$tmp/out" && [ -f "$dr/audit.md" ] && [ ! -e "$tmp/land/.10x/audit/ticket.md" ] &&
  ok "ticket refuses the audit slug" || { bad "ticket refuses the audit slug"; cat "$tmp/out"; }
rm -rf "$tmp/land/.10x/audit"; rm "$dr/audit.md"
rm -r .claude
printf '# T\n\n## Acceptance criteria\n- [ ] AC1 — ok\n' >"$dr/ongh.md"
expect "ticket exits 2 in github mode" 2 10x-land ticket ongh
grep -qF "ticket needs tickets: files, but this repo's tickets are github" "$tmp/out" && [ -f "$dr/ongh.md" ] && [ ! -e "$tmp/land/.10x/ongh" ] &&
  ok "ticket refuses github mode" || { bad "ticket refuses github mode"; cat "$tmp/out"; }
rm "$dr/ongh.md"

# advisory and the issue route guard, on a public repo with one release and a security log of two entries: 1 is confirmed
# high in the released bin/deploy.sh (route: advisory), 2 is low (route: issue).
adv="$tmp/adv"
git -c init.defaultBranch=main init -q "$adv"
cd "$adv" || exit 2
git config user.email t@t; git config user.name t
mkdir bin; seq 1 15 | sed 's/^/echo line /' >bin/deploy.sh
git add -A && git commit -qm "init" && git tag v1.0.0
git remote add origin git@github.com:acme/adv.git
advp="$(pwd -P)"
mkdir -p .10x/drafts
{
  printf '# Security entries\n'
  sec_entry 1 confirmed high 'Shell injection in deploy hook' bin/deploy.sh:12 later gh-1
  sec_entry 2 confirmed low 'Weak temp file in backup job' bin/deploy.sh:3 later gh-1
} >.10x/security.md
cp .10x/security.md "$tmp/adv-sec.before"
AF1="$(sec_fp 1)"; AF2="$(sec_fp 2)"
ZERO_FP="sha256:$(printf 'f%.0s' {1..64})"
GHSA_URL="https://github.com/acme/adv/security/advisories/GHSA-abcd-efgh-ijkl"
# adv_draft <slug> <fingerprint> [<context line>] — a draft whose one header line is `Security: <fingerprint>`.
adv_draft() {
  printf '# Fix security entry 00000000\nSecurity: %s\n\n## Context\n%s\n\n## Acceptance criteria\n- [ ] AC1 — The entry is fixed.\n' \
    "$2" "${3:-Security entry in the local security log.}" >"$adv/.10x/drafts/$1.md"
}
# api_calls — the number of advisory requests gh was given.
api_calls() { grep -c 'security-advisories' "$tmp/stub.log"; }

adv_draft security-00000000 "$AF1"
cp .10x/drafts/security-00000000.md "$tmp/adv-draft.want"
awk -v l="Advisory: GHSA-abcd-efgh-ijkl $GHSA_URL" '{ print } /^Security: / { print l }' "$tmp/adv-draft.want" >"$tmp/adv-ticket.want"
: >"$tmp/stub.log"
STUB_ADV_COPY="$tmp/adv-req.json" expect "advisory: runs on a released high entry" 0 10x-land advisory security-00000000
adv_ok=1
grep -qxF "advisory: $GHSA_URL" "$tmp/out" || adv_ok=0
{ grep -qxF "ticket: $adv/.10x/security-00000000/ticket.md" "$tmp/out" || grep -qxF "ticket: $advp/.10x/security-00000000/ticket.md" "$tmp/out"; } || adv_ok=0
grep -qE -- '^api --hostname github.com -X POST repos/acme/adv/security-advisories --input .+$' "$tmp/stub.log" || adv_ok=0
grep -qxF "repo view github.com/acme/adv --json visibility --jq .visibility" "$tmp/stub.log" || adv_ok=0
# shellcheck disable=SC2016  # JavaScript, not shell
node -e '
  const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")), v = (r.vulnerabilities || [])[0] || {}
  const ok = r.summary === "Fix security entry 00000000" && r.severity === "high" && r.description.startsWith("## Context") &&
    !r.description.includes("Security: ") && v.package && v.package.ecosystem === "other" && v.package.name === "adv" &&
    v.vulnerable_version_range === "<= v1.0.0" && !("start_private_fork" in r) && !("patched_versions" in v)
  process.exit(ok ? 0 : 1)
' "$tmp/adv-req.json" || { adv_ok=0; cat "$tmp/adv-req.json" 2>&1; }
cmp -s ".10x/security-00000000/ticket.md" "$tmp/adv-ticket.want" || adv_ok=0
[ ! -e .10x/drafts/security-00000000.md ] || adv_ok=0
[ "$adv_ok" = 1 ] && ok "advisory creates a draft advisory and a local ticket" || { bad "advisory creates a draft advisory and a local ticket"; cat "$tmp/out" "$tmp/stub.log"; }

adv_draft security-0000000f "$AF1"
cp .10x/drafts/security-0000000f.md "$tmp/adv-draft.want"
: >"$tmp/stub.log"
STUB_ADV_RC=1 expect "advisory: exits 0 when gh api fails" 0 10x-land advisory security-0000000f
adv_ok=1
grep -qxF "10x: gh api failed (exit 1):" "$tmp/out" || adv_ok=0
grep -qxF "gh: Resource not accessible by integration" "$tmp/out" || adv_ok=0
{ grep -qxF "ticket: $adv/.10x/security-0000000f/ticket.md" "$tmp/out" || grep -qxF "ticket: $advp/.10x/security-0000000f/ticket.md" "$tmp/out"; } || adv_ok=0
! grep -q '^advisory:' "$tmp/out" || adv_ok=0
cmp -s ".10x/security-0000000f/ticket.md" "$tmp/adv-draft.want" || adv_ok=0
[ ! -e .10x/drafts/security-0000000f.md ] || adv_ok=0
[ "$adv_ok" = 1 ] && ok "advisory keeps the local ticket when gh api fails" || { bad "advisory keeps the local ticket when gh api fails"; cat "$tmp/out" "$tmp/stub.log"; }

mkdir -p .claude && echo '{"tickets":"files"}' >.claude/10x.json
adv_draft security-0000000e "$AF1"
: >"$tmp/stub.log"
expect "advisory: exits 2 with tickets files" 2 10x-land advisory security-0000000e
[ ! -s "$tmp/stub.log" ] && [ ! -e .10x/security-0000000e ] && [ -f .10x/drafts/security-0000000e.md ] &&
  ok "advisory refuses with tickets files and creates nothing" || { bad "advisory refuses with tickets files and creates nothing"; cat "$tmp/out" "$tmp/stub.log"; }
rm -r .claude .10x/drafts/security-0000000e.md

# refused <slug> <text the message names> — advisory exits 2, names the text, calls no advisory API and creates nothing.
adv_refused() {
  : >"$tmp/stub.log"
  10x-land advisory "$1" >"$tmp/out" 2>&1; local rc=$?
  [ "$rc" -eq 2 ] && grep -qF -- "$2" "$tmp/out" && [ "$(api_calls)" = 0 ] && [ ! -e ".10x/$1" ] && [ -f ".10x/drafts/$1.md" ]
}
adv_bad=0
printf '# Fix security entry 00000000\n\n## Context\nNo Security line.\n\n## Acceptance criteria\n- [ ] AC1 — The entry is fixed.\n' >.10x/drafts/advnosec.md
adv_refused advnosec "Security" || { adv_bad=1; echo "      no Security line:"; cat "$tmp/out"; }
adv_draft advunknown "$ZERO_FP"
adv_refused advunknown "no security entry $ZERO_FP" || { adv_bad=1; echo "      unknown fingerprint:"; cat "$tmp/out"; }
adv_draft advlow "$AF2"
adv_refused advlow "routes to issue, not advisory" || { adv_bad=1; echo "      low entry:"; cat "$tmp/out"; }
adv_draft advprivate "$AF1"
STUB_VIS=PRIVATE adv_refused advprivate "routes to issue, not advisory" || { adv_bad=1; echo "      private repo:"; cat "$tmp/out"; }
adv_draft advloc "$AF1" "The sink is bin/deploy.sh:12."
adv_refused advloc "the draft names the location of security entry $AF1" && ! grep -qF 'deploy.sh' "$tmp/out" || { adv_bad=1; echo "      named location:"; cat "$tmp/out"; }
printf '# Fix security entry 00000000\nSecurity: %s\nLabels: bug\n\n## Context\nx\n\n## Acceptance criteria\n- [ ] AC1 — The entry is fixed.\n' "$AF1" >.10x/drafts/advlabel.md
adv_refused advlabel "Labels" || { adv_bad=1; echo "      Labels line:"; cat "$tmp/out"; }
[ "$adv_bad" = 0 ] && ok "advisory refuses a draft without Security, an unknown or non-advisory entry, or a named location" ||
  bad "advisory refuses a draft without Security, an unknown or non-advisory entry, or a named location"

# issue: the Security: line routes the draft. An advisory route is refused, naming the fingerprint and nothing else.
adv_draft advissue "$AF1"
: >"$tmp/stub.log"
10x-land issue advissue >"$tmp/out" 2>&1; rc=$?
[ "$rc" -ne 0 ] && grep -qF "draft security entry $AF1 routes to advisory: use 10x-land advisory advissue" "$tmp/out" &&
  ! grep -qiE 'injection|deploy' "$tmp/out" && ! grep -qE 'issue create|label list' "$tmp/stub.log" && [ -f .10x/drafts/advissue.md ] &&
  ok "issue refuses a draft whose security entry routes to advisory" || { bad "issue refuses a draft whose security entry routes to advisory (exit $rc)"; cat "$tmp/out" "$tmp/stub.log"; }

# On the issue route, a title or body that names the entry is refused before anything is created.
named_bad=0
for v in title fingerprint location entry-title; do
  case "$v" in
    title) printf '# Fix Weak temp file in backup job\nSecurity: %s\n\n## Context\nx\n\n## Acceptance criteria\n- [ ] AC1 — Fixed.\n' "$AF2" ;;
    fingerprint) printf '# Fix\nSecurity: %s\n\n## Context\nEntry %s.\n\n## Acceptance criteria\n- [ ] AC1 — Fixed.\n' "$AF2" "$AF2" ;;
    location) printf '# Fix\nSecurity: %s\n\n## Context\nSee bin/deploy.sh:3.\n\n## Acceptance criteria\n- [ ] AC1 — Fixed.\n' "$AF2" ;;
    entry-title) printf '# Fix\nSecurity: %s\n\n## Context\nThe weak TEMP FILE in backup job is the issue.\n\n## Acceptance criteria\n- [ ] AC1 — Fixed.\n' "$AF2" ;;
  esac >.10x/drafts/advnamed.md
  : >"$tmp/stub.log"
  10x-land issue advnamed >"$tmp/out" 2>&1; rc=$?
  { [ "$rc" -eq 2 ] && grep -qF "10x: draft advnamed contains security entry $AF2" "$tmp/out" && ! grep -qE 'issue create|label list' "$tmp/stub.log" &&
    [ -f .10x/drafts/advnamed.md ]; } || { named_bad=1; echo "      $v (exit $rc):"; cat "$tmp/out" "$tmp/stub.log"; }
done
rm -f .10x/drafts/advnamed.md
[ "$named_bad" = 0 ] && ok "issue refuses a security draft that names its entry" || bad "issue refuses a security draft that names its entry"

# A draft that names nothing is created, and its Security: line is a header, not part of the issue body.
adv_draft advclean "$AF2" 'A security fix planned in roadmap version v1; the entry is in `.10x/security.md`.'
: >"$tmp/stub.log"
STUB_BODY_COPY="$tmp/adv-body.md" expect "issue: creates a security draft that names nothing" 0 10x-land issue advclean
grep -qE -- '^issue create --repo github.com/acme/adv --title Fix security entry 00000000 --body-file .+' "$tmp/stub.log" &&
  [ "$(head -n 1 "$tmp/adv-body.md")" = "## Context" ] && ! grep -qF 'Security:' "$tmp/adv-body.md" && ! grep -qF "$AF2" "$tmp/adv-body.md" &&
  [ ! -e .10x/drafts/advclean.md ] &&
  ok "issue keeps the Security line out of the issue body" || { bad "issue keeps the Security line out of the issue body"; cat "$tmp/out" "$tmp/stub.log"; cat "$tmp/adv-body.md" 2>&1; }

cmp -s .10x/security.md "$tmp/adv-sec.before" && ok "advisory and issue leave security.md byte-identical" ||
  bad "advisory and issue leave security.md byte-identical"
cd "$tmp/land" || exit 2

# grill: prints the shared grill verbatim, takes no argument
10x-grill >"$tmp/grill.out" 2>&1 && cmp -s "$tmp/grill.out" "$BIN/../references/grill.md" \
  && ok "grill prints references/grill.md" || bad "grill prints references/grill.md"
expect "grill refuses an argument" 2 10x-grill open

# plan-check: a plan in the template's format passes; every line at fault is named
mkdir -p "$tmp/land/.10x/P1"
pc_part() { # <part> — one piece of the fixture plan
  case "$1" in
    head) cat <<'EOF'
# P1 — fixture

Status: approved

## Goal
A thing.

## Acceptance criteria
- AC1 — the first thing.
  - a nested note
- AC2: the second thing.

## Approach
Code may say `etc.` here.

## Files
- `src/a.mjs` — the change.
EOF
    ;;
    readers) cat <<'EOF'
## Readers
- `oldName` — `grep -rn oldName .` (gone)
  - `src/a.mjs:3` — renamed.
- `other` — `grep -rn other .`
  - no hits
EOF
    ;;
    readers-empty) printf '## Readers\n\n' ;;
    readers-nohit) cat <<'EOF'
## Readers
- `oldName` — `grep -rn oldName .` (gone)
  - `src/a.mjs:3` — renamed.
- `other` — `grep -rn other .`
EOF
    ;;
    tools) cat <<'EOF'
## Tool behaviour relied on
- `node` prints its version:
  ```
  $ node --version
  v22.0.0
  ```
EOF
    ;;
    tools-nooutput) cat <<'EOF'
## Tool behaviour relied on
- `node` prints its version:
  ```
  $ node --version
  ```
EOF
    ;;
    overlap) printf '## Overlap\n- `origin/main`: none — `git log --oneline HEAD..origin/main` printed nothing.\n' ;;
    overlap-empty) printf '## Overlap\n\n' ;;
    tests) cat <<'EOF'
## Tests
| AC | Test file | Case |
|---|---|---|
| AC1 | `tests/a.test.sh` | `does the first thing` |
| AC2 | — | read the diff |
EOF
    ;;
    files3) printf -- '- `src/b.mjs` — the second change.\n- `src/c.mjs` — the third change.\n' ;;
    files4) printf -- '- `src/b.mjs` — the second change.\n- `src/c.mjs` — the third change.\n- `src/d.mjs` — the fourth change.\n' ;;
    tests-noac2) printf '## Tests\n| AC | Test file | Case |\n|---|---|---|\n| AC1 | `tests/a.test.sh` | `does the first thing` |\n' ;;
    tests-header) printf '## Tests\n| Criterion | Test | Case |\n|---|---|---|\n| AC1 | `tests/a.test.sh` | `x` |\n| AC2 | — | read the diff |\n' ;;
  esac
}
pc_plan() { # <part>... — write .10x/P1/plan.md from the parts, in order
  local p; for p in "$@"; do pc_part "$p"; echo; done >"$tmp/land/.10x/P1/plan.md"
}
pc_names() { # <case> <text>... — the last run named each text
  local d=$1 t; shift
  for t in "$@"; do grep -qF -- "$t" "$tmp/out" || { bad "$d: names '$t'"; cat "$tmp/out"; return; }; done
  ok "$d: names each line"
}
pc_plan head readers tools overlap tests
expect "plan-check accepts a plan in the template's format" 0 10x-plan-check P1
pc_plan head readers tools overlap tests-noac2
expect "plan-check refuses a criterion with no Tests row" 1 10x-plan-check P1
pc_names "plan-check refuses a criterion with no Tests row" 'line 11: AC2 has no row in "## Tests"'
! grep -q 'AC1 has no row' "$tmp/out" && ok "plan-check: a covered criterion is not named" || bad "plan-check: a covered criterion is not named"
pc_plan head readers tools overlap tests-header
expect "plan-check refuses a Tests table with another header" 1 10x-plan-check P1
pc_names "plan-check refuses a Tests table with another header" 'Tests table header must be "| AC | Test file | Case |"'
pc_plan head readers tools overlap
expect "plan-check refuses a plan without a Tests section" 1 10x-plan-check P1
pc_names "plan-check refuses a plan without a Tests section" 'no "## Tests" section'
pc_plan head readers tools overlap tests
sed 's/^A thing\.$/A thing, as needed./' "$tmp/land/.10x/P1/plan.md" >"$tmp/pc" && mv "$tmp/pc" "$tmp/land/.10x/P1/plan.md"
expect "plan-check refuses a banned phrase" 1 10x-plan-check P1
pc_names "plan-check refuses a banned phrase" 'line 6: banned phrase "as needed"'
pc_plan head readers tools overlap tests
printf '## Notes\n`as needed` and\n```\nTBD etc.\n```\n' >>"$tmp/land/.10x/P1/plan.md"
expect "plan-check ignores a banned phrase in code" 0 10x-plan-check P1
pc_plan head readers-empty tools overlap tests
expect "plan-check refuses an empty Readers" 1 10x-plan-check P1
pc_names "plan-check refuses an empty Readers" 'line 19: "## Readers" is empty'
pc_plan head tools overlap tests
expect "plan-check refuses a missing Readers" 1 10x-plan-check P1
pc_names "plan-check refuses a missing Readers" 'no "## Readers" section'
pc_plan head readers-nohit tools overlap tests
expect "plan-check refuses a Readers entry with no hits" 1 10x-plan-check P1
pc_names "plan-check refuses a Readers entry with no hits" 'line 22: Readers entry has no hit line'
! grep -q 'line 20:' "$tmp/out" && ok "plan-check: an entry with a hit is not named" || bad "plan-check: an entry with a hit is not named"
pc_plan head readers tools-nooutput overlap tests
expect "plan-check refuses a tool claim without output" 1 10x-plan-check P1
pc_names "plan-check refuses a tool claim without output" 'line 26: tool claim has no fenced `$ <command>` block'
pc_plan head readers tools overlap-empty tests
expect "plan-check refuses an empty Overlap" 1 10x-plan-check P1
pc_names "plan-check refuses an empty Overlap" 'line 32: "## Overlap" is empty'
pc_plan head readers-nohit tools-nooutput overlap-empty tests-noac2
sed 's/^A thing\.$/A thing, as needed./' "$tmp/land/.10x/P1/plan.md" >"$tmp/pc" && mv "$tmp/pc" "$tmp/land/.10x/P1/plan.md"
expect "plan-check names every refusal" 1 10x-plan-check P1
pc_names "plan-check names every refusal" 'line 6: banned phrase' 'line 11: AC2 has no row' 'line 22: Readers entry has no hit line' 'line 25: tool claim' 'line 30: "## Overlap" is empty'
rm "$tmp/land/.10x/P1/plan.md"
expect "plan-check exits 2 without a plan" 2 10x-plan-check P1
expect "plan-check exits 2 without an id" 2 10x-plan-check
expect "plan-check exits 2 on a bad id" 2 10x-plan-check ../P1
cold="$tmp/land/.10x/P1/cold-read.md"
pc_cold() { # <case> — the last run printed the cold read line, last
  [ "$(tail -n 1 "$tmp/out")" = "cold read required: 4 files — spawn Explore before showing the plan" ] \
    && ok "$1: prints the cold read line last" || { bad "$1: prints the cold read line last"; cat "$tmp/out"; }
}
pc_nocold() { # <case> — the last run printed no cold read line
  ! grep -q 'cold read required' "$tmp/out" && ok "$1: prints no cold read line" || { bad "$1: prints no cold read line"; cat "$tmp/out"; }
}
pc_plan head files3 readers tools overlap tests
expect "plan-check needs no cold read for 3 files" 0 10x-plan-check P1
pc_nocold "plan-check needs no cold read for 3 files"
pc_plan head files4 readers tools overlap tests
expect "plan-check asks for a cold read of a plan binding 4 files" 1 10x-plan-check P1
pc_cold "plan-check asks for a cold read of a plan binding 4 files"
grep -q '^/.*plan\.md:$' "$tmp/out" && bad "plan-check: the cold read line alone has no plan header" \
  || ok "plan-check: the cold read line alone has no plan header"
printf '\n  \n' >"$cold"
expect "plan-check treats a blank cold-read.md as missing" 1 10x-plan-check P1
pc_cold "plan-check treats a blank cold-read.md as missing"
rm "$cold"
printf 'a guess\n' >"$tmp/cold-target"
ln -s "$tmp/cold-target" "$cold"
expect "plan-check treats a symlinked cold-read.md as missing" 1 10x-plan-check P1
pc_cold "plan-check treats a symlinked cold-read.md as missing"
rm "$cold"
pc_plan head files4 readers tools overlap tests-noac2
expect "plan-check prints the cold read line after the other refusals" 1 10x-plan-check P1
pc_names "plan-check prints the cold read line after the other refusals" 'AC2 has no row in "## Tests"'
pc_cold "plan-check prints the cold read line after the other refusals"
pc_plan head files4 readers tools overlap tests
printf -- '- No guess needed.\n' >"$cold"
expect "plan-check accepts 4 files once cold-read.md is saved" 0 10x-plan-check P1
pc_nocold "plan-check accepts 4 files once cold-read.md is saved"
rm "$cold"

# with the repo's own forms
mkdir -p "$tmp/land/.github/ISSUE_TEMPLATE"
cp "$BIN"/../.github/ISSUE_TEMPLATE/*.yml "$tmp/land/.github/ISSUE_TEMPLATE/"
refuse "issue refuses a draft without Form: when the repo has forms" 'Form:' thing
printf '# T\nForm: nope.yml\n\nb\n' >"$dr/noform.md"
refuse "issue refuses a Form: that is not in the repo" 'line 2' noform
printf '# T\nForm: ../bug.yml\n\nb\n' >"$dr/pathform.md"
refuse "issue refuses a Form: with a path" 'line 2' pathform
printf '# T\nForm: config.yml\n\nb\n' >"$dr/cfgform.md"
refuse "issue refuses Form: config.yml" 'is not an issue form' cfgform
bugbody() { # <what> <steps> <expected> <version> <criteria>
  printf '# T\nLabels: bug\nForm: bug.yml\n\n### What happens\n%s\n\n### Steps to reproduce\n%s\n\n### Expected\n%s\n\n### Version / commit\n%s\n\n### Acceptance criteria\n%s\n' "$@"
}
bugbody 'it breaks' '1. run' 'it holds' 'abc123' '- [ ] AC1 — it holds' >"$dr/bugok.md"
: >"$tmp/stub.log"
expect "issue accepts a draft filled per bug.yml" 0 10x-land issue bugok
grep -q 'issue create' "$tmp/stub.log" && ok "bug.yml draft is created" || bad "bug.yml draft is created"
bugbody 'it breaks' '1. run' 'it holds' 'abc123' '- [ ] AC1 — it holds' | grep -v '^### Expected' >"$dr/bugmiss.md"
refuse "issue refuses a draft missing a required section" '"Expected"' bugmiss
bugbody 'it breaks' '1. run' 'it holds' '_No response_' '- [ ] AC1 — it holds' >"$dr/bugnores.md"
refuse "issue refuses a _No response_ required section" 'Version / commit' bugnores
bugbody '' '1. run' 'it holds' 'abc123' '- [ ] AC1 — it holds' >"$dr/bugempty.md"
refuse "issue refuses an empty required section" 'What happens' bugempty
bugbody 'it breaks' '1. run' 'it holds' 'abc123' '- [ ] it holds' >"$dr/bugac.md"
refuse "issue refuses an unnumbered criterion in a form" 'lacks' bugac
bugbody 'it breaks' '1. run' 'it holds' 'abc123' '- it holds' >"$dr/bugplain.md"
refuse "issue refuses form criteria with no checkbox" 'no checkbox criterion' bugplain
printf '# T\nLabels: enhancement\nForm: feature.yml\n\n### Problem\nneed\n\n### Proposed behaviour\ndo\n\n### Acceptance criteria\n- [ ] AC1 — done\n' >"$dr/featok.md"
: >"$tmp/stub.log"
STUB_LABELS=$'enhancement' expect "issue accepts a draft filled per feature.yml, optional fields absent" 0 10x-land issue featok
printf '# T\nForm: feature.yml\n\n### Problem\nneed\n\n### Acceptance criteria\n- [ ] AC1 — done\n' >"$dr/featmiss.md"
refuse "issue refuses feature.yml without Proposed behaviour" 'Proposed behaviour' featmiss
printf 'body:\n  - type: textarea\n    attributes: {label: X}\n' >"$tmp/land/.github/ISSUE_TEMPLATE/flow.yml"
printf '# T\nForm: flow.yml\n\nb\n' >"$dr/flow.md"
refuse "issue refuses a form in flow style, naming it" 'flow.yml' flow
printf 'labels: [bug, "triage"]\nbody:\n  - type: textarea\n    attributes:\n      label: X\n    validations:\n      required: true\n' >"$tmp/land/.github/ISSUE_TEMPLATE/flowlabels.yml"
printf '# T\nForm: flowlabels.yml\n\n### X\nx\n' >"$dr/flowlabels.md"
: >"$tmp/stub.log"
expect "issue reads a form whose labels are a flow list" 0 10x-land issue flowlabels
rm -r "$tmp/land/.github"
ln "$tmp/real-body.md" "$td/pr-body.md"
expect "pr refuses a hard-linked body" 2 10x-land pr L1
rm "$td/pr-body.md"; printf 'Closes #1\n' >"$td/pr-body.md"

# security entries: pr refuses a title, a body or a commit message that names an entry, and names only the file or
# commit and the fingerprint. refused <case> <label> <command…> — exit 2, the label and the fingerprint named, never the title or the location.
refused() {
  local d=$1 label=$2; shift 2
  "$@" >"$tmp/out" 2>&1; local rc=$?
  [ "$rc" -eq 2 ] && grep -qF "$sec_fp1" "$tmp/out" && grep -qF "$label" "$tmp/out" && ! grep -qiE 'injection|deploy' "$tmp/out" &&
    ok "$d" || { bad "$d (exit $rc)"; sed 's/^/      /' "$tmp/out"; }
}
git remote set-url origin git@github.com:acme/land.git
sec_disclosed
: >"$tmp/stub.log"
printf 'fix: SHELL injection in deploy HOOK\n' >"$td/pr-title"
STUB_VIEW_RC=1 refused "pr refuses a title naming a security entry" "$td/pr-title" 10x-land pr L1
printf 'feat: the feature\n' >"$td/pr-title"
printf 'Closes #1\n\nTouches bin/deploy.sh:12 in the hook.\n' >"$td/pr-body.md"
STUB_VIEW_RC=1 refused "pr refuses a body naming a security entry" "$td/pr-body.md" 10x-land pr L1
printf 'Closes #1\n' >"$td/pr-body.md"
git -C "$lw" commit -q --allow-empty -m 'fix: bin/deploy.sh:12 hardening'
STUB_VIEW_RC=1 refused "pr refuses a commit message naming a security entry" "commit $(git -C "$lw" rev-parse --short=7 HEAD)" 10x-land pr L1
git -C "$lw" reset -q --hard HEAD~1
[ ! -s "$tmp/stub.log" ] && ok "no gh call for a disclosed security entry" || { bad "no gh call for a disclosed security entry"; cat "$tmp/stub.log"; }
# a path that only contains the location, or a longer line number, is not the entry
printf 'Closes #1\n\nSee lib/bin/deploy.sh:12 and bin/deploy.sh:123.\n' >"$td/pr-body.md"
STUB_VIEW_RC=1 expect "pr allows text that only resembles a security entry" 0 10x-land pr L1
printf 'Closes #1\n' >"$td/pr-body.md"
rm "$tmp/land/.10x/security.md"

# comment: posts .10x/gh-<n>/comment.md on issue <n> of origin's repo, without a worktree
mkdir -p "$tmp/land/.10x/gh-7"
gd="$(cd "$tmp/land/.10x/gh-7" && pwd -P)"
: >"$tmp/stub.log"
expect "comment refuses a missing comment.md" 2 10x-land comment gh-7
: >"$gd/comment.md"
expect "comment refuses an empty comment.md" 2 10x-land comment gh-7
printf 'Decisions from planning:\n' >"$tmp/real-comment.md"; rm "$gd/comment.md"; ln -s "$tmp/real-comment.md" "$gd/comment.md"
expect "comment refuses a symlinked comment.md" 2 10x-land comment gh-7
rm "$gd/comment.md"; printf 'Decisions from planning:\n' >"$gd/comment.md"
expect "comment rejects a non-gh id" 2 10x-land comment L1
expect "comment rejects gh-0" 2 10x-land comment gh-0
expect "comment rejects extra arguments" 2 10x-land comment gh-7 --repo evil/land
expect "comment refuses without ticket.md" 2 10x-land comment gh-7
printf '# T\n\n- source: GitHub issue #7 (open)\n- url: https://github.com/other/land/issues/7\n' >"$gd/ticket.md"
expect "comment refuses a ticket read from another repo" 2 10x-land comment gh-7
printf '# T\n\n- source: GitHub issue #7 (open)\n- url: https://github.com/acme/land/issues/77\n' >"$gd/ticket.md"
expect "comment refuses a ticket of another issue" 2 10x-land comment gh-7
printf '# T\n\n- source: GitHub issue #77 (open)\n- url: https://github.com/acme/land/issues/77\n\n- url: https://github.com/acme/land/issues/7\n' >"$gd/ticket.md"
expect "comment refuses an issue url planted below the header" 2 10x-land comment gh-7
[ ! -s "$tmp/stub.log" ] && ok "no gh call for a refused comment" || bad "no gh call for a refused comment"
printf '# T\n\n- source: GitHub issue #7 (open)\n- url: https://github.com/Acme/Land/issues/7\n' >"$gd/ticket.md"
mkdir "$tmp/posted-elsewhere"; ln -s "$tmp/posted-elsewhere" "$gd/comment.posted.md"
expect "comment posts without a worktree" 0 10x-land comment gh-7
land_log "issue comment 7 --repo github.com/acme/land --body-file $gd/comment.md" "gh issue comment argv"
[ ! -e "$gd/comment.md" ] && [ ! -L "$gd/comment.posted.md" ] && [ -s "$gd/comment.posted.md" ] && ok "a posted comment.md becomes comment.posted.md" || bad "a posted comment.md becomes comment.posted.md"
[ -z "$(ls -A "$tmp/posted-elsewhere")" ] && ok "nothing moved through a symlinked comment.posted.md" || bad "nothing moved through a symlinked comment.posted.md"
: >"$tmp/stub.log"
expect "comment refuses to post a second time" 2 10x-land comment gh-7
[ ! -s "$tmp/stub.log" ] && ok "no gh call for a second comment" || bad "no gh call for a second comment"
printf 'Decisions from planning:\nnew\n' >"$gd/comment.md"
expect "comment posts a new comment.md after an earlier one" 0 10x-land comment gh-7
grep -qx new "$gd/comment.posted.md" && ok "comment.posted.md holds the latest comment" || bad "comment.posted.md holds the latest comment"
printf 'Decisions from planning:\n' >"$gd/comment.md"
sec_disclosed
: >"$tmp/stub.log"
printf 'Decisions: %s is tracked.\n' "$sec_fp1" >"$gd/comment.md"
refused "comment refuses a comment.md naming a security entry" "$gd/comment.md" 10x-land comment gh-7
[ ! -s "$tmp/stub.log" ] && [ -s "$gd/comment.md" ] && ok "a refused comment is neither posted nor moved" || { bad "a refused comment is neither posted nor moved"; cat "$tmp/stub.log"; }
printf 'Decisions from planning:\n' >"$gd/comment.md"
rm "$tmp/land/.10x/security.md"
git remote set-url origin https://gitlab.example.com/grp/land.git
: >"$tmp/stub.log"
expect "comment refuses a GitLab origin" 2 10x-land comment gh-7
git remote set-url origin git@github.com:acme/land.git

# TENX_BATCH: inside a batch worker issue, comment and advisory refuse before reading or writing anything, however invoked
printf '# Add the thing\nLabels: bug, ui\nType: Bug\n\n## Context\nbody\n\n## Acceptance criteria\n- [ ] AC1 — it exists\n' >"$tmp/land/.10x/drafts/thing.md"
: >"$tmp/stub.log"
snap10x() { find "$tmp/land/.10x" -print0 | sort -z | xargs -0 cksum 2>&1; }
snap10x >"$tmp/batch.before"
batch_bad=0
for args in "issue thing" "comment gh-7" "advisory thing"; do
  # shellcheck disable=SC2086  # $args is split on purpose
  for form in name path shell; do
    case "$form" in
      name)  TENX_BATCH=1 10x-land $args >"$tmp/out" 2>&1 ;;
      path)  TENX_BATCH=1 "$BIN/10x-land" $args >"$tmp/out" 2>&1 ;;
      shell) TENX_BATCH=1 sh -c "10x-land $args" >"$tmp/out" 2>&1 ;;
    esac
    rc=$?
    { [ "$rc" -eq 2 ] && [ "$(cat "$tmp/out")" = "10x: refused inside a batch worker" ]; } || { batch_bad=1; echo "      $args ($form): exit $rc"; cat "$tmp/out"; }
  done
done
[ "$batch_bad" = 0 ] && ok "TENX_BATCH: issue, comment and advisory refuse by name, by absolute path and through sh -c" ||
  bad "TENX_BATCH: issue, comment and advisory refuse by name, by absolute path and through sh -c"
snap10x >"$tmp/batch.after"
[ ! -s "$tmp/stub.log" ] && cmp -s "$tmp/batch.before" "$tmp/batch.after" && [ -f "$tmp/land/.10x/drafts/thing.md" ] && [ -s "$gd/comment.md" ] &&
  ok "TENX_BATCH: a refused issue, comment or advisory creates, posts, renames or deletes nothing" ||
  { bad "TENX_BATCH: a refused issue, comment or advisory creates, posts, renames or deletes nothing"; cat "$tmp/stub.log"; diff "$tmp/batch.before" "$tmp/batch.after"; }
TENX_BATCH=1 10x-land comment L1 >"$tmp/out" 2>&1; rc=$?
[ "$rc" -eq 2 ] && [ "$(cat "$tmp/out")" = "10x: refused inside a batch worker" ] && ! grep -qF "comment needs a GitHub issue ticket id" "$tmp/out" &&
  ok "TENX_BATCH: comment with a bad id reports the batch refusal" || { bad "TENX_BATCH: comment with a bad id reports the batch refusal"; cat "$tmp/out"; }
rm "$tmp/land/.10x/drafts/thing.md"

# 10x-ticket reads the issue from origin's repo only
: >"$tmp/stub.log"
expect "ticket by number" 0 10x-ticket github 7
land_log "issue view 7 --repo github.com/acme/land --json number,title,body,url,state,labels,issueType,comments" "gh issue view pinned to origin's repo"
: >"$tmp/stub.log"
expect "ticket by origin's URL" 0 10x-ticket github https://github.com/Acme/land/issues/7
land_log "issue view 7 --repo github.com/acme/land --json number,title,body,url,state,labels,issueType,comments" "a URL is read as its number in origin's repo"
cp "$tmp/out" "$tmp/ticket.stdout"
expect "ticket --out" 0 10x-ticket github 7 --out .10x/gh-7/ticket.md
[ ! -s "$tmp/out" ] && ok "ticket --out prints nothing" || bad "ticket --out prints nothing"
cmp -s "$gd/ticket.md" "$tmp/ticket.stdout" && ok "ticket --out writes what it would print" || bad "ticket --out writes what it would print"
echo keep >"$tmp/victim"
ln -sf "$tmp/victim" "$gd/ticket.md"
expect "ticket --out over a symlinked ticket.md" 0 10x-ticket github 7 --out "$gd/ticket.md"
[ "$(cat "$tmp/victim")" = keep ] && [ ! -L "$gd/ticket.md" ] && ok "symlink replaced, its target untouched" || bad "symlink replaced, its target untouched"
: >"$tmp/stub.log"
expect "ticket refuses an unknown trailing argument" 2 10x-ticket github 7 --web
expect "ticket refuses --out without a path" 2 10x-ticket github 7 --out
expect "ticket refuses an argument after --out <path>" 2 10x-ticket github 7 --out "$gd/ticket.md" extra
expect "ticket refuses --out outside .10x/" 2 10x-ticket github 7 --out "$tmp/x.md"
expect "ticket refuses --out into another issue's dir" 2 10x-ticket github 8 --out "$gd/ticket.md"
expect "ticket refuses --out to another file name" 2 10x-ticket github 7 --out "$gd/plan.md"
mv "$gd" "$tmp/gh-7.real"
ln -s "$tmp/gh-7.real" .10x/gh-7
expect "ticket refuses a symlinked gh-<n> dir" 2 10x-ticket github 7 --out .10x/gh-7/ticket.md
rm .10x/gh-7
mv "$tmp/gh-7.real" "$gd"
[ ! -e "$tmp/x.md" ] && ok "nothing written outside .10x/" || bad "nothing written outside .10x/"
expect "ticket refuses another repo's URL" 2 10x-ticket github https://github.com/other/land/issues/7
expect "ticket refuses a URL on a look-alike host" 2 10x-ticket github https://github.com.evil/acme/land/issues/7
expect "ticket refuses a flag" 2 10x-ticket github --web
expect "ticket refuses a repo-qualified ref" 2 10x-ticket github other/land#7
git remote set-url origin https://notgithub.com/acme/land.git
expect "ticket refuses a non-github.com origin" 2 10x-ticket github 7
git remote set-url origin git@github.com:acme/land.git
[ ! -s "$tmp/stub.log" ] && ok "no gh call for a refused ticket" || bad "no gh call for a refused ticket"

# 10x-ticket issue-types lists the issue types of origin's repo
STUB_GRAPHQL='{"data":{"repository":{"issueTypes":{"nodes":[{"name":"Bug"},{"name":"Feature"}]}}}}' expect "issue-types prints one type per line" 0 10x-ticket issue-types
[ "$(cat "$tmp/out")" = $'Bug\nFeature' ] && ok "issue-types prints the names alone" || { bad "issue-types prints the names alone"; cat "$tmp/out"; }
land_log 'api --hostname github.com graphql -f query=query($o:String!,$r:String!){repository(owner:$o,name:$r){issueTypes(first:25){nodes{name}}}} -f o=acme -f r=land' "issue-types queries origin's repo on github.com"
expect "issue-types prints nothing for a repo without issue types" 0 10x-ticket issue-types
[ ! -s "$tmp/out" ] && ok "issue-types prints nothing for null issue types" || bad "issue-types prints nothing for null issue types"
STUB_GRAPHQL='{"data":{"repository":{"issueTypes":{"nodes":[]}}}}' expect "issue-types prints nothing for no issue types" 0 10x-ticket issue-types
[ ! -s "$tmp/out" ] && ok "issue-types prints nothing for an empty list" || bad "issue-types prints nothing for an empty list"
STUB_GRAPHQL_RC=1 expect "issue-types fails naming gh's error" 2 10x-ticket issue-types
grep -qx '10x-ticket: gh: Could not resolve to a Repository' "$tmp/out" && ok "issue-types relays gh's stderr" || { bad "issue-types relays gh's stderr"; cat "$tmp/out"; }
STUB_GRAPHQL='{"data":{"repository":null}}' expect "issue-types fails on an answer with no repository" 2 10x-ticket issue-types
STUB_GRAPHQL='not json' expect "issue-types fails on an answer that is not JSON" 2 10x-ticket issue-types
: >"$tmp/stub.log"
expect "issue-types refuses an argument" 2 10x-ticket issue-types --repo other/land
git remote set-url origin https://notgithub.com/acme/land.git
expect "issue-types refuses a non-github.com origin" 2 10x-ticket issue-types
grep -q "^10x-ticket: issue-types needs a github.com origin" "$tmp/out" && ok "issue-types names itself in the refusal" || { bad "issue-types names itself in the refusal"; cat "$tmp/out"; }
git remote set-url origin git@github.com:acme/land.git
[ ! -s "$tmp/stub.log" ] && ok "no gh call for a refused issue-types" || bad "no gh call for a refused issue-types"
git remote set-url origin https://notgithub.com/acme/land.git
: >"$tmp/stub.log"
expect "pr refuses a host that only contains github.com" 2 10x-land pr L1
mkdir -p .claude && echo '{"tickets":"github"}' >.claude/10x.json
expect "issue refuses a host that only contains github.com" 2 10x-land issue thing
grep -qF "issue needs a github.com origin" "$tmp/out" && ok "issue: the look-alike host fails the host check" || { bad "issue: the look-alike host fails the host check"; cat "$tmp/out"; }
rm -r .claude
expect "comment refuses a host that only contains github.com" 2 10x-land comment gh-7
[ ! -s "$tmp/stub.log" ] && ok "no gh call for a look-alike host" || bad "no gh call for a look-alike host"
unset STUB_LABELS
git remote set-url origin "$tmp/github.com/land.git"

# squash: local mode, several tickets in a row without pushing the base
mkdir -p .claude && echo '{ "close": "local" }' >.claude/10x.json
git add .claude/10x.json && git commit -qm "chore: local mode" && git push -q origin main
echo extra >"$lw/extra.txt"; git -C "$lw" add -A; git -C "$lw" commit -qm "feat: extra"
expect "rebase L1 in local mode" 0 10x-land rebase L1
expect "squash refuses without a commit message" 2 10x-land squash L1
: >"$td/commit-msg"
expect "squash refuses an empty commit message" 2 10x-land squash L1
rm "$td/commit-msg"; echo outside >"$tmp/outside-msg"; ln -s "$tmp/outside-msg" "$td/commit-msg"
expect "squash refuses a symlinked commit message" 2 10x-land squash L1
rm "$td/commit-msg"
before="$(git rev-parse main)"
sec_disclosed
printf 'feat: land L1\n\nFixes the Shell Injection in deploy hook.\n' >"$td/commit-msg"
refused "squash refuses a commit-msg naming a security entry" "$td/commit-msg" 10x-land squash L1
git reset -q --hard "$before" # without the refusal the squash has already moved the base: put it back so the cases below still start from the same state
rm "$tmp/land/.10x/security.md"
printf 'feat: land L1\n\nBody line.\n' >"$td/commit-msg"
expect "squash lands the branch" 0 10x-land squash L1
[ "$(git rev-parse main^)" = "$before" ] && ok "one commit on the base" || bad "one commit on the base"
[ "$(git rev-parse 'main^{tree}')" = "$(git rev-parse 'feat/L1^{tree}')" ] && ok "base has the branch's tree" || bad "base has the branch's tree"
git cat-file commit main | sed '1,/^$/d' | cmp -s - "$td/commit-msg" && ok "non-gh ticket: squash commit is commit-msg unchanged" || bad "non-gh ticket: squash commit is commit-msg unchanged"
[ -z "$(git status --porcelain)" ] && ok "main checkout updated with the base" || bad "main checkout updated with the base"
expect "squash refuses a branch not rebased onto the base" 2 10x-land squash L1
expect "rm after a local squash" 0 10x-worktree rm L1
grep -q 'deleted branch feat/L1 (its changes are on main)' "$tmp/out" && ok "locally squashed branch deleted" || bad "locally squashed branch deleted"
[ "$(cat .10x/L1/landed 2>/dev/null)" = "landed on main at $(git rev-parse --short main)" ] &&
  ok "local close records the landing for a file ticket" || { bad "local close records the landing for a file ticket"; cat "$tmp/out"; }
10x-worktree add L0 --no-setup >/dev/null
mkdir -p .10x/L0 && echo "feat: nothing" >.10x/L0/commit-msg
expect "squash refuses a branch with nothing beyond the base" 2 10x-land squash L0
grep -q 'no commits beyond main' "$tmp/out" && ok "empty branch: reason given" || bad "empty branch: reason given"
10x-worktree rm L0 >/dev/null
expect "add starts from the unpushed local base" 0 10x-worktree add L2 --no-setup
grep -q 'from main (' "$tmp/out" && ok "L2 starts from main" || bad "L2 starts from main"
echo two >"$tmp/land/.worktrees/L2/two.txt"; git -C "$tmp/land/.worktrees/L2" add -A; git -C "$tmp/land/.worktrees/L2" commit -qm "feat: two"
mkdir -p .10x/L2 && echo "feat: two" >.10x/L2/commit-msg
git checkout -q -b elsewhere
expect "rebase onto the unpushed local base" 0 10x-land rebase L2
grep -q 'onto main$' "$tmp/out" && ok "L2 rebased onto main" || bad "L2 rebased onto main"
expect "squash off the base" 0 10x-land squash L2
[ "$(git rev-parse 'main^{tree}')" = "$(git rev-parse 'feat/L2^{tree}')" ] && [ "$(git rev-parse --abbrev-ref HEAD)" = elsewhere ] && ok "base ref updated, checkout untouched" || bad "base ref updated, checkout untouched"
[ "$(git rev-list --count origin/main..main)" = 2 ] && ok "two tickets squashed in a row without a push" || bad "two tickets squashed in a row without a push"
10x-worktree add L3 --no-setup >/dev/null
echo three >"$tmp/land/.worktrees/L3/three.txt"; git -C "$tmp/land/.worktrees/L3" add -A; git -C "$tmp/land/.worktrees/L3" commit -qm "feat: three"
mkdir -p .10x/L3 && echo "feat: three" >.10x/L3/commit-msg
git checkout -q main
echo more >g.txt; git commit -qam "chore: base moves"
expect "squash refuses when the base moved" 2 10x-land squash L3
git checkout -q elsewhere
expect "squash refuses (off the base) when the base moved" 2 10x-land squash L3
git checkout -q main
# the local base behind origin: start from origin/main; diverged: refuse
git push -q origin main
git clone -q "$tmp/github.com/land.git" "$tmp/land-other"
echo upstream >"$tmp/land-other/up.txt"
git -C "$tmp/land-other" add -A && git -C "$tmp/land-other" -c user.email=t@t -c user.name=t commit -qm "feat: upstream" && git -C "$tmp/land-other" push -q origin main
expect "add with the local base behind origin" 0 10x-worktree add L4 --no-setup
grep -q 'from origin/main (' "$tmp/out" && ok "behind: starts from origin/main" || bad "behind: starts from origin/main"
echo four >"$tmp/land/.worktrees/L4/four.txt"; git -C "$tmp/land/.worktrees/L4" add -A; git -C "$tmp/land/.worktrees/L4" commit -qm "feat: four"
mkdir -p .10x/L4 && echo "feat: four" >.10x/L4/commit-msg
expect "rebase with the local base behind origin" 0 10x-land rebase L4
grep -q 'onto origin/main$' "$tmp/out" && ok "behind: rebased onto origin/main" || bad "behind: rebased onto origin/main"
expect "squash with the local base behind origin" 0 10x-land squash L4
[ "$(git rev-parse main^)" = "$(git rev-parse origin/main)" ] && [ -z "$(git rev-list main..origin/main)" ] && ok "behind: squash lands on origin/main, not diverged" || bad "behind: squash lands on origin/main, not diverged"
[ -z "$(git status --porcelain)" ] && [ -f up.txt ] && ok "behind: checkout has the upstream file" || bad "behind: checkout has the upstream file"
# a dirty main checkout on the base: unrelated changes kept, a change to a file the ticket touches refused
10x-worktree add L7 --no-setup >/dev/null
echo seven >"$tmp/land/.worktrees/L7/seven.txt"; echo ticket-g >"$tmp/land/.worktrees/L7/g.txt"
git -C "$tmp/land/.worktrees/L7" add -A; git -C "$tmp/land/.worktrees/L7" commit -qm "feat: seven"
mkdir -p .10x/L7 && echo "feat: seven" >.10x/L7/commit-msg
echo mine >g.txt
before="$(git rev-parse main)"
expect "squash refuses over an uncommitted change to a touched file" 2 10x-land squash L7
grep -q 'uncommitted changes to files the ticket touches' "$tmp/out" && ! grep -q 'moved since' "$tmp/out" && ok "dirty checkout: reason given" || bad "dirty checkout: reason given"
[ "$(git rev-parse main)" = "$before" ] && [ "$(cat g.txt)" = mine ] && ok "dirty checkout: base and change untouched" || bad "dirty checkout: base and change untouched"
git checkout -q -- g.txt
echo mine >>f.txt; echo staged >s.txt; git add s.txt
expect "squash with unrelated uncommitted changes" 0 10x-land squash L7
[ "$(git rev-parse main^)" = "$before" ] && [ -f seven.txt ] && ok "dirty checkout: squash applied" || bad "dirty checkout: squash applied"
[ "$(git diff --name-only)" = f.txt ] && [ "$(git diff --cached --name-only)" = s.txt ] && ok "dirty checkout: unrelated changes kept" || bad "dirty checkout: unrelated changes kept"
git checkout -q -- f.txt; git rm -q --cached s.txt; rm s.txt
# a gh-<n> ticket: the squash commit carries Closes #<n>, before a closing trailer block
: >"$tmp/stub.log"
gh_squash() { # <id> <commit-msg contents>
  10x-worktree add "$1" --no-setup >/dev/null
  echo "$1" >"$tmp/land/.worktrees/$1/$1.txt"; git -C "$tmp/land/.worktrees/$1" add -A; git -C "$tmp/land/.worktrees/$1" commit -qm "feat: $1"
  mkdir -p ".10x/$1" && printf '%s' "$2" >".10x/$1/commit-msg"
  10x-land rebase "$1" >/dev/null && 10x-land squash "$1" >/dev/null && 10x-worktree rm "$1" >/dev/null
}
gh_squash gh-9 $'fix: nine\n  \n'
[ "$(cat .10x/gh-9/landed 2>/dev/null)" = "landed on main at $(git rev-parse --short main)" ] &&
  ok "local close records the landing for a gh ticket" || bad "local close records the landing for a gh ticket"
git cat-file commit main | sed '1,/^$/d' | cmp -s - <(printf 'fix: nine\n\nCloses #9\n') && ok "gh ticket: Closes #9 appended after a subject-only message" || bad "gh ticket: Closes #9 appended after a subject-only message"
gh_squash gh-10 $'feat: ten\n\nBody.\n\nCo-Authored-By: A <a@b>\n'
git cat-file commit main | sed '1,/^$/d' | cmp -s - <(printf 'feat: ten\n\nBody.\n\nCloses #10\n\nCo-Authored-By: A <a@b>\n') && ok "gh ticket: Closes #10 goes before the trailer block" || bad "gh ticket: Closes #10 goes before the trailer block"
[ "$(git log -1 --format=%B main | git interpret-trailers --parse)" = "Co-Authored-By: A <a@b>" ] && ok "gh ticket: trailers still parse after Closes #10" || bad "gh ticket: trailers still parse after Closes #10"
gh_squash gh-11 $'feat: eleven\n\nCloses #11 \nMore text.\n'
git cat-file commit main | sed '1,/^$/d' | cmp -s - .10x/gh-11/commit-msg && ok "gh ticket: a Closes line already present leaves commit-msg unchanged" || bad "gh ticket: a Closes line already present leaves commit-msg unchanged"
[ ! -s "$tmp/stub.log" ] && ok "no gh call from local squashes" || bad "no gh call from local squashes"
echo upstream2 >"$tmp/land-other/up.txt"
git -C "$tmp/land-other" pull -q && git -C "$tmp/land-other" -c user.email=t@t -c user.name=t commit -qam "feat: upstream again" && git -C "$tmp/land-other" push -q origin main
git fetch -q origin
echo local >h.txt; git add h.txt && git commit -qm "chore: local only"
expect "add refuses a diverged base" 2 10x-worktree add L5 --no-setup
[ ! -e "$tmp/land/.worktrees/L5" ] && ok "no worktree for a diverged base" || bad "no worktree for a diverged base"
expect "rebase refuses a diverged base" 2 10x-land rebase L4
# pr mode ignores the local base
git rm -q .claude/10x.json && git commit -qm "chore: pr mode"
expect "add in pr mode with an unpushed local base" 0 10x-worktree add L6 --no-setup
grep -q 'from origin/main (' "$tmp/out" && ok "pr mode starts from origin/main" || bad "pr mode starts from origin/main"
cd "$tmp/repo" || exit 2

# sync-base: after a merged PR, fast-forward the main checkout's base only when that is safe
expect "sync-base when level" 0 10x-worktree sync-base
grep -q 'main is up to date' "$tmp/out" && ok "level base reported up to date" || bad "level base reported up to date"
git clone -q "$tmp/origin.git" "$tmp/other"
merged() { # land a commit on origin/main from elsewhere, as a merged PR would
  echo "$1" >"$tmp/other/$1.txt"
  git -C "$tmp/other" add -A && git -C "$tmp/other" -c user.email=t@t -c user.name=t commit -qm "feat: $1" && git -C "$tmp/other" push -q origin main
}
merged pr1
before=$(git rev-parse main)
git switch -q -c side
expect "sync-base off the base" 0 10x-worktree sync-base
grep -q 'main is behind origin/main, not updated: the main checkout is on side' "$tmp/out" && ok "off the base: left behind" || bad "off the base: left behind"
git switch -q main && git branch -q -D side
[ "$(git rev-parse main)" = "$before" ] && ok "base untouched off the base" || bad "base untouched off the base"
echo 'export const add = (a, b) => b + a' >src/math.mjs
expect "sync-base with an unrelated unstaged change" 0 10x-worktree sync-base
grep -q "fast-forwarded main to $(git rev-parse --short origin/main)" "$tmp/out" && ok "unrelated unstaged change: fast-forwarded" || bad "unrelated unstaged change: fast-forwarded"
[ "$(git rev-parse main)" = "$(git rev-parse origin/main)" ] && ok "base equals origin/main" || bad "base equals origin/main"
[ "$(git diff --name-only)" = src/math.mjs ] && ok "unstaged change kept" || bad "unstaged change kept"
merged pr2
git add src/math.mjs
expect "sync-base with an unrelated staged change" 0 10x-worktree sync-base
grep -q "fast-forwarded main to $(git rev-parse --short origin/main)" "$tmp/out" && ok "unrelated staged change: fast-forwarded" || bad "unrelated staged change: fast-forwarded"
[ "$(git diff --cached --name-only)" = src/math.mjs ] && ok "staged change kept staged" || bad "staged change kept staged"
git reset -q -- src/math.mjs
echo 'export const add = (a, b) => a + b + 0' >"$tmp/other/src/math.mjs"
git -C "$tmp/other" -c user.email=t@t -c user.name=t commit -qam "fix: math" && git -C "$tmp/other" push -q origin main
before=$(git rev-parse main)
expect "sync-base with a change to an incoming file" 0 10x-worktree sync-base
grep -q 'not updated: git merge --ff-only refused' "$tmp/out" && grep -q 'src/math.mjs' "$tmp/out" && ok "conflicting change: refused, file named" || bad "conflicting change: refused, file named"
[ "$(git rev-parse main)" = "$before" ] && ok "base untouched when git refuses" || bad "base untouched when git refuses"
git checkout -q -- src/math.mjs
expect "sync-base on a clean base" 0 10x-worktree sync-base
grep -q "fast-forwarded main to $(git rev-parse --short origin/main)" "$tmp/out" && ok "clean base fast-forwarded" || bad "clean base fast-forwarded"
merged pr3
echo local >local.txt && git add local.txt && git commit -qm "chore: local only"
before=$(git rev-parse main)
expect "sync-base with local commits" 0 10x-worktree sync-base
grep -q 'not updated: main has commits origin/main does not' "$tmp/out" && ok "diverged base: left behind" || bad "diverged base: left behind"
[ "$(git rev-parse main)" = "$before" ] && ok "diverged base untouched" || bad "diverged base untouched"

# ci-gates.sh: every gate runs, a table lands in the summary, gate changes against a base are listed
cig="$(cd "$BIN/.." && pwd)/scripts/ci-gates.sh"
cg="$tmp/cig"
git -c init.defaultBranch=main init -q "$cg"
mkdir "$cg/.claude"
cat >"$cg/.claude/10x.json" <<'EOF'
{ "gates": ["echo gate-one", "echo gate-bad >&2; exit 3", "echo gate-three"] }
EOF
git -C "$cg" add -A && git -C "$cg" -c user.email=t@t -c user.name=t commit -qm "init"
cgbase="$(git -C "$cg" rev-parse HEAD)"
cd "$cg" || exit 2
GITHUB_STEP_SUMMARY="$tmp/cig-summary" expect "ci-gates: a failing gate fails the run" 1 "$cig"
grep -q 'gate-three' "$tmp/out" && ok "ci-gates: runs the gates after a failed one" || bad "ci-gates: runs the gates after a failed one"
grep -c '^::group::' "$tmp/out" | grep -qx 3 && grep -c '^::endgroup::' "$tmp/out" | grep -qx 3 && ok "ci-gates: one group per gate" || bad "ci-gates: one group per gate"
grep -q '^| `echo gate-one` | pass |' "$tmp/cig-summary" && grep -q 'exit 3` | FAIL |' "$tmp/cig-summary" && grep -q '`echo gate-three` | pass |' "$tmp/cig-summary" && ok "ci-gates: summary has pass and FAIL rows" || bad "ci-gates: summary has pass and FAIL rows"
[ "$(grep -n 'gate-one' "$tmp/cig-summary" | cut -d: -f1)" -lt "$(grep -n 'gate-three' "$tmp/cig-summary" | cut -d: -f1)" ] && ok "ci-gates: gate order kept" || bad "ci-gates: gate order kept"
expect "ci-gates: writes the table to stdout without GITHUB_STEP_SUMMARY" 1 env -u GITHUB_STEP_SUMMARY "$cig"
grep -q '^| gate | result | secs |' "$tmp/out" && ok "ci-gates: table on stdout" || bad "ci-gates: table on stdout"
echo '{ "gates": ["echo gate-one", "echo gate-added"] }' >.claude/10x.json
git add -A && git -c user.email=t@t -c user.name=t commit -qm "chore: gates"
: >"$tmp/cig-summary"
GITHUB_STEP_SUMMARY="$tmp/cig-summary" expect "ci-gates: only passing gates" 0 "$cig"
! grep -q 'gates differ' "$tmp/cig-summary" && ok "ci-gates: no base, no gate changes" || bad "ci-gates: no base, no gate changes"
GITHUB_STEP_SUMMARY="$tmp/cig-summary" expect "ci-gates: with a base" 0 "$cig" "$cgbase"
grep -qxF '  - echo gate-bad >&2; exit 3' "$tmp/cig-summary" && grep -qxF '  + echo gate-added' "$tmp/cig-summary" && grep -qxF '  - echo gate-three' "$tmp/cig-summary" && ok "ci-gates: lists added and removed gates" || bad "ci-gates: lists added and removed gates"
! grep -qF 'gate-one' <(grep '^  [+-] ' "$tmp/cig-summary") && ok "ci-gates: kept gates not listed" || bad "ci-gates: kept gates not listed"
echo '{}' >.claude/10x.json
expect "ci-gates: no gates" 2 "$cig"

[ "$fail" -eq 0 ] && echo "scripts: all cases pass"
exit "$fail"
