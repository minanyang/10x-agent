#!/usr/bin/env node
// Reads stream-json logs of `claude -p` runs: tool calls, permission denials, cost and duration. Never reads text.
//
//   toollog.js calls   <log>...   one JSON object per tool call: {turn, seq, name, command, subagent_type, run_in_background, file_path, skill, denied}
//   toollog.js denials <log>...   every denied call, one per line: <tool name> TAB <command, or the tool name>
//   toollog.js stats   <log>...   {"cost": <usd>, "ms": <duration>}
//
// A call is denied when a `result` line lists its tool_use_id under permission_denials.

const fs = require('node:fs')

const lines = (file) => {
  const out = []
  for (const l of fs.readFileSync(file, 'utf8').split('\n')) {
    if (!l.trim()) continue
    try {
      out.push(JSON.parse(l))
    } catch {} // a truncated line is not an event
  }
  return out
}

const parse = (files) => {
  const calls = []
  const denied = new Map()
  const results = []
  files.forEach((file, turn) => {
    for (const ev of lines(file)) {
      if (ev.type === 'assistant' && ev.message && Array.isArray(ev.message.content)) {
        for (const c of ev.message.content) {
          if (c.type !== 'tool_use') continue
          const i = c.input || {}
          calls.push({
            turn,
            seq: calls.length,
            id: c.id,
            name: c.name,
            command: typeof i.command === 'string' ? i.command : null,
            subagent_type: typeof i.subagent_type === 'string' ? i.subagent_type : null,
            run_in_background: i.run_in_background === true,
            file_path: typeof i.file_path === 'string' ? i.file_path : null,
            skill: typeof i.skill === 'string' ? i.skill : null,
          })
        }
      } else if (ev.type === 'result') {
        results.push(ev)
        for (const d of ev.permission_denials || []) denied.set(d.tool_use_id, d)
      }
    }
  })
  for (const c of calls) c.denied = denied.has(c.id)
  return { calls, denied, results }
}

const [cmd, ...files] = process.argv.slice(2)
const { calls, denied, results } = parse(files)

if (cmd === 'calls') {
  for (const c of calls) console.log(JSON.stringify({ ...c, id: undefined }))
} else if (cmd === 'denials') {
  for (const d of denied.values()) {
    const tool = d.tool_name || 'unknown'
    console.log(`${tool}\t${(d.tool_input && d.tool_input.command) || tool}`)
  }
} else if (cmd === 'stats') {
  let cost = 0
  let ms = 0
  for (const r of results) {
    cost += Number(r.total_cost_usd) || 0
    ms += Number(r.duration_ms) || 0
  }
  console.log(JSON.stringify({ cost, ms }))
} else {
  console.error('usage: toollog.js calls|denials|stats <log>...')
  process.exit(2)
}
