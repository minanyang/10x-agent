#!/bin/bash
# The skills' `allowed-tools` must cover every command their fenced bash blocks run and every command their prose names in inline code (unless Claude Code allows it as read-only, it is left to the user, or it is named but never run), and must not
# grant anything that can destroy work, force-push, bypass branch protection or run arbitrary code.
# Creating an issue and posting a comment are public writes: never granted, so they always prompt.
# open, work and roadmap must load the shared references/grill.md (beside the skills directory) through a granted `10x-grill`.
# The grill must always ask a ticket's own open questions, and work must post their answers through comment.md.
# The skills and review agents that report on work must carry the verify-first rule.
# work and close must resolve .10x/<id>/ paths against the printed `ticket dir:` and take the base from `base:`.
# work's Step 0 must map a typed gh-<n> to its id and read an approved plan before any ticket text is fetched; close must
# name the valid tickets values when check refuses one.
# work must grant 10x-test and run tests only through it, editing only with Edit and Write.
# work must lock the tests half before the implementation half, and send a relock to a fresh code-reviewer.
# open, work, close, batch and roadmap must each have a `## Replies` section.
# SKILLS_DIR overrides the skills directory (used to show the test red against another tree).
set -uo pipefail
SKILLS_DIR="${SKILLS_DIR:-$(cd "$(dirname "$0")/.." && pwd)/skills}"
exec node - "$SKILLS_DIR" <<'JS'
const fs = require("fs")
const dir = process.argv[2]
let fail = 0
const ok = (m) => console.log(`ok    ${m}`)
const bad = (m) => { console.log(`FAIL  ${m}`); fail = 1 }

// Commands left to the user's own permissions, per skill (prefix of the placeholder-normalised line).
const userOwn = {
  close: [],
  work: ["git -C X add ", "git -C X commit ", "10x-land comment ", "10x-security set ", "10x-security remove "],
  open: ["10x-land issue "],
  batch: ["10x-land comment ", "10x-batch approve ", "10x-batch accept-green ", "10x-batch checked "],
  roadmap: ["10x-land issue ", "10x-land advisory "],
  audit: ["10x-security set ", "10x-security ticket "],
}
const ownedBy = (skill, line) => userOwn[skill].some((p) => line === p.trimEnd() || line.startsWith(p))
// Exact prose commands Claude Code runs without a grant (checked with `claude -p` in default mode). Granting
// `git log *` or `git diff *` instead would also allow `--output=<file>`.
const readOnly = ["git log --name-only HEAD..origin/X", "git log -n 5 --oneline", "git worktree list",
  "git diff --name-only X...X", "git diff origin/X...X -- .claude/agent-memory"]
// Commands a skill's prose names for the user or as an explanation, never runs itself.
const notRun = {
  close: ["gh auth login", "glab auth login", "git rebase --skip", "git merge --ff-only", "git -C X …"],
  work: ["git -C X …"],
  open: ["gh auth login"],
  batch: [],
  roadmap: ["gh auth login"],
  audit: [],
}
const forbidden = ["git push", "git rebase", "git merge", "git log", "gh pr merge", "glab mr merge", "gh api",
  "gh issue create", "gh pr create", "gh pr edit", "glab mr create", "glab mr update"]
const bareGrants = ["10x-worktree *", "10x-land *", "git *"]
// Commands that must always ask: the public writes, and a batch's plan approval, which text a worker wrote must
// never be able to give.
const publicWrites = ["10x-land issue", "10x-land comment", "10x-batch approve", "10x-batch accept-green", "10x-batch checked", "10x-land advisory"]

const norm = (s) => s.replace(/<[^>]*>/g, "X")

for (const skill of Object.keys(userOwn)) {
  if (!fs.existsSync(`${dir}/${skill}/SKILL.md`)) { bad(`${skill}: skills/${skill}/SKILL.md is missing`); continue }
  const text = fs.readFileSync(`${dir}/${skill}/SKILL.md`, "utf8")
  const fm = /^---\n([\s\S]*?)\n---/.exec(text)[1]
  const m = /^allowed-tools:\n((?:  - .*\n?)+)/m.exec(fm + "\n")
  const entries = m ? m[1].split("\n").filter(Boolean).map((l) => l.replace(/^  - /, "").trim()) : []
  entries.length ? ok(`${skill}: allowed-tools declared`) : bad(`${skill}: no allowed-tools list`)

  const bodies = []
  for (const e of entries) {
    const b = /^Bash\((.*)\)$/.exec(e)
    if (!b) { bad(`${skill}: entry ${e} is not Bash(...)`); continue }
    const body = b[1]
    const toks = body.split(" ")
    if (toks.slice(0, -1).some((t) => t.includes("*")) || (toks.at(-1).includes("*") && toks.at(-1) !== "*"))
      bad(`${skill}: ${e} has a * that is not the last token`)
    if (bareGrants.includes(body) || forbidden.some((f) => body === f || body.startsWith(f + " "))) bad(`${skill}: ${e} is a forbidden grant`)
    // Only the exact `git fetch`: with arguments, `--upload-pack=<cmd>` runs arbitrary code.
    if (/^git( -[cC] \S+)* fetch /.test(body)) bad(`${skill}: ${e} grants git fetch with arguments`)
    bodies.push(body)
  }
  if (entries.length) ok(`${skill}: entries are well-formed and safe`)
  const covered = (line) => bodies.some((b) => b.endsWith(" *") ? line === b.slice(0, -2) || line.startsWith(b.slice(0, -1)) : line === b)

  const lines = []
  for (const blk of text.matchAll(/```bash\n([\s\S]*?)```/g))
    lines.push(...blk[1].replace(/\\\n\s*/g, " ").split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#")))

  for (const raw of lines) {
    const line = norm(raw)
    if (/&&|\|\||;|\|/.test(line)) { bad(`${skill}: chained command: ${raw}`); continue }
    if (covered(line)) ok(`${skill}: covered: ${raw}`)
    else if (ownedBy(skill, line)) ok(`${skill}: left to the user: ${raw}`)
    else bad(`${skill}: not covered by allowed-tools: ${raw}`)
  }

  // Prose: fenced blocks of every kind are removed first, then each inline-code span that is a command.
  const prose = []
  let fence = 0
  for (const l of text.split("\n")) {
    const f = /^\s*(`{3,})/.exec(l)
    if (!fence && f) fence = f[1].length
    else if (fence && f && f[1].length >= fence && /^\s*`+\s*$/.test(l)) fence = 0
    else if (!fence) prose.push(l)
  }
  const spans = new Set()
  const p = prose.join("\n")
  for (let i = 0; i < p.length;) {
    const run = /^`+/.exec(p.slice(i))
    if (!run) { i++; continue }
    const n = run[0].length
    const close = new RegExp(`(?<!\`)\`{${n}}(?!\`)`, "g")
    close.lastIndex = i + n
    const c = close.exec(p)
    if (!c) { i += n; continue }
    spans.add(p.slice(i + n, c.index).replace(/\n/g, " ").trim())
    i = c.index + n
  }
  for (const raw of spans) {
    const line = norm(raw)
    if (!/^(git|gh|glab|10x-[a-z-]+) /.test(line)) continue
    if (/&&|\|\||;|\|/.test(line)) bad(`${skill}: chained command in prose: ${raw}`)
    else if (covered(line)) ok(`${skill}: covered (prose): ${raw}`)
    else if (ownedBy(skill, line)) ok(`${skill}: left to the user: ${raw}`)
    else if (readOnly.includes(line)) ok(`${skill}: left to Claude Code's read-only rules: ${raw}`)
    else if (notRun[skill].includes(line)) ok(`${skill}: named, not run: ${raw}`)
    else bad(`${skill}: prose command not covered by allowed-tools: ${raw}`)
  }
}

// No skill may grant one of them, by any pattern that covers it: `*`, `10x-land *`, `10x-land i*`,
// the legacy `10x-land issue:*`, or the command itself.
for (const skill of fs.readdirSync(dir).filter((d) => fs.existsSync(`${dir}/${d}/SKILL.md`))) {
  const fm = (/^---\n([\s\S]*?)\n---/.exec(fs.readFileSync(`${dir}/${skill}/SKILL.md`, "utf8")) || ["", ""])[1]
  const covers = (body, w) => {
    body = body.replace(/:\*$/, " *")
    return body.endsWith("*") ? (w + " ").startsWith(body.slice(0, -1)) : body === w || body.startsWith(w + " ")
  }
  const hits = [...fm.matchAll(/Bash\(([^)]*)\)/g)].filter((b) => publicWrites.some((w) => covers(b[1].trim(), w)))
  // A bare `Bash` (or `Bash()`) grants every command.
  const tools = (/^allowed-tools:(.*(?:\n  - .*)*)/m.exec(fm) || ["", ""])[1]
  hits.push(...[...tools.matchAll(/(?:^|[\s,-])(Bash(?:\(\s*\))?)(?=[\s,]|$)/g)].map((b) => [b[1]]))
  hits.length ? hits.forEach((b) => bad(`${skill}: ${b[0]} grants ${b[1] ?? b[0]}, which must always prompt`))
    : ok(`${skill}: grants no public write or batch approval`)
}

// open, work and roadmap load the one shared grill rather than each carrying a copy. A Read of it would prompt (the
// plugin root is outside the workspace and a Read rule takes only an absolute path), so they run the granted 10x-grill.
const grill = `${dir}/../references/grill.md`
fs.existsSync(grill) ? ok("references/grill.md exists") : bad("references/grill.md is missing")
for (const skill of ["open", "work", "roadmap"]) {
  const text = fs.readFileSync(`${dir}/${skill}/SKILL.md`, "utf8")
  text.includes("run `10x-grill`") && /^  - Bash\(10x-grill\)$/m.test(text)
    ? ok(`${skill}: loads the grill through a granted 10x-grill`) : bad(`${skill}: does not load the grill through a granted 10x-grill`)
}

// open reads the issue types through its granted script: Claude Code refuses the raw GraphQL query for its braces.
{
  const text = fs.readFileSync(`${dir}/open/SKILL.md`, "utf8")
  const fm = /^---\n([\s\S]*?)\n---/.exec(text)[1]
  const step2 = (/^## Step 2\b[\s\S]*?(?=^## )/m.exec(text) || [""])[0]
  const runs = [...step2.matchAll(/```bash\n([\s\S]*?)```/g)].some((b) => b[1].split("\n").some((l) => l.trim() === "10x-ticket issue-types"))
  fm.split("\n").some((l) => l.trim() === "- Bash(10x-ticket issue-types)") && runs
    ? ok("open: looks up issue types through a granted 10x-ticket issue-types")
    : bad("open: does not look up issue types through a granted 10x-ticket issue-types")
}

// open runs 10x-worktree init before anything else: its tickets: line decides whether origin and gh are checked at
// all, and its listing — not reading the forms or the banned file itself — is what the draft is built from.
{
  const text = fs.readFileSync(`${dir}/open/SKILL.md`, "utf8")
  // Up to the next step: Step 3's draft layout has `## ` headings of its own.
  const step = (n) => (new RegExp(`^## Step ${n}\\b[\\s\\S]*?(?=^## Step )`, "m").exec(text) || [""])[0]
  const blocks = (s) => [...s.matchAll(/```bash\n([\s\S]*?)```/g)].map((b) => b[1].split("\n").map((l) => l.trim()))
  const s1 = text.search(/^## Step 1\b/m)
  const pre = s1 === -1 ? "" : text.slice(0, s1), steps = s1 === -1 ? text : text.slice(s1)
  const initAt = blocks(pre).findIndex((b) => b.includes("10x-worktree init"))
  const originAt = blocks(pre).findIndex((b) => b.includes("git remote get-url origin"))
  const s2 = step(2), s3 = step(3)
  initAt !== -1 && originAt > initAt && !blocks(steps).some((b) => b.includes("10x-worktree init")) &&
    pre.includes("`tickets: github`") && pre.includes("`tickets: files`") &&
    ["`form:`", "`drafts:`", "`banned:`"].every((l) => (s2 + s3).includes(l)) &&
    s3.includes("`<drafts>/<short-slug>.md`") && !text.includes("Read it whole") && !text.includes("`references/banned-phrases.txt`")
    ? ok("open: reads the tickets mode from 10x-worktree init before checking origin")
    : bad("open: reads the tickets mode from 10x-worktree init before checking origin")
}

const rule = "Never reply that something is unverified, unchecked or not yet confirmed: check it first. " +
  "Only when a check is impossible, say so, naming what was tried and why it cannot be checked."
for (const f of ["skills/open/SKILL.md", "skills/work/SKILL.md", "skills/close/SKILL.md", "skills/batch/SKILL.md", "skills/roadmap/SKILL.md", "skills/audit/SKILL.md", "skills/code-review/SKILL.md",
  "skills/code-review-branch/SKILL.md", "agents/code-reviewer.md", "agents/security-reviewer.md"]) {
  const file = `${dir}/../${f}`
  fs.existsSync(file) && fs.readFileSync(file, "utf8").includes(rule)
    ? ok(`${f}: carries the verify-first rule`) : bad(`${f}: lost the verify-first rule`)
}

// work's cold read is driven by plan-check's line and saved, and a draft is checked before it is shown.
{
  const text = fs.readFileSync(`${dir}/work/SKILL.md`, "utf8")
  const step = (n) => (new RegExp(`^## Step ${n}\\b[\\s\\S]*?(?=^## Step )`, "m").exec(text) || [""])[0]
  step(1).includes("cold read required") && step(1).includes("`.10x/<id>/cold-read.md`")
    ? ok("work: acts on plan-check's cold read line") : bad("work: does not act on plan-check's cold read line")
  const draft = step(0).slice(step(0).indexOf("exists as a draft"))
  draft.indexOf("`10x-plan-check <id>`") !== -1 && draft.indexOf("`10x-plan-check <id>`") < draft.indexOf("show the draft once")
    ? ok("work: checks a draft plan before showing it") : bad("work: does not check a draft plan before showing it")
}

// A question the ticket itself asks is never settled silently: the grill always asks it, an accepted recommendation
// counts as its answer, and work posts that answer to the issue through comment.md.
{
  const text = fs.readFileSync(grill, "utf8")
  text.includes("An open question the ticket itself states — its own words ask it — is always asked, whatever the ticket's size.")
    ? ok("grill: always asks the ticket's own open questions") : bad("grill: does not always ask the ticket's own open questions")
  text.includes("Accepting the recommendations (\"go with your recommendations\") answers every question asked in that round")
    ? ok("grill: an accepted recommendation is an answer") : bad("grill: an accepted recommendation is not an answer")
  const step1 = (/^## Step 1\b[\s\S]*?(?=^## Step )/m.exec(fs.readFileSync(`${dir}/work/SKILL.md`, "utf8")) || [""])[0]
  step1.includes("`.10x/<id>/comment.md` — every open question the ticket itself states among them, whether the user answered it or accepted the recommendation")
    ? ok("work: posts the answers to the ticket's own questions through comment.md")
    : bad("work: does not post the answers to the ticket's own questions through comment.md")
}

// close takes its mode from check's mode: line, never from reading the config itself.
{
  const text = fs.readFileSync(`${dir}/close/SKILL.md`, "utf8")
  const step0 = (/^## Step 0\b[\s\S]*?(?=^## Step )/m.exec(text) || [""])[0]
  step0.includes("`mode: <close>`") && step0.includes("never read `.claude/10x.json`") &&
    !text.includes("comes from `.claude/10x.json`")
    ? ok("close: takes the mode from check's mode: line") : bad("close: does not take the mode from check's mode: line")
}

// close fills the template check names, and answers pr's refusal by adding the missing sections.
{
  const text = fs.readFileSync(`${dir}/close/SKILL.md`, "utf8")
  const step0 = (/^## Step 0\b[\s\S]*?(?=^## Step )/m.exec(text) || [""])[0]
  const step3 = (/^## Step 3\b[\s\S]*?(?=^## Step )/m.exec(text) || [""])[0]
  step0.includes("`pr template: <path>`") && step3.includes("`pr template: <path>`") &&
    step3.includes("with the Read tool") && step3.includes("add them to `pr-body.md`")
    ? ok("close: fills the template check names and adds the sections pr names")
    : bad("close: does not fill the template check names or add the sections pr names")
}

// .10x/<id>/ paths resolve against the printed ticket dir, never the worktree, and the base comes from base:.
{
  const text = fs.readFileSync(`${dir}/work/SKILL.md`, "utf8")
  const step0 = (/^## Step 0\b[\s\S]*?(?=^## Step )/m.exec(text) || [""])[0]
  text.includes("`ticket dir: <path>`") && text.includes("`base: <branch> (<ref>)`") && text.includes("never under the worktree") &&
    step0.includes("run `10x-worktree init <id>` on every invocation, before anything reads or writes under `.10x/`") &&
    !text.includes(".worktrees/<id>")
    ? ok("work: resolves .10x paths against ticket dir: and takes the base from base:")
    : bad("work: resolves .10x paths against ticket dir: and takes the base from base:")
}
{
  const text = fs.readFileSync(`${dir}/close/SKILL.md`, "utf8")
  const step0 = (/^## Step 0\b[\s\S]*?(?=^## Step )/m.exec(text) || [""])[0]
  const first = (/```bash\n([\s\S]*?)```/.exec(step0) || ["", ""])[1].split("\n").filter(Boolean)
  first[0] === "10x-land check <id>" && first[1] === "10x-worktree path <id>" &&
    step0.includes("`ticket dir: <path>`") && step0.includes("`review: missing`") && step0.includes("never under the worktree") &&
    !text.includes("`.10x/<id>/review.md` is missing")
    ? ok("close: runs check first and resolves .10x paths against ticket dir:")
    : bad("close: runs check first and resolves .10x paths against ticket dir:")
}

// work's Step 0 only names the ticket: a typed gh-<n> is its id, and an approved plan is read before Step 1 fetches
// any ticket text, so a new session never re-plans an approved ticket.
{
  const text = fs.readFileSync(`${dir}/work/SKILL.md`, "utf8")
  const step = (n) => (new RegExp(`^## Step ${n}\\b[\\s\\S]*?(?=^## Step )`, "m").exec(text) || [""])[0]
  step(0).split("\n").includes("| `gh-<n>` | `gh-<n>` |")
    ? ok("work: Step 0 maps gh-<n> to its id") : bad("work: Step 0 maps gh-<n> to its id")
  !step(0).includes("10x-ticket") && !step(0).includes("Ticket text") && step(0).includes("`Status: approved`") &&
    step(1).includes("`10x-ticket github")
    ? ok("work: Step 0 reads an approved plan before any ticket text is fetched")
    : bad("work: Step 0 reads an approved plan before any ticket text is fetched")
}

// close names the valid tickets values when check refuses one.
{
  const step0 = (/^## Step 0\b[\s\S]*?(?=^## Step )/m.exec(fs.readFileSync(`${dir}/close/SKILL.md`, "utf8")) || [""])[0]
  step0.includes("`tickets: <value>`") && step0.includes("`unknown tickets value") && step0.includes("`github` and `files`")
    ? ok("close: names the valid tickets values on check's exit 2")
    : bad("close: names the valid tickets values on check's exit 2")
}

// work's implementer runs tests only through a granted 10x-test and edits only with Edit and Write: a /10x:batch
// worker runs where no one can approve a test runner or a shell edit.
{
  const text = fs.readFileSync(`${dir}/work/SKILL.md`, "utf8")
  const front = (/^---\n([\s\S]*?)\n---/.exec(text) || ["", ""])[1]
  front.split("\n").includes("  - Bash(10x-test *)")
    ? ok("work: grants 10x-test") : bad("work: grants 10x-test")
  const step3 = (/^## Step 3\b[\s\S]*?(?=^## Step )/m.exec(text) || [""])[0]
  const delegated = (/^Delegated:.*$/m.exec(step3) || [""])[0]
  step3.includes("`10x-test <id> [test file…]`") && step3.includes("only with Edit and Write") &&
    delegated.includes("`10x-test <id>") && delegated.includes("only with Edit and Write") &&
    !delegated.includes("the full gate once at the end")
    ? ok("work: Step 3 runs tests only through 10x-test and edits only with Edit and Write")
    : bad("work: Step 3 runs tests only through 10x-test and edits only with Edit and Write")
}

// work writes, commits and locks the tests before any implementation, delegates the tests half to qa-engineer, and
// sends a locked test's change to a cold code-reviewer that sees only the relock request.
{
  const text = fs.readFileSync(`${dir}/work/SKILL.md`, "utf8")
  const step3 = (/^## Step 3\b[\s\S]*?(?=^## Step )/m.exec(text) || [""])[0]
  const at = (s) => step3.indexOf(s)
  const tests = step3.slice(at("### Tests half"), at("### Implementation half"))
  const impl = step3.slice(at("### Implementation half"), at("### Relock"))
  const relock = step3.slice(at("### Relock"))
  const lock = at("10x-red-proof <id> --lock")
  at("### Tests half") !== -1 && at("### Tests half") < at("Commit them as in Step 4, test files and test helpers only") &&
    at("Commit them as in Step 4, test files and test helpers only") < lock && lock < at("### Implementation half") &&
    tests.includes("Write only the test files `## Tests` names") && tests.includes("```bash\n10x-red-proof <id> --lock\n```")
    ? ok("work: the tests half is committed and locked before the implementation")
    : bad("work: the tests half is committed and locked before the implementation")
  const qa = at("spawn `10x:qa-engineer`")
  const delegated = (/^Delegated:.*$/m.exec(impl) || [""])[0]
  qa !== -1 && tests.includes("spawn `10x:qa-engineer`") && qa < lock && lock < at("Delegated: spawn `10x:frontend-engineer`") &&
    impl.includes("Only after `10x-red-proof <id> --lock` passes") &&
    delegated.includes("The tests the plan names are written and locked: never edit them; make them pass.")
    ? ok("work: qa-engineer writes the tests half before the engineer is spawned")
    : bad("work: qa-engineer writes the tests half before the engineer is spawned")
  relock.includes("Spawn a fresh `10x:code-reviewer` with only the path of `.10x/<id>/relock-request.md`") &&
    relock.includes("Read this relock request whole, and nothing of the implementation.") &&
    ["the reason", "the text of every criterion whose `## Tests` row names a file it changes", "the locked files' paths", "unified diff", "One request may cover several wrong locked files", "Several relocks may be pending"].every((s) => relock.includes(s)) &&
    relock.includes("If rejected: no `commit` line. Write `- asked: <the arbiter's reason")
    ? ok("work: a relock goes to a fresh code-reviewer arbiter")
    : bad("work: a relock goes to a fresh code-reviewer arbiter")
  tests.includes("Skipped when `tdd` is `false` in the main checkout's `.claude/10x.json`, or when every `## Tests` row has `—` as test file")
    ? ok("work: tdd false and an all-— Tests table skip the tests half")
    : bad("work: tdd false and an all-— Tests table skip the tests half")
}

// The security reviewer judges by Cloudflare's guidance-mode criteria (pinned commit, MIT notice) and splits its output
// into the confirmed findings in the diff and everything else, which work hands to 10x-security and never publishes.
{
  const flat = (s) => s.replace(/\s+/g, " ")
  const reviewer = flat(fs.readFileSync(`${dir}/../agents/security-reviewer.md`, "utf8"))
  const work = fs.readFileSync(`${dir}/work/SKILL.md`, "utf8")
  const anchors = [
    "an unauthenticated actor gains code execution, full data-store access, or takeover of arbitrary accounts",
    "an actor fully defeats an explicit security control with real consequences: authentication bypass, cross-tenant read or write, stored script execution affecting other users, authenticated code execution, or an unauthenticated remote stop of a shared service",
    "a real boundary violation with limited blast radius, uncommon preconditions, or consequences confined to a narrow resource set",
    "disclosure of non-secret internals, or an effect requiring sustained effort for minimal gain",
    "a confirmed but minimal-impact observation, useful mainly as a prerequisite inside a larger finding",
  ]
  const antiPatterns = [
    "Checklist deviations presented as vulnerabilities",
    "Defense-in-depth advice with no reachable boundary violation",
    "Guessing provider, proxy, browser, identity, or deployment behavior not present in source",
    "Treating intended same-principal authority or self-impact as a cross-boundary result",
    "Reporting a parser or runtime effect stronger than the observed effect",
    "Assigning severity to `needs_validation` records",
  ]
  const missing = [
    ["## Judging criteria", "a ## Judging criteria section"],
    ["https://github.com/cloudflare/security-audit-skill/tree/c1c8a8c1471069fb0e188eeaff69b8e8db6564a8", "the link to Cloudflare's repo at the pinned commit"],
    ["Adapted from Cloudflare's security-audit-skill, MIT License, Copyright (c) 2025-2026 Cloudflare, Inc.", "the MIT notice"],
    ["overall severity cannot exceed demonstrated impact", "the overall-severity rule"],
    ...["critical", "high", "medium", "low", "informational"].map((s) => [`**${s}**`, `the ${s} anchor`]),
    ...anchors.map((a) => [a, `the anchor "${a.slice(0, 40)}…"`]),
    ...antiPatterns.map((a) => [a, `the anti-pattern "${a.slice(0, 40)}…"`]),
    ...["`confirmed`", "`needs_validation`", "`rejected`"].map((v) => [v, `the ${v} verdict`]),
  ].filter(([s]) => !reviewer.includes(s)).map(([, w]) => w)
  // The six element names are Cloudflare's; the plan gives no list to pin them to, so only their two halves are required.
  if (!/boundary/i.test(reviewer) || !/observed result/i.test(reviewer)) missing.push("the boundary + result elements")
  if (reviewer.includes("Critical, High, Medium, Low, Info")) missing.push("no `Critical, High, Medium, Low, Info` scale (still there)")
  missing.length === 0 ? ok("security-reviewer: carries Cloudflare's criteria with attribution")
    : bad(`security-reviewer: carries Cloudflare's criteria with attribution (missing: ${missing.join("; ")})`)

  const contract = flat((/^## Output contract[\s\S]*/m.exec(fs.readFileSync(`${dir}/../agents/security-reviewer.md`, "utf8")) || [""])[0])
  const keys = ["verdict", "rule", "title", "path", "line", "snippet", "trace", "severity"]
  contract.includes("## Findings") && contract.includes("## Out of diff") && contract.includes("```json") &&
    keys.every((k) => contract.includes(`\`${k}\``)) && contract.includes("- **[<severity>] <title>** (`path:line`)") &&
    /severity[^.]*\bonly\b[^.]*confirmed/i.test(contract)
    ? ok("security-reviewer: output has ## Findings and ## Out of diff")
    : bad("security-reviewer: output has ## Findings and ## Out of diff")

  const w = flat(work)
  w.includes("Only `## Findings` goes to `review.md`") && w.includes("nothing from `## Out of diff` goes into `review.md`, the report, a commit or a PR")
    ? ok("work: writes only ## Findings to review.md") : bad("work: writes only ## Findings to review.md")

  const step = (n) => (new RegExp(`^## Step ${n}\\b[\\s\\S]*?(?=^## )`, "m").exec(work) || [""])[0]
  const front = (/^---\n([\s\S]*?)\n---/.exec(work) || ["", ""])[1].split("\n")
  const header = work.slice(0, work.search(/^## Step 0\b/m))
  const step8 = work.slice(work.search(/^## Step 8\b/m), work.search(/^## Replies$/m))
  const handsOver = (s) => s.includes("10x-security add <id>") && s.includes("out-of-diff.json")
  front.includes("  - Bash(10x-security add *)") && !front.includes("  - Bash(10x-security *)") && header.includes("`10x-security`") && handsOver(step(6)) && handsOver(step("7a")) &&
    flat(step(7)).includes("`blocker`, `major`, a plan check, any confirmed security finding in the diff") &&
    flat(step8).includes("Step 8 security entries: <fp>") && step8.includes("10x-security set <id> <fp> <status> [reason]") &&
    ["fix-now", "later", "accepted", "rejected"].every((s) => step8.includes(`\`${s}\``)) &&
    step8.indexOf("10x-security set") < step8.indexOf("10x-worktree memory")
    ? ok("work: hands Out of diff to 10x-security and asks about new entries in Step 8")
    : bad("work: hands Out of diff to 10x-security and asks about new entries in Step 8")
}

// gh-2 — /10x:audit: the skill file is read once; a missing file fails each case and does not stop the run.
{
  const file = `${dir}/audit/SKILL.md`
  const text = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : ""
  const flat = text.replace(/\s+/g, " ")
  const front = (/^---\n([\s\S]*?)\n---/.exec(text) || ["", ""])[1].split("\n")
  const missing = (pairs) => pairs.filter(([c]) => !c).map(([, w]) => w)
  const verdict = (name, miss) => !text ? bad(`${name} (skills/audit/SKILL.md is missing)`)
    : miss.length ? bad(`${name} (missing: ${miss.join("; ")})`) : ok(name)

  // AC2 — one asking round, and a bad answer is asked again.
  verdict("audit: asks scope, profile and agent limit in one round and re-asks a bad ref or path", missing([
    [flat.includes("scope") && flat.includes("profile") && flat.includes("agent limit"), "scope, profile and agent limit"],
    [["`quick`", "`standard`", "`deep`"].every((p) => flat.includes(p)), "the three profiles quick, standard, deep"],
    [flat.includes("in one round"), "'in one round'"],
    [flat.includes("`git rev-parse --verify <ref>`"), "'git rev-parse --verify <ref>' for a ref"],
    [flat.includes("`test -e <path>`"), "'test -e <path>' for a path"],
    [/asking again|ask(s)? again|re-ask/.test(flat), "asking again on a failed check"],
    [flat.includes("`<ref>..<ref>`"), "a diff scope written <ref>..<ref>"],
    [flat.indexOf("in one round") !== -1 && flat.indexOf("in one round") < flat.indexOf("Skill tool"), "the round before the Skill tool call"],
  ]))

  // AC4 — prepare first, then the installed skill in this session, never a subagent.
  const firstBlock = (/```bash\n([\s\S]*?)```/.exec(text) || ["", ""])[1].split("\n").map((l) => l.trim()).filter(Boolean)
  verdict("audit: invokes security-audit in the main session with scope, profile, budget, output dir and prior runs", missing([
    [front.includes("disable-model-invocation: true"), "disable-model-invocation: true"],
    [["  - Bash(10x-security prepare)", "  - Bash(10x-security import *)", "  - Bash(git rev-parse --verify *)", "  - Bash(test -e *)"].every((g) => front.includes(g)),
      "the four granted commands"],
    [!front.some((l) => /10x-security (set|ticket)/.test(l)) && !front.includes("  - Bash(10x-security *)"), "no grant for set or ticket"],
    [firstBlock[0] === "10x-security prepare", "10x-security prepare as the first command"],
    [flat.includes("`security-audit` skill") && flat.includes("with the Skill tool") && /never a subagent/.test(flat), "the Skill tool, never a subagent"],
    [/(this|the main) session/.test(flat), "this session"],
    [flat.includes("`run:`") && flat.includes("`prior:`"), "the run: and prior: lines of prepare"],
    [/budget/.test(flat) && /output directory/.test(flat), "budget and the output directory"],
    [flat.includes('`scope_paths: ["."]`'), 'a whole-repo scope recorded as `scope_paths: ["."]`'],
    [flat.includes("`rules.json`") && flat.includes("10x-security import run-<n>"), "rules.json written, then 10x-security import run-<n>"],
    [flat.indexOf("Skill tool") !== -1 && flat.indexOf("Skill tool") < flat.indexOf("10x-security import run-<n>"), "the skill runs before import"],
  ]))

  // AC9 — each new or later entry, one at a time, in import's order.
  verdict("audit: asks each new or later entry of the run one at a time", missing([
    [flat.includes("one at a time"), "'one at a time'"],
    [flat.includes("`added`") && flat.includes("`seen`"), "the added and seen lines of import"],
    [flat.includes("`new` or `later`"), "'`new` or `later`'"],
    [flat.includes("import's output order"), "import's output order"],
    [["`fix-now`", "`later`", "`accepted`", "`rejected`"].every((s) => flat.includes(s)), "the four statuses"],
    [flat.includes("10x-security set audit/run-<n> <fp> <status> [reason]"), "10x-security set audit/run-<n> <fp> <status> [reason]"],
    [flat.includes("10x-security ticket <fp> security-<8 hex>"), "10x-security ticket <fp> security-<8 hex>"],
    [flat.indexOf("10x-security set") !== -1 && flat.indexOf("10x-security set") < flat.indexOf("10x-security ticket"), "set before ticket"],
    [/severity/.test(flat) && /fingerprint/.test(flat) && /title/.test(flat) && /location/.test(flat), "fingerprint, severity, title and location shown"],
  ]))

  // AC12 — what the final reply names.
  verdict("audit: the final reply names the run, run_status, counts and fix-now tickets", missing([
    [/^## Replies$/m.test(text) && /final reply/i.test(flat), "a ## Replies section and a final reply"],
    [flat.includes("`run_status`"), "run_status"],
    [/new/.test(flat) && /matched/.test(flat) && /not[- ]seen/.test(flat), "the new, matched and not-seen counts"],
    [/count per status|per status/.test(flat), "the count per status"],
    [flat.includes("`/10x:work <slug>`"), "one /10x:work <slug> per fix-now ticket"],
    [/run path|path of the run|`run:`/.test(flat), "the run path"],
  ]))
}

// gh-2 AC15 — work keeps the ticket.md `10x-security ticket` wrote for a security-<8 hex> ticket, posts nothing for it,
// branches it by its id, and removes the entry after a clean full round.
{
  const work = fs.readFileSync(`${dir}/work/SKILL.md`, "utf8")
  const flat = (s) => s.replace(/\s+/g, " ")
  const step = (n) => flat((new RegExp(`^## Step ${n}\\b[\\s\\S]*?(?=^## Step )`, "m").exec(work) || [""])[0])
  const miss = [
    [step(1).includes("a ticket whose id is not `gh-<n>` and whose `ticket.md` already exists"), "Step 1: keeps an existing ticket.md of any non-gh ticket"],
    [step(1).includes("**Words**, or any ticket that is not a GitHub issue"), "Step 1: nothing is posted for a non-issue ticket"],
    [step(2).includes("`security-<8 hex>`") && step(2).includes("the id itself") && step(2).includes("`<type>/security-<8 hex>`"), "Step 2: --slug is the id itself"],
    [step("7b").includes("`security-<8 hex>` ticket") && step("7b").includes("`10x:security-reviewer`") &&
      step("7b").includes("`10x-security remove <id> <fp>`"), "Step 7b: a security-<8 hex> ticket's full round removes the entry"],
  ].filter(([c]) => !c).map(([, w]) => w)
  miss.length ? bad(`work: a security ticket keeps its ticket.md, posts nothing, is branched by its id and removes its entry after a clean full round (missing: ${miss.join("; ")})`)
    : ok("work: a security ticket keeps its ticket.md, posts nothing, is branched by its id and removes its entry after a clean full round")
}

// gh-3 — /10x:roadmap plans security entries: Requirements lists the plannable ones and writes a picked one as a security
// item; Tickets asks 10x-security route for each such item and creates it with the command the route names. 10x-land
// advisory is never granted to the skill.
{
  const text = fs.readFileSync(`${dir}/roadmap/SKILL.md`, "utf8")
  const flat = (s) => s.replace(/\s+/g, " ")
  const front = (/^---\n([\s\S]*?)\n---/.exec(text) || ["", ""])[1].split("\n")
  // A step runs to the next `### Step`: Tickets Step 3 has `## ` headings of its own inside a fence.
  const step = (s, n) => s.split(/^(?=### Step )/m).find((p) => p.startsWith(`### Step ${n}`)) || ""
  const reqText = text.slice(text.search(/^## Requirements$/m), text.search(/^## Tickets$/m))
  const ticketsText = text.slice(text.search(/^## Tickets$/m), text.search(/^## Replies$/m))
  const missing = (pairs) => pairs.filter(([c]) => !c).map(([, w]) => w)
  const verdict = (name, miss) => miss.length ? bad(`${name} (missing: ${miss.join("; ")})`) : ok(name)

  verdict("roadmap: offers plannable security entries and writes them as security items", missing([
    [front.includes("  - Bash(10x-security list --plannable)"), "the grant Bash(10x-security list --plannable)"],
    [flat(step(reqText, 1)).includes("10x-security list --plannable"), "Requirements Step 1 runs 10x-security list --plannable"],
    [/<fp> <severity> <title>|<fingerprint> <severity> <title>/.test(flat(step(reqText, 1))), "Step 1 shows each entry as fingerprint, severity and title"],
    [flat(step(reqText, 2)).includes("`<title> (security <fingerprint>)`"), "Step 2 writes a picked entry as `<title> (security <fingerprint>)`"],
    [flat(step(reqText, 2)).includes("`\\|`") && flat(step(reqText, 2)).includes("`; `"), "Step 2 escapes | and ; in the title"],
  ]))

  const tstep = (n) => flat(step(ticketsText, n))
  verdict("roadmap: routes each security item and never grants 10x-land advisory", missing([
    [front.includes("  - Bash(10x-security route *)"), "the grant Bash(10x-security route *)"],
    [!front.some((l) => l.includes("10x-land advisory")) && !front.includes("  - Bash(10x-land *)"), "no grant covering 10x-land advisory"],
    [tstep(1).includes("10x-security route <fp>") && tstep(1).includes("(security sha256:"), "Tickets Step 1 runs 10x-security route <fp> for an item with a fingerprint"],
    [tstep(3).includes("`security-<8 hex>`"), "Step 3 gives a security item the slug `security-<8 hex>`"],
    [tstep(3).includes("# Fix security entry <first 8 hex>") && tstep(3).includes("`Security: <fp>`"), "Step 3: the title and the `Security: <fp>` header line"],
    [["→ advisory", "→ issue", "→ ticket file"].every((k) => tstep(3).includes(k)), "Step 3: a Kind line per route"],
    [["advisory", "issue", "ticket"].every((c) => tstep(4).includes(`10x-land ${c} <slug>`)), "Step 4: the command each route creates with"],
    [/allowed-tools/.test(tstep(4).slice(tstep(4).indexOf("10x-land advisory"))), "Step 4: 10x-land advisory is named as not granted"],
  ]))
}

// batch accepts `auto` as its first argument: it initialises with --auto, runs `10x-batch loop` in the background,
// relays only the items loop printed, and on done ends with the board and every ticket's ## Auto decisions.
{
  const name = "batch: auto runs 10x-batch loop in the background and relays its items"
  const text = fs.readFileSync(`${dir}/batch/SKILL.md`, "utf8")
  const front = (/^---\n([\s\S]*?)\n---/.exec(text) || ["", ""])[1].split("\n")
  const step0 = (/^## Step 0\b[\s\S]*?(?=^## Step )/m.exec(text) || [""])[0]
  const loopPara = text.split(/\n\s*\n/).find((p) => p.includes("10x-batch loop") && p.includes("run_in_background")) || ""
  const missing = [
    [front.includes("  - Bash(10x-batch loop)"), "the grant Bash(10x-batch loop)"],
    [step0.includes("10x-batch init --auto <tickets>"), "Step 0 runs 10x-batch init --auto <tickets>"],
    [step0.includes("/10x:batch auto auto"), "Step 0: a ticket named auto is written /10x:batch auto auto"],
    [loopPara.includes("7200000"), "10x-batch loop runs with run_in_background and timeout: 7200000"],
    [["answer", "approve", "failed", "denied", "done"].every((k) => text.includes(`\`${k}\``)), "the item kinds answer, approve, failed, denied and done"],
    [/only (the )?items/i.test(text), "relays only the items loop printed"],
    [text.includes("## Auto decisions") && text.includes("verbatim"), "the final reply holds each ticket's ## Auto decisions verbatim"],
  ].filter(([c]) => !c).map(([, w]) => w)
  missing.length ? bad(`${name} (missing: ${missing.join("; ")})`) : ok(name)
}

// batch resumes with 10x-batch loop when it has no arguments and status shows mode: auto, and for `auto` with no tickets.
{
  const name = "batch: an auto batch resumes with 10x-batch loop"
  const text = fs.readFileSync(`${dir}/batch/SKILL.md`, "utf8")
  const step0 = (/^## Step 0\b[\s\S]*?(?=^## Step )/m.exec(text) || [""])[0]
  const missing = [
    [step0.includes("mode: auto"), "Step 0 reads mode: auto from status"],
    [step0.includes("`/10x:batch auto`") || /`auto`[^\n]*(alone|no tickets)/.test(step0), "Step 0 names `auto` with no tickets"],
    [step0.includes("10x-batch loop"), "Step 0 resumes with 10x-batch loop"],
  ].filter(([c]) => !c).map(([, w]) => w)
  missing.length ? bad(`${name} (missing: ${missing.join("; ")})`) : ok(name)
}

// the user is shown only the lines of plan.md above its "# Appendix" line; batch offers one approve for the whole round.
{
  const name = "work: shows only the plan above its Appendix line"
  const text = fs.readFileSync(`${dir}/work/SKILL.md`, "utf8")
  const flat = (s) => s.replace(/\s+/g, " ")
  const step = (n) => flat((new RegExp(`^## Step ${n}\\b[\\s\\S]*?(?=^## Step )`, "m").exec(text) || [""])[0])
  const missing = [0, 1].flatMap((n) => [
    [step(n).includes("above `# Appendix`"), `Step ${n} names the lines above \`# Appendix\``],
    [step(n).includes("`user-facing: lines 1-<n>`"), `Step ${n} takes them from the \`user-facing: lines 1-<n>\` line`],
  ]).filter(([c]) => !c).map(([, w]) => w)
  missing.length ? bad(`${name} (missing: ${missing.join("; ")})`) : ok(name)
}
{
  const name = "batch: shows only the plan above its Appendix line"
  const text = fs.readFileSync(`${dir}/batch/SKILL.md`, "utf8")
  const step2 = (/^## Step 2\b[\s\S]*?(?=^## )/m.exec(text) || [""])[0].replace(/\s+/g, " ")
  step2.includes("above its `# Appendix` line") ? ok(name) : bad(`${name} (Step 2 lacks "above its \`# Appendix\` line")`)
}
{
  const name = "batch: approve all runs one 10x-batch approve naming the round's approvable tickets"
  const text = fs.readFileSync(`${dir}/batch/SKILL.md`, "utf8")
  const step2 = (/^## Step 2\b[\s\S]*?(?=^## )/m.exec(text) || [""])[0].replace(/\s+/g, " ")
  const missing = [
    [step2.includes("`approve all`"), "Step 2 offers `approve all`"],
    [step2.includes("`10x-batch approve <id> <id>…`"), "Step 2 runs `10x-batch approve <id> <id>…`"],
    [step2.includes("shown in that message"), "Step 2 names only the tickets shown in that message"],
  ].filter(([c]) => !c).map(([, w]) => w)
  missing.length ? bad(`${name} (missing: ${missing.join("; ")})`) : ok(name)
}

// work gains no issue-author check: the check lives in 10x-batch alone, and neither work's skill nor a script it runs
// asks gh who wrote an issue.
{
  const name = "work: adds no issue-author check"
  const root = `${dir}/..`
  const read = (f) => (fs.existsSync(`${root}/${f}`) ? fs.readFileSync(`${root}/${f}`, "utf8") : "")
  const needles = ["not your issue", "api user", "--json author", "cannot check the author"]
  const files = ["skills/work/SKILL.md", ...["10x-worktree", "10x-ticket", "10x-plan-check", "10x-land", "10x-test", "10x-verify", "10x-grill"].map((s) => `bin/${s}`)]
  const dirty = files.flatMap((f) => needles.filter((n) => read(f).includes(n)).map((n) => `${f}: ${n}`))
  const batch = read("bin/10x-batch")
  const owner = needles.slice(0, 3).filter((n) => !batch.includes(n))
  dirty.length ? bad(`${name} (${dirty.join("; ")})`)
    : owner.length ? bad(`${name} (the check is not in bin/10x-batch: lacks ${owner.join(", ")})`) : ok(name)
}

for (const skill of ["open", "work", "close", "batch", "roadmap", "audit"])
  fs.existsSync(`${dir}/${skill}/SKILL.md`) && /^## Replies$/m.test(fs.readFileSync(`${dir}/${skill}/SKILL.md`, "utf8"))
    ? ok(`${skill}: has a ## Replies section`) : bad(`${skill}: lacks a ## Replies section`)
{
  const name = "batch: 10x-batch accept-green is named in the prose and not granted in allowed-tools"
  const t = fs.existsSync(`${dir}/batch/SKILL.md`) ? fs.readFileSync(`${dir}/batch/SKILL.md`, "utf8") : ""
  const fm = /^---\n([\s\S]*?)\n---/.exec(t)
  fm && !fm[1].includes("accept-green") && t.slice(fm[0].length).includes("10x-batch accept-green") ? ok(name) : bad(name)
}
{
  const name = "batch: 10x-batch replan is granted and offered for a failed ticket on the user's word"
  const t = fs.existsSync(`${dir}/batch/SKILL.md`) ? fs.readFileSync(`${dir}/batch/SKILL.md`, "utf8") : ""
  const fm = /^---\n([\s\S]*?)\n---/.exec(t)
  const body = fm ? t.slice(fm[0].length) : ""
  const section = (re) => {
    const lines = body.split("\n")
    const at = lines.findIndex((s) => re.test(s))
    const next = lines.findIndex((s, k) => k > at && /^## /.test(s))
    return at < 0 ? [] : lines.slice(at + 1, next < 0 ? undefined : next)
  }
  const step1 = section(/^## Step 1\b/), step4 = section(/^## Step 4\b/), never = section(/^## Never$/)
  const missing = [
    [fm && fm[1].split("\n").includes("  - Bash(10x-batch replan *)"), "the grant `Bash(10x-batch replan *)` in allowed-tools"],
    [body.includes("10x-batch replan <id>"), "`10x-batch replan <id>` in the body"],
    [step1.some((s) => s.includes("replan") && s.includes("drop")), "a Step 1 paragraph naming `replan` and `drop`"],
    [step4.some((s) => s.includes("`failed`") && s.includes("replan") && s.includes("drop")), "the Step 4 `failed` bullet naming `replan` and `drop`"],
    [never.some((s) => s.includes("10x-batch replan")), "a `## Never` line naming `10x-batch replan`"],
  ].filter(([c]) => !c).map(([, w]) => w)
  missing.length ? bad(`${name} (missing: ${missing.join("; ")})`) : ok(name)
}
{
  const name = "batch: 10x-batch checked is named in the prose and not granted in allowed-tools"
  const t = fs.existsSync(`${dir}/batch/SKILL.md`) ? fs.readFileSync(`${dir}/batch/SKILL.md`, "utf8") : ""
  const fm = /^---\n([\s\S]*?)\n---/.exec(t)
  fm && !fm[1].includes("10x-batch checked") && t.slice(fm[0].length).includes("`10x-batch checked ") ? ok(name) : bad(name)
}

// gh-35 AC7 — the skills say how hand checks work; only batch names the command that records one.
{
  const name = "skills: work, close, batch and roadmap describe hand checks"
  const read = (s) => (fs.existsSync(`${dir}/${s}/SKILL.md`) ? fs.readFileSync(`${dir}/${s}/SKILL.md`, "utf8") : "")
  const work = read("work"), close = read("close"), batch = read("batch"), roadmap = read("roadmap")
  const step8 = work.slice(work.search(/^## Step 8\b/m), work.search(/^## Replies$/m))
  const missing = [
    [work.includes("hand check:"), "work: `hand check:`"],
    [work.includes("hand-check:"), "work: `hand-check:`"],
    [step8.includes("Deferred:") && step8.indexOf("Deferred:") < step8.indexOf("Hand checks pending:"), "work: Step 8 reports `Hand checks pending:` after `Deferred:`"],
    [close.includes("(hand check pending)"), "close: `(hand check pending)`"],
    [batch.includes("## Hand checks pending"), "batch: `## Hand checks pending`"],
    [batch.includes("10x-batch checked"), "batch: `10x-batch checked`"],
    [roadmap.includes("hand check"), "roadmap: `hand check`"],
    [!work.includes("10x-batch checked") && !close.includes("10x-batch checked") && !roadmap.includes("10x-batch checked"), "work, close and roadmap do not name `10x-batch checked`"],
  ].filter(([c]) => !c).map(([, w]) => w)
  missing.length ? bad(`${name} (missing: ${missing.join("; ")})`) : ok(name)
}
// gh-36 AC9 — work's small path.
{
  const name = "work has a small path: no plan, one reviewer, a fixes round only on blocker or major, escalation"
  const work = fs.existsSync(`${dir}/work/SKILL.md`) ? fs.readFileSync(`${dir}/work/SKILL.md`, "utf8") : ""
  // Only the paragraphs that state the small path: the words below also appear in the normal path's text.
  const small = work.split("\n").filter((s) => /^Small path:|small path/.test(s)).join("\n")
  const missing = [
    [small, "`size: small`", "`size: small`"],
    [small, "`10x-worktree init <id>` again", "a second `10x-worktree init` after the ticket is saved"],
    [small, "no `plan.md`", "no `plan.md`"],
    [small, "no `10x-plan-check`", "no `10x-plan-check`"],
    [small, "no approval stop", "no approval stop"],
    [small, "per criterion of `ticket.md`", "evidence lines from the criteria of `ticket.md`"],
    [small, "`10x:code-reviewer` alone", "`10x:code-reviewer` alone in the full round"],
    [small, "only when the full round has a `blocker` or `major`", "Step 7a only on a `blocker` or `major`"],
    [small, "escalated to normal", "`escalated to normal`"],
    [small, "spawn `10x:security-reviewer` too", "the security reviewer for an escalated ticket"],
    [small, "the fixes round follows as for a normal ticket", "the fixes round for an escalated ticket"],
    [small, "or the ticket is escalated", "Step 7a runs for an escalated ticket"],
    [work, "`Escalated: <reasons>`", "`Escalated:` in the report"],
    [small, "`fix-now`", "a `fix-now` answer turns the ticket normal"],
    [small, "turns the ticket normal", "a plan change turns the ticket normal"],
    [small, "the approval stop", "the plan of a ticket turned normal is approved"],
  ].filter(([t, w]) => !t.includes(w)).map(([, , d]) => d)
  missing.length ? bad(`${name} (missing: ${missing.join("; ")})`) : ok(name)
}

// gh-36 AC10 — open proposes the size by rule; close reads the ticket when there is no plan.
{
  const name = "open proposes Size: small by rule and close falls back to ticket.md"
  const read = (s) => (fs.existsSync(`${dir}/${s}/SKILL.md`) ? fs.readFileSync(`${dir}/${s}/SKILL.md`, "utf8") : "")
  const open = read("open"), close = read("close")
  const missing = [
    [open.includes("Size: small"), "open: `Size: small`"],
    [/3 files|three files|≤ 3/.test(open), "open: the ≤ 3 files rule"],
    [open.includes("security.paths") || /sensitive path/.test(open), "open: no sensitive path"],
    [open.includes("· Size: small"), "open: `· Size: small` on the `Kind:` line"],
    [close.includes("ticket.md") && /no `plan\.md`|has no plan|without a `plan\.md`/.test(close), "close: criteria from `ticket.md` when there is no `plan.md`"],
  ].filter(([c]) => !c).map(([, w]) => w)
  missing.length ? bad(`${name} (missing: ${missing.join("; ")})`) : ok(name)
}

// gh-39 AC6 — work and close run git in a worktree with -C, never after cd.
{
  const name = "work and close: run git as git -C <worktree>, never after cd"
  const read = (s) => (fs.existsSync(`${dir}/${s}/SKILL.md`) ? fs.readFileSync(`${dir}/${s}/SKILL.md`, "utf8") : "")
  const missing = ["work", "close"].flatMap((s) => ["`git -C <worktree> …`", "never after `cd`"].filter((w) => !read(s).includes(w)).map((w) => `${s}: ${w}`))
  missing.length ? bad(`${name} (missing: ${missing.join("; ")})`) : ok(name)
}

// gh-39 AC8 — a ticket can wait with no question in its turn.md: the conductor shows its Evidence from the board first.
{
  const name = "batch: an answer on a non-plan session shows the board's evidence"
  const text = fs.existsSync(`${dir}/batch/SKILL.md`) ? fs.readFileSync(`${dir}/batch/SKILL.md`, "utf8") : ""
  const step = (n) => (new RegExp(`^## Step ${n}\\b[\\s\\S]*?(?=^## |(?![\\s\\S]))`, "m").exec(text) || [""])[0].replace(/\s+/g, " ")
  const missing = [2, 4].filter((n) => !(step(n).includes("not a plan session") && step(n).includes("Evidence"))).map((n) => `Step ${n}: "not a plan session" and its Evidence`)
  missing.length ? bad(`${name} (missing: ${missing.join("; ")})`) : ok(name)
}
// gh-40 — work's stop-or-proceed rule, the report's decisions and no deferral on a recommendation.
{
  const work = fs.existsSync(`${dir}/work/SKILL.md`) ? fs.readFileSync(`${dir}/work/SKILL.md`, "utf8") : ""
  const at = work.search(/^### Stop or proceed$/m)
  const rule = at < 0 ? "" : work.slice(at, at + 1 + work.slice(at + 1).search(/^##+ /m)).replace(/\s+/g, " ")
  const step8 = work.slice(work.search(/^## Step 8\b/m), work.search(/^## Replies$/m)).replace(/\s+/g, " ")
  const report = (n, checks) => {
    const missing = checks.filter(([c]) => !c).map(([, w]) => w)
    missing.length ? bad(`${n} (missing: ${missing.join("; ")})`) : ok(n)
  }
  report("work: lists the questions that stop and those that proceed on the recommendation", [
    [at >= 0 && at < work.search(/^### Tests half$/m), "a `### Stop or proceed` heading before `### Tests half`"],
    ...["security", "no recommended answer", "cannot undo", "- Decided: <question> — <answer taken>; alternative:",
      "## Assumptions", "10x-plan-check <id>", ".10x/<id>/decisions.md", "GREEN", "relock", "Step 8", "memory",
      "Step 7b", "--fixes"].map((w) => [rule.includes(w), `the rule names ${w}`]),
    [!work.includes("otherwise ask the user"), `no "otherwise ask the user"`],
    [!work.includes("is asked to the user before the report"), `no "is asked to the user before the report"`],
  ])
  report("work: the report lists the decisions taken", [
    [step8.includes("Decisions taken:") && step8.indexOf("Hand checks pending:") < step8.indexOf("Decisions taken:")
      && step8.indexOf("Decisions taken:") < step8.indexOf("the next step"), "Step 8: `Decisions taken:` after `Hand checks pending:` and before the next step"],
    [step8.includes("decisions.md"), "Step 8 reads `decisions.md` on the small path"],
  ])
  report("work: a criterion is never deferred on a recommendation", [
    [rule.includes("never deferred on your own recommendation"), `the rule says "never deferred on your own recommendation"`],
    [step8.includes("with the user's words"), `Step 8 keeps "with the user's words"`],
  ])
}
process.exit(fail)
JS
