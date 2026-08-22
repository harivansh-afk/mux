# Rules that do not gate yet

Each rule below states a convention the code has not finished adopting. It is
declared `warning` instead of `error`, so `astlog scan` prints it on every
`just lint` run but the exit code ignores it. When the task named here lands
and the count reaches zero, change that one word to `error` and delete the row.
Delete this file when the table is empty.

Counts measured on 2026-08-22 at the head of this branch.

| rule | ruleset | sites | cleared by |
|---|---|---:|---|
| `no-handrolled-frame` | rust | 6 | task 06 (frame is one place) |
| `no-libc-termios` | rust | 4 | task 07 (mux-attach is a pure relay) |
| `no-poison-unwrap` | rust | 5 | tasks 07 and 09 |
| `no-getpwuid` | rust | 2 | task 08 (one passwd helper) |
| `no-nslog` | swift | 11 | tasks 04 and 18 |
| `no-delegate-cast` | swift | 8 | task 12 (`App.delegate`) |
| `no-raw-process` | swift | 1 | task 13 (`Muxd.Attach`) |
| `no-adhoc-font` | swift | 1 | task 18 (clipboard sheet through `Chrome`) |

`no-anon-tuple` and `no-cargo-path-dep` pass today and gate at `error`.

To see the current sites for one rule:

    astlog scan lint/astlog/rust.astlog crates --json

Two suppressions exist and are the definitions the rules point at:
`Subprocess.swift` (the one `Process()`) and `Theme.swift` (the one `NSFont`).
Task 12 adds a third when `App.delegate` gets its accessor. Audit them with
`astlog suppressions lint/astlog/swift.astlog app/Sources`.
