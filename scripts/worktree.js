// Whether git may run in a ticket worktree: its .git file and its admin directory must still point at the main
// checkout. A redirected `.git` or `commondir` makes git read another config, whose core.fsmonitor, filters or hooks
// then run as whoever runs git there. Reads files only, never git, so the check cannot trip the config it guards.
// A clean check also gives what git is then pinned to: with GIT_DIR, GIT_COMMON_DIR and GIT_WORK_TREE set, git does no
// discovery, never reads <wt>/.git again and takes config, hooks and objects from GIT_COMMON_DIR, so rewriting the link
// files after the check runs no planted command. Refs still follow <admin>/commondir (git's files ref backend reads it
// whatever GIT_COMMON_DIR says): they are data, which a worker can write in the common dir directly anyway.
//
//   pin(<worktree>, <git common dir>)  — { reason: <one line> } when git must not run there, else
//                                         { env: { GIT_DIR: <real admin dir>, GIT_COMMON_DIR: <real common dir>,
//                                         GIT_WORK_TREE: <worktree as given> } }
//   node scripts/worktree.js <worktree> <git common dir>  — clean: prints the admin dir, exit 0; refused: prints the
//                                         reason, exit 3 (not 1, which an uncaught exception in node gives); usage: exit 2
//
// Accepted, as git writes them (absolute, or relative under worktree.useRelativePaths), each one line of valid UTF-8,
// all compared as real paths:
//   <wt>/.git              a regular file `gitdir: <common>/worktrees/<name>`, relative to <wt>
//   <admin>/commondir      a regular file naming <common>, relative to <admin>
//   <admin>/gitdir         a regular file naming <wt>/.git, relative to <admin>
const fs = require('node:fs')
const path = require('node:path')

// Newlines and carriage returns escaped, other control characters replaced, as shown() in scripts/lib.sh: a path comes
// from a file a worker can write and must not print lines that read as a script's own.
const shown = (s) => String(s).replace(/\n/g, '\\n').replace(/\r/g, '\\r').replace(/[\x00-\x1f\x7f-\x9f]/g, '?')

// realpath(3), which follows each symlink before applying the `..` after it, as git does. Never path.resolve, path.join
// or fs.realpathSync first: they fold `<link>/..` as text, so `<wt>/l/../../../.git` would pass while git, following
// `l`, reads another directory.
const real = (p) => {
  try { return fs.realpathSync.native(p) } catch { return null }
}
// <value> read from a link file, taken against <base> the way git takes it: absolute as is, else <base>/<value> raw.
const against = (base, value) => (path.isAbsolute(value) ? value : `${base}/${value}`)

// The one line a link file holds, or { bad } saying why it is not one.
function line(file) {
  const st = fs.lstatSync(file, { throwIfNoEntry: false })
  if (!st) return { bad: `${shown(file)} is missing` }
  if (!st.isFile()) return { bad: `${shown(file)} is not a regular file` }
  // git resolves the raw bytes, node the decoded string: a byte that is not UTF-8 (decoded to U+FFFD) could name
  // another directory for each, so only content that survives a decode and re-encode is taken.
  const raw = fs.readFileSync(file)
  const decoded = raw.toString('utf8')
  if (!Buffer.from(decoded, 'utf8').equals(raw)) return { bad: `${shown(file)} is not valid UTF-8` }
  const s = decoded.replace(/\n$/, '')
  if (/[\n\r]/.test(s) || !s) return { bad: `${shown(file)} does not hold one line` }
  return { value: s }
}

function pin(wt, common) {
  const refuse = (what) => ({ reason: `refusing to run git in ${shown(wt)}: ${what}; inspect it, then remove the worktree directory and run git worktree prune` })
  const realWt = real(wt)
  if (!realWt) return refuse(`${shown(wt)} does not resolve`)
  const realCommon = real(common)
  if (!realCommon) return refuse(`the git common directory ${shown(common)} does not resolve`)

  const dotGit = path.join(wt, '.git')
  const g = line(dotGit)
  if (g.bad) return refuse(g.bad)
  const m = /^gitdir: (.+)$/.exec(g.value)
  if (!m) return refuse(`${shown(dotGit)} does not read gitdir: <path>`)
  const admin = real(against(realWt, m[1]))
  if (!admin) return refuse(`${shown(dotGit)} points at ${shown(m[1])}, which does not resolve`)
  if (path.dirname(admin) !== path.join(realCommon, 'worktrees'))
    return refuse(`${shown(dotGit)} points at ${shown(admin)}, outside ${shown(path.join(realCommon, 'worktrees'))}`)

  const c = line(path.join(admin, 'commondir'))
  if (c.bad) return refuse(c.bad)
  if (real(against(admin, c.value)) !== realCommon)
    return refuse(`${shown(path.join(admin, 'commondir'))} points at ${shown(c.value)}, not ${shown(realCommon)}`)

  const d = line(path.join(admin, 'gitdir'))
  if (d.bad) return refuse(d.bad)
  if (real(against(admin, d.value)) !== path.join(realWt, '.git'))
    return refuse(`${shown(path.join(admin, 'gitdir'))} points at ${shown(d.value)}, not ${shown(path.join(realWt, '.git'))}`)
  // bash reads the admin dir back through $(…), which would cut or fold a line break.
  if (/[\n\r]/.test(admin)) return refuse(`${shown(dotGit)} points at ${shown(admin)}, whose path holds a line break`)
  return { env: { GIT_DIR: admin, GIT_COMMON_DIR: realCommon, GIT_WORK_TREE: wt } }
}

module.exports = { pin }

if (require.main === module) {
  const a = process.argv.slice(2)
  if (a.length !== 2) {
    console.error('usage: node scripts/worktree.js <worktree> <git common dir>')
    process.exit(2)
  }
  const p = pin(a[0], a[1])
  if (p.reason) {
    console.log(p.reason)
    process.exitCode = 3
  } else {
    console.log(p.env.GIT_DIR)
  }
}
