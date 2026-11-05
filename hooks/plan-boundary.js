#!/usr/bin/env node
// PreToolUse hook (Edit|Write|NotebookEdit): keeps a batch plan session's file writes inside its ticket dir.
// `10x-batch run` sets TENX_BATCH_PLAN_DIR to the absolute ticket dir (<root>/.10x/<id>) for a plan session's worker and
// removes it for every other worker; the worker cannot change the environment its hooks get. Without it (an interactive
// session, a batch implement or close session) the hook prints nothing.
//
// With it, a write is denied unless the dir exists and the target — file_path, or notebook_path for NotebookEdit — has
// no `..` component and, canonical, lies under the canonical dir: resolved against the input's cwd, its deepest
// existing ancestor-or-self (a dangling symlink counts as existing, and so fails) through realpath, the rest appended.
// Subagents included. Any error of its own while the variable is set is a deny.

const fs = require('node:fs')
const path = require('node:path')

const TOOLS = new Set(['Edit', 'Write', 'NotebookEdit'])
const dir = process.env.TENX_BATCH_PLAN_DIR

// Read whole even when it is not needed, so the writer never meets a closed pipe.
let raw = null
try {
  raw = fs.readFileSync(0, 'utf8')
} catch {}
if (!dir) process.exit(0)
let ok = false
try {
  ok = allowed(JSON.parse(raw))
} catch {}
if (!ok) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'deny',
        permissionDecisionReason: `10x: a batch plan session writes only under ${dir}`,
      },
    }),
  )
}
process.exit(0)

// True when the input is no file write of a plan session, or one inside the ticket dir.
function allowed(input) {
  if (!input || typeof input !== 'object') return false
  if (input.hook_event_name !== 'PreToolUse' || !TOOLS.has(input.tool_name)) return true
  if (!path.isAbsolute(dir)) return false
  const root = fs.realpathSync(dir)
  const t = input.tool_input && typeof input.tool_input === 'object' ? input.tool_input : {}
  const target = input.tool_name === 'NotebookEdit' ? t.notebook_path : t.file_path
  if (typeof target !== 'string' || !target || target.split('/').includes('..')) return false
  if (!path.isAbsolute(target) && !(typeof input.cwd === 'string' && path.isAbsolute(input.cwd))) return false
  return canonical(path.resolve(path.isAbsolute(target) ? '/' : input.cwd, target)).startsWith(root + path.sep)
}

function canonical(p) {
  const rest = []
  let cur = p
  while (!fs.lstatSync(cur, { throwIfNoEntry: false })) {
    const up = path.dirname(cur)
    if (up === cur) break
    rest.unshift(path.basename(cur))
    cur = up
  }
  return path.join(fs.realpathSync(cur), ...rest)
}
