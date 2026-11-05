// The one parser of .10x/roadmap.md, shared by bin/10x-roadmap and bin/10x-batch.
//
// The file holds a table under the exact header row `| Version | Contents | Why this order | State |` (cells trimmed),
// with a separator row of four `:?-+:?` cells right after it, then the sections `## Not yet assigned`, `## Later` and
// `## Decided against`, each once, after the table, in any order. Rows are split on unescaped `|`. `Contents` holds
// items separated by `; ` outside code spans; an item has a ticket when its last code span ends it and is `gh-<n>` or an
// id with .10x/<id>/ticket.md. A section entry is a top-level `-`, `*` or `+` bullet with its indented continuation
// lines; a `## Decided against` entry needs a reason after ` — `, ` – `, ` - ` or `: `. A state is done when it reads
// `Done <YYYY-MM-DD>`.

const fs = require('node:fs')
const path = require('node:path')
const md = require(path.join(__dirname, 'md-check.js'))

const HEADER = ['Version', 'Contents', 'Why this order', 'State']
const SECTIONS = ['Not yet assigned', 'Later', 'Decided against']
const ID = /^[A-Za-z0-9][A-Za-z0-9._-]*$/
const GH = /^gh-[1-9][0-9]*$/
const DONE = /^Done \d{4}-\d{2}-\d{2}$/
const REASON = /\S(?: [—–-]|:) +\S/

const escaped = (s, i) => {
  let n = 0
  while (i - n - 1 >= 0 && s[i - n - 1] === '\\') n++
  return n % 2 === 1
}

// The cells of a table row: [{ text, from, to }], [from, to) the trimmed cell in <line>; null when <line> is not a row.
function cells(line) {
  if (!/^\s*\|/.test(line)) return null
  const bars = []
  for (let i = 0; i < line.length; i++) if (line[i] === '|' && !escaped(line, i)) bars.push(i)
  const out = []
  const cell = (a, b) => {
    const s = line.slice(a, b)
    const lead = s.length - s.trimStart().length
    const text = s.trim()
    const from = text ? a + lead : a + Math.min(1, s.length)
    out.push({ text, from, to: from + text.length })
  }
  for (let j = 0; j + 1 < bars.length; j++) cell(bars[j] + 1, bars[j + 1])
  const tail = bars[bars.length - 1] + 1
  if (line.slice(tail).trim()) cell(tail, line.length)
  return out
}

const isHeader = (line) => {
  const c = cells(line)
  return !!c && c.length === HEADER.length && c.every((x, i) => x.text === HEADER[i])
}
const isSeparator = (line) => {
  const c = cells(line)
  return !!c && c.length === HEADER.length && c.every((x) => /^:?-+:?$/.test(x.text))
}

// The end of the run of exactly <n> backticks after <from>, or -1.
function closing(s, from, to, n) {
  for (let i = from; i < to; ) {
    if (s[i] !== '`') {
      i++
      continue
    }
    let k = 0
    while (i + k < to && s[i + k] === '`') k++
    if (k === n) return i
    i += k
  }
  return -1
}

// The items of the Contents cell <c> of <line>, split on `; ` outside code spans: [{ text, from, to }].
function split(line, c) {
  const out = []
  const push = (a, b) => {
    const s = line.slice(a, b)
    const lead = s.length - s.trimStart().length
    const text = s.trim()
    out.push({ text, from: a + lead, to: a + lead + text.length })
  }
  let start = c.from
  for (let i = c.from; i < c.to; ) {
    if (line[i] === '`') {
      let n = 0
      while (i + n < c.to && line[i + n] === '`') n++
      const end = closing(line, i + n, c.to, n)
      i = end < 0 ? i + n : end + n
    } else if (line[i] === ';' && line[i + 1] === ' ' && i + 1 < c.to) {
      push(start, i)
      start = i + 2
      i += 2
    } else i++
  }
  push(start, c.to)
  return out
}

// Whether <id> is a ticket id: `gh-<n>` by its pattern, else an id with <10x>/<id>/ticket.md.
const ticketTest = (tenx) => (id) => GH.test(id) || (ID.test(id) && fs.existsSync(path.join(tenx, id, 'ticket.md')))

function idOf(text, isTicket) {
  const m = /`([^`]+)`$/.exec(text)
  if (!m) return null
  const id = m[1].trim()
  return isTicket(id) ? id : null
}

// { lines, faults: [{ line, why }], rows, table, sections } — <line>s are 1-based. <rows> are the well-formed version
// rows: { line, raw, version, why, state, cells, items: [{ n, text, from, to, id }], ids }; <table> every row line
// whole; <sections> the entries of each of SECTIONS (first occurrence): [{ line, text }].
function parse(text, isTicket = () => false) {
  const lines = text.split('\n')
  const b = md.blank(lines)
  const faults = []
  const fault = (line, why) => faults.push({ line, why })
  const rows = []
  const table = []
  const head = lines.findIndex((s, k) => b[k] !== null && isHeader(s))
  if (head < 0) fault(1, `no table header \`| ${HEADER.join(' | ')} |\``)
  else {
    let k = head + 1
    if (lines[k] !== undefined && isSeparator(lines[k])) k++
    else fault(head + 2, 'no separator row under the table header')
    const seen = new Map()
    for (; k < lines.length && b[k] !== null && cells(lines[k]); k++) {
      const raw = lines[k]
      const line = k + 1
      table.push({ line, text: raw })
      const c = cells(raw)
      if (c.length !== HEADER.length) {
        fault(line, `row has ${c.length} cells, not ${HEADER.length}`)
        continue
      }
      const [v, contents, why, state] = c
      const version = v.text
      if (!version) fault(line, 'row has an empty Version')
      else if (!ID.test(version) || /^[0-9]+$/.test(version))
        fault(line, `Version '${version}' must match [A-Za-z0-9][A-Za-z0-9._-]* and not be all digits`)
      else if (seen.has(version)) fault(line, `duplicate Version '${version}' (first at line ${seen.get(version)})`)
      else seen.set(version, line)
      const label = version ? `version ${version}` : 'row'
      if (!why.text) fault(line, `${label} has an empty Why this order`)
      const items = split(raw, contents).map((it, i) => ({ n: i + 1, ...it, id: it.text ? idOf(it.text, isTicket) : null }))
      for (const it of items) if (!it.text) fault(line, `${label} has an empty item ${it.n} in Contents`)
      rows.push({ line, raw, version, why: why.text, state: state.text, cells: c, items, ids: items.map((it) => it.id).filter(Boolean) })
    }
  }
  const secs = md.sections(text)
  const sections = {}
  for (const name of SECTIONS) {
    const found = secs.filter((s) => s.name === name)
    if (!found.length) {
      fault(1, `no \`## ${name}\` section`)
      sections[name] = []
      continue
    }
    for (const s of found.slice(1)) fault(s.line, `\`## ${name}\` appears again (first at line ${found[0].line})`)
    if (head >= 0 && found[0].line <= head + 1) fault(found[0].line, `\`## ${name}\` comes before the table`)
    sections[name] = entries(lines, b, found[0])
    if (name === 'Decided against')
      for (const e of sections[name]) if (!REASON.test(e.blanked)) fault(e.line, 'a `## Decided against` entry has no ` — <reason>`')
  }
  return { lines, faults: faults.sort((x, y) => x.line - y.line), rows, table, sections }
}

function entries(lines, b, sec) {
  const out = []
  for (let k = sec.from; k < sec.to; k++) {
    if (b[k] === null || !/^[-*+]\s/.test(b[k])) continue
    let e = k + 1
    while (e < sec.to && /^[ \t]+\S/.test(lines[e])) e++
    const blanked = [b[k].replace(/^[-*+]\s+/, ''), ...b.slice(k + 1, e).map((s) => (s === null ? '' : s.trim()))].join(' ')
    out.push({ line: k + 1, text: lines.slice(k, e).join('\n'), blanked })
    k = e - 1
  }
  return out
}

// The lines of <oldText> that <newText> does not keep byte-identical: table rows (each line whole) in the table, and
// section entries (each block whole) in their own section, duplicates counted. [{ line, text }] in file order.
function notKept(oldText, newText) {
  const a = parse(oldText)
  const z = parse(newText)
  const out = []
  const drop = (olds, news) => {
    const left = new Map()
    for (const x of news) left.set(x.text, (left.get(x.text) || 0) + 1)
    for (const x of olds) {
      const n = left.get(x.text) || 0
      if (n) left.set(x.text, n - 1)
      else x.text.split('\n').forEach((t, i) => out.push({ line: x.line + i, text: t }))
    }
  }
  drop(a.table, z.table)
  for (const name of SECTIONS) drop(a.sections[name], z.sections[name])
  return out.sort((x, y) => x.line - y.line)
}

const isDone = (state) => DONE.test(state)

// <text> with the row of <version>'s line replaced by <replace(row)>.
function rewrite(text, version, replace) {
  const p = parse(text)
  const row = p.rows.find((r) => r.version === version)
  if (!row) return null
  const lines = p.lines.slice()
  lines[row.line - 1] = replace(row)
  return lines.join('\n')
}

// <text> with <version>'s State cell set to <state>; nothing else changes.
const setState = (text, version, state) => rewrite(text, version, (r) => r.raw.slice(0, r.cells[3].from) + state + r.raw.slice(r.cells[3].to))

// <text> with `` `<id>` `` appended to item <n> of <version>.
const link = (text, version, n, id) =>
  rewrite(text, version, (r) => {
    const it = r.items[n - 1]
    return r.raw.slice(0, it.to) + ` \`${id}\`` + r.raw.slice(it.to)
  })

module.exports = { HEADER, SECTIONS, ID, GH, parse, notKept, isDone, setState, link, ticketTest }
