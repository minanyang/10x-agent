#!/bin/bash
# README.md must open with a centred header (name, the plugin.json tagline, license and Claude Code badges, the
# language links) and keep its prose — outside fences and tables — to 900 words.
# README.md must document /10x:roadmap — a commands-fence line naming /10x:batch <version>, and a Skills table row.
# docs/loop.md, docs/scripts.md, docs/configuration.md and both READMEs must name `tdd` and the relock, and loop.md and
# scripts.md `--lock`.
# README.zh-TW.md must have the same ## / ### headings, level by level, and the two READMEs must link to each other.
# Every relative link in README.md, README.zh-TW.md and docs/*.md must resolve to a file, and an anchor to a heading
# of that file as GitHub slugs it.
set -uo pipefail
exec node - "$(cd "$(dirname "$0")/.." && pwd)" <<'JS'
const fs = require("fs")
const path = require("path")
const root = process.argv[2]
let fail = 0
const ok = (m) => console.log(`ok    ${m}`)
const bad = (m, why) => { console.log(`FAIL  ${m}${why ? `\n      ${why}` : ""}`); fail = 1 }
const read = (rel) => { try { return fs.readFileSync(path.join(root, rel), "utf8") } catch { return null } }

// The lines of a Markdown text with fenced blocks (fence lines included) replaced by null.
function unfenced(text) {
  let fence = null
  return text.split("\n").map((s) => {
    const f = s.match(/^\s*(`{3,}|~{3,})/)
    if (fence) {
      if (f && f[1][0] === fence[0] && f[1].length >= fence.length && /^\s*[`~]+\s*$/.test(s)) fence = null
      return null
    }
    if (f) { fence = f[1]; return null }
    return s
  })
}
const headings = (text) => unfenced(text).map((s) => s !== null && s.match(/^(#{1,6})\s+(.*?)\s*#*\s*$/)).filter(Boolean)
  .map((m) => ({ level: m[1].length, text: m[2] }))

// GitHub's heading anchors: link targets and [ ] ` dropped, lowercased, anything but letters, marks, digits,
// space, - and _ removed, spaces to -, repeats suffixed -1, -2, ...
function slugs(text) {
  const seen = new Map(), out = new Set()
  for (const h of headings(text)) {
    const base = h.text.replace(/\]\([^)]*\)/g, "").replace(/[[\]`]/g, "").toLowerCase()
      .replace(/[^\p{L}\p{M}\p{N} _-]/gu, "").replace(/ /g, "-")
    const n = seen.get(base) || 0
    seen.set(base, n + 1)
    out.add(n ? `${base}-${n}` : base)
  }
  return out
}

const readme = read("README.md")
const zh = read("README.zh-TW.md")
if (readme === null) { bad("README.md exists"); process.exit(1) }

// AC1 — header.
{
  const name = "README.md opens with a centred header: name, tagline, license and Claude Code badges, language links"
  const lines = readme.split("\n")
  const first = lines.findIndex((s) => s.trim() !== "")
  const end = lines.findIndex((s) => s.trim() === "</div>")
  const head = end > first ? lines.slice(first, end) : []
  const tagline = JSON.parse(read(".claude-plugin/plugin.json")).description
  const missing = [
    [lines[first] === '<div align="center">', 'first line <div align="center">'],
    [head.includes("# 10x Agent"), "# 10x Agent"],
    [head.includes(tagline), `tagline "${tagline}"`],
    [head.some((s) => s.includes("img.shields.io/badge/license-MIT")), "license badge"],
    [head.some((s) => s.includes("img.shields.io/badge/Claude_Code-plugin")), "Claude Code plugin badge"],
    [head.includes("**English** · [繁體中文](README.zh-TW.md)"), "language links"],
  ].filter(([c]) => !c).map(([, w]) => w)
  missing.length ? bad(name, `missing: ${missing.join("; ")}`) : ok(name)
}

// AC1 — prose word count: fences, table rows and tag-only lines dropped; outside inline code, HTML tags, link
// targets and [ ] ! markup removed; tokens holding a letter or digit counted.
{
  const name = "README.md prose is at most 900 words"
  let words = 0
  for (const s of unfenced(readme)) {
    if (s === null || /^\s*\|/.test(s) || /^\s*<\/?[a-zA-Z][^>]*>\s*$/.test(s)) continue
    const prose = s.split(/(`+[^`]*?`+)/).map((part, k) => k % 2 ? part.replace(/`/g, "")
      : part.replace(/<\/?[a-zA-Z][^>]*>/g, " ").replace(/\]\([^)]*\)/g, " ").replace(/!?\[|\]/g, " ")).join("")
    words += (prose.match(/\S+/g) || []).filter((w) => /[\p{L}\p{N}]/u.test(w)).length
  }
  words <= 900 ? ok(`${name} (${words})`) : bad(name, `${words} words`)
}

// gh-77 AC8 — the roadmap skill and how it feeds a batch: a commands-fence line and a Skills table row.
{
  const name = "README.md documents /10x:roadmap and /10x:batch <version>"
  const lines = readme.split("\n"), fenced = unfenced(readme)
  const missing = [
    [lines.some((s, k) => fenced[k] === null && s.startsWith("/10x:roadmap ") && s.includes("/10x:batch <version>")),
      "a commands-fence line for /10x:roadmap naming /10x:batch <version>"],
    [fenced.some((s) => s !== null && s.startsWith("| `/10x:roadmap` |")), "a Skills table row for /10x:roadmap"],
  ].filter(([c]) => !c).map(([, w]) => w)
  missing.length ? bad(name, `missing: ${missing.join("; ")}`) : ok(name)
}

// gh-87 AC10 — the tests half, the lock, the relock arbiter and `tdd: false`.
{
  const name = "docs describe the tests half, the lock, the relock arbiter and tdd: false"
  const missing = []
  for (const f of ["docs/loop.md", "docs/scripts.md", "docs/configuration.md", "README.md", "README.zh-TW.md"]) {
    const text = read(f)
    if (text === null) { missing.push(`${f}: missing`); continue }
    const want = ["tdd", "relock", ...(f === "docs/loop.md" || f === "docs/scripts.md" ? ["--lock"] : [])]
    for (const w of want) if (!text.includes(w)) missing.push(`${f}: ${w}`)
  }
  missing.length ? bad(name, `missing: ${missing.join("; ")}`) : ok(name)
}

// gh-1 AC12 — 10x-security, the security.md format and fingerprint, and security.blockClose.
{
  const name = "docs describe 10x-security, security.md and security.blockClose"
  const scripts = read("docs/scripts.md"), config = read("docs/configuration.md")
  const missing = []
  for (const w of ["10x-security", "security.md", "sha256:"]) if (scripts === null || !scripts.includes(w)) missing.push(`docs/scripts.md: ${w}`)
  if (config === null || !config.includes("security.blockClose")) missing.push("docs/configuration.md: security.blockClose")
  missing.length ? bad(name, `missing: ${missing.join("; ")}`) : ok(name)
}

// gh-2 AC14 — /10x:audit in the README, and the three new 10x-security subcommands and rules.json in docs/scripts.md.
{
  const name = "README.md documents /10x:audit"
  const lines = readme.split("\n"), fenced = unfenced(readme)
  const missing = [
    [lines.some((s, k) => fenced[k] === null && s.startsWith("/10x:audit ")), "a commands-fence line for /10x:audit"],
    [fenced.some((s) => s !== null && s.startsWith("| `/10x:audit` |")), "a Skills table row for /10x:audit"],
  ].filter(([c]) => !c).map(([, w]) => w)
  missing.length ? bad(name, `missing: ${missing.join("; ")}`) : ok(name)
}
{
  const name = "docs/scripts.md documents 10x-security prepare, import, ticket and rules.json"
  const scripts = read("docs/scripts.md")
  const missing = ["10x-security prepare", "10x-security import", "10x-security ticket", "rules.json"]
    .filter((w) => scripts === null || !scripts.includes(w)).map((w) => `docs/scripts.md: ${w}`)
  missing.length ? bad(name, `missing: ${missing.join("; ")}`) : ok(name)
}

// AC4 — heading parity and cross-links.
{
  const name = "README.zh-TW.md has the same ## and ### headings, level by level, as README.md"
  const levels = (t) => headings(t).filter((h) => h.level === 2 || h.level === 3).map((h) => h.level).join(",")
  if (zh === null) bad(name, "README.zh-TW.md is missing")
  else levels(readme) === levels(zh) ? ok(name) : bad(name, `README.md ${levels(readme)}; README.zh-TW.md ${levels(zh)}`)
}
{
  const name = "README.md and README.zh-TW.md link to each other"
  const en = readme.split("\n").includes("**English** · [繁體中文](README.zh-TW.md)")
  const back = zh !== null && zh.split("\n").includes("[English](README.md) · **繁體中文**")
  en && back ? ok(name) : bad(name, `${en ? "" : "README.md lacks its link; "}${back ? "" : "README.zh-TW.md lacks its link"}`)
}

// AC5 — relative links.
{
  const name = "every relative link in README.md, README.zh-TW.md and docs/*.md resolves"
  let docs = []
  try { docs = fs.readdirSync(path.join(root, "docs")).filter((f) => f.endsWith(".md")).map((f) => `docs/${f}`) } catch {}
  const files = ["README.md", "README.zh-TW.md", ...docs]
  const broken = []
  for (const file of files) {
    const text = read(file)
    if (text === null) { broken.push(`${file}: missing`); continue }
    unfenced(text).forEach((s, k) => {
      if (s === null) return
      const line = s.replace(/(`+)[^`]*?\1/g, " ")
      const targets = []
      for (const m of line.matchAll(/\]\(\s*(<[^>]*>|[^\s)]*)(?:\s+"[^"]*")?\s*\)/g)) targets.push(m[1])
      for (const m of line.matchAll(/^\s*\[[^\]]+\]:\s*(<[^>]*>|\S+)/g)) targets.push(m[1])
      for (const m of line.matchAll(/\b(?:href|src)="([^"]*)"/g)) targets.push(m[1])
      for (let t of targets) {
        t = t.replace(/^<|>$/g, "")
        if (/^[a-z][a-z0-9+.-]*:/i.test(t) || t.startsWith("//")) continue
        const [rel, anchor] = t.split("#")
        const target = rel.split("?")[0] ? path.join(path.dirname(path.join(root, file)), rel.split("?")[0]) : path.join(root, file)
        const where = `${file}:${k + 1} ${t}`
        if (!fs.existsSync(target)) { broken.push(`${where}: no such file`); continue }
        if (anchor === undefined) continue
        if (fs.statSync(target).isDirectory()) { broken.push(`${where}: anchor into a directory`); continue }
        let a
        try { a = decodeURIComponent(anchor) } catch { a = anchor }
        if (!slugs(fs.readFileSync(target, "utf8")).has(a)) broken.push(`${where}: no heading #${a}`)
      }
    })
  }
  broken.length ? bad(name, broken.join("\n      ")) : ok(name)
}

process.exit(fail)
JS
