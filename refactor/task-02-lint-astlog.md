# task 02: the lint gate is astlog, with fixtures

PR title: `lint: astlog rules for rust, swift and cargo; drop ast-grep and the pedantic tax`

Depends on: 01.

## Why

Two things are true at once. `clippy::pedantic` and `clippy::cargo` are
denied workspace-wide on four `publish = false` crates, and the bill is 29
`#[must_use]` attributes and 24 `# Errors` / `# Panics` sections (107
lines) that restate the signature next to them, e.g. peer.rs:529-532
"# Panics: Never for the types in this module". Meanwhile the two rules
that encode a real convention (`no-anon-tuple`, `no-cargo-path-dep`) are a
hand-port to ast-grep YAML of the astlog rules in
`~/Documents/Git/indexable/index/astlog-rules/`, with their own test
format, a pinned `ASTGREP_VERSION`, an `sgconfig.yml`, and a
`scripts/lint/no-cargo-path-dep.sh` shell duplicate of the cargo rule.

astlog (the index repo's Datalog over tree-sitter) runs the original rules
unchanged, parses Swift (tree-sitter-swift is in `ast-merge-langs`), and
has the fixture self-test convention this plan wants: every `(lint ...)`
needs a `tests/<rule>/{bad,good}.fixture` pair, and the gate fails if a
lint has no pair, does not fire on `bad`, or fires on `good`. The rules
below are the machine-checked half of the deep modules in the README. A
rule that says "the frame layout is written in one place" is worth more
than a paragraph saying it.

## Changes

### Workspace lints

In `Cargo.toml` `[workspace.lints.clippy]`, keep `all` and `pedantic` at
deny, drop the `cargo` group, and add:

```toml
must_use_candidate = "allow"
missing_errors_doc = "allow"
missing_panics_doc = "allow"
```

Then delete every `#[must_use]` on a function returning `PathBuf`,
`String` or `Vec<u8>` (paths.rs ×11, peer.rs ×2, migrate.rs ×1, manager.rs
×4, tls.rs ×2, pty.rs ×1, ghostty-vt lib.rs ×5, mux-attach none) and every
`/// # Errors` and `/// # Panics` block whose text restates the function
name or the error enum. Keep, as a one-line `///`, the two that say
something the signature does not: `Manager::open` ("the pty limit is
reached") and `server::bind` ("another daemon already owns the socket").
Verified: `cargo clippy -p mux-proto --all-targets` is clean with the
allows in place and the attributes stripped.

### astlog in the repo

Layout, mirroring index:

```
lint/astlog/rust.astlog
lint/astlog/swift.astlog
lint/astlog/cargo.astlog
lint/astlog/tests/<rule-id>/bad.fixture
lint/astlog/tests/<rule-id>/good.fixture
lint/astlog/check.sh        # the fixture self-test (port of index's checks.nix)
```

Delete `lint/ast-grep/`, `sgconfig.yml`, `scripts/lint/`, the `ASTGREP_VERSION`
env and the ast-grep install steps in `.forgejo/workflows/ci.yml`.

Binary: add `index` as a flake input
(`inputs.index.url = "github:indexable-inc/index"; inputs.index.inputs.nixpkgs.follows = "nixpkgs"`)
and expose `index.packages.${system}.astlog` in a `devShells.default`. The
`just lint` recipe calls `astlog` from PATH. CI runs
`nix run github:indexable-inc/index#astlog -- scan ...` (cache.ix.dev is
already a trusted substituter on this machine; add it to the CI runner's
nix.conf in the same PR). If the flake input proves too heavy to evaluate,
fall back to `cargo install --git https://github.com/indexable-inc/index astlog`
pinned to a rev in the justfile; do not hand-port the rules to another tool.

`just lint`:

```
lint: check
    cargo fmt --check
    astlog scan lint/astlog/rust.astlog crates
    astlog scan lint/astlog/swift.astlog app/Sources
    astlog scan lint/astlog/cargo.astlog Cargo.toml crates/*/Cargo.toml
    lint/astlog/check.sh
```

`check.sh` is the `check_ruleset` function from index's
`astlog-rules/checks.nix` as a plain bash script: for each `(lint NAME`
in a ruleset, copy `tests/NAME/{bad,good}.fixture` to a temp dir with the
ruleset's extension (`rs`, `swift`, `toml`), run `astlog scan --json`,
require ≥1 finding for NAME on bad and 0 on good. Exit nonzero on any
miss. Fixtures are `.fixture` so the scan stages never read them.

### Rules

Each rule below ships with its fixture pair. Tree-sitter node kinds were
checked with `ast-grep --debug-query=ast` on 2026-08-22 and are named
here so the author does not have to rediscover them.

`rust.astlog`:

1. `no-anon-tuple`: copy verbatim from index
   (`(tuple_type (_) (_) (_)) @n`). Existing fixtures carry over from
   `lint/ast-grep/tests/no-anon-tuple-test.yml`.
2. `no-poison-unwrap`: a `call_expression` whose `function` is a
   `field_expression` with field `unwrap_or_else` and whose `arguments`
   contain a `scoped_identifier` with name `into_inner` and path ending
   `PoisonError`. Message: "std Mutex poison ceremony; use
   parking_lot::Mutex (already a workspace dependency)". Fires today at
   broker.rs:445,475 and mux-attach main.rs:444,450,459; task 09 and 07
   remove those.
3. `no-getpwuid`: `call_expression` with `function: (scoped_identifier
   path: (identifier) @p name: (identifier) @n)`, `(text p "libc")`,
   `(text n "getpwuid")`. Message: "non-reentrant getpwuid from a
   multithreaded runtime; use nix::unistd::User::from_uid". Fires at
   pty.rs:71,95; task 08 removes them.
4. `no-libc-termios`: same shape with `n` matched by
   `text-match "^(tcgetattr|tcsetattr|cfmakeraw)$"`. Message: "use
   nix::sys::termios". Fires in mux-attach `RawModeGuard`; task 07.
5. `no-handrolled-frame`: `call_expression` with
   `function: (field_expression field: (field_identifier) @m)` and
   `(text-match m "^(write_u32_le|read_u32_le)$")`. Message: "the lane
   frame and handshake layout live in mux_proto::frame; call its
   read/write functions". The two legitimate sites (the sync and async
   adapters inside `frame.rs`) carry `// astlog-ignore: no-handrolled-frame`
   so `astlog suppressions` lists exactly them. Fires today in server.rs,
   broker.rs, mux-attach, and both integration tests; task 06 makes it
   pass.

`swift.astlog`:

6. `no-raw-process`: `(call_expression (simple_identifier) @f)` with
   `(text f "Process")`. Message: "launch helpers through
   Subprocess.run". One suppression inside `Subprocess.swift`. Fires at
   PaneView.swift:457; task 13.
7. `no-nslog`: `(call_expression (simple_identifier) @f)`,
   `(text f "NSLog")`. Message: "use AppLog.log". Fires in
   GhosttyRuntime, PaneView, Snapshot, SecureInput; tasks 04/18 fix.
8. `no-adhoc-font`: `(call_expression (navigation_expression target:
   (simple_identifier) @t suffix: (navigation_suffix suffix:
   (simple_identifier) @m)))` with `(text t "NSFont")` and `(text-match
   m "^(systemFont|monospacedSystemFont)$")`, plus the
   `(call_expression (simple_identifier) @f)` `(text f "NSFont")` form
   for `NSFont(name:size:)`. Message: "all chrome text comes from
   Chrome in UI/Theme.swift". Suppressions only inside `Theme.swift`.
   Fires at GhosttyRuntime.swift:313 (`.monospacedSystemFont` in the
   clipboard sheet); task 18 routes it through `Chrome`.
9. `no-delegate-cast`: `(as_expression expr: (navigation_expression
   target: (simple_identifier) @t suffix: (navigation_suffix suffix:
   (simple_identifier) @s)) name: (user_type (type_identifier) @ty))`
   with `(text t "NSApp")`, `(text s "delegate")`, `(text ty
   "AppDelegate")`. Message: "use App.delegate". Fires in PrefixEngine,
   MuxWindowController (×2), Overlays (×2), PaneView, GhosttyRuntime;
   task 12 introduces the accessor and removes all but its definition,
   which carries the suppression.

`cargo.astlog`: copy `no-cargo-path-dep` verbatim from index, both rule
forms and the lint line.

Tree-sitter query text must be validated by astlog at load, so a typo is a
load error, not a silent pass. Write the rule, run `astlog query` on the
fixture, then the lint line.

## Keep

- `warnings = "deny"` and `clippy::all` at deny. This task lowers the
  documentation tax, not the correctness bar.
- `cargo fmt --check` in `just lint`.
- The SwiftLint/SwiftFormat steps in CI are untouched.

## Done when

- `just lint` passes on main with every rule's fixture pair present;
  `lint/astlog/check.sh` exits 0.
- `astlog suppressions lint/astlog/rust.astlog crates` lists only the two
  frame adapters; the Swift equivalent lists only `Subprocess.swift`,
  `Theme.swift`, and the `App.delegate` definition. (Until tasks 06, 07,
  08, 12, 13, 18 land, the rules that fire on current code are listed in
  `lint/astlog/PENDING.md` with the task that clears them, and `just
  lint` runs those rulesets with `--json` but does not gate on them.
  Delete PENDING.md when it is empty.)
- `rg -c '#\[must_use\]' crates` is ≤ 3 (the ones on non-trivial
  getters you chose to keep), `rg -c '# Errors|# Panics' crates` is ≤ 2.
- `lint/ast-grep`, `sgconfig.yml`, `scripts/lint` do not exist;
  `ASTGREP_VERSION` is gone from CI.
