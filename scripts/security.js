// The main checkout's .10x/security.md: parse, serialise, the fingerprint, the check of a reviewer's records and the
// disclosure match. bin/10x-security is its only writer; bin/10x-land reads it.
//
//   # Security entries
//
//   ## sha256:<hex>
//   - title: <text>
//   - verdict: confirmed | needs_validation
//   - severity: critical | high | medium | low | informational   (empty for needs_validation)
//   - rule: <kebab-case>
//   - location: <path>:<line>
//   - trace: <text>
//   - status: new | fix-now | later | accepted | rejected
//   - reason:
//   - found in: <id>
//   - seen in: <id>, <id>
//   - audit fingerprint:
//   - not seen in:
//
// One blank line between sections, one newline at the end. An empty field is `- <field>:`. Every value is one line:
// `\` is stored as `\\`, newline as `\n`, carriage return as `\r`, tab as `\t`. Parse and serialise are exact inverses,
// so rewriting one entry leaves every other byte as it was. Fault messages never quote a value: a refusal must not
// publish an entry's title or location.

const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')

const HEADER = '# Security entries'
const FILE = 'security.md'
const FIELDS = ['title', 'verdict', 'severity', 'rule', 'location', 'trace', 'status', 'reason', 'found in', 'seen in', 'audit fingerprint', 'not seen in']
const VERDICTS = ['confirmed', 'needs_validation']
// Most severe first: a threshold blocks its own index and every lower one.
const SEVERITIES = ['critical', 'high', 'medium', 'low', 'informational']
const STATUSES = ['new', 'fix-now', 'later', 'accepted', 'rejected']
const ID = /^[A-Za-z0-9][A-Za-z0-9._-]*$/
const RULE = /^[a-z0-9]+(-[a-z0-9]+)*$/
const FP = /^sha256:[0-9a-f]{64}$/
// Control characters a stored value may not hold (newline, carriage return and tab are escaped instead).
const CONTROL = /[\x00-\x08\x0b-\x0c\x0e-\x1f\x7f-\x9f]/
// The snippet is only hashed; the whitespace it normalises is allowed in it.
const SNIPPET_CONTROL = /[\x00-\x08\x0e-\x1f\x7f-\x9f]/
const RECORD_KEYS = ['verdict', 'rule', 'title', 'path', 'line', 'snippet', 'trace']

const escape = (s) => s.replace(/[\\\n\r\t]/g, (c) => ({ '\\': '\\\\', '\n': '\\n', '\r': '\\r', '\t': '\\t' })[c])

// The value with its escapes reversed, or null for a bad escape.
function unescape(s) {
  let bad = false
  const out = s.replace(/\\(.?)/g, (_, c) => {
    const v = { '\\': '\\', n: '\n', r: '\r', t: '\t' }[c]
    if (v === undefined) bad = true
    return v ?? ''
  })
  return bad ? null : out
}

const list = (s) => (s === '' ? [] : s.split(', '))

function fingerprint(rule, file, snippet) {
  const norm = snippet.replace(/[ \t\r\n\f\v]+/g, ' ').replace(/^ | $/g, '')
  return 'sha256:' + crypto.createHash('sha256').update(`${rule}\n${file}\n${norm}`).digest('hex')
}

// { entries: [{ fp, line, values }], faults: [{ line, why }] }. A fault in the layout stops the parse.
function parse(text) {
  const entries = []
  const faults = []
  const fault = (line, why) => faults.push({ line, why })
  const stop = (line, why) => {
    fault(line, why)
    return { entries, faults }
  }
  const lines = text.split('\n')
  if (lines[lines.length - 1] !== '') return stop(lines.length, 'the file does not end with a newline')
  lines.pop()
  if (lines[0] !== HEADER) return stop(1, `line 1 must be "${HEADER}"`)
  const at = new Map()
  let i = 1
  while (i < lines.length) {
    if (lines[i] !== '') return stop(i + 1, 'a line outside the layout; want a blank line before each entry')
    i++
    const m = /^## (.*)$/.exec(lines[i] ?? '')
    if (!m) return stop(i + 1, 'want "## <fingerprint>"')
    const fp = m[1]
    const head = i + 1
    if (!FP.test(fp)) fault(head, 'the fingerprint is not sha256: and 64 lowercase hex digits')
    else if (at.has(fp)) fault(head, `the fingerprint of line ${at.get(fp)} is repeated`)
    else at.set(fp, head)
    i++
    const values = {}
    for (const f of FIELDS) {
      const n = i + 1
      const fm = /^- ([a-z ]+):(?: (.+))?$/.exec(lines[i] ?? '')
      if (!fm) return stop(n, `want "- ${f}:"`)
      if (fm[1] !== f) return stop(n, FIELDS.includes(fm[1]) ? `field "${fm[1]}" out of order; want "${f}"` : `unknown field; want "${f}"`)
      const bad = (why) => fault(n, `"${f}" ${why}`)
      const raw = fm[2] ?? ''
      let v = ''
      if (/[\x00-\x1f\x7f-\x9f]/.test(raw)) bad('holds a control character')
      else if ((v = unescape(raw)) === null) {
        bad('holds a bad escape')
        v = ''
      }
      values[f] = v
      if (f === 'verdict' && !VERDICTS.includes(v)) bad('must be confirmed or needs_validation')
      if (f === 'severity' && values.verdict === 'confirmed' && !SEVERITIES.includes(v)) bad(`must be one of ${SEVERITIES.join(', ')}`)
      if (f === 'severity' && values.verdict === 'needs_validation' && v !== '') bad('must be empty for needs_validation')
      if (f === 'rule' && !RULE.test(v)) bad('must be kebab-case')
      if (f === 'status' && !STATUSES.includes(v)) bad(`must be one of ${STATUSES.join(', ')}`)
      if (f === 'found in' && !ID.test(v)) bad('must be a ticket id')
      if (f === 'seen in' && !list(v).every((id) => ID.test(id))) bad('must be ticket ids separated by ", "')
      i++
    }
    entries.push({ fp, line: head, values })
  }
  return { entries, faults }
}

function serialise(entries) {
  const field = (e, f) => `- ${f}:${e.values[f] === '' ? '' : ' ' + escape(e.values[f])}\n`
  return HEADER + '\n' + entries.map((e) => `\n## ${e.fp}\n` + FIELDS.map((f) => field(e, f)).join('')).join('')
}

// Every fault of a reviewer's records, as `records[<i>]: <field> <why>`; empty when all are valid.
function validate(records) {
  const faults = []
  records.forEach((r, i) => {
    const bad = (field, why) => faults.push(`records[${i}]: ${field} ${why}`)
    if (!r || typeof r !== 'object' || Array.isArray(r)) return void faults.push(`records[${i}]: not an object`)
    const has = (k) => Object.hasOwn(r, k)
    for (const k of Object.keys(r)) if (!RECORD_KEYS.includes(k) && k !== 'severity') bad(JSON.stringify(k).slice(1, -1), 'is not a record field')
    for (const k of RECORD_KEYS) if (!has(k)) bad(k, 'missing')
    if (has('verdict') && !VERDICTS.includes(r.verdict)) bad('verdict', 'must be confirmed or needs_validation')
    if (r.verdict === 'confirmed' && !has('severity')) bad('severity', 'missing (confirmed records carry one)')
    if (r.verdict === 'needs_validation' && has('severity')) bad('severity', 'must be absent on needs_validation')
    else if (has('severity') && !SEVERITIES.includes(r.severity)) bad('severity', `must be one of ${SEVERITIES.join(', ')}`)
    if (has('rule') && !(typeof r.rule === 'string' && RULE.test(r.rule))) bad('rule', 'must match ^[a-z0-9]+(-[a-z0-9]+)*$')
    if (has('path')) {
      const p = r.path
      if (typeof p !== 'string' || p === '') bad('path', 'must be a non-empty string')
      else if (/[\x00-\x1f\x7f-\x9f]/.test(p)) bad('path', 'holds a control character')
      else if (p.startsWith('/') || p.startsWith('./') || p.includes('\\') || p.includes('//') || p.split('/').includes('..'))
        bad('path', 'must be relative, with no leading / or ./, no \\, no // and no .. segment')
    }
    if (has('line') && !(Number.isInteger(r.line) && r.line >= 1)) bad('line', 'must be an integer of at least 1')
    for (const k of ['title', 'snippet', 'trace']) {
      if (!has(k)) continue
      if (typeof r[k] !== 'string' || r[k].trim() === '') bad(k, 'must be a non-empty string')
      else if ((k === 'snippet' ? SNIPPET_CONTROL : CONTROL).test(r[k])) bad(k, 'holds a control character')
    }
  })
  return faults
}

const lstat = (p) => fs.lstatSync(p, { throwIfNoEntry: false })

// security.md under <tenx>: { file, entries, faults, refusal }. No file means no entries; a symlinked .10x/ or
// security.md, or one that is not a regular file, is a refusal.
function load(tenx) {
  const file = path.join(tenx, FILE)
  if (lstat(tenx)?.isSymbolicLink()) return { file, entries: [], faults: [], refusal: `${tenx} is a symlink` }
  const st = lstat(file)
  if (!st) return { file, entries: [], faults: [] }
  if (st.isSymbolicLink()) return { file, entries: [], faults: [], refusal: `${file} is a symlink` }
  if (!st.isFile()) return { file, entries: [], faults: [], refusal: `${file} is not a regular file` }
  return { file, ...parse(fs.readFileSync(file, 'utf8')) }
}

// load(), or exit 2 printing `<prefix><why>` on stderr for its refusal or each fault.
function loadOrExit(tenx, prefix) {
  const s = load(tenx)
  const why = s.refusal ? [s.refusal] : s.faults.map((f) => `${s.file}:${f.line}: ${f.why}`)
  if (why.length) {
    process.stderr.write(why.map((w) => prefix + w + '\n').join(''))
    process.exit(2)
  }
  return s
}

const PATH_CHAR = /[A-Za-z0-9._/-]/

function locationIn(text, loc) {
  for (let k = text.indexOf(loc); k !== -1; k = text.indexOf(loc, k + 1)) {
    if ((k === 0 || !PATH_CHAR.test(text[k - 1])) && !/[0-9]/.test(text[k + loc.length] ?? '')) return true
  }
  return false
}

// The fingerprints of the entries <text> names: the fingerprint verbatim, the title in any case, or the location
// verbatim, not inside a longer path and not followed by a digit. Whatever the entry's status.
function disclosed(entries, text) {
  const lower = text.toLowerCase()
  return entries
    .filter((e) => {
      const title = e.values.title.trim().toLowerCase()
      const loc = e.values.location
      return text.includes(e.fp) || (title !== '' && lower.includes(title)) || (loc !== '' && locationIn(text, loc))
    })
    .map((e) => e.fp)
}

// The fingerprints of confirmed entries found in or seen in <id>, new or fix-now, at or above <level>.
function open(entries, id, level) {
  const max = SEVERITIES.indexOf(level)
  return entries
    .filter((e) => {
      const v = e.values
      const sev = SEVERITIES.indexOf(v.severity)
      return v.verdict === 'confirmed' && (v['found in'] === id || list(v['seen in']).includes(id)) &&
        (v.status === 'new' || v.status === 'fix-now') && sev >= 0 && sev <= max
    })
    .map((e) => e.fp)
}

module.exports = { HEADER, FILE, FIELDS, SEVERITIES, STATUSES, ID, CONTROL, escape, unescape, list, fingerprint, parse, serialise, validate, load, loadOrExit, disclosed, open }
