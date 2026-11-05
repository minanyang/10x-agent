#!/usr/bin/env node
// UserPromptSubmit and PreToolUse (Bash) hook: a flow skill's Bash grants hold for the rest of the
// session in which the user typed it. Claude Code applies a skill's `allowed-tools` only to the turn
// the skill was invoked in, not to a background wake-up, a later approval turn or a `--resume` turn.
//
// UserPromptSubmit: a prompt that starts with `/10x:open`, `/10x:work`, `/10x:close`, `/10x:batch`,
// `/10x:roadmap` or `/10x:audit` records that skill's `Bash(...)` grants, as its SKILL.md lists them now (but TYPED_ONLY), as pending, in
//   ${CLAUDE_PLUGIN_DATA}/sessions/<session_id>.json
//   { "skills": { "<skill>": { "confirmed": { "prompt_id", "grants", "id"? }, "pending": { "prompt_id", "grants", "id"? } } } }
// outside the working directory, so the agent cannot write itself a record without being asked.
// The hook input does not say who sent the prompt (a scheduled prompt looks the same), so a pending
// entry is confirmed only when the transcript line of that prompt_id is the user's typed skill.
//
// PreToolUse: allows a single command (no shell metacharacters) matching a confirmed grant, or a
// pending one that the transcript confirms, outside a subagent. A 10x script run on a ticket is
// allowed only for the entry's ticket id: the one typed with the skill, or for a task in words the
// first one the hook allows (`10x-security list` and `route` take none); an UNBOUND skill's entry (/10x:roadmap creates a ticket per roadmap item,
// /10x:audit works on audit runs) binds none. Anything else, and any error of its own, prints nothing: Claude Code decides as usual.

const fs = require('node:fs')
const path = require('node:path')

const SID = /^[A-Za-z0-9-]+$/
const TYPED = /^\s*\/10x:(open|work|close|batch|roadmap|audit)(?=\s|$)/
// Skills whose entry is not bound to one ticket id: /10x:roadmap runs `10x-land ticket <slug>` once per item, and
// /10x:audit runs `10x-security import run-<n>` on a new run each time.
const UNBOUND = new Set(['roadmap', 'audit'])
const META = /[;&|<>$`\n\r]/
// Grants used only in the turn the skill was typed, where its allowed-tools apply anyway: kept out of the record so a
// later turn cannot start a new batch the user never named.
const TYPED_ONLY = new Set(['10x-batch init *'])
// Commands that always ask, whatever a session's record holds — one saved by an older SKILL.md included: the public
// writes (a security advisory included), a batch's plan approval, starting a batch, and settling, removing or opening a
// ticket for a security entry (a session can put its own ticket into any entry's `seen in` with `10x-security add`, so
// the ticket binding alone does not protect them).
const ALWAYS_ASK = /^(10x-land (issue|comment|advisory)|10x-batch (approve|init)|10x-security (set|remove|ticket))(\s|$)/
const ID = /^[A-Za-z0-9][A-Za-z0-9._-]*$/
// The word that carries the ticket id: `10x-land <sub> <id>`, `10x-verify <id>`, ….
const ID_WORD = {
  '10x-land': 2,
  '10x-worktree': 2,
  '10x-verify': 1,
  '10x-red-proof': 1,
  '10x-test': 1,
  '10x-review-packet': 1,
  '10x-plan-check': 1,
  '10x-security': 2,
}
const CHUNK = 1 << 20
const MAX_SCAN = 16 << 20

const pass = () => process.exit(0)

try {
  main()
} catch {
  pass()
}

function main() {
  const input = JSON.parse(fs.readFileSync(0, 'utf8'))
  if (!input || typeof input !== 'object') pass()
  const sid = typeof input.session_id === 'string' && SID.test(input.session_id) ? input.session_id : null
  const data = process.env.CLAUDE_PLUGIN_DATA
  if (!sid || !data || !path.isAbsolute(data)) pass()
  const file = path.join(data, 'sessions', `${sid}.json`)

  if (input.hook_event_name === 'UserPromptSubmit') {
    const typed = TYPED.exec(typeof input.prompt === 'string' ? input.prompt : '')
    if (typed && typeof input.prompt_id === 'string' && input.prompt_id) {
      record(file, typed[1], input.prompt_id, UNBOUND.has(typed[1]) ? undefined : typedId(input.prompt.slice(typed[0].length)))
    }
    pass()
  }
  if (input.hook_event_name !== 'PreToolUse' || input.tool_name !== 'Bash') pass()
  if (input.agent_id !== undefined) pass()
  const raw = input.tool_input && typeof input.tool_input.command === 'string' ? input.tool_input.command : ''
  const command = raw.trim()
  if (!command || META.test(command)) pass()
  const ticket = ticketOf(command)
  const skills = readSkills(file)
  for (const [skill, entry] of Object.entries(skills)) {
    const confirmed = entry && entry.confirmed
    if (!granting(confirmed, command, ticket, skill)) continue
    if (ticket && !confirmed.id && !UNBOUND.has(skill)) {
      confirmed.id = ticket
      write(file, skills)
    }
    allow(skill)
  }
  for (const [skill, entry] of Object.entries(skills)) {
    const pending = entry && entry.pending
    if (!granting(pending, command, ticket, skill) || !typedBy(input.transcript_path, pending.prompt_id, skill)) continue
    skills[skill] = { confirmed: ticket && !pending.id && !UNBOUND.has(skill) ? { ...pending, id: ticket } : pending }
    write(file, skills)
    allow(skill)
  }
  pass()
}

// The ticket id typed with the skill: `gh-<n>` for `<n>`, `#<n>` or an issues URL, as work's Step 0
// maps them; a lone valid id as it is; nothing for a task in words.
function typedId(args) {
  const words = args.trim().split(/\s+/).filter(Boolean)
  if (words.length !== 1) return undefined
  const n = /^#?(\d+)$/.exec(words[0]) || /^https?:\/\/\S*\/issues\/(\d+)\/?$/.exec(words[0])
  if (n) return `gh-${n[1]}`
  return ID.test(words[0]) ? words[0] : undefined
}

// The ticket id a command runs on: undefined for a command that takes none, '' for an invalid one.
function ticketOf(command) {
  const words = command.split(/\s+/)
  // They read security.md and take a flag or a fingerprint, never a ticket id.
  if (words[0] === '10x-security' && (words[1] === 'list' || words[1] === 'route')) return undefined
  const at = Object.hasOwn(ID_WORD, words[0]) ? ID_WORD[words[0]] : -1
  if (at < 0 || words[at] === undefined) return undefined
  return ID.test(words[at]) ? words[at] : ''
}

function allow(skill) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'allow',
        permissionDecisionReason: `10x: granted by /10x:${skill}`,
      },
    }),
  )
  pass()
}

function granting(part, command, ticket, skill) {
  // Judged on the words, as bash splits them: two spaces or a tab between them must not get past it.
  if (ALWAYS_ASK.test(command.split(/\s+/).join(' '))) return false
  if (!part || !Array.isArray(part.grants) || !part.grants.some((g) => typeof g === 'string' && matches(g, command))) return false
  if (ticket === undefined) return true
  return !!ticket && (UNBOUND.has(skill) || part.id === undefined || part.id === ticket)
}

// Reads the transcript backwards, at most MAX_SCAN bytes, for the line of prompt `id`: the user's
// typed expansion of the skill: `origin.kind: "human"`, or under `claude -p` / the SDK no `origin` and
// `turnOrigin: "sdk"`, not meta and with no `promptSource`, starting with the expansion. A scheduled
// prompt's line is neither and keeps its raw text, so text the model wrote cannot start that way; a
// tool result has array content.
function typedBy(transcript, id, skill) {
  if (typeof transcript !== 'string' || !path.isAbsolute(transcript) || typeof id !== 'string' || !id) return false
  const fd = fs.openSync(transcript, 'r')
  try {
    let pos = fs.fstatSync(fd).size
    let rest = Buffer.alloc(0)
    let scanned = 0
    while (pos > 0 && scanned < MAX_SCAN) {
      const n = Math.min(CHUNK, pos)
      pos -= n
      scanned += n
      const buf = Buffer.alloc(n)
      fs.readSync(fd, buf, 0, n, pos)
      const data = Buffer.concat([buf, rest])
      const nl = data.indexOf(10)
      if (pos > 0 && nl === -1) {
        rest = data
        continue
      }
      const start = pos > 0 ? nl + 1 : 0
      rest = data.subarray(0, start)
      const lines = data.subarray(start).toString('utf8').split('\n')
      for (let i = lines.length - 1; i >= 0; i--) {
        if (lines[i].includes(id) && typedLine(lines[i], id, skill)) return true
      }
    }
  } finally {
    fs.closeSync(fd)
  }
  return false
}

function typedLine(line, id, skill) {
  let l
  try {
    l = JSON.parse(line)
  } catch {
    return false
  }
  return (
    !!l &&
    l.type === 'user' &&
    l.promptId === id &&
    (l.origin ? l.origin.kind === 'human' : l.turnOrigin === 'sdk' && l.isMeta !== true && l.promptSource == null) &&
    !!l.message &&
    typeof l.message.content === 'string' &&
    l.message.content.startsWith(`<command-message>10x:${skill}</command-message>\n<command-name>/10x:${skill}</command-name>`)
  )
}

function readSkills(file) {
  try {
    const r = JSON.parse(fs.readFileSync(file, 'utf8'))
    if (r && typeof r === 'object' && r.skills && typeof r.skills === 'object' && !Array.isArray(r.skills)) return r.skills
  } catch {}
  return {}
}

function skillGrants(skill) {
  let text
  try {
    text = fs.readFileSync(path.join(__dirname, '..', 'skills', skill, 'SKILL.md'), 'utf8').replace(/\r/g, '')
  } catch {
    return []
  }
  const fm = /^---\n([\s\S]*?)\n---/.exec(text)
  if (!fm) return []
  const m = /^allowed-tools:\n((?:  - .*\n?)+)/m.exec(fm[1] + '\n')
  if (!m) return []
  return m[1]
    .split('\n')
    .filter(Boolean)
    .map((l) => /^Bash\((.*)\)$/.exec(l.replace(/^  - /, '').trim()))
    .filter(Boolean)
    .map((b) => b[1].trim())
    .filter((g) => g && !g.startsWith('*') && !TYPED_ONLY.has(g))
}

// Typing a skill again replaces only its pending entry: its confirmed grants stay until a new
// prompt is confirmed, so a prompt the user did not type neither adds grants nor takes them away.
function record(file, skill, promptId, id) {
  const skills = readSkills(file)
  const entry = skills[skill] && typeof skills[skill] === 'object' ? skills[skill] : {}
  skills[skill] = { ...entry, pending: { prompt_id: promptId, grants: skillGrants(skill), id } }
  write(file, skills)
}

function write(file, skills) {
  const dir = path.dirname(file)
  fs.mkdirSync(dir, { recursive: true })
  const tmp = path.join(dir, `.${path.basename(file)}.${process.pid}.tmp`)
  fs.writeFileSync(tmp, JSON.stringify({ skills }) + '\n', { mode: 0o600 })
  fs.renameSync(tmp, file)
}

// `<prefix> *` matches the prefix alone or followed by a space and anything; any other `*` matches
// any run of characters; the rest is literal and the whole command must match.
function matches(grant, command) {
  if (grant.endsWith(' *')) {
    const prefix = grant.slice(0, -2)
    if (command === prefix) return true
    return glob(prefix + ' *', command)
  }
  return glob(grant, command)
}

function glob(pattern, command) {
  const re = pattern
    .split('*')
    .map((s) => s.replace(/[.+?^${}()|[\]\\]/g, '\\$&'))
    .join('.*')
  return new RegExp(`^${re}$`, 's').test(command)
}
