// Markdown matching shared by 10x-land issue and ticket, 10x-plan-check, 10x-review-packet, 10x-batch and hooks/stop-gate.js,
// so every check reads code, fences and the banned list the same way; and a ticket's size (scripts/lib.sh ticket_size).

const fs = require('node:fs')

// Per line: null inside a fence (its fence lines included) or before <start>, else the line with inline code
// spans blanked.
function blank(lines, start = 0) {
  let fence = null
  return lines.map((s, k) => {
    if (k < start) return null
    const f = s.match(/^\s*(`{3,}|~{3,})/)
    if (fence) {
      if (f && f[1][0] === fence[0] && f[1].length >= fence.length && /^\s*[`~]+\s*$/.test(s)) fence = null
      return null
    }
    if (f) { fence = f[1]; return null }
    return s.replace(/(`+)[^`]*?\1/g, ' ')
  })
}

const phrases = (bannedPath) =>
  fs.readFileSync(bannedPath, 'utf8').split('\n').map((s) => s.trim()).filter((s) => s && !s.startsWith('#'))

// [{ line, phrase }] for each phrase of <bannedPath> in the blanked lines <text>, on word boundaries and
// case-insensitive; ordered by phrase, then line. <line> is 1-based.
function bannedHits(text, bannedPath) {
  const esc = (p) => p.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const hits = []
  for (const p of phrases(bannedPath)) {
    const re = new RegExp('(?<![\\w])' + esc(p).replace(/\s+/g, '\\s+') + '(?![\\w])', 'i')
    text.forEach((s, k) => { if (s !== null && re.test(s)) hits.push({ line: k + 1, phrase: p }) })
  }
  return hits
}

// The `## ` sections of a Markdown text, headings inside fences ignored:
// [{ name, line, from, to }] — <line> is the heading's 1-based line, [from, to) the 0-based body lines.
function sections(text) {
  const lines = text.split('\n'), b = blank(lines)
  const out = []
  b.forEach((s, k) => {
    const m = s !== null && s.match(/^(#{1,2})\s+(.*?)\s*#*\s*$/)
    if (!m) return
    if (out.length && out[out.length - 1].to === lines.length) out[out.length - 1].to = k
    if (m[1].length === 2) out.push({ name: lines[k].replace(/^##\s+/, '').trim(), line: k + 1, from: k + 1, to: lines.length })
  })
  return out
}

// Top-level bullets `- AC<n> — <text>` (a dash or colon after the number, an optional `[ ]` / `[x]` checkbox after
// the bullet) on the 0-based lines [from, to). [{ id, n, line, text }] — <line> is 1-based.
function acBullets(lines, b, from, to) {
  const out = []
  for (let k = from; k < to; k++) {
    if (b[k] === null || !/^[-*+]\s+(?:\[[ xX]\]\s*)?AC\d+\s*[—–:-]/.test(b[k])) continue
    const m = lines[k].match(/^[-*+]\s+(?:\[[ xX]\]\s*)?AC(\d+)\s*[—–:-]\s*(.*)$/)
    if (m) out.push({ id: 'AC' + m[1], n: Number(m[1]), line: k + 1, text: m[2] })
  }
  return out
}

// The criteria of a plan: the AC bullets under `## Acceptance criteria`.
function criteria(text) {
  const lines = text.split('\n'), b = blank(lines)
  const sec = sections(text).find((s) => s.name.toLowerCase() === 'acceptance criteria')
  if (!sec) return []
  return acBullets(lines, b, sec.from, sec.to)
}

// The criteria of a ticket: the AC bullets under the first `## Acceptance criteria` or `### Acceptance criteria`
// heading (an issue form's field) before the first `## Comments` heading, to the next heading of its level or above.
function ticketCriteria(text) {
  const lines = text.split('\n'), b = blank(lines)
  let from = -1, level = 0
  for (let k = 0; k < lines.length; k++) {
    const m = b[k] !== null && b[k].match(/^(#{1,6})\s+(.*?)\s*#*\s*$/)
    if (!m) continue
    const name = m[2].toLowerCase()
    if (from >= 0) {
      if (m[1].length <= level) return acBullets(lines, b, from, k)
    } else if (m[1].length === 2 && name === 'comments') return []
    else if ((m[1].length === 2 || m[1].length === 3) && name === 'acceptance criteria') { from = k + 1; level = m[1].length }
  }
  return from < 0 ? [] : acBullets(lines, b, from, lines.length)
}

// A ticket's size: `small` when its header declares it and ticketCriteria() is not empty, else `normal`. The header is
// the non-blank lines under the title, holding the line `Size: small` (a draft, a files ticket); or, when line 2 is
// blank and line 3 starts `- source: `, that list block, holding `- size: small` (what bin/10x-ticket writes). Trailing
// whitespace and `\r` dropped, case-sensitive.
function size(text) {
  const l = text.split('\n').map((s) => s.replace(/\s+$/, ''))
  const listed = l.length > 2 && l[1] === '' && l[2].startsWith('- source: ')
  const head = []
  for (let k = listed ? 2 : 1; k < l.length && l[k] !== ''; k++) head.push(l[k])
  return head.includes(listed ? '- size: small' : 'Size: small') && ticketCriteria(text).length ? 'small' : 'normal'
}

// The paths a plan binds: the first code span of each top-level bullet under `## Files`, read from the raw line,
// with a leading `./` dropped; bullets without one are skipped. A path ending in `/` stands for a directory.
function files(text) {
  const lines = text.split('\n'), b = blank(lines)
  const sec = sections(text).find((s) => s.name.toLowerCase() === 'files')
  if (!sec) return []
  const out = []
  for (let k = sec.from; k < sec.to; k++) {
    if (b[k] === null || !/^[-*+]\s/.test(b[k])) continue
    const m = lines[k].match(/(`+)(.+?)\1/)
    const p = m && m[2].trim().replace(/^(\.\/)+/, '')
    if (p && !out.includes(p)) out.push(p)
  }
  return out
}

// The test files a plan's `## Tests` table names: the second cell of each row after the header, its code span
// unquoted; a cell of dashes is no file. Each once, in order.
function testFiles(text) {
  const lines = text.split('\n'), b = blank(lines)
  const sec = sections(text).find((s) => s.name.toLowerCase() === 'tests')
  if (!sec) return []
  const rows = []
  for (let k = sec.from; k < sec.to; k++) if (b[k] !== null && /^\s*\|/.test(lines[k]) && !/^\s*\|[\s:|-]+$/.test(lines[k])) rows.push(lines[k])
  const out = []
  for (const r of rows.slice(1)) {
    const c = r.trim().replace(/^\||\|$/g, '').split('|').map((s) => s.trim())
    const f = (c[1] || '').replace(/^`+|`+$/g, '').trim()
    if (f && !/^[—–-]+$/.test(f) && !out.includes(f)) out.push(f)
  }
  return out
}

// The criteria a plan declares hand checks: `AC<n>` (each once, in order) of every AC id in the first cell of a
// `## Tests` row whose second cell is dashes and whose third, its code span unquoted, starts with `hand check:`.
function handChecks(text) {
  const lines = text.split('\n'), b = blank(lines)
  const sec = sections(text).find((s) => s.name.toLowerCase() === 'tests')
  if (!sec) return []
  const rows = []
  for (let k = sec.from; k < sec.to; k++) if (b[k] !== null && /^\s*\|/.test(lines[k]) && !/^\s*\|[\s:|-]+$/.test(lines[k])) rows.push(lines[k])
  const out = []
  for (const r of rows.slice(1)) {
    const c = r.trim().replace(/^\||\|$/g, '').split('|').map((s) => s.trim())
    const f = (c[1] || '').replace(/^`+|`+$/g, '').trim()
    const kase = (c[2] || '').replace(/^`+|`+$/g, '').trim()
    if (!/^[—–-]+$/.test(f) || !/^hand check:/i.test(kase)) continue
    for (const m of (c[0] || '').matchAll(/AC(\d+)/g)) {
      const id = `AC${Number(m[1])}`
      if (!out.includes(id)) out.push(id)
    }
  }
  return out
}

module.exports = { blank, bannedHits, phrases, sections, criteria, ticketCriteria, size, files, testFiles, handChecks }
