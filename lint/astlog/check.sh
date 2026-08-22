#!/usr/bin/env bash
# Fixture self-test for the astlog rulesets: every (lint ...) must have a
# committed fixture pair, fire on the violating one and stay silent on the
# valid one, driven through the same `astlog scan --json` surface `just lint`
# uses. A lint that never fires in a test is unproven - its query may have
# silently stopped matching a grammar that moved under it.
#
# Fixtures are stored as `.fixture` so the scan stages in `just lint` never
# read the deliberately-violating snippets; this script stages each one back
# to its ruleset's extension, which is how astlog picks the grammar.
set -euo pipefail

cd "$(dirname "$0")"
fail=0

check_ruleset() {
  local rules="$1" ext="$2" rule dir work bad good
  for rule in $(sed -n 's/^(lint \([a-z0-9-]*\).*/\1/p' "$rules" | sort -u); do
    dir="tests/$rule"
    if [ ! -f "$dir/bad.fixture" ] || [ ! -f "$dir/good.fixture" ]; then
      echo "lint $rule has no fixture pair under lint/astlog/$dir" >&2
      fail=1
      continue
    fi
    work=$(mktemp -d)
    cp "$dir/bad.fixture" "$work/bad.$ext"
    cp "$dir/good.fixture" "$work/good.$ext"
    # `astlog scan` exits nonzero on a violating fixture by design, so take
    # its JSON regardless of the exit status and count separately.
    bad=$(astlog scan "$rules" "$work/bad.$ext" --json 2>/dev/null || true)
    good=$(astlog scan "$rules" "$work/good.$ext" --json 2>/dev/null || true)
    rm -rf "$work"
    bad=$(count "$rule" "$bad")
    good=$(count "$rule" "$good")
    if [ "$bad" = 0 ]; then
      echo "lint $rule did not fire on its violating fixture" >&2
      fail=1
    fi
    if [ "$good" != 0 ]; then
      echo "lint $rule fired $good finding(s) on its valid fixture" >&2
      fail=1
    fi
  done
}

count() {
  python3 -c '
import json, sys
rule = sys.argv[1]
rows = json.loads(sys.argv[2] or "[]")
print(sum(1 for r in rows if r["rule"] == rule))
' "$1" "$2"
}

check_ruleset rust.astlog rs
check_ruleset swift.astlog swift
check_ruleset cargo.astlog toml

# Every fixture dir must back a lint, or it is a rule that was renamed or
# deleted and left its tests behind.
for dir in tests/*/; do
  rule=$(basename "$dir")
  if ! grep -q "^(lint $rule " rust.astlog swift.astlog cargo.astlog; then
    echo "fixture dir lint/astlog/tests/$rule matches no lint" >&2
    fail=1
  fi
done

exit "$fail"
