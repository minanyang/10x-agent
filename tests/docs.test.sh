#!/bin/bash
# README.md must open with a centred header (name, the plugin.json tagline, license and Claude Code badges, the
# language links) and keep its prose — outside fences and tables — to 900 words.
# README.md must document /10x:roadmap — a commands-fence line naming /10x:batch <version>, and a Skills table row.
# docs/loop.md, docs/scripts.md, docs/configuration.md and both READMEs must name `tdd` and the relock, and loop.md and
# scripts.md `--lock`.
# docs/loop.md must name the batch sandbox's `sandbox unavailable` refusal, `allowUnsandboxedCommands` and
# `--disable-sandbox`, and docs/scripts.md `sandbox unavailable`.
# docs/scripts.md's `10x-batch run` entry must name the `git common dir` a worker's Write and Edit tools are denied.
# docs/scripts.md's `10x-batch run` entry must name the `PATH entry` a worker is denied, and refused when it contains
# an allowWrite path.
# docs/scripts.md's `10x-batch run` entry must name the main checkout's `.claude/10x.json` a worker is denied.
# README.md, README.zh-TW.md, docs/configuration.md and the Unreleased changelog section must give `batch.parallel`'s
# default as 2, and docs/loop.md must say a roadmap follow-up joins the next version.
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

// gh-3 AC12 — the security requirements of /10x:roadmap: the two 10x-security subcommands, 10x-land advisory and the audit
// prompt in docs/scripts.md; the hook rules in docs/hooks.md; the /10x:roadmap row of both READMEs.
{
  const name = "docs describe list --plannable, route, advisory and the audit prompt"
  const scripts = read("docs/scripts.md"), hooks = read("docs/hooks.md")
  const missing = []
  for (const w of ["10x-security list --plannable", "10x-security route", "10x-land advisory", "audit:", "Security:"])
    if (scripts === null || !scripts.includes(w)) missing.push(`docs/scripts.md: ${w}`)
  if (hooks === null || !hooks.includes("10x-land advisory")) missing.push("docs/hooks.md: 10x-land advisory")
  for (const f of ["README.md", "README.zh-TW.md"]) {
    const text = read(f)
    const row = text === null ? undefined : text.split("\n").find((s) => s.startsWith("| `/10x:roadmap` |"))
    if (row === undefined) { missing.push(`${f}: the /10x:roadmap row`); continue }
    for (const w of ["security", "advisory", "/10x:audit"]) if (!row.includes(w)) missing.push(`${f}: the /10x:roadmap row lacks ${w}`)
  }
  missing.length ? bad(name, `missing: ${missing.join("; ")}`) : ok(name)
}

// gh-8 AC8 — batch workers in auto mode, the fallback to today's modes and the plan-session hook.
{
  const name = "docs describe auto-mode batch workers and the plan-session hook"
  const loop = read("docs/loop.md"), scripts = read("docs/scripts.md"), hooks = read("docs/hooks.md"), log = read("CHANGELOG.md")
  // The text of section `## <title>` of <text>, up to the next ## heading.
  const section = (text, title) => {
    if (text === null) return ""
    const lines = text.split("\n"), at = lines.findIndex((s) => s.trim() === `## ${title}`)
    if (at < 0) return ""
    const next = lines.findIndex((s, k) => k > at && /^##\s/.test(s))
    return lines.slice(at, next < 0 ? undefined : next).join("\n")
  }
  const missing = []
  for (const w of ["auto mode", "falls back"]) if (loop === null || !loop.includes(w)) missing.push(`docs/loop.md: ${w}`)
  if (loop !== null && loop.includes("run in `acceptEdits`")) missing.push("docs/loop.md still says workers run in `acceptEdits`")
  for (const w of ["--permission-mode auto", "-fallback"]) if (scripts === null || !scripts.includes(w)) missing.push(`docs/scripts.md: ${w}`)
  for (const w of ["## Plan boundary", "TENX_BATCH_PLAN_DIR"]) if (hooks === null || !hooks.includes(w)) missing.push(`docs/hooks.md: ${w}`)
  if (!section(hooks, "Grant").includes("10x-test")) missing.push("docs/hooks.md: 10x-test in ## Grant")
  // The release these phrases belong to: the `## 0.2.0` section.
  const released = ((log || "").split("\n").find((s) => /^##\s+0\.2\.0\b/.test(s)) || "").replace(/^##\s+/, "").trim()
  if (!section(log, released).includes("auto mode")) missing.push("CHANGELOG.md: auto mode in the 0.2.0 section")
  missing.length ? bad(name, `missing: ${missing.join("; ")}`) : ok(name)
}

// gh-7 AC16 — batch auto mode, loop, the TENX_BATCH refusal and the own-tickets rule in docs/loop.md and docs/scripts.md.
{
  const name = "docs describe batch auto mode, loop, TENX_BATCH and the own-tickets rule"
  const loop = read("docs/loop.md"), scripts = read("docs/scripts.md")
  const missing = []
  const need = (f, text, words) => { for (const w of words) if (text === null || !text.includes(w)) missing.push(`${f}: ${w}`) }
  need("docs/loop.md", loop, ["/10x:batch auto", "10x-batch loop", "TENX_BATCH", "no permission prompt"])
  need("docs/scripts.md", scripts, ["init --auto", "10x-batch loop", "TENX_BATCH", "refused inside a batch worker", "not your issue", "auto-approved", "mode"])
  if (loop !== null && !/only your own (issues|tickets)|your own (issues|tickets)/i.test(loop)) missing.push("docs/loop.md: the own-tickets rule")
  if (loop !== null && !/because/i.test(loop.split("\n").filter((s) => /your own (issues|tickets)/i.test(s)).join("\n"))) missing.push("docs/loop.md: the reason for the own-tickets rule")
  for (const [f, text] of [["docs/loop.md", loop], ["docs/scripts.md", scripts]])
    if (text !== null && text.includes("issues you trust")) missing.push(`${f}: still says "issues you trust"`)
  missing.length ? bad(name, `missing: ${missing.join("; ")}`) : ok(name)
}

// gh-11 AC6 — the TENX_BATCH refusal of 10x-land and 10x-security, and that it is a layer, not a boundary.
{
  const name = "docs name the TENX_BATCH refusal of 10x-land and 10x-security and call it a layer, not a boundary"
  const loop = read("docs/loop.md"), scripts = read("docs/scripts.md")
  const missing = []
  for (const w of ["10x: refused inside a batch worker", "10x-security: refused inside a batch worker"])
    if (scripts === null || !scripts.includes(w)) missing.push(`docs/scripts.md: ${w}`)
  for (const w of ["a layer, not a boundary", "env -u TENX_BATCH", "`gh` directly"])
    if (loop === null || !loop.includes(w)) missing.push(`docs/loop.md: ${w}`)
  if (loop !== null && loop.includes("matches the command as typed")) missing.push('docs/loop.md: still says "matches the command as typed"')
  missing.length ? bad(name, `missing: ${missing.join("; ")}`) : ok(name)
}

// gh-12 AC7 — the batch sandbox, its settings, its refusal and the state dir.
{
  const name = "docs describe the batch sandbox, its settings, its refusal and the state dir"
  const loop = read("docs/loop.md"), scripts = read("docs/scripts.md")
  const missing = []
  for (const w of ["sandbox unavailable", "allowUnsandboxedCommands", "--disable-sandbox"])
    if (loop === null || !loop.includes(w)) missing.push(`docs/loop.md: ${w}`)
  if (scripts === null || !scripts.includes("sandbox unavailable")) missing.push("docs/scripts.md: sandbox unavailable")
  missing.length ? bad(name, `missing: ${missing.join("; ")}`) : ok(name)
}

// gh-19 AC7 — the `10x-batch run` entry of docs/scripts.md names the git common dir among the paths a worker's Write
// and Edit tools are denied.
{
  const name = "docs/scripts.md names the git common dir and the other paths a worker's Write is denied"
  const scripts = read("docs/scripts.md")
  const entry = (scripts || "").split("\n").find((s) => s.startsWith("- `10x-batch run "))
  !entry ? bad(name, "no `10x-batch run` entry in docs/scripts.md")
    : entry.includes("git common dir") ? ok(name) : bad(name, "the `10x-batch run` entry does not name the git common dir")
}

// gh-24 AC8 — the `10x-batch run` entry of docs/scripts.md names `denyWrite`.
{
  const name = "docs/scripts.md names denyWrite in the 10x-batch run entry"
  const scripts = read("docs/scripts.md")
  const entry = (scripts || "").split("\n").find((s) => s.startsWith("- `10x-batch run "))
  !entry ? bad(name, "no `10x-batch run` entry in docs/scripts.md")
    : entry.includes("denyWrite") ? ok(name) : bad(name, "the `10x-batch run` entry does not name denyWrite")
}

// gh-27 AC9 — the `10x-batch run` entry of docs/scripts.md names the PATH entries a worker is denied and refused.
{
  const name = "docs/scripts.md names PATH entry in the 10x-batch run entry"
  const scripts = read("docs/scripts.md")
  const entry = (scripts || "").split("\n").find((s) => s.startsWith("- `10x-batch run "))
  !entry ? bad(name, "no `10x-batch run` entry in docs/scripts.md")
    : entry.includes("PATH entry") ? ok(name) : bad(name, "the `10x-batch run` entry does not name PATH entry")
}

// worker-10x-json AC3 — the `10x-batch run` entry of docs/scripts.md names the main checkout's project config.
{
  const name = "docs/scripts.md names the project config in the 10x-batch run entry"
  const scripts = read("docs/scripts.md")
  const entry = (scripts || "").split("\n").find((s) => s.startsWith("- `10x-batch run "))
  !entry ? bad(name, "no `10x-batch run` entry in docs/scripts.md")
    : entry.includes(".claude/10x.json") ? ok(name) : bad(name, "the `10x-batch run` entry does not name .claude/10x.json")
}

// gh-24 AC5, AC8 — docs/loop.md's `### The batch sandbox` section names `denyWrite`.
{
  const name = "docs/loop.md names denyWrite in the batch sandbox section"
  const lines = (read("docs/loop.md") || "").split("\n")
  const at = lines.findIndex((s) => s.trim() === "### The batch sandbox")
  const next = lines.findIndex((s, k) => k > at && /^#{1,3}\s/.test(s))
  const section = at < 0 ? "" : lines.slice(at, next < 0 ? undefined : next).join("\n")
  at < 0 ? bad(name, "no `### The batch sandbox` heading in docs/loop.md")
    : section.includes("denyWrite") ? ok(name) : bad(name, "the batch sandbox section does not name denyWrite")
}

// gh-7 AC22 — the changelog and both READMEs name /10x:batch auto; neither README keeps the trust sentence.
{
  const name = "README and CHANGELOG mention batch auto mode"
  const log = read("CHANGELOG.md")
  const lines = log === null ? [] : log.split("\n")
  // The release these phrases belong to: the `## 0.2.0` section.
  const at = lines.findIndex((s) => /^##\s+0\.2\.0\b/.test(s))
  const next = lines.findIndex((s, k) => k > at && /^##\s/.test(s))
  const newest = at < 0 ? "" : lines.slice(at, next < 0 ? undefined : next).join("\n")
  const missing = []
  if (!newest.includes("/10x:batch auto")) missing.push("CHANGELOG.md: /10x:batch auto in the 0.2.0 section")
  for (const [f, text, trust] of [["README.md", readme, "issues you trust"], ["README.zh-TW.md", zh, "只批次處理你信任的 issue"]]) {
    if (text === null) { missing.push(`${f}: missing`); continue }
    if (!text.includes("/10x:batch auto")) missing.push(`${f}: /10x:batch auto`)
    if (text.includes(trust)) missing.push(`${f}: still says "${trust}"`)
  }
  missing.length ? bad(name, `missing: ${missing.join("; ")}`) : ok(name)
}

// gh-35 AC8 — the hand-check state, the board section, `10x-batch checked` and the agent-run hand check.
{
  const name = "docs name the hand-check state, 10x-batch checked and the agent-run hand check"
  const missing = []
  const need = (f, words) => {
    const text = read(f)
    for (const w of words) if (text === null || !text.includes(w)) missing.push(`${f}: ${w}`)
  }
  need("docs/loop.md", ["hand-check:", "## Hand checks pending", "10x-batch checked", "### Hand checks", "deep link", "screenshot"])
  need("docs/scripts.md", ["## Hand checks pending", "10x-batch checked"])
  need("docs/hooks.md", ["hand-check", "10x-batch checked"])
  need("CHANGELOG.md", ["10x-batch checked"])
  const log = read("CHANGELOG.md")
  const first = ((log || "").split("\n").find((s) => /^##\s/.test(s)) || "").trim()
  if (first !== "## Unreleased") missing.push(`CHANGELOG.md: newest section is "${first}", not "## Unreleased"`)
  missing.length ? bad(name, `missing: ${missing.join("; ")}`) : ok(name)
}

// gh-36 AC11 — small tickets and security.paths in the docs and the Unreleased changelog section.
{
  const name = "docs and CHANGELOG describe Size: small and security.paths"
  const missing = []
  const need = (f, text, words) => { for (const w of words) if (text === null || !text.includes(w)) missing.push(`${f}: ${w}`) }
  need("docs/loop.md", read("docs/loop.md"), ["Size: small", "security.paths"])
  need("docs/scripts.md", read("docs/scripts.md"), ["Size: small", "size: small", "security.paths"])
  need("docs/configuration.md", read("docs/configuration.md"), ["security.paths"])
  need("docs/hooks.md", read("docs/hooks.md"), ["Size: small", "ticket.md"])
  const lines = (read("CHANGELOG.md") || "").split("\n")
  const at = lines.findIndex((s) => s.trim() === "## Unreleased")
  const next = lines.findIndex((s, k) => k > at && /^##\s/.test(s))
  const unreleased = at < 0 ? "" : lines.slice(at, next < 0 ? undefined : next).join("\n")
  need("CHANGELOG.md ## Unreleased", unreleased, ["Size: small", "security.paths"])
  missing.length ? bad(name, `missing: ${missing.join("; ")}`) : ok(name)
}

// gh-39 AC7 — the denied count on the board and the runs that wait instead of failing, in the docs and the changelog.
{
  const name = "docs describe the denied count and the waiting cases"
  const missing = []
  const need = (f, text, words) => { for (const w of words) if (text === null || !text.includes(w)) missing.push(`${f}: ${w}`) }
  need("docs/loop.md", read("docs/loop.md"), ["denied (see", "instead of `failed`"])
  need("docs/scripts.md", read("docs/scripts.md"), ["denied (see", "instead of `failed`"])
  const lines = (read("CHANGELOG.md") || "").split("\n")
  const at = lines.findIndex((s) => s.trim() === "## Unreleased")
  const next = lines.findIndex((s, k) => k > at && /^##\s/.test(s))
  need("CHANGELOG.md ## Unreleased", at < 0 ? "" : lines.slice(at, next < 0 ? undefined : next).join("\n"), ["denied (see"])
  missing.length ? bad(name, `missing: ${missing.join("; ")}`) : ok(name)
}

// gh-40 AC5 — decisions taken on a recommendation in docs/loop.md and the Unreleased changelog section.
{
  const name = "docs describe decisions taken on a recommendation"
  const missing = []
  const loop = read("docs/loop.md")
  for (const w of ["Decided:", "decided:"]) if (loop === null || !loop.includes(w)) missing.push(`docs/loop.md: ${w}`)
  if (loop !== null && loop.includes("is asked, not left")) missing.push(`docs/loop.md: still says "is asked, not left"`)
  const lines = (read("CHANGELOG.md") || "").split("\n")
  const at = lines.findIndex((s) => s.trim() === "## Unreleased")
  const next = lines.findIndex((s, k) => k > at && /^##\s/.test(s))
  if (!(at < 0 ? "" : lines.slice(at, next < 0 ? undefined : next).join("\n")).includes("Decided:")) missing.push("CHANGELOG.md ## Unreleased: Decided:")
  missing.length ? bad(name, `missing: ${missing.join("; ")}`) : ok(name)
}

// gh-41 AC3 — the batch.parallel default of 2 in the docs and the Unreleased changelog section; the roadmap follow-up in
// docs/loop.md.
{
  const name = "docs and CHANGELOG give the batch.parallel default as 2"
  const missing = []
  const need = (f, text, words) => { for (const w of words) if (text === null || !text.includes(w)) missing.push(`${f}: ${w}`) }
  need("README.md", read("README.md"), ["(default `2`)"])
  need("README.zh-TW.md", read("README.zh-TW.md"), ["（預設 `2`）"])
  need("docs/configuration.md", read("docs/configuration.md"), ["| `batch.parallel` | `2`."])
  need("docs/loop.md", read("docs/loop.md"), ["follow-up"])
  const lines = (read("CHANGELOG.md") || "").split("\n")
  const at = lines.findIndex((s) => /^##\s/.test(s))
  const next = lines.findIndex((s, k) => k > at && /^##\s/.test(s))
  if (at < 0 || lines[at].trim() !== "## Unreleased") missing.push("CHANGELOG.md: the first ## heading is not ## Unreleased")
  need("CHANGELOG.md ## Unreleased", at < 0 ? "" : lines.slice(at, next < 0 ? undefined : next).join("\n"), ["`batch.parallel`", "defaults to `2`"])
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

// gh-38 AC6 — 10x-batch replan in docs/scripts.md, docs/loop.md and the changelog's first section.
{
  const name = "docs describe 10x-batch replan"
  const missing = []
  const scripts = read("docs/scripts.md")
  const entry = (scripts || "").split("\n").find((s) => s.startsWith("- `10x-batch replan <id>`"))
  if (!entry) missing.push("docs/scripts.md: no `- `10x-batch replan <id>`` entry")
  else for (const w of ["not failed", "Status: draft", "auto-approved", "reply.md"]) if (!entry.includes(w)) missing.push(`docs/scripts.md entry: ${w}`)
  const refused = (scripts || "").split("\n").find((s) => s.includes("10x-batch: refused inside a batch worker"))
  if (!refused || !refused.includes("`replan`")) missing.push("docs/scripts.md: `replan` in the paragraph naming `refused inside a batch worker`")
  if (!(read("docs/loop.md") || "").includes("10x-batch replan")) missing.push("docs/loop.md: 10x-batch replan")
  const lines = (read("CHANGELOG.md") || "").split("\n")
  const at = lines.findIndex((s) => /^##\s/.test(s))
  const next = lines.findIndex((s, k) => k > at && /^##\s/.test(s))
  const first = at < 0 ? "" : lines.slice(at, next < 0 ? undefined : next).join("\n")
  if (!first.includes("10x-batch replan")) missing.push("CHANGELOG.md: 10x-batch replan under the first ## heading")
  missing.length ? bad(name, `missing: ${missing.join("; ")}`) : ok(name)
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
