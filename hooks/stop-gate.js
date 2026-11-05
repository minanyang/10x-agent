#!/usr/bin/env node
// UserPromptSubmit, PostToolUse (Bash), Stop and SubagentStop hook: /10x:work cannot end its
// implementation with an acceptance criterion that lacks evidence or a question the user has not
// been asked, and a flow or a reviewer cannot end on a claim it has not checked.
//
// Binding. A session owns ticket <id> after `10x-worktree add <id>` ran and created the worktree,
// or after `/10x:work <arg>` was typed for a ticket whose plan.md has `Status: approved`. State:
//   .10x/.sessions/<session_id>.json   { "flow": true, "ticket": "<id>" }
//   .10x/<id>/session                  the owning session id; the latest binding owns the ticket
// `flow` is set by /10x:open, /10x:work, /10x:close, /10x:batch and /10x:roadmap.
//
// Stop blocks while the owned ticket's worktree exists and .10x/<id>/evidence.md misses a plan
// criterion, leaves one pending or in no known state, or has an `asked` question the last message
// does not carry. Lines: `- AC<n> — pending | met: … | deferred: "…" | asked: …`, `- asked: …`;
// the last line for a criterion wins.
//
// Stop during a flow, and SubagentStop of the two reviewers, also block on a claim that something is
// unverified, unchecked or not yet confirmed, outside code.
//
// Passes on stop_hook_active, running background tasks, and on any error of its own.

const fs = require('node:fs')
const path = require('node:path')
const { execFileSync } = require('node:child_process')

const ID = /^[A-Za-z0-9][A-Za-z0-9._-]*$/
const SID = /^[A-Za-z0-9-]+$/
const REVIEWERS = ['10x:code-reviewer', '10x:security-reviewer']
const UNVERIFIED_EN = ['unverified', 'not verified', 'unchecked', 'not checked', 'not yet confirmed', 'not confirmed']
const UNVERIFIED_ZH = ['未驗證', '未验证', '未經驗證', '未经验证', '未確認', '未确认', '未檢查', '未检查']
const CLAIM =
  'Your last message says something is unverified, unchecked or not yet confirmed. Check it now, or state what was tried and why it cannot be checked.'

const pass = () => process.exit(0)
const block = (reasons) => {
  process.stdout.write(JSON.stringify({ decision: 'block', reason: reasons.join('\n\n') }))
  process.exit(0)
}

try {
  main()
} catch {
  pass()
}

function main() {
  const input = JSON.parse(fs.readFileSync(0, 'utf8'))
  if (!input || typeof input !== 'object') pass()
  const md = require(path.join(__dirname, '..', 'scripts', 'md-check.js'))
  const event = input.hook_event_name
  const sid = typeof input.session_id === 'string' && SID.test(input.session_id) ? input.session_id : null

  if (event === 'UserPromptSubmit' || event === 'PostToolUse') {
    if (sid) bind(input, sid, event)
    pass()
  }
  if (event !== 'Stop' && event !== 'SubagentStop') pass()
  if (input.stop_hook_active === true) pass()
  if (Array.isArray(input.background_tasks) && input.background_tasks.length) pass()
  const message = typeof input.last_assistant_message === 'string' ? input.last_assistant_message : ''

  if (event === 'SubagentStop') {
    if (REVIEWERS.includes(input.agent_type) && unverified(md, message)) block([CLAIM])
    pass()
  }

  if (!sid) pass()
  const root = mainRoot(input.cwd)
  const state = readSession(root, sid)
  if (!state) pass()
  const reasons = []
  let gaps = []
  try {
    if (state.ticket) gaps = evidenceGaps(md, root, sid, state.ticket, message)
  } catch {} // an unreadable plan or evidence.md passes this check, not the unverified-claim one
  if (gaps.length) reasons.push(`Ticket ${state.ticket}: .10x/${state.ticket}/evidence.md is not done:\n${gaps.map((g) => `- ${g}`).join('\n')}`)
  if (state.flow === true && unverified(md, message)) reasons.push(CLAIM)
  if (reasons.length) block(reasons)
  pass()
}

function mainRoot(cwd) {
  const common = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], {
    cwd: cwd || process.cwd(),
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
  }).trim()
  return { root: path.dirname(common), common }
}

function worktreeOf({ root }, id) {
  let dir = '.worktrees'
  const cfg = path.join(root, '.claude', '10x.json')
  if (fs.existsSync(cfg)) {
    const v = JSON.parse(fs.readFileSync(cfg, 'utf8')).worktreeDir
    if (typeof v === 'string' && v) dir = v
  }
  return path.join(root, dir, id)
}

function readSession({ root }, sid) {
  const f = path.join(root, '.10x', '.sessions', `${sid}.json`)
  if (!fs.existsSync(f)) return null
  const s = JSON.parse(fs.readFileSync(f, 'utf8'))
  return s && typeof s === 'object' ? s : null
}

function approved(r, id) {
  const plan = path.join(r.root, '.10x', id, 'plan.md')
  return fs.existsSync(plan) && /^Status:\s*approved\s*$/m.test(fs.readFileSync(plan, 'utf8'))
}

function resolveArg(r, arg) {
  if (!arg) return null
  const n = /^#?(\d+)$/.exec(arg) || /^https?:\/\/[^/\s]+\/[^/\s]+\/[^/\s]+\/issues\/(\d+)\/?(?:[?#]\S*)?$/.exec(arg)
  const ids = [arg, n && `gh-${n[1]}`].filter((id) => id && ID.test(id))
  return ids.find((id) => approved(r, id)) || null
}

function bind(input, sid, event) {
  let flow = false
  let ticket = null
  let r
  if (event === 'UserPromptSubmit') {
    const cmd = /^\s*\/10x:(open|work|close|batch|roadmap)\b(.*)$/s.exec(typeof input.prompt === 'string' ? input.prompt : '')
    if (!cmd) return
    r = mainRoot(input.cwd)
    flow = true
    if (cmd[1] === 'work') ticket = resolveArg(r, cmd[2].trim().split(/\s+/)[0])
  } else {
    if (input.tool_name !== 'Bash') return
    const command = input.tool_input && typeof input.tool_input.command === 'string' ? input.tool_input.command : ''
    const m = /^\s*10x-worktree add (\S+)(\s|$)/.exec(command)
    if (!m || !ID.test(m[1])) return
    r = mainRoot(input.cwd)
    if (!fs.existsSync(path.join(worktreeOf(r, m[1]), '.git'))) return
    ticket = m[1]
  }
  const prev = readSession(r, sid) || {}
  const next = { flow: prev.flow === true || flow }
  const owned = ticket || (typeof prev.ticket === 'string' && ID.test(prev.ticket) ? prev.ticket : null)
  if (owned) next.ticket = owned
  if (prev.flow === next.flow && prev.ticket === next.ticket && !ticket) return
  exclude(r)
  const tenx = path.join(r.root, '.10x')
  const sessions = path.join(tenx, '.sessions')
  noLink(tenx, sessions)
  fs.mkdirSync(sessions, { recursive: true })
  noLink(tenx, sessions)
  write(path.join(sessions, `${sid}.json`), JSON.stringify(next) + '\n')
  if (ticket) {
    const dir = path.join(tenx, ticket)
    noLink(dir)
    fs.mkdirSync(dir, { recursive: true })
    noLink(dir)
    write(path.join(dir, 'session'), sid + '\n')
  }
}

// A committed symlink at .10x could otherwise point the hook's writes anywhere.
function noLink(...paths) {
  for (const p of paths) if (fs.lstatSync(p, { throwIfNoEntry: false })?.isSymbolicLink()) throw new Error(`${p} is a symlink`)
}

function write(file, text) {
  noLink(file)
  fs.writeFileSync(file, text)
}

function exclude({ common }) {
  const f = path.join(common, 'info', 'exclude')
  const have = fs.existsSync(f) ? fs.readFileSync(f, 'utf8') : ''
  if (have.split('\n').includes('/.10x/')) return
  fs.mkdirSync(path.dirname(f), { recursive: true })
  fs.appendFileSync(f, (have && !have.endsWith('\n') ? '\n' : '') + '/.10x/\n')
}

function evidenceGaps(md, r, sid, id, message) {
  if (!ID.test(id)) return []
  const dir = path.join(r.root, '.10x', id)
  if (fs.readFileSync(path.join(dir, 'session'), 'utf8').trim() !== sid) return []
  if (!fs.existsSync(path.join(worktreeOf(r, id), '.git'))) return []
  const plan = md.criteria(fs.readFileSync(path.join(dir, 'plan.md'), 'utf8')).map((c) => `AC${c.n}`)
  const raw = fs.readFileSync(path.join(dir, 'evidence.md'), 'utf8').split('\n')
  const outside = md.blank(raw, 0)
  const last = new Map()
  const free = []
  raw.forEach((line, k) => {
    if (outside[k] === null) return
    const ac = /^\s*[-*+]\s+(AC\d+)\s*[—–:-]\s*(.*?)\s*$/.exec(line)
    if (ac) return void last.set(ac[1], ac[2])
    const q = /^\s*[-*+]\s+asked:\s*(.*?)\s*$/.exec(line)
    if (q) free.push(q[1])
  })
  const said = collapse(message)
  const unasked = (q) => !q || !said.includes(collapse(q))
  const gaps = []
  for (const ac of plan) {
    const v = last.get(ac)
    if (v === undefined) gaps.push(`${ac}: no line; add \`- ${ac} — pending\` and settle it`)
    else if (/^pending$/.test(v)) gaps.push(`${ac}: pending; give its evidence (met), the user's deferral, or ask the user`)
    else if (/^asked:/.test(v)) {
      const q = v.replace(/^asked:\s*/, '')
      if (unasked(q)) gaps.push(`${ac}: asked "${q}", but your last message does not ask it; ask it verbatim`)
    } else if (!/^(met|deferred):\s*\S/.test(v)) gaps.push(`${ac}: "${v}" is not a known state (pending, met: <evidence>, deferred: "<the user's words>", asked: <question>)`)
  }
  for (const q of free) if (unasked(q)) gaps.push(`asked "${q}", but your last message does not ask it; ask it verbatim, or remove the line once answered`)
  return gaps
}

function collapse(s) {
  return String(s).replace(/\s+/g, ' ').trim()
}

function unverified(md, message) {
  const text = md
    .blank(message.split('\n'), 0)
    .filter((l) => l !== null)
    .join('\n')
  if (UNVERIFIED_ZH.some((p) => text.includes(p))) return true
  return UNVERIFIED_EN.some((p) => new RegExp(`(?<![\\w])${p.replace(/ /g, '\\s+')}(?![\\w])`, 'i').test(text))
}
