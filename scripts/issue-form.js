// GitHub issue forms, read the same way by 10x-land issue (the check) and 10x-worktree init (the listing).
//
//   node scripts/issue-form.js <root> <banned-phrases path>
//
// prints `drafts: <root>/.10x/drafts`, one `form:` line per form in <root>/.github/ISSUE_TEMPLATE/ (or
// `forms: none`), one `template:` line per .md template and `banned: <json array>`. Every value is JSON-encoded,
// so none can print a line that reads as another; symlinks are never followed.

const fs = require('node:fs')
const path = require('node:path')

// Block-style YAML subset of GitHub issue forms; anything else throws. Returns the whole document; a block
// scalar reads as "(block)".
function parseForm(text) {
  const raw = text.split('\n').map((t, n) => ({ n: n + 1, t }))
  const L = raw.filter((r) => r.t.trim() !== '' && !/^\s*#/.test(r.t)).map((r) => {
    if (/^ *\t/.test(r.t)) throw new Error('line ' + r.n + ': tab indentation')
    return { n: r.n, ind: r.t.match(/^ */)[0].length, t: r.t.trim() }
  })
  const bad = (l, m) => { throw new Error('line ' + l.n + ': ' + m + ' (only block-style YAML is supported)') }
  const scalar = (l, v) => {
    // A flow list of plain scalars, as GitHub documents for labels: [bug, "triage"].
    const fl = v.match(/^\[([^\[\]{}]*)\]$/)
    if (fl) return fl[1].split(',').map((s) => s.trim().replace(/^["']|["']$/g, '')).filter(Boolean)
    if (/^[\[{&*!]/.test(v)) bad(l, 'flow style, anchor or tag')
    const q = v.match(/^"(.*)"$/) || v.match(/^'(.*)'$/)
    return q ? q[1] : v.replace(/\s+#.*$/, '')
  }
  const keyRe = /^("[^"]*"|'[^']*'|[A-Za-z0-9_][A-Za-z0-9_ -]*):(?:\s+(.*))?$/
  let i = 0
  const block = (ind) => {
    const l = L[i]
    if (l.t === '-' || l.t.startsWith('- ')) return seq(l.ind)
    if (keyRe.test(l.t)) return map(l.ind)
    bad(l, 'unexpected content')
  }
  const seq = (ind) => {
    const out = []
    while (i < L.length && L[i].ind === ind && (L[i].t === '-' || L[i].t.startsWith('- '))) {
      const l = L[i], rest = l.t.slice(1).trimStart()
      if (rest === '') { i++; out.push(i < L.length && L[i].ind > ind ? block(L[i].ind) : null); continue }
      if (keyRe.test(rest)) { L[i] = { n: l.n, ind: ind + l.t.length - rest.length, t: rest }; out.push(map(L[i].ind)) }
      else { i++; out.push(scalar(l, rest)) }
    }
    return out
  }
  const map = (ind) => {
    const out = {}
    while (i < L.length && L[i].ind === ind && !(L[i].t === '-' || L[i].t.startsWith('- '))) {
      const l = L[i], m = l.t.match(keyRe)
      if (!m) bad(l, 'unexpected content')
      const key = m[1].replace(/^["']|["']$/g, ''), v = (m[2] || '').trim()
      i++
      if (v === '' || v.startsWith('#')) {
        const nx = L[i]
        out[key] = nx && nx.ind > ind ? block(nx.ind) : nx && nx.ind === ind && nx.t.startsWith('- ') ? seq(ind) : null
      } else if (/^[|>]/.test(v)) {
        while (i < L.length && L[i].ind > ind) i++
        out[key] = '(block)'
      } else out[key] = scalar(l, v)
    }
    if (i < L.length && L[i].ind > ind) bad(L[i], 'unexpected indentation')
    return out
  }
  if (!L.length) throw new Error('empty')
  const doc = block(L[0].ind)
  if (i < L.length) bad(L[i], 'unexpected content')
  if (!doc || !Array.isArray(doc.body)) throw new Error('no top-level body: list')
  return doc
}

// The rest of a `form:` line for <text>, or `error: <json>`.
function describe(text) {
  let doc
  try { doc = parseForm(text) } catch (e) { return 'error: ' + JSON.stringify(e.message) }
  const fields = [], required = []
  for (const f of doc.body.filter((f) => f && f.type !== 'markdown')) {
    const label = f.attributes && f.attributes.label
    if (typeof label !== 'string') return 'error: ' + JSON.stringify('a ' + f.type + ' field has no attributes.label')
    fields.push(label)
    if (f.validations && String(f.validations.required) === 'true') required.push(label)
  }
  if (doc.title === '(block)') return 'error: ' + JSON.stringify('title is a block scalar')
  const str = (v) => typeof v === 'string' ? JSON.stringify(v) : 'none'
  const labels = Array.isArray(doc.labels) ? doc.labels.filter((s) => typeof s === 'string')
    : typeof doc.labels === 'string' ? doc.labels.split(',').map((s) => s.trim()).filter(Boolean) : []
  return 'name: ' + str(doc.name) + ' labels: ' + JSON.stringify(labels) + ' title: ' + str(doc.title) +
    ' required: ' + JSON.stringify(required) + ' fields: ' + JSON.stringify(fields)
}

function list(root, bannedPath) {
  const { phrases } = require('./md-check.js')
  if (!fs.existsSync(bannedPath) || !fs.statSync(bannedPath).isFile()) {
    process.stderr.write('10x: ' + bannedPath + ' is missing\n')
    process.exit(2)
  }
  const out = ['drafts: ' + path.join(root, '.10x', 'drafts')]
  const dir = path.join(root, '.github', 'ISSUE_TEMPLATE')
  let names = []
  // Neither .github nor ISSUE_TEMPLATE may be a symlink: the listing never reads outside the repo.
  try {
    if (fs.lstatSync(path.dirname(dir)).isDirectory() && fs.lstatSync(dir).isDirectory()) names = fs.readdirSync(dir).sort()
  } catch (e) { if (e.code !== 'ENOENT') throw e }
  const regular = (f) => { const s = fs.lstatSync(path.join(dir, f)); return !s.isSymbolicLink() && s.isFile() }
  // A name 10x-land would refuse as Form: is never usable, and could carry a newline into the output.
  const entry = (kind, f, ok, rest) =>
    kind + ': ' + (ok.test(f) ? f + ' ' + rest() : JSON.stringify(f) + ' error: "invalid file name"')
  const forms = names.filter((f) => /\.ya?ml$/.test(f) && f !== 'config.yml' && f !== 'config.yaml')
  for (const f of forms) out.push(entry('form', f, /^[A-Za-z0-9][A-Za-z0-9._-]*\.ya?ml$/, () =>
    regular(f) ? describe(fs.readFileSync(path.join(dir, f), 'utf8')) : 'error: "symlink or not a regular file"'))
  if (!forms.length) out.push('forms: none')
  for (const f of names.filter((f) => /\.md$/.test(f))) out.push(entry('template', f, /^[A-Za-z0-9][A-Za-z0-9._-]*\.md$/, () =>
    regular(f) ? '' : 'error: "symlink or not a regular file"').trimEnd())
  out.push('banned: ' + JSON.stringify(phrases(bannedPath)))
  console.log(out.join('\n'))
}

module.exports = { parseForm }

if (require.main === module) list(process.argv[2], process.argv[3])
