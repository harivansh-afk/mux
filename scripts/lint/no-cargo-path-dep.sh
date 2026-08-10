#!/usr/bin/env bash
# no-cargo-path-dep: an inter-crate `path = "..."` dependency in a member
# manifest breaks every relative path when a crate moves. Declare local
# crates once in the root [workspace.dependencies] (the one table where a
# `path` is allowed) and inherit with `name.workspace = true`.
set -euo pipefail
cd "$(dirname "$0")/../.."
if hits=$(grep -rn --include=Cargo.toml -E '\bpath[[:space:]]*=' crates/); then
  printf '%s\n' "$hits" >&2
  printf 'inter-crate `path` dependency in a member manifest; declare it in [workspace.dependencies] and inherit with `name.workspace = true`\n' >&2
  exit 1
fi
