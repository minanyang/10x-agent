import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'

const greet = (name) => execFileSync(new URL('../bin/greet', import.meta.url).pathname, [name], { encoding: 'utf8' })

test('greets by name', () => {
  assert.ok(greet('Ann').startsWith('Hello, Ann!\n'))
})
