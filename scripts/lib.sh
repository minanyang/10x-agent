#!/bin/bash
# Shared helpers for 10x's bin/ scripts. Sourced, never run.
#
# Layout inside the project (the main checkout, wherever the script is called from):
#   .claude/10x.json   optional project config, committed
#   .10x/<id>/         ticket files (spec, plan, review, logs), never committed
#   .worktrees/<id>/      one worktree per ticket (configurable: worktreeDir)
# Both .10x/ and the worktree dir are added to .git/info/exclude, never to .gitignore.

say() { printf '%s\n' "$*"; }
die() { printf '10x: %s\n' "$*" >&2; exit 2; }
# Newlines and carriage returns escaped, other control characters replaced: a value must not print lines
# that read as a script's own (a forged `pr:` or `ticket dir:`).
shown() { local s="${1//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; printf '%s' "${s//[[:cntrl:]]/?}"; }

# The main checkout's root, also when called from inside a worktree.
main_root() {
  local common
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || die "not inside a git repository"
  dirname "$common"
}

ROOT="$(main_root)"
CONFIG="$ROOT/.claude/10x.json"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"

# cfg <dotted.key> [default] — print a config value (arrays one item per line).
cfg() { cfg_in "$CONFIG" "$@"; }

# cfg_in <file> <dotted.key> [default] — the same, from another config file.
cfg_in() {
  local file=$1; shift
  [ -f "$file" ] || { [ $# -gt 1 ] && printf '%s\n' "$2"; return 0; }
  # shellcheck disable=SC2016  # JavaScript, not shell
  node -e '
    const [file, key, dflt] = process.argv.slice(1)
    let v
    try { v = key.split(".").reduce((o, k) => (o == null ? undefined : o[k]), JSON.parse(require("fs").readFileSync(file, "utf8"))) }
    catch (e) { console.error(`10x: cannot read ${file}: ${e.message}`); process.exit(2) }
    if (v === undefined || v === null) { if (dflt !== undefined) console.log(dflt); process.exit(0) }
    console.log(Array.isArray(v) ? v.join("\n") : typeof v === "object" ? JSON.stringify(v) : String(v))
  ' "$file" "$1" ${2+"$2"}
}

# wt_cfg <worktree> <dotted.key> — a config value from the worktree's 10x.json, else the main checkout's.
wt_cfg() {
  local file="$1/.claude/10x.json"
  [ -f "$file" ] || file="$CONFIG"
  cfg_in "$file" "$2"
}

# gate_changes <base-cfg> <cfg> — gates added (+) and removed (-) in <cfg> against <base-cfg>; an empty or missing base lists every gate as added.
gate_changes() {
  gate_set() { [ -s "$1" ] && cfg_in "$1" gates | sed '/^$/d' | sort -u; }
  comm -3 <(gate_set "$1") <(gate_set "$2") | awk -F'\t' '{ print ($1 == "" ? "  + " $2 : "  - " $1) }'
}

check_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid ticket id '$1' (letters, digits, . _ -)"
}

# Sets o_host and o_path (the repo path, groups included) from a remote URL.
url_parts() {
  local u="$1"
  u="${u%/}"; u="${u%.git}"
  o_host=""
  if [[ "$u" == *://* ]]; then
    u="${u#*://}"; o_host="${u%%/*}"; o_host="${o_host##*@}"; o_host="${o_host%%:*}"; o_path="${u#*/}"
  elif [[ "$u" =~ ^([^/:]+@)?([^/:]+):(.+)$ ]]; then
    o_host="${BASH_REMATCH[2]}"; o_path="${BASH_REMATCH[3]}"
  else
    o_path="${u#/}"
  fi
}

# The configured `tickets` value, unchecked; absent or null: github for a github.com origin, else files.
tickets_mode() {
  # shellcheck disable=SC2034  # o_path is set by url_parts; local so a caller's o_host/o_path are not clobbered
  local o_host o_path url dflt=files
  if url="$(git -C "$ROOT" remote get-url origin 2>/dev/null)"; then
    url_parts "$url"
    [ "$o_host" = github.com ] && dflt=github
  fi
  cfg tickets "$dflt"
}

# Prints `tickets: <mode>`, then dies on a value other than github or files.
tickets_line() {
  local v
  v="$(tickets_mode)"
  say "tickets: $(shown "$v")"
  case "$v" in github|files) ;; *) die "unknown tickets value '$(shown "$v")' in .claude/10x.json (want github or files)" ;; esac
}

# tickets_need <want> <subcommand> — dies, printing nothing, unless the tickets mode is <want>.
tickets_need() {
  local v
  v="$(tickets_mode)"
  case "$v" in github|files) ;; *) die "unknown tickets value '$(shown "$v")' in .claude/10x.json (want github or files)" ;; esac
  [ "$v" = "$1" ] || die "$2 needs tickets: $1, but this repo's tickets are $v"
}

worktree_dir() { printf '%s/%s\n' "$ROOT" "$(cfg worktreeDir .worktrees)"; }
task_dir() { printf '%s/.10x/%s\n' "$ROOT" "$1"; }

# The worktree of ticket <id>, or die.
wt_path() {
  local p r
  p="$(worktree_dir)/$1"
  [ -e "$p/.git" ] || die "ticket $1 has no worktree at $p (run: 10x-worktree add $1)"
  r="$(wt_check "$p")"
  [ -z "$r" ] || die "$r"
  printf '%s\n' "$p"
}

# wt_check <worktree> — prints why git must not run in <worktree> (its .git file or admin directory no longer points at
# the main checkout), nothing when it may. scripts/worktree.js reads files only, never git. A check that cannot run is a
# reason too: an empty one must never come from a broken check.
wt_check() {
  local out
  if ! out="$(node "$(dirname "${BASH_SOURCE[0]}")/worktree.js" "$1" "$COMMON" 2>&1)"; then
    printf 'refusing to run git in %s: the worktree check failed: %s\n' "$(shown "$1")" "$(shown "$out")"
    return 0
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
}

# Base branch name: config `base`, else develop if origin has it, else origin's default, else main.
base_branch() {
  local b
  b="$(cfg base)"
  if [ -z "$b" ]; then
    if git -C "$ROOT" show-ref --verify --quiet refs/remotes/origin/develop; then b=develop
    else b="$(git -C "$ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; b="${b#origin/}"
    fi
  fi
  printf '%s\n' "${b:-main}"
}

# A ref to start from and diff against: origin/<base> when the remote has it, else the local branch.
# In `close: local` mode the local base wins when it contains origin/<base>: tickets squashed onto it
# but not pushed yet are part of the base.
base_ref() {
  local b
  b="$(base_branch)"
  if ! git -C "$ROOT" show-ref --verify --quiet "refs/remotes/origin/$b"; then printf '%s\n' "$b"
  elif [ "$(cfg close pr)" = local ] && git -C "$ROOT" merge-base --is-ancestor "refs/remotes/origin/$b" "refs/heads/$b" 2>/dev/null; then printf '%s\n' "$b"
  else printf 'origin/%s\n' "$b"
  fi
}

# The lines the skills resolve `.10x/<id>/` paths and the base from: `ticket dir: <abs>` and `base: <branch> (<ref>)`.
ticket_lines() { # <id>
  say "ticket dir: $(shown "$(task_dir "$1")")"
  say "base: $(shown "$(base_branch)") ($(shown "$(base_ref)"))"
}

# In `close: local` mode, true when the local base and origin/<base> each have commits the other lacks.
base_diverged() {
  local b
  b="$(base_branch)"
  [ "$(cfg close pr)" = local ] || return 1
  git -C "$ROOT" show-ref --verify --quiet "refs/remotes/origin/$b" || return 1
  git -C "$ROOT" show-ref --verify --quiet "refs/heads/$b" || return 1
  ! git -C "$ROOT" merge-base --is-ancestor "refs/remotes/origin/$b" "refs/heads/$b" &&
    ! git -C "$ROOT" merge-base --is-ancestor "refs/heads/$b" "refs/remotes/origin/$b"
}

# Package manager from the lockfile in <dir>.
package_manager() {
  if [ -f "$1/pnpm-lock.yaml" ]; then echo pnpm
  elif [ -f "$1/yarn.lock" ]; then echo yarn
  elif [ -f "$1/bun.lockb" ] || [ -f "$1/bun.lock" ]; then echo bun
  elif [ -f "$1/package-lock.json" ]; then echo npm
  else echo npm
  fi
}

# rp_config <worktree> — sets rp_cmd (redProof.command) and rp_globs (redProof.tests as git pathspecs), or dies
# when the declared runner is incomplete or the stack has no package.json and no declared runner.
rp_config() {
  local g
  rp_cmd="$(wt_cfg "$1" redProof.command)"
  rp_globs=()
  if [ -n "$rp_cmd" ]; then
    while IFS= read -r g; do [ -n "$g" ] && rp_globs+=(":(glob)$g"); done < <(wt_cfg "$1" redProof.tests)
    [ ${#rp_globs[@]} -gt 0 ] || die "redProof.command is set but redProof.tests is missing (git pathspec globs naming the test files)"
    [[ "$rp_cmd" == *'{file}'* ]] || die "redProof.command has no {file} placeholder"
  elif [ ! -f "$1/package.json" ]; then
    die "unsupported: red-proof runs JavaScript/TypeScript tests (jest, vitest, node --test) out of the box; for another stack set redProof.command and redProof.tests in .claude/10x.json"
  fi
}

# test_runner <worktree> — custom (redProof.command, after rp_config), jest, vitest, else node-test.
test_runner() {
  if [ -n "${rp_cmd:-}" ]; then
    echo custom
  elif ls "$1"/jest.config.* >/dev/null 2>&1 || node -e 'process.exit(require(process.argv[1]).jest ? 0 : 1)' "$1/package.json" 2>/dev/null; then
    echo jest
  elif ls "$1"/vitest.config.* >/dev/null 2>&1 || node -e 'const p = require(process.argv[1]); process.exit({ ...p.dependencies, ...p.devDependencies }.vitest ? 0 : 1)' "$1/package.json" 2>/dev/null; then
    echo vitest
  else
    echo node-test
  fi
}

# runner_exec <worktree> — sets the array exec_cmd: `<pm> exec`, or `npx --no-install` for npm.
runner_exec() {
  local pm
  pm="$(package_manager "$1")"
  # shellcheck disable=SC2034  # read by the caller
  if [ "$pm" = npm ]; then exec_cmd=(npx --no-install); else exec_cmd=("$pm" exec); fi
}

# rp_fill <path> — rp_cmd with every {file} replaced by the shell-quoted path.
rp_fill() {
  local c=$rp_cmd q; q="$(printf %q "$1")"
  while [[ "$c" == *'{file}'* ]]; do c="${c%%'{file}'*}$q${c#*'{file}'}"; done
  printf '%s' "$c"
}

has_script() { # <dir> <script>
  [ -f "$1/package.json" ] && node -e 'process.exit((require(process.argv[1]).scripts || {})[process.argv[2]] ? 0 : 1)' "$1/package.json" "$2"
}

# Keep 10x's directories out of git without touching the project's .gitignore.
ensure_excluded() {
  local exclude entry
  exclude="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
  mkdir -p "$(dirname "$exclude")"
  touch "$exclude"
  for entry in "/.10x/" "/$(cfg worktreeDir .worktrees)/"; do
    grep -qxF "$entry" "$exclude" || printf '%s\n' "$entry" >>"$exclude"
  done
}

# Agents may write their memory into a worktree while it is frozen; it is committed later
# (10x-worktree memory), so it never counts as a change to the tree under test.
MEMORY_EXCLUDE=':(exclude).claude/agent-memory'
tree_status() { git -C "$1" status --porcelain -- . "$MEMORY_EXCLUDE"; } # <dir>

# Ticket-level lock shared by verify, red-proof and 10x-test, so a test run never overlaps a tree rewrite.
take_lock() { # <id>
  local lock
  lock="$(task_dir "$1")/lock"
  mkdir -p "$(task_dir "$1")"
  mkdir "$lock" 2>/dev/null || die "ticket $1's tree is in use by 10x-verify, 10x-red-proof or 10x-test (lock: $lock, pid $(cat "$lock/pid" 2>/dev/null || echo '?')); remove the directory if that process is gone"
  echo $$ >"$lock/pid"
  LOCK_DIR="$lock"
}
release_lock() { [ -n "${LOCK_DIR:-}" ] && rm -r "$LOCK_DIR" 2>/dev/null; return 0; }

# The tests-half lock (10x-red-proof --lock), in the worktree's own git dir so it goes with the worktree:
# one `lock <sha>` line per lock, the last current, and one `file <blob> <path>` line per locked file. Blob ids,
# not the commit alone: a rebase changes the shas but not the blobs.
lock_path() { printf '%s/10x-lock\n' "$(git -C "$1" rev-parse --absolute-git-dir)"; } # <worktree>
lock_commits() { # <worktree>
  local f; f="$(lock_path "$1")"
  [ ! -f "$f" ] || sed -n 's/^lock //p' "$f"
}
lock_files() { local f; f="$(lock_path "$1")"; [ ! -f "$f" ] || sed -n 's/^file [^ ]* //p' "$f"; } # <worktree>
# lock_changed <worktree> — each locked path whose blob at HEAD differs from the record, a deleted one included;
# nothing without a record.
lock_changed() {
  local f line rest now
  f="$(lock_path "$1")"
  [ -f "$f" ] || return 0
  while IFS= read -r line; do
    [[ "$line" == "file "* ]] || continue
    rest="${line#file }"
    now="$(git -C "$1" rev-parse -q --verify "HEAD:${rest#* }")" || now=""
    [ "$now" = "${rest%% *}" ] || printf '%s\n' "${rest#* }"
  done <"$f"
}
# lock_write <worktree> <commit> — appends `lock <commit>` and rewrites the `file` lines from that commit's blobs:
# the locked paths, or on a first lock every file the branch changed up to <commit>.
lock_write() {
  local f paths p
  f="$(lock_path "$1")"
  if [ -f "$f" ]; then paths="$(lock_files "$1")"
  else paths="$(git -C "$1" diff -z --name-only --no-renames --diff-filter=d "$(git -C "$1" merge-base "$(base_ref)" "$2")" "$2" -- . "$MEMORY_EXCLUDE" | tr '\0' '\n')"; fi
  {
    [ ! -f "$f" ] || grep '^lock ' "$f"
    printf 'lock %s\n' "$(git -C "$1" rev-parse "$2")"
    while IFS= read -r p; do [ -z "$p" ] || printf 'file %s %s\n' "$(git -C "$1" rev-parse -q --verify "$2:$p")" "$p"; done <<<"$paths"
  } >"$f.new" && mv "$f.new" "$f"
}
# relock_entries <relock.md> — one line per `## Relock <n>` entry, fields split by \x1f: n, approved|rejected (empty
# when the ruling begins with neither), commit, reason, ruling.
relock_entries() {
  [ -f "$1" ] || return 0
  awk '
    function flush() { if (on) print n "\037" verdict "\037" commit "\037" reason "\037" ruling; on = 0 }
    function value(s) { sub(/^-[ \t]*[a-z]+:[ \t]*/, "", s); sub(/[ \t]+$/, "", s); return s }
    /^## / { flush() }
    /^## Relock/ { on = 1; n = $3 == "" ? "?" : $3; reason = ruling = commit = verdict = ""; next }
    on && /^- reason:/ { reason = value($0) }
    on && /^- commit:/ { commit = value($0) }
    on && /^- ruling:/ {
      ruling = value($0); r = tolower(ruling)
      if (r ~ /^approved[ \t]*(—|-|:)/) verdict = "approved"; else if (r ~ /^rejected[ \t]*(—|-|:)/) verdict = "rejected"
    }
    END { flush() }
  ' "$1"
}

# state_dir — bin/10x-batch's state dir S: <base>/10x/<first 16 hex of the sha256 of the realpath of the git common
# dir>, <base> being $XDG_STATE_HOME when absolute, else ~/.local/state, canonical through its deepest existing ancestor.
state_dir() {
  # shellcheck disable=SC2016  # JavaScript, not shell
  node -e '
    const fs = require("fs"), os = require("os"), path = require("path"), { createHash } = require("crypto")
    const x = process.env.XDG_STATE_HOME
    let cur = path.join(x && path.isAbsolute(x) ? x : path.join(os.homedir(), ".local", "state"), "10x",
      createHash("sha256").update(fs.realpathSync(process.argv[1])).digest("hex").slice(0, 16))
    const rest = []
    while (!fs.lstatSync(cur, { throwIfNoEntry: false }) && path.dirname(cur) !== cur) { rest.unshift(path.basename(cur)); cur = path.dirname(cur) }
    console.log(path.join(fs.realpathSync(cur), ...rest))
  ' "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
}

# accepted_source <id> — the record of the GREEN test files the user accepted: S/batch/<id>/accepted-green.md, written
# only by `10x-batch accept-green`, when TENX_BATCH is set or <id> is a line of S/batch/tickets; else
# .10x/<id>/accepted-green.md. A worker controls its own environment, so the batch's ticket list decides too.
accepted_source() {
  local sb
  sb="$(state_dir)/batch" || die "could not work out the state dir"
  if in_batch "$1"; then
    printf '%s/%s/accepted-green.md\n' "$sb" "$1"
  else
    printf '%s/accepted-green.md\n' "$(task_dir "$1")"
  fi
}

# in_batch <id> — true when TENX_BATCH is set or <id> is a line of S/batch/tickets.
in_batch() {
  local sb
  [ -z "${TENX_BATCH:-}" ] || return 0
  sb="$(state_dir)/batch" || die "could not work out the state dir"
  [ -f "$sb/tickets" ] && awk -v id="$1" '{ gsub(/^[ \t\r]+|[ \t\r]+$/, "") } $0 == id { f = 1 } END { exit !f }' "$sb/tickets"
}

# ticket_size <id> — `small` when .10x/<id>/ticket.md is a regular, non-symlinked file that scripts/md-check.js size()
# calls small, no .10x/<id>/plan.md exists (a symlink counts) and in_batch <id> is false, tested in that order; else
# `normal`.
ticket_size() {
  local t s plan
  t="$(task_dir "$1")/ticket.md"; plan="$(task_dir "$1")/plan.md"
  if [ ! -L "$t" ] && [ -f "$t" ]; then
    s="$(node -e 'console.log(require(process.argv[1]).size(require("fs").readFileSync(process.argv[2], "utf8")))' \
      "$(dirname "${BASH_SOURCE[0]}")/md-check.js" "$t")" || die "could not read $t"
    if [ "$s" = small ] && [ ! -e "$plan" ] && [ ! -L "$plan" ] && ! in_batch "$1"; then echo small; return 0; fi
  fi
  echo normal
}

# security_globs — the main checkout's security.paths, one `:(glob)<g>` pathspec per line; nothing without the key.
# Dies unless it is an array of non-empty strings, none starting with `:` or holding a control character.
security_globs() {
  [ -f "$CONFIG" ] || return 0
  # shellcheck disable=SC2016  # JavaScript, not shell
  node -e '
    const f = process.argv[1]
    let c
    try { c = JSON.parse(require("fs").readFileSync(f, "utf8")) } catch (e) { console.error(`10x: cannot read ${f}: ${e.message}`); process.exit(2) }
    const s = c && typeof c === "object" ? c.security : undefined
    const v = s && typeof s === "object" ? s.paths : undefined
    if (v == null) process.exit(0)
    if (!Array.isArray(v) || !v.every((g) => typeof g === "string" && g !== "" && !g.startsWith(":") && !/[\x00-\x1f\x7f]/.test(g))) {
      console.error(`10x: security.paths in ${f} must be an array of git pathspec globs (non-empty strings, none starting with ":"), got ${JSON.stringify(v)}`)
      process.exit(2)
    }
    for (const g of v) console.log(":(glob)" + g)
  ' "$CONFIG" || exit 2
}

# accepted_entries <accepted-green.md> — one line per `## Accepted <n>` entry, fields split by \x1f: n, file (backticks
# and a leading ./ removed), blob, reason.
accepted_entries() {
  [ -f "$1" ] || return 0
  awk '
    function flush() { if (on) print n "\037" file "\037" blob "\037" reason; on = 0 }
    function value(s) { sub(/^-[ \t]*[a-z]+:[ \t]*/, "", s); sub(/[ \t]+$/, "", s); return s }
    /^## / { flush() }
    /^## Accepted/ { on = 1; n = $3 == "" ? "?" : $3; file = blob = reason = ""; next }
    on && /^- file:/ { file = value($0); gsub(/^`+|`+$/, "", file); sub(/^\.\//, "", file) }
    on && /^- blob:/ { blob = value($0) }
    on && /^- reason:/ { reason = value($0) }
    END { flush() }
  ' "$1"
}

# accepted_last <accepted-green.md> — dies on the first entry without a file, a valid blob or a reason, superseded
# ones included; else prints the last entry for each file, fields split by \x1f: file, blob, reason.
accepted_last() {
  local n f b r
  while IFS=$'\x1f' read -r n f b r; do
    [ -n "$f" ] || die "accepted entry $n ($(shown "$f")) in $1 has no file"
    [[ "$b" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || die "accepted entry $n ($(shown "$f")) in $1 has no valid blob"
    [ -n "$r" ] || die "accepted entry $n ($(shown "$f")) in $1 has no reason"
  done < <(accepted_entries "$1")
  accepted_entries "$1" | awk -F $'\x1f' '!($2 in last) { order[++k] = $2 } { last[$2] = $2 FS $3 FS $4 } END { for (i = 1; i <= k; i++) print last[order[i]] }'
}
