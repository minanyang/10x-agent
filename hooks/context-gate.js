#!/usr/bin/env node
// UserPromptSubmit hook: refuse /10x:work and /10x:close on a session that is
// already carrying a large context, and say to /clear first.
//
// A flow skill run on top of an unrelated conversation re-reads all of it on every turn:
// slower turns and a bigger bill, for context the ticket does not need. The ticket's files
// in .10x/<id>/ are the memory; a fresh session loses nothing.
//
// Context = input + cache_creation + cache_read tokens of the last assistant message in
// the transcript. A compaction after that message means the context was just reset.
//
// .claude/10x.json: { "contextGate": { "maxTokens": 200000 } }; maxTokens 0 turns it off.
// The nearest one at or above the session's cwd, within its repo, counts, so a worktree's own file wins. One
// that does not parse, or whose maxTokens is not a number, gets the default and a warning.

const fs = require('node:fs')
const path = require('node:path')

let input
try {
  input = JSON.parse(fs.readFileSync(0, 'utf8'))
} catch {
  process.exit(0) // never block a prompt on a malformed payload
}

const cmd = /^\s*\/10x:(work|close)\b(.*)$/.exec(input.prompt || '')
if (!cmd) process.exit(0)

const DEFAULT = 200_000
let limit = DEFAULT
let warning = ''
// The nearest config up to the repo root (the first directory with a .git dir or file); none outside a repo.
let file = ''
for (let dir = path.resolve(input.cwd || process.cwd()); ; dir = path.dirname(dir)) {
  const f = path.join(dir, '.claude', '10x.json')
  if (!file && fs.statSync(f, { throwIfNoEntry: false })?.isFile()) file = f // not a FIFO or device to block on
  if (fs.existsSync(path.join(dir, '.git'))) break
  if (path.dirname(dir) === dir) {
    file = ''
    break
  }
}
if (file) {
  try {
    const gate = JSON.parse(fs.readFileSync(file, 'utf8')).contextGate
    if (gate && Number.isFinite(gate.maxTokens)) limit = gate.maxTokens
    else if (gate) warning = 'contextGate.maxTokens is not a number'
  } catch (e) {
    warning = `cannot read it (${e.name})` // not e.message: it can quote the file's contents
  }
}
if (warning) warning = `10x: ${file}: ${warning}; using the default ${DEFAULT / 1000}k context limit.`
const pass = () => {
  if (warning) process.stdout.write(JSON.stringify({ systemMessage: warning }))
  process.exit(0)
}
if (limit <= 0) process.exit(0)

let lines
try {
  lines = fs.readFileSync(input.transcript_path, 'utf8').split('\n')
} catch {
  pass() // no transcript yet: a fresh session
}

let ctx = 0
for (let i = lines.length - 1; i >= 0 && !ctx; i--) {
  const line = lines[i]
  if (!line) continue
  if (line.includes('"isCompactSummary":true')) pass()
  if (!line.includes('"usage"')) continue
  let e
  try {
    e = JSON.parse(line)
  } catch {
    continue
  }
  const u = e.type === 'assistant' && e.message && e.message.usage
  if (u) ctx = (u.input_tokens || 0) + (u.cache_creation_input_tokens || 0) + (u.cache_read_input_tokens || 0)
}
if (ctx < limit) pass()

const again = `/10x:${cmd[1]}${cmd[2].trim() ? ' ' + cmd[2].trim() : ''}`
process.stdout.write(
  JSON.stringify({
    decision: 'block',
    reason:
      `Context is ${Math.round(ctx / 1000)}k tokens, over 10x's ${Math.round(limit / 1000)}k limit for a flow skill. ` +
      `Run /clear, then ${again} — the ticket's files in .10x/ carry everything the next session needs.`,
    ...(warning && { systemMessage: warning }),
  }),
)
