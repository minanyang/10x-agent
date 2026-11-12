#!/bin/bash
# gh-36: ticket sizes and security.paths, end to end on a throwaway repository with a bare origin and its own `gh` stub.
# `Size: small` in 10x-land drafts, `- size: small` from 10x-ticket, `size: small` from 10x-worktree init, red-proof --lock
# without a ## Tests table, the review packet's size line and security.paths reasons, and the draft-time refusals.
# shellcheck disable=SC2015,SC2016  # `cond && ok || bad` is safe: ok always returns 0; backticks in patterns are literal Markdown
set -uo pipefail
BIN="$(cd "$(dirname "$0")/.." && pwd)/bin"
export PATH="$BIN:$PATH"
unset TENX_BATCH # the TENX_BATCH cases set it per call
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
export XDG_STATE_HOME="$tmp/state"
git -c init.defaultBranch=main init -q --bare "$tmp/origin.git"
git -c init.defaultBranch=main init -q "$tmp/repo"
cd "$tmp/repo" || exit 2
git config user.email t@t; git config user.name t
cat >package.json <<'EOF'
{ "name": "fixture", "private": true, "scripts": { "test": "node --test" } }
EOF
mkdir src hooks
echo 'export const add = (a, b) => a + b' >src/app.js
echo 'export const guard = 1' >hooks/guard.js
git add -A && git commit -qm "init"
git remote add origin "$tmp/origin.git" && git push -q -u origin main
git remote set-url origin git@github.com:acme/size.git
# fetches of git@github.com:… are served from the bare repo
mkdir -p "$tmp/stub"
printf '#!/bin/bash\nexec git upload-pack "%s"\n' "$tmp/origin.git" >"$tmp/stub/ssh"; chmod +x "$tmp/stub/ssh"
export GIT_SSH_COMMAND="$tmp/stub/ssh"
cat >"$tmp/stub/gh" <<'STUB'
#!/bin/bash
echo "$*" >>"$STUB_LOG"
case "$1 $2" in
  "issue create")
    prev=""; for a in "$@"; do [ "$prev" = --body-file ] && [ -n "${STUB_BODY_COPY-}" ] && cp "$a" "$STUB_BODY_COPY"; prev=$a; done
    exit 0 ;;
  "issue view") cat "$STUB_ISSUE"; exit 0 ;;
  "label list") exit 0 ;;
esac
exit 0
STUB
chmod +x "$tmp/stub/gh"
export PATH="$tmp/stub:$PATH" STUB_LOG="$tmp/stub.log" STUB_ISSUE="$tmp/issue.json" STUB_BODY_COPY="$tmp/body.md"
: >"$STUB_LOG"
dr="$tmp/repo/.10x/drafts"
mkdir -p "$dr" .claude
paths='"security":{"paths":["hooks/**","auth/*.js"]}'
# setcfg <extra json members, trailing comma included> — the main checkout's .claude/10x.json
setcfg() { printf '{%s%s}\n' "$1" "$paths" >.claude/10x.json; }
crit='## Acceptance criteria\n- [ ] AC1 — it exists\n'

# AC1
setcfg ''
printf '# Small thing\nSize: small\n\n## Context\nb\n\n%b' "$crit" >"$dr/small1.md"
: >"$STUB_LOG"; : >"$STUB_BODY_COPY"
expect "issue creates a Size: small draft" 0 10x-land issue small1
printf '# Plain thing\nSize: normal\n\n## Context\nb\n\n%b' "$crit" >"$dr/plain1.md"
cp "$STUB_BODY_COPY" "$tmp/body.small"
: >"$STUB_BODY_COPY"
expect "issue creates a Size: normal draft" 0 10x-land issue plain1
{ [ "$(sed -n 1p "$tmp/body.small")" = 'Size: small' ] && [ -z "$(sed -n 2p "$tmp/body.small")" ] && [ "$(sed -n 3p "$tmp/body.small")" = '## Context' ] &&
  [ "$(grep -c '^Size:' "$tmp/body.small")" = 1 ] && ! grep -q '^Size:' "$STUB_BODY_COPY" && [ ! -e "$dr/small1.md" ]; } &&
  ok "issue writes Size: small as the first body line" || { bad "issue writes Size: small as the first body line"; cat "$tmp/body.small"; echo ---; cat "$STUB_BODY_COPY"; }

setcfg '"tickets":"files",'
printf '# Small file\nSize: small\n\n## Context\nb\n\n%b' "$crit" >"$dr/small2.md"
cp "$dr/small2.md" "$tmp/small2.want"
expect "ticket files a Size: small draft" 0 10x-land ticket small2
expect "init on the filed ticket" 0 10x-worktree init small2
{ cmp -s .10x/small2/ticket.md "$tmp/small2.want" && [ "$(sed -n 2p .10x/small2/ticket.md)" = 'Size: small' ] && [ ! -e "$dr/small2.md" ] && grep -qxF 'size: small' "$tmp/out"; } &&
  ok "ticket keeps the Size: small header line" || { bad "ticket keeps the Size: small header line"; cat "$tmp/out"; }

bad_size=0
for v in huge Small ''; do
  for mode in issue ticket; do
    if [ "$mode" = issue ]; then setcfg ''; else setcfg '"tickets":"files",'; fi
    rm -rf .10x/sz
    printf '# T\nSize: %s\n\n%b' "$v" "$crit" >"$dr/sz.md"
    : >"$STUB_LOG"
    10x-land "$mode" sz >"$tmp/out" 2>&1; rc=$?
    { [ "$rc" -eq 2 ] && grep -qF "line 2: invalid Size '$v' (want small or normal)" "$tmp/out" && [ -f "$dr/sz.md" ] && [ ! -e .10x/sz ] && ! grep -q 'issue create' "$STUB_LOG"; } ||
      { bad_size=1; echo "      $mode Size: '$v' (exit $rc):"; cat "$tmp/out"; }
  done
done
rm -f "$dr/sz.md"
[ "$bad_size" = 0 ] && ok "issue and ticket refuse an unknown Size value" || bad "issue and ticket refuse an unknown Size value"

# AC2: 10x-ticket github
# issue_json <body> [<comment bodies as a JSON array>]
issue_json() {
  node -e '
    const [body, comments] = process.argv.slice(1)
    process.stdout.write(JSON.stringify({ number: 7, title: "T", body, url: "https://github.com/acme/size/issues/7", state: "OPEN",
      labels: [{ name: "bug" }], issueType: { name: "Bug" },
      comments: JSON.parse(comments).map((b) => ({ author: { login: "u" }, createdAt: "2026-01-01T00:00:00Z", body: b })) }))
  ' -- "$1" "${2:-[]}" >"$STUB_ISSUE"
}
# size_line_ok <expected: yes|no> — the ticket on stdout has `- size: small` as the last header line (line 7, before the blank line 8)
header_has_size() { [ "$(sed -n 7p "$tmp/out")" = '- size: small' ] && [ -z "$(sed -n 8p "$tmp/out")" ]; }
issue_json $'Size: small\n\n## Context\nb\n'
expect "ticket github, a small issue" 0 10x-ticket github 7
printf '%s\n' '# T' '' '- source: GitHub issue #7 (open)' '- url: https://github.com/acme/size/issues/7' '- type: Bug' '- labels: bug' '- size: small' '' 'Size: small' '' '## Context' 'b' >"$tmp/ticket.want"
cmp -s "$tmp/out" "$tmp/ticket.want" && ok "10x-ticket writes - size: small from the body's first line (exact)" || { bad "10x-ticket writes - size: small from the body's first line (exact)"; diff "$tmp/ticket.want" "$tmp/out"; }
size_bad=0
for body in $'Size: small\r\n\r\nb' $'\n\nSize: small\n\nb' $'Size: small  \nb'; do
  issue_json "$body"
  10x-ticket github 7 >"$tmp/out" 2>&1 && header_has_size || { size_bad=1; echo "      body: $(printf '%q' "$body")"; cat "$tmp/out"; }
done
[ "$size_bad" = 0 ] && ok "10x-ticket writes - size: small from the body's first line" || bad "10x-ticket writes - size: small from the body's first line"

none_bad=0
issue_json $'Size: small\nb'
10x-ticket github 7 >"$tmp/out" 2>&1 && header_has_size || { none_bad=1; echo "      positive control: the first line should declare it"; cat "$tmp/out"; }
for body in $'Intro\n\nSize: small\n' $'size: small\nb' $'Size: smaller\nb' $'Size: normal\nb' $'- Size: small\nb' $'x\nSize: small'; do
  issue_json "$body"
  10x-ticket github 7 >"$tmp/out" 2>&1 && ! grep -q '^- size:' "$tmp/out" || { none_bad=1; echo "      body: $(printf '%q' "$body")"; cat "$tmp/out"; }
done
issue_json $'Plain body\n' '["Size: small","Size: small\nmore"]'
10x-ticket github 7 >"$tmp/out" 2>&1 && ! grep -q '^- size:' "$tmp/out" && grep -qF 'Size: small' "$tmp/out" || { none_bad=1; echo "      comments:"; cat "$tmp/out"; }
[ "$none_bad" = 0 ] && ok "10x-ticket ignores Size: small in a comment or lower in the body" || bad "10x-ticket ignores Size: small in a comment or lower in the body"

# AC3: 10x-worktree init
setcfg ''
mkticket() { mkdir -p ".10x/$1"; printf '%b' "$2" >".10x/$1/ticket.md"; }
small='# T\nSize: small\n\n## Context\nx\n\n## Acceptance criteria\n- [ ] AC1 — one\n'
# init_shows <id> — init's last two lines are `size: small` and a `plan:` line, and there are five lines
init_shows() { 10x-worktree init "$1" >"$tmp/out" 2>&1 && [ "$(sed -n 4p "$tmp/out")" = 'size: small' ] && [ "$(sed -n 5p "$tmp/out")" = 'plan: none' ] && [ "$(wc -l <"$tmp/out" | tr -d ' ')" = 5 ]; }
# init_silent <id> — init prints no size line
init_silent() { 10x-worktree init "$1" >"$tmp/out" 2>&1 && ! grep -q '^size:' "$tmp/out"; }
mkticket I1 "$small"
init_shows I1 && ok "init prints size: small before plan: for a small ticket" || { bad "init prints size: small before plan: for a small ticket"; cat "$tmp/out"; }

mkticket I2 "$small"; printf '# T\n\nStatus: approved\n' >.10x/I2/plan.md
mkticket I3 "$small"; printf '# T\n\nStatus: draft\n' >.10x/I3/plan.md
mkticket I4 "$small"; echo x >"$tmp/target.md"; ln -s "$tmp/target.md" .10x/I4/plan.md
mkticket I5 "$small"
mkticket I6 '# T\n\n## Acceptance criteria\n- [ ] AC1 — one\n'
mkticket I7 "$small"
h="$(node -e 'const fs=require("fs"),c=require("crypto");console.log(c.createHash("sha256").update(fs.realpathSync(process.argv[1])).digest("hex").slice(0,16))' "$(git rev-parse --path-format=absolute --git-common-dir)")"
mkdir -p "$XDG_STATE_HOME/10x/$h/batch"; printf 'other\nI7\n' >"$XDG_STATE_HOME/10x/$h/batch/tickets"
none_bad=0
init_shows I1 || { none_bad=1; echo "      positive control: I1 should show size: small"; cat "$tmp/out"; }
for id in I2 I3 I4 I6 I7; do init_silent "$id" || { none_bad=1; echo "      $id:"; cat "$tmp/out"; }; done
TENX_BATCH=1 10x-worktree init I5 >"$tmp/out" 2>&1 && ! grep -q '^size:' "$tmp/out" || { none_bad=1; echo "      I5 with TENX_BATCH:"; cat "$tmp/out"; }
[ "$none_bad" = 0 ] && ok "init prints no size line with a plan.md, in a batch, or without the declaration" || bad "init prints no size line with a plan.md, in a batch, or without the declaration"

mkticket I8 '# T\n\nSize: small\n\n## Acceptance criteria\n- [ ] AC1 — one\n'
mkticket I9 '# T\nSize: small\n\n## Context\nx\n'
mkticket I10 '# T\n\n- source: GitHub issue #7 (open)\n- url: https://github.com/acme/size/issues/7\n\nSize: small\n\n## Acceptance criteria\n- [ ] AC1 — one\n'
mkticket I11 '# T\nSize: small\n\n## Context\nx\n\n## Comments\n\n## Acceptance criteria\n- [ ] AC1 — a comment\n'
mkticket I12 '# T\n\n- source: GitHub issue #7 (open)\n- url: https://github.com/acme/size/issues/7\n- size: small\n\n### Acceptance criteria\n- [ ] AC1 — one\n'
none_bad=0
init_shows I12 || { none_bad=1; echo "      positive control: a 10x-ticket layout ticket should show size: small"; cat "$tmp/out"; }
for id in I8 I9 I10 I11; do init_silent "$id" || { none_bad=1; echo "      $id:"; cat "$tmp/out"; }; done
[ "$none_bad" = 0 ] && ok "init prints no size line for a declaration below the header or a ticket with no criterion" || bad "init prints no size line for a declaration below the header or a ticket with no criterion"

# AC5: red-proof --lock. A worktree whose branch adds a test that fails until src/cube.mjs exists.
red_test() { # <id> — commit src/cube.test.mjs in <id>'s worktree
  printf '%s\n' "import { test } from 'node:test'" "import assert from 'node:assert'" \
    "test('cube', async () => { const { cube } = await import('./cube.mjs'); assert.equal(cube(2), 8) })" >"$tmp/repo/.worktrees/$1/src/cube.test.mjs"
  git -C "$tmp/repo/.worktrees/$1" add -A && git -C "$tmp/repo/.worktrees/$1" commit -qm "test: cube"
}
mkticket R1 "$small"
mkticket R2 "$small"
mkticket R3 '# T\n\n## Context\nx\n\n## Acceptance criteria\n- [ ] AC1 — one\n'
mkticket R4 '# T\n\n## Context\nx\n\n## Acceptance criteria\n- [ ] AC1 — one\n'
for id in R1 R2 R3 R4; do 10x-worktree add "$id" --no-setup >/dev/null 2>&1 || { bad "worktree add $id"; }; done
for id in R1 R3; do red_test "$id"; done
10x-red-proof R1 --lock >"$tmp/out" 2>&1; rc=$?
lockf="$(git -C "$tmp/repo/.worktrees/R1" rev-parse --absolute-git-dir)/10x-lock"
{ [ "$rc" = 0 ] && grep -qF 'locked 1 file(s)' "$tmp/out" && grep -qF ' src/cube.test.mjs' "$lockf"; } &&
  ok "red-proof --lock locks a small ticket without a Tests table" || { bad "red-proof --lock locks a small ticket without a Tests table (exit $rc)"; cat "$tmp/out"; }

# a normal ticket: a test file but no ## Tests table; and no test file at all
10x-red-proof R3 --lock >"$tmp/out" 2>&1; rc3=$?
10x-red-proof R4 --lock >"$tmp/out4" 2>&1; rc4=$?
10x-red-proof R2 --lock >"$tmp/out2" 2>&1; rc2=$?
lock3="$(git -C "$tmp/repo/.worktrees/R3" rev-parse --absolute-git-dir)/10x-lock"
{ [ "$rc3" = 2 ] && grep -qF 'names no test file' "$tmp/out" && [ ! -e "$lock3" ] &&
  [ "$rc4" = 2 ] && grep -qF 'write the failing tests first' "$tmp/out4" &&
  [ "$rc2" = 2 ] && grep -qF 'write the failing tests first' "$tmp/out2"; } &&
  ok "red-proof --lock still needs a named test file for a normal ticket" ||
  { bad "red-proof --lock still needs a named test file for a normal ticket (exits $rc3 $rc4 $rc2)"; cat "$tmp/out" "$tmp/out4" "$tmp/out2"; }

# AC6/AC7: the review packet
sec() { grep '^- security review: required (' "$1" || true; }
ticket_asks() { grep -qE '^- `.*/\.10x/'"$1"'/ticket\.md` — what the ticket asks for$' "$2"; }
commit_in() { # <id> <file> <content> — commit one file in <id>'s worktree
  mkdir -p "$(dirname "$tmp/repo/.worktrees/$1/$2")"
  printf '%s\n' "$3" >"$tmp/repo/.worktrees/$1/$2"
  git -C "$tmp/repo/.worktrees/$1" add -A && git -C "$tmp/repo/.worktrees/$1" commit -qm "feat: $2"
}
setcfg ''
mkticket PS "$small"
mkticket PE "$small"
mkticket PN '# T\n\n## Context\nx\n\n## Acceptance criteria\n- [ ] AC1 — one\n'
mkticket PW "$small"; printf '# T\n\nStatus: approved\n\n## Acceptance criteria\n- AC1 — one\n' >.10x/PW/plan.md
for id in PS PE PN PW; do 10x-worktree add "$id" --no-setup >/dev/null 2>&1 || bad "worktree add $id"; done
commit_in PS src/app.js 'export const add = (a, b) => b + a'
commit_in PW src/app.js 'export const add = (a, b) => b + a'
commit_in PE hooks/guard.js 'export const guard = 2'
commit_in PN auth/login.js 'export const login = 1'
commit_in PN hooks/guard.js 'export const guard = 3'
commit_in PN src/app.js 'export const add = (a, b) => a + b + 0'
cp /dev/null "$tmp/none"
expect "packet PS" 0 10x-review-packet PS
ps=.10x/PS/review-packet.md
{ grep -qxF -- '- size: small' "$ps" && ticket_asks PS "$ps" && [ -z "$(sec "$ps")" ]; } && p1=ok || p1=bad
printf '## Round 1 — full\n\nVerdict: x\n' >.10x/PS/review.md
commit_in PS src/app.js 'export const add = (a, b) => b + a + 0'
expect "fixes packet PS" 0 10x-review-packet PS --fixes
fx=.10x/PS/fixes-packet.md
{ [ "$p1" = ok ] && grep -qxF -- '- size: small' "$fx" && ticket_asks PS "$fx" && [ -z "$(sec "$fx")" ]; } &&
  ok "packet of a small ticket says size: small and lists ticket.md" || { bad "packet of a small ticket says size: small and lists ticket.md"; cat "$ps" "$fx"; }

expect "packet PE" 0 10x-review-packet PE
pe=.10x/PE/review-packet.md
printf '## Round 1 — full\n\nVerdict: x\n' >.10x/PE/review.md
commit_in PE hooks/guard.js 'export const guard = 4'
expect "fixes packet PE" 0 10x-review-packet PE --fixes
want_sec='- security review: required (hooks/guard.js matches security.paths)'
want_size='- size: small, escalated to normal (security review: required)'
esc_ok=1
for f in "$pe" .10x/PE/fixes-packet.md; do
  [ "$(sec "$f")" = "$want_sec" ] && [ "$(grep -c '^- size:' "$f")" = 1 ] && grep -qxF -- "$want_size" "$f" &&
    [ "$(grep -n -F -x -- "$want_size" "$f" | cut -d: -f1)" = "$(($(grep -n -F -x -- "$want_sec" "$f" | cut -d: -f1) + 1))" ] || { esc_ok=0; echo "      $f:"; sed -n 1,12p "$f"; }
done
[ "$esc_ok" = 1 ] && ticket_asks PE "$pe" && ok "packet escalates a small ticket whose diff needs a security review" || bad "packet escalates a small ticket whose diff needs a security review"

expect "packet PN" 0 10x-review-packet PN
pn=.10x/PN/review-packet.md
expect "packet PW" 0 10x-review-packet PW
pw=.10x/PW/review-packet.md
{ grep -qxF -- '- size: small' "$ps" && ! grep -q '^- size:' "$pn" && ! grep -q '^- size:' "$pw" && ! ticket_asks PN "$pn" && ! ticket_asks PW "$pw"; } &&
  ok "packet of a normal ticket has no size line" || { bad "packet of a normal ticket has no size line"; sed -n 1,12p "$pn" "$pw"; }

# AC7
{ [ "$(sec "$pn")" = '- security review: required (auth/login.js matches security.paths; hooks/guard.js matches security.paths)' ] && ! grep -q 'src/app.js matches' "$pn"; } &&
  ok_main=1 || ok_main=0
# an existing reason comes first: hooks/hooks.json is both a plugin-shape reason and under hooks/**
printf '## Round 1 — full\n\nVerdict: x\n' >.10x/PN/review.md
git -C "$tmp/repo/.worktrees/PN" rev-parse HEAD >.10x/PN/review-head
commit_in PN hooks/hooks.json '{}'
expect "fixes packet PN" 0 10x-review-packet PN --fixes
[ "$(sec .10x/PN/fixes-packet.md)" = '- security review: required (hooks/hooks.json changed; hooks/hooks.json matches security.paths)' ] && ok_order=1 || ok_order=0
{ [ "$ok_main" = 1 ] && [ "$ok_order" = 1 ]; } && ok "packet requires a security review for a file under security.paths" ||
  { bad "packet requires a security review for a file under security.paths"; sec "$pn"; sec .10x/PN/fixes-packet.md; }

# the branch's own security.paths is not read, and it cannot drop the main checkout's entry
mkticket PB '# T\n\n## Context\nx\n\n## Acceptance criteria\n- [ ] AC1 — one\n'
mkticket PC '# T\n\n## Context\nx\n\n## Acceptance criteria\n- [ ] AC1 — one\n'
for id in PB PC; do 10x-worktree add "$id" --no-setup >/dev/null 2>&1 || bad "worktree add $id"; done
commit_in PB .claude/10x.json '{"security":{"paths":[]}}'
commit_in PB hooks/guard.js 'export const guard = 5'
commit_in PC .claude/10x.json '{"security":{"paths":["src/**"]}}'
commit_in PC src/app.js 'export const add = (a, b) => b + a + 1'
expect "packet PB" 0 10x-review-packet PB
expect "packet PC" 0 10x-review-packet PC
{ [ "$(sec .10x/PB/review-packet.md)" = '- security review: required (hooks/guard.js matches security.paths)' ] && ! grep -q 'matches security.paths' .10x/PC/review-packet.md; } &&
  ok "packet reads security.paths from the main checkout, not the branch" ||
  { bad "packet reads security.paths from the main checkout, not the branch"; sec .10x/PB/review-packet.md; sec .10x/PC/review-packet.md; }

bad_cfg=0
for v in '"hooks/**"' '[1]' '[""]' '[":(exclude)hooks/**"]' '{"a":"b"}' '["hooks/**",null]'; do
  printf '{"security":{"paths":%s}}\n' "$v" >.claude/10x.json
  10x-review-packet PN >"$tmp/out" 2>&1; rc=$?
  { [ "$rc" = 2 ] && grep -qF 'security.paths' "$tmp/out"; } || { bad_cfg=1; echo "      paths $v (exit $rc):"; cat "$tmp/out"; }
done
printf '{"security":{"paths":[]}}\n' >.claude/10x.json
10x-review-packet PN >"$tmp/out" 2>&1 || { bad_cfg=1; echo "      an empty array should be accepted:"; cat "$tmp/out"; }
[ "$bad_cfg" = 0 ] && ok "a security.paths that is not an array of globs exits 2" || bad "a security.paths that is not an array of globs exits 2"

# AC8: draft-time refusals
issue_mode() { setcfg ''; }
files_mode() { setcfg '"tickets":"files",'; }
# draft <slug> <size line> <body line naming a file> — a draft with the Size line at line 2 and the naming line at line 5
draft() { printf '# T\n%s\n\n## Context\n%s\n\n%b' "$2" "$3" "$crit" >"$dr/$1.md"; }
a8_bad=0
for mode in issue ticket; do
  if [ "$mode" = issue ]; then issue_mode; else files_mode; fi
  : >"$STUB_LOG"
  draft sp1 'Size: small' 'The check lives in `./hooks/guard.js:12-20`.'
  10x-land "$mode" sp1 >"$tmp/out" 2>&1; rc=$?
  { [ "$rc" = 2 ] && grep -qF 'line 2' "$tmp/out" && grep -qF 'hooks/guard.js' "$tmp/out" && grep -qF 'security.paths' "$tmp/out" && [ -f "$dr/sp1.md" ] && [ ! -e .10x/sp1 ] && ! grep -q 'issue create' "$STUB_LOG"; } ||
    { a8_bad=1; echo "      $mode refusal (exit $rc):"; cat "$tmp/out"; }
  rm -f "$dr/sp1.md"
  n=0
  # controls, all accepted: an untracked or non-matching file, a file in plain text, a normal ticket
  for case in 'Size: small|Look at `hooks/missing.js` and `src/app.js:4`.' 'Size: small|Look at hooks/guard.js in plain text.' 'Size: normal|Look at `hooks/guard.js`.'; do
    n=$((n + 1)); size="${case%%|*}"; line="${case#*|}"
    draft "sa$n" "$size" "$line"
    10x-land "$mode" "sa$n" >"$tmp/out" 2>&1; rc=$?
    [ "$rc" = 0 ] || { a8_bad=1; echo "      $mode control $n ($line): exit $rc, want 0"; cat "$tmp/out"; }
    rm -f "$dr/sa$n.md"; rm -rf ".10x/sa$n"
  done
done
[ "$a8_bad" = 0 ] && ok "issue and ticket refuse a small draft that names a security.paths file" || bad "issue and ticket refuse a small draft that names a security.paths file"

sec_hdr="Security: sha256:$(printf 'a%.0s' {1..64})"
s_bad=0
for mode in issue ticket advisory; do
  case "$mode" in ticket) files_mode ;; *) issue_mode ;; esac
  for order in "$sec_hdr|Size: small" "Size: small|$sec_hdr"; do
    printf '# T\n%s\n%s\n\n## Context\nx\n\n%b' "${order%%|*}" "${order#*|}" "$crit" >"$dr/sb.md"
    : >"$STUB_LOG"
    10x-land "$mode" sb >"$tmp/out" 2>&1; rc=$?
    { [ "$rc" = 2 ] && grep -qF 'Size' "$tmp/out" && grep -qF 'Security' "$tmp/out" && [ -f "$dr/sb.md" ] && [ ! -e .10x/sb ] && [ ! -s "$STUB_LOG" ]; } ||
      { s_bad=1; echo "      $mode ($order): exit $rc"; cat "$tmp/out" "$STUB_LOG"; }
  done
done
rm -f "$dr/sb.md"
[ "$s_bad" = 0 ] && ok "issue, ticket and advisory refuse Size: small beside a Security: line" || bad "issue, ticket and advisory refuse Size: small beside a Security: line"

[ "$fail" -eq 0 ] && echo "size: all cases pass"
exit "$fail"
