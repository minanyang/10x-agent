#!/bin/bash
# Shared helpers for bin/greet. Sourced, never run.

# greet_line <name> — the line greet prints for <name>.
greet_line() {
  local name="$1"
  printf 'Hello, %s!\n' "$name"
  printf 'Hello, %s!\n' "$name"
}
