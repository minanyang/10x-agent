#!/bin/bash
# 10x-red-proof with real jest and vitest, on throwaway repositories with an origin.
# Installs jest and vitest once per run (npm's cache makes repeat runs fast); skips when it cannot, fails under CI=true.
# shellcheck disable=SC2015,SC2016  # `cond && ok || bad` is safe: ok always returns 0; backticks in patterns are literal Markdown
set -uo pipefail
BIN="$(cd "$(dirname "$0")/.." && pwd)/bin"
export PATH="$BIN:$PATH"
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
mkdir "$tmp/deps"
if ! (cd "$tmp/deps" && npm init -y && npm install --prefer-offline --no-audit --no-fund jest@30 vitest@5) >"$tmp/install.log" 2>&1; then
  tail -5 "$tmp/install.log" | sed 's/^/      /'
  if [ "${CI:-}" = true ]; then echo "FAIL  could not install jest and vitest"; exit 1; fi
  echo "skip: could not install jest and vitest (offline?) — red-proof runner cases not run"
  exit 0
fi

# Every fixture is reached through a symlink, as macOS's /var → /private/var does for mktemp.
mkdir "$tmp/real"
ln -s "$tmp/real" "$tmp/link"

case_runner() { # <runner> <package.json> <ext> <impl at base> <impl on branch> <test header>
  local runner=$1 pkg=$2 ext=$3 base_impl=$4 branch_impl=$5 header=$6
  local repo="$tmp/link/$runner" wt
  echo "--- $runner"
  git -c init.defaultBranch=main init -q --bare "$tmp/real/$runner-origin.git"
  git -c init.defaultBranch=main init -q "$repo"
  cd "$repo" || exit 2
  git config user.email t@t; git config user.name t
  printf '%s\n' "$pkg" >package.json
  printf 'node_modules\n' >.gitignore
  mkdir src
  printf '%s\n' "$base_impl" >"src/calc.$ext"
  git add -A && git commit -qm "init"
  git remote add origin "$tmp/real/$runner-origin.git" && git push -q -u origin main

  expect "$runner: worktree add" 0 10x-worktree add T1 --no-setup
  wt="$repo/.worktrees/T1"
  ln -s "$tmp/deps/node_modules" "$wt/node_modules"

  # a real test and a constant one in a new file, against a modified implementation
  printf '%s\n' "$branch_impl" >"$wt/src/calc.$ext"
  cat >"$wt/src/calc.test.$ext" <<EOF
$header
test('mul multiplies', () => expect(mul(2, 3)).toBe(6))
test('one is one', () => expect(1).toBe(1))
EOF
  git -C "$wt" add -A && git -C "$wt" commit -qm "feat: add mul"
  expect "$runner: real test goes red" 0 10x-red-proof T1
  grep -q "runner: $runner" "$tmp/out" && ok "$runner: runner detected" || bad "$runner: runner detected"
  grep -q "^RED    src/calc.test.$ext   1 failed / 1 passed" "$tmp/out" && ok "$runner: per-test counts" || bad "$runner: per-test counts"
  grep -q '· one is one' "$tmp/out" && ok "$runner: lists the new test that passes without the change" || bad "$runner: lists the new test that passes without the change"
  ! grep -q '· mul multiplies' "$tmp/out" && ok "$runner: does not list the real test" || bad "$runner: does not list the real test"
  [ -z "$(git -C "$wt" status --porcelain)" ] && grep -q mul "$wt/src/calc.$ext" && ok "$runner: tree restored" || bad "$runner: tree restored"

  10x-test T1 >"$tmp/out" 2>&1; local rc=$?
  [ "$rc" = 0 ] && [ "$(head -n 1 "$tmp/out")" = "T1 · 10x-test · runner: $runner · 1 file(s)" ] &&
    [ "$(grep -E '^(pass|FAIL) ' "$tmp/out")" = "pass src/calc.test.$ext" ] &&
    ok "$runner: 10x-test runs the changed test file" || { bad "$runner: 10x-test runs the changed test file (exit $rc)"; sed 's/^/      /' "$tmp/out"; }

  # a test that does not test the change
  cat >"$wt/src/noop.test.$ext" <<EOF
$header
test('noop', () => expect(add(1, 1)).toBe(2))
EOF
  git -C "$wt" add -A && git -C "$wt" commit -qm "test: noop"
  expect "$runner: unrelated test stays green" 1 10x-red-proof T1
  grep -q "^GREEN  src/noop.test.$ext" "$tmp/out" && ok "$runner: names the green file" || bad "$runner: names the green file"
  [ -z "$(git -C "$wt" status --porcelain)" ] && ok "$runner: tree restored after GREEN" || bad "$runner: tree restored after GREEN"

  # the tests half: a todo the runner reports, though no skip pattern names it
  expect "$runner: worktree add T2" 0 10x-worktree add T2 --no-setup
  wt="$repo/.worktrees/T2"
  ln -s "$tmp/deps/node_modules" "$wt/node_modules"
  mkdir -p "$repo/.10x/T2"
  printf '## Tests\n| AC | Test file | Case |\n|---|---|---|\n| AC1 | `src/skip.test.%s` | `mul` |\n' "$ext" >"$repo/.10x/T2/plan.md"
  cat >"$wt/src/skip.test.$ext" <<EOF
$header
test('mul multiplies', () => expect(mul(2, 3)).toBe(6))
test.todo('mul by zero')
EOF
  git -C "$wt" add -A && git -C "$wt" commit -qm "test: mul"
  10x-red-proof T2 --lock >"$tmp/out" 2>&1; rc=$?
  [ "$rc" = 2 ] && grep -qF "src/skip.test.$ext: 1 test(s) skipped or todo" "$tmp/out" && [ ! -e "$(git -C "$wt" rev-parse --absolute-git-dir)/10x-lock" ] &&
    ok "$runner: --lock refuses a skipped test" || { bad "$runner: --lock refuses a skipped test (exit $rc)"; sed 's/^/      /' "$tmp/out"; }
}

case_runner jest '{ "name": "fixture", "private": true, "jest": {} }' js \
  'exports.add = (a, b) => a + b' \
  'exports.add = (a, b) => a + b
exports.mul = (a, b) => a * b' \
  "const { add, mul } = require('./calc.js')"

case_runner vitest '{ "name": "fixture", "private": true, "devDependencies": { "vitest": "^5.0.0" } }' mjs \
  'export const add = (a, b) => a + b' \
  'export const add = (a, b) => a + b
export const mul = (a, b) => a * b' \
  "import { test, expect } from 'vitest'
import * as calc from './calc.mjs'
const { add, mul } = calc"

[ "$fail" -eq 0 ] && echo "red-proof runners: all cases pass"
exit "$fail"
