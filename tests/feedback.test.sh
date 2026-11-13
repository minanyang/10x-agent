#!/bin/bash
# End-to-end test of bin/10x-feedback on a throwaway repository whose origin is not minanyang/10x-agent, against a stub
# gh and a stub claude: the report always goes to minanyang/10x-agent, through the plugin's own issue forms, with an
# Environment section a script generates, and never with the current project's name or paths.
# shellcheck disable=SC2015  # `cond && ok || bad` is safe: ok always returns 0
set -uo pipefail
BIN="$(cd "$(dirname "$0")/.." && pwd)/bin"
PLUGIN="$(dirname "$BIN")"
unset TENX_BATCH # a batch worker's gates run this suite; the TENX_BATCH cases set it per call
fail=0
ok()   { echo "ok    $1"; }
bad()  { echo "FAIL  $1"; fail=1; }
tmp=$(mktemp -d)
trap 'rm -r "$tmp"' EXIT
export PATH="$tmp/stub:$BIN:$PATH"
export STUB_LOG="$tmp/stub.log"
export STUB_BODY_COPY="$tmp/body.copy"

REPO_URL=https://github.com/minanyang/10x-agent
SECURITY_URL=$REPO_URL/security/advisories/new

# The stubs: gh logs its argv, answers `auth status` with $STUB_AUTH_RC and `issue create` / `issue comment` with
# $STUB_CREATE_RC; claude prints a fixed version.
mkdir "$tmp/stub"
cat >"$tmp/stub/gh" <<'STUB'
#!/bin/bash
echo "$*" >>"$STUB_LOG"
case "$1 $2" in
  "auth status") exit "${STUB_AUTH_RC:-0}" ;;
  "issue create"|"issue comment")
    prev=""; for a in "$@"; do [ "$prev" = --body-file ] && cp "$a" "$STUB_BODY_COPY"; prev=$a; done
    exit "${STUB_CREATE_RC:-0}" ;;
esac
exit 0
STUB
printf '#!/bin/bash\necho "9.9.9 (Claude Code)"\n' >"$tmp/stub/claude"
chmod +x "$tmp/stub/gh" "$tmp/stub/claude"
# "gh missing": a PATH of symlinks to the commands the script needs, gh left out.
mkdir "$tmp/nogh"
for c in bash env git node sed grep awk uname dirname basename readlink mktemp rm cat tail head tr sort cut mkdir cp mv ls wc cmp tee find xargs date id chmod ln realpath uniq comm stat touch; do
  p="$(command -v "$c" 2>/dev/null)" && [ -x "$p" ] && ln -s "$p" "$tmp/nogh/$c"
done
ln -s "$tmp/stub/claude" "$tmp/nogh/claude"

# The project: directory gizmo, origin acme/widget (a local bare repo under a path containing github.com/acme/widget).
mkdir -p "$tmp/github.com/acme"
git -c init.defaultBranch=main init -q --bare "$tmp/github.com/acme/widget.git"
git -c init.defaultBranch=main init -q "$tmp/gizmo"
repo="$tmp/gizmo"
cd "$repo" || exit 2
git config user.email t@t; git config user.name t
echo base >f.txt
git add -A && git commit -qm "init"
git remote add origin "$tmp/github.com/acme/widget.git" && git push -q -u origin main
real_root="$(pwd -P)"
drafts="$repo/.10x/drafts/feedback"
mkdir -p .claude
cfg() { printf '%s\n' "$1" >"$repo/.claude/10x.json"; } # <json>
cfg '{"close":"local","tickets":"files","tdd":true,"batch":{"parallel":2}}'

# run <args…> — 10x-feedback with its exit code in $rc, stdout in $tmp/out and stderr in $tmp/err.
run() { 10x-feedback "$@" >"$tmp/out" 2>"$tmp/err"; rc=$?; }
show() { echo "      exit $rc"; sed 's/^/      out: /' "$tmp/out"; sed 's/^/      err: /' "$tmp/err"; }
# the seven environment lines init prints now
envlines() { 10x-feedback init 2>/dev/null | sed '1,/^environment:$/d'; }
# bug <slug> <title> <what> [header…] — a bug draft in bug.yml's shape, Environment section last
bug() {
  local slug=$1 title=$2 what=$3 h; shift 3
  {
    printf '# %s\nForm: bug.yml\n' "$title"
    for h in "$@"; do printf '%s\n' "$h"; done
    printf '\n### What happens\n%s\n\n### Steps to reproduce\n1. Run the worker\n\n### Expected\nThe worker finishes\n\n' "$what"
    printf '### Version / commit\n0.2.0\n\n### Acceptance criteria\n- [ ] AC1 — the worker finishes with exit code 0\n\n### Environment\n'
    envlines
  } >"$drafts/$slug.md"
}
# feature <slug> <title> — a feature draft in feature.yml's shape
feature() {
  {
    printf '# %s\nForm: feature.yml\n\n### Problem\nNo way to pause a run\n\n### Proposed behaviour\nA pause command\n\n' "$2"
    printf '### Acceptance criteria\n- [ ] AC1 — a paused run prints paused and exits 0\n\n### Environment\n'
    envlines
  } >"$drafts/$1.md"
}
# comment <slug> <n> <text> — a comment draft
comment() {
  {
    printf '# Same problem\nComment: %s\n\n%s\n\n### Environment\n' "$2" "$3"
    envlines
  } >"$drafts/$1.md"
}
reset() { : >"$STUB_LOG"; rm -f "$STUB_BODY_COPY"; rm -f "$drafts"/*.md; }
mkdir -p "$drafts"

# ---- init
ver="$(node -p 'require(process.argv[1]).version' "$PLUGIN/.claude-plugin/plugin.json")"
forms="$(node "$PLUGIN/scripts/issue-form.js" "$PLUGIN" "$PLUGIN/references/banned-phrases.txt" | grep -v '^drafts: ')"
cfg '{"close":"local","tickets":"files","tdd":false,"batch":{"parallel":3},"setup":"SECRETSETUP","gates":["SECRETGATE"],"redProof":{"command":"SECRETRED"},"preReviewGates":["SECRETPRE"]}'
run init
want_out="repo: minanyang/10x-agent
gh: ok
drafts: @
$forms
new issue: $REPO_URL/issues/new?template=<form>
search: $REPO_URL/issues?q=is%3Aissue
security: $SECURITY_URL
environment:
- 10x: $ver
- Claude Code: 9.9.9
- OS: $(uname -srm)
- close: local
- tickets: files
- tdd: false
- batch.parallel: 3"
[ "$rc" -eq 0 ] && [ "$(sed 's|^drafts: .*|drafts: @|' "$tmp/out")" = "$want_out" ] &&
  { [ "$(sed -n 3p "$tmp/out")" = "drafts: $repo/.10x/drafts/feedback" ] || [ "$(sed -n 3p "$tmp/out")" = "drafts: $real_root/.10x/drafts/feedback" ]; } &&
  [ -d "$drafts" ] &&
  ok "init: environment has the versions, the OS and the four settings" ||
  { bad "init: environment has the versions, the OS and the four settings"; show; diff <(echo "$want_out") "$tmp/out"; }

[ "$rc" -eq 0 ] && ! grep -q 'SECRET' "$tmp/out" &&
  ok "init: no setup, gates, redProof.command or preReviewGates value is printed" ||
  { bad "init: no setup, gates, redProof.command or preReviewGates value is printed"; show; }

# closed sets: a value outside them prints invalid, tdd is false only for false or "false", a default says so
env_of() { run init; sed '1,/^environment:$/d' "$tmp/out" | tr '\n' ' '; }
cfg '{"close":"pr; rm -rf x","tickets":"gitlab","tdd":"false","batch":{"parallel":0}}'
got_a="$(env_of)"
cfg '{"close":"pr-merge","tickets":"github","tdd":"yes","batch":{"parallel":1.5}}'
got_b="$(env_of)"
cfg '{"close":null,"batch":{"parallel":"2"}}'
got_c="$(env_of)"
cfg '{}'
got_d="$(env_of)"
git remote set-url origin https://github.com/acme/widget.git
got_e="$(env_of)"
git remote set-url origin "$tmp/github.com/acme/widget.git"
cfg '{"close":"local","tickets":"files","tdd":true,"batch":{"parallel":2}}'
tail4() { printf '%s' "$1" | sed 's/^.*- close:/- close:/'; }
[ "$(tail4 "$got_a")" = "- close: invalid - tickets: invalid - tdd: false - batch.parallel: invalid " ] &&
  [ "$(tail4 "$got_b")" = "- close: pr-merge - tickets: github - tdd: true - batch.parallel: invalid " ] &&
  [ "$(tail4 "$got_c")" = "- close: pr (default) - tickets: files (default) - tdd: true (default) - batch.parallel: invalid " ] &&
  [ "$(tail4 "$got_d")" = "- close: pr (default) - tickets: files (default) - tdd: true (default) - batch.parallel: 2 (default) " ] &&
  [ "$(tail4 "$got_e")" = "- close: pr (default) - tickets: github (default) - tdd: true (default) - batch.parallel: 2 (default) " ] &&
  ok "init: a setting outside its closed set prints invalid" ||
  { bad "init: a setting outside its closed set prints invalid"; printf '      %s\n' "$got_a" "$got_b" "$got_c" "$got_d" "$got_e"; }

# gh missing and gh logged out
STUB_AUTH_RC=1 10x-feedback init >"$tmp/out" 2>"$tmp/err"; rc=$?
logged_out_rc=$rc; grep -qxF 'gh: logged-out' "$tmp/out"; logged_out=$?
PATH="$tmp/nogh" "$BIN/10x-feedback" init >"$tmp/out" 2>"$tmp/err"; rc=$?
[ "$logged_out_rc" -eq 0 ] && [ "$logged_out" -eq 0 ] && [ "$rc" -eq 0 ] && grep -qxF 'gh: missing' "$tmp/out" && ! PATH="$tmp/nogh" command -v gh >/dev/null &&
  ok "init: gh missing and gh logged out are named" ||
  { bad "init: gh missing and gh logged out are named"; show; }

# ---- check: the Environment section
reset
bug env-ok "Worker stops on a stale lock" "The worker stops"
run check env-ok
[ "$rc" -eq 0 ] && grep -qxF 'ok: env-ok issue bug.yml' "$tmp/out" && [ ! -s "$tmp/err" ] &&
  ok "check: a draft with init's environment passes" || { bad "check: a draft with init's environment passes"; show; }
bug env-diff "Worker stops on a stale lock" "The worker stops"
sed 's/^- close: .*/- close: pr/' "$drafts/env-diff.md" >"$drafts/env-diff.new" && mv "$drafts/env-diff.new" "$drafts/env-diff.md"
run check env-diff
d1=$rc; grep -qE '^10x: .*env-diff\.md: line [0-9]+: "### Environment" differs from 10x-feedback init$' "$tmp/err" && [ ! -s "$tmp/out" ]; d1b=$?
bug env-none "Worker stops on a stale lock" "The worker stops"
sed '/^### Environment$/,$d' "$drafts/env-none.md" >"$drafts/env-none.new" && mv "$drafts/env-none.new" "$drafts/env-none.md"
run check env-none
d2=$rc; grep -qE '^10x: .*env-none\.md: no "### Environment" section$' "$tmp/err"; d2b=$?
bug env-last "Worker stops on a stale lock" "The worker stops"
printf '\n### Notes\nmore\n' >>"$drafts/env-last.md"
run check env-last
d3=$rc; grep -qE '^10x: .*env-last\.md: line [0-9]+: "### Environment" is not the last section$' "$tmp/err"; d3b=$?
bug env-extra "Worker stops on a stale lock" "The worker stops"
printf -- '- tickets-token: SECRETSETUP\n' >>"$drafts/env-extra.md"
run check env-extra
[ "$d1" -eq 2 ] && [ "$d1b" -eq 0 ] && [ "$d2" -eq 2 ] && [ "$d2b" -eq 0 ] && [ "$d3" -eq 2 ] && [ "$d3b" -eq 0 ] && [ "$rc" -eq 2 ] &&
  grep -qE 'line [0-9]+: "### Environment" differs from 10x-feedback init$' "$tmp/err" &&
  ok "check: refuses an Environment section that differs from init" ||
  { bad "check: refuses an Environment section that differs from init"; show; }

# ---- check: the project's names and paths
reset
line_of() { grep -nF -- "$1" "$drafts/$2.md" | head -n 1 | cut -d: -f1; } # <text> <slug>
bug name-dir "Worker stops on a stale lock" "It happens in the gizmo project"
n="$(line_of 'gizmo project' name-dir)"
run check name-dir
dir_rc=$rc; [ ! -s "$tmp/out" ] && grep -qxF "10x: draft name-dir line $n: directory name \"gizmo\"" "$tmp/err"; dir_b=$?
bug name-dir2 "GIZMO stops on a stale lock" "The worker stops"
run check name-dir2
[ "$dir_rc" -eq 2 ] && [ "$dir_b" -eq 0 ] && [ "$rc" -eq 2 ] && [ ! -s "$tmp/out" ] && grep -qE '^10x: draft name-dir2 line 1: directory name "' "$tmp/err" &&
  ok "check: refuses the directory name, naming it" || { bad "check: refuses the directory name, naming it"; show; }

bug name-origin "Worker stops on a stale lock" "From acme and widget on one line
Second line has widget"
n1="$(line_of 'From acme' name-origin)"; n2="$(line_of 'Second line' name-origin)"
run check name-origin
{ [ "$rc" -eq 2 ] && [ ! -s "$tmp/out" ] && [ "$(grep -c '^10x: draft name-origin ' "$tmp/err")" -eq 3 ] &&
  [ "$(sed -n 1p "$tmp/err")" = "10x: draft name-origin line $n1: origin owner \"acme\"" ] &&
  [ "$(sed -n 2p "$tmp/err")" = "10x: draft name-origin line $n1: origin repo \"widget\"" ] &&
  [ "$(sed -n 3p "$tmp/err")" = "10x: draft name-origin line $n2: origin repo \"widget\"" ]; } &&
  ok "check: refuses the origin owner and the origin repo, naming each" || { bad "check: refuses the origin owner and the origin repo, naming each"; show; }

bug name-path "Worker stops on a stale lock" "See $real_root/src/a.js for the code"
n="$(line_of 'for the code' name-path)"
run check name-path
[ "$rc" -eq 2 ] && [ ! -s "$tmp/out" ] && grep -qE "^10x: draft name-path line $n: absolute path \"/.*gizmo\"\$" "$tmp/err" &&
  ok "check: refuses an absolute path under the project, naming it" || { bad "check: refuses an absolute path under the project, naming it"; show; }

bug name-word "Gizmos stop on a stale lock" "my-acme, acme_x, widgets and gizmotron are other words"
run check name-word
[ "$rc" -eq 0 ] && grep -qxF 'ok: name-word issue bug.yml' "$tmp/out" &&
  ok "check: a name inside a longer word passes" || { bad "check: a name inside a longer word passes"; show; }

# origin minanyang/10x-agent (any case): the three name checks are skipped, the path check stays
git remote set-url origin https://github.com/Minanyang/10x-Agent.git
bug name-self "Worker stops on a stale lock" "gizmo, minanyang and 10x-agent are fine here"
bug name-self-path "Worker stops on a stale lock" "See $real_root/src/a.js"
run check name-self
s1=$rc; grep -qxF 'ok: name-self issue bug.yml' "$tmp/out"; s1b=$?
run check name-self-path
git remote set-url origin "$tmp/github.com/acme/widget.git"
[ "$s1" -eq 0 ] && [ "$s1b" -eq 0 ] && [ "$rc" -eq 2 ] && grep -qE '^10x: draft name-self-path line [0-9]+: absolute path "' "$tmp/err" &&
  ok "check: origin minanyang/10x-agent skips the name checks and keeps the path check" ||
  { bad "check: origin minanyang/10x-agent skips the name checks and keeps the path check"; show; }

# ---- issue
reset
bug create "Worker stops on a stale lock" "The worker stops"
cp "$drafts/create.md" "$tmp/create.draft"
run issue create
{ [ "$rc" -eq 0 ] && [ "$(cat "$STUB_BODY_COPY")" = "$(tail -n +4 "$tmp/create.draft")" ] &&
  grep -E '^issue create --repo github.com/minanyang/10x-agent --title Worker stops on a stale lock --body-file [^ ]+ --label bug$' "$STUB_LOG" >/dev/null &&
  [ "$(grep -c '^issue create ' "$STUB_LOG")" -eq 1 ] && ! grep -qE -- '--type|^label list|acme|widget|gizmo' "$STUB_LOG" &&
  [ ! -e "$drafts/create.md" ]; } &&
  ok "issue: creates on minanyang/10x-agent from a project with another origin" ||
  { bad "issue: creates on minanyang/10x-agent from a project with another origin"; show; cat "$STUB_LOG"; }

reset
bug lbl-bug "Worker stops on a stale lock" "The worker stops"
feature lbl-feat "Pause a run"
run issue lbl-bug
l1="$(grep '^issue create ' "$STUB_LOG")"
cp "$STUB_BODY_COPY" "$tmp/lbl-bug.body"
: >"$STUB_LOG"
run issue lbl-feat
l2="$(grep '^issue create ' "$STUB_LOG")"
{ [[ "$l1" == *" --label bug" ]] && [[ "$l1" != *"--label enhancement"* ]] &&
  [[ "$l2" == "issue create --repo github.com/minanyang/10x-agent --title Pause a run --body-file "*" --label enhancement" ]] &&
  [[ "$l2" != *"--label bug"* ]] &&
  [ "$(sed -n 1p "$tmp/lbl-bug.body")" = "### What happens" ]; } &&
  ok "issue: a bug draft takes bug.yml's label, a feature draft feature.yml's" ||
  { bad "issue: a bug draft takes bug.yml's label, a feature draft feature.yml's"; printf '      %s\n' "$l1" "$l2"; }

reset
bug keep "Worker stops on a stale lock" "The worker stops"
STUB_CREATE_RC=7 10x-feedback issue keep >"$tmp/out" 2>"$tmp/err"; rc=$?
kept=0; [ -f "$drafts/keep.md" ] && kept=1
failed_rc=$rc
bug keep "Worker stops on a stale lock" "The worker stops"
: >"$STUB_LOG"
run issue keep
{ [ "$failed_rc" -eq 7 ] && [ "$kept" -eq 1 ] && [ "$rc" -eq 0 ] && [ ! -e "$drafts/keep.md" ]; } &&
  ok "issue: deletes the draft once created and keeps it when gh fails" ||
  { bad "issue: deletes the draft once created and keeps it when gh fails"; show; echo "      gh failed: rc $failed_rc, draft kept: $kept"; }

# ---- TENX_BATCH
reset
bug batch "Worker stops on a stale lock" "The worker stops"
comment batch-c 12 "It also happens here"
b=0
for args in "issue no-such-draft" "comment no-such-draft" "issue batch" "comment batch-c"; do
  # shellcheck disable=SC2086  # the subcommand and the slug are two words
  TENX_BATCH=1 10x-feedback $args >"$tmp/out" 2>"$tmp/err"; rc=$?
  { [ "$rc" -eq 2 ] && [ "$(cat "$tmp/err")" = "10x: refused inside a batch worker" ] && [ ! -s "$tmp/out" ]; } || { b=1; show; }
done
[ "$b" -eq 0 ] && ! grep -q '^issue ' "$STUB_LOG" && [ -f "$drafts/batch.md" ] && [ -f "$drafts/batch-c.md" ] &&
  ok "TENX_BATCH: issue and comment refuse before reading anything" || bad "TENX_BATCH: issue and comment refuse before reading anything"

# ---- comment
reset
comment post 12 "It also happens when two workers start at once"
bug post-form "Worker stops on a stale lock" "The worker stops"
cp "$drafts/post.md" "$tmp/post.draft"
run issue post
w1=$rc; grep -qxF '10x: draft post is a comment: use 10x-feedback comment post' "$tmp/err"; w1b=$?
run comment post-form
w2=$rc; grep -qxF '10x: draft post-form is not a comment: use 10x-feedback issue post-form' "$tmp/err"; w2b=$?
w3=0; ! grep -q '^issue ' "$STUB_LOG" || w3=1
printf '# Same problem\nComment: 12\n\n### Environment\n' >"$drafts/empty.md"; envlines >>"$drafts/empty.md"
run check empty
w4=$rc; grep -qE '^10x: .*empty\.md: the comment has no text$' "$tmp/err"; w4b=$?
run comment post
{ [ "$w1" -eq 2 ] && [ "$w1b" -eq 0 ] && [ "$w2" -eq 2 ] && [ "$w2b" -eq 0 ] && [ "$w3" -eq 0 ] && [ "$w4" -eq 2 ] && [ "$w4b" -eq 0 ] &&
  [ "$rc" -eq 0 ] &&
  grep -qE '^issue comment 12 --repo github.com/minanyang/10x-agent --body-file [^ ]+$' "$STUB_LOG" &&
  [ "$(grep -c '^issue ' "$STUB_LOG")" -eq 1 ] && [ "$(cat "$STUB_BODY_COPY")" = "$(tail -n +4 "$tmp/post.draft")" ] &&
  [ ! -e "$drafts/post.md" ] && [ -f "$drafts/post-form.md" ]; } &&
  ok "comment: posts on the issue the draft names, on minanyang/10x-agent" ||
  { bad "comment: posts on the issue the draft names, on minanyang/10x-agent"; show; cat "$STUB_LOG"; }

# ---- without gh
reset
bug nogh "Worker stops on a stale lock" "The worker stops"
comment nogh-c 12 "It also happens here"
body_of() { tail -n +4 "$drafts/$1.md"; }
want_issue="$(printf 'new issue: %s/issues/new?template=bug.yml\n# Worker stops on a stale lock\n\n%s\n' "$REPO_URL" "$(body_of nogh)")"
want_comment="$(printf 'issue: %s/issues/12\n# Same problem\n\n%s\n' "$REPO_URL" "$(body_of nogh-c)")"
PATH="$tmp/nogh" "$BIN/10x-feedback" issue nogh >"$tmp/out" 2>"$tmp/err"; rc=$?
m1=$rc; [ "$(cat "$tmp/out")" = "$want_issue" ] && grep -qxF '10x: gh is missing: nothing created' "$tmp/err"; m1b=$?
PATH="$tmp/nogh" "$BIN/10x-feedback" comment nogh-c >"$tmp/out" 2>"$tmp/err"; rc=$?
m2=$rc; [ "$(cat "$tmp/out")" = "$want_comment" ]; m2b=$?
STUB_AUTH_RC=1 10x-feedback issue nogh >"$tmp/out" 2>"$tmp/err"; rc=$?
{ [ "$m1" -eq 3 ] && [ "$m1b" -eq 0 ] && [ "$m2" -eq 3 ] && [ "$m2b" -eq 0 ] && [ "$rc" -eq 3 ] &&
  [ "$(cat "$tmp/out")" = "$want_issue" ] && grep -qxF '10x: gh is logged-out: nothing created' "$tmp/err" &&
  ! grep -qE '^(issue create|issue comment)' "$STUB_LOG"; } &&
  ok "issue: without gh it prints the URL and the draft, exits 3 and creates nothing" ||
  { bad "issue: without gh it prints the URL and the draft, exits 3 and creates nothing"; show; diff <(echo "$want_issue") "$tmp/out"; }

# ---- a vulnerability
reset
bug vuln "Worker stops on a stale lock" "The worker stops" "Vulnerability: yes"
comment vuln-c 12 "It also happens here"
sed 's/^Comment: 12$/Comment: 12\nVulnerability: yes/' "$drafts/vuln-c.md" >"$drafts/vuln-c.new" && mv "$drafts/vuln-c.new" "$drafts/vuln-c.md"
run check vuln
v0=$rc; grep -qxF "ok: vuln issue bug.yml" "$tmp/out" && grep -qxF "vulnerability: report privately at $SECURITY_URL" "$tmp/out"; v0b=$?
run issue vuln
v1=$rc; grep -qxF "10x: draft vuln is a vulnerability: nothing is filed publicly; report it at $SECURITY_URL" "$tmp/err"; v1b=$?
run comment vuln-c
v2=$rc; grep -qxF "10x: draft vuln-c is a vulnerability: nothing is filed publicly; report it at $SECURITY_URL" "$tmp/err"; v2b=$?
{ [ "$v0" -eq 0 ] && [ "$v0b" -eq 0 ] && [ "$v1" -eq 2 ] && [ "$v1b" -eq 0 ] && [ "$v2" -eq 2 ] && [ "$v2b" -eq 0 ] &&
  ! grep -qE '^(issue create|issue comment)' "$STUB_LOG" && [ -f "$drafts/vuln.md" ] && [ -f "$drafts/vuln-c.md" ]; } &&
  ok "issue and comment: a Vulnerability draft files nothing and names the private reporting URL" ||
  { bad "issue and comment: a Vulnerability draft files nothing and names the private reporting URL"; show; }

[ "$fail" -eq 0 ] && echo "feedback: all cases pass"
exit "$fail"
