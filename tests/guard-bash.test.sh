#!/bin/bash
# Self-test for scripts/guard-bash.sh: each case feeds a hook payload and checks the exit code.
set -uo pipefail
GUARD="$(cd "$(dirname "$0")/.." && pwd)/scripts/guard-bash.sh"
unset CLAUDE_PROJECT_DIR
fail=0

check() { # expected-exit command
  local expected=$1 cmd=$2 payload got
  payload=$(node -e 'process.stdout.write(JSON.stringify({tool_input:{command:process.argv[1]}}))' "$cmd")
  printf '%s' "$payload" | bash "$GUARD" >/dev/null 2>&1
  got=$?
  if [ "$got" -ne "$expected" ]; then
    echo "FAIL (want $expected, got $got): $cmd"
    fail=1
  fi
}

# blocked
check 2 'rm -rf build'
check 2 'rm -fr /tmp/x'
check 2 'git push --force origin main'
check 2 'git push -f'
check 2 'git push origin feature --force'
check 2 'git branch --list -D old'
check 2 'git reset --hard HEAD~1'
check 2 'git clean -fd'
check 2 'git branch -D feature'
check 2 'git checkout -- .'
check 2 'pnpm publish'
check 2 'dd if=/dev/zero of=/dev/disk2'
# allowed
check 0 'rm file.txt'
check 0 'git push origin feature'
check 0 'git push --force-with-lease origin feature'
check 0 'git reset --soft HEAD~1'
check 0 'git branch -d merged'
check 0 'ls -la'
check 0 ''

# unreadable input fails closed
if printf 'not json' | bash "$GUARD" >/dev/null 2>&1; then
  echo "FAIL: unreadable input was allowed"
  fail=1
fi

# a project that ships its own guard takes over
tmp=$(mktemp -d)
mkdir -p "$tmp/.claude/scripts"
touch "$tmp/.claude/scripts/guard-bash.sh"
if ! printf '{"tool_input":{"command":"rm -rf x"}}' | CLAUDE_PROJECT_DIR="$tmp" bash "$GUARD" >/dev/null 2>&1; then
  echo "FAIL: did not defer to the project's guard"
  fail=1
fi
rm -r "$tmp"

[ "$fail" -eq 0 ] && echo "guard-bash: all cases pass"
exit "$fail"
