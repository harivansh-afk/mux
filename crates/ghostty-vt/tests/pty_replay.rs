//! Real PTY replay tests.
//!
//! Spawns actual programs in a pseudo-terminal, reads the raw byte
//! output, feeds it through our Terminal, and asserts the viewport
//! contains expected content. This is the most realistic integration
//! test — exercising the exact byte path a VM console would produce.

#![expect(unsafe_code, reason = "PTY setup requires unsafe libc/fd calls")]
#![expect(
    unreachable_code,
    clippy::expect_used,
    clippy::panic,
    clippy::unreachable,
    reason = "tests use expect/panic for clarity, PTY child path uses unreachable after execvp"
)]

use std::{
    io::Read as _,
    os::fd::{FromRawFd as _, IntoRawFd as _},
};

use ghostty_vt::Terminal;

const ROWS: u16 = 24;
const COLS: u16 = 80;

/// Run a command in a PTY and return its raw output bytes.
fn capture_output(cmd: &str, args: &[&str]) -> Vec<u8> {
    let winsize = nix::pty::Winsize {
        ws_row: ROWS,
        ws_col: COLS,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };

    // SAFETY: forkpty creates a PTY pair, forks, and sets up the slave
    // as the child's controlling terminal with proper stdin/stdout/stderr.
    let result = unsafe { nix::pty::forkpty(Some(&winsize), None) }.expect("forkpty");

    match result {
        nix::pty::ForkptyResult::Child => {
            // In child: exec the command. This replaces the process.
            let c_cmd = std::ffi::CString::new(cmd).expect("CString cmd");
            let c_args: Vec<std::ffi::CString> = std::iter::once(cmd)
                .chain(args.iter().copied())
                .map(|a| std::ffi::CString::new(a).expect("CString arg"))
                .collect();
            nix::unistd::execvp(&c_cmd, &c_args).expect("execvp");
            unreachable!();
        }
        nix::pty::ForkptyResult::Parent { child, master } => {
            // SAFETY: master fd from forkpty is valid; into_raw_fd transfers ownership.
            let mut master_file = unsafe { std::fs::File::from_raw_fd(master.into_raw_fd()) };

            const READ_BUF_SIZE: usize = 4096;

            let mut output = Vec::new();
            let mut buf = [0u8; READ_BUF_SIZE];
            loop {
                match master_file.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        output.extend_from_slice(buf.get(..n).expect("read returned n > buf len"));
                    }
                    Err(e) if e.raw_os_error() == Some(nix::errno::Errno::EIO as i32) => break,
                    Err(e) => panic!("read error: {e}"),
                }
            }

            // Reap child — ECHILD if another waiter already reaped it.
            if let Err(_e) = nix::sys::wait::waitpid(child, None) {
                // Expected: child process already reaped.
            }
            output
        }
    }
}

#[test]
fn echo_hello() {
    let output = capture_output("echo", &["hello world"]);
    assert!(!output.is_empty(), "got no PTY output");

    let mut term = Terminal::new(24, 80).expect("terminal creation");
    term.feed(&output);

    let dump = term.screen_dump();
    let all_text: String = dump.row_texts.join("\n");
    assert!(
        all_text.contains("hello world"),
        "viewport missing 'hello world': {all_text:?}"
    );
}

#[test]
fn printf_escape_sequences() {
    let output = capture_output("printf", &[r"\033[3;5Hpositioned\033[0m trailing"]);

    let mut term = Terminal::new(24, 80).expect("terminal creation");
    term.feed(&output);

    let dump = term.screen_dump();
    let all_text: String = dump.row_texts.join("\n");
    assert!(
        all_text.contains("positioned"),
        "viewport missing 'positioned': {all_text:?}"
    );
}

#[test]
fn multiline_output() {
    let output = capture_output("seq", &["1", "30"]);

    let mut term = Terminal::new(24, 80).expect("terminal creation");
    term.feed(&output);

    let dump = term.screen_dump();
    let all_text: String = dump.row_texts.join("\n");
    assert!(
        all_text.contains("30"),
        "viewport missing '30': {all_text:?}"
    );
}

#[test]
fn output_no_crash() {
    let output = capture_output("ls", &["/etc"]);
    assert!(!output.is_empty());

    let mut term = Terminal::new(24, 80).expect("terminal creation");
    term.feed(&output);

    drop(term.screen_dump());
    drop(term.render_screen_bytes());
}

#[test]
fn reattach_scenario() {
    let output = capture_output("echo", &["reattach test"]);

    let mut source = Terminal::new(24, 80).expect("source terminal");
    source.feed(&output);

    let reattach = source.render_screen_bytes();
    let mut client = Terminal::new(24, 80).expect("client terminal");
    client.feed(&reattach);

    let src_dump = source.screen_dump();
    let cli_dump = client.screen_dump();

    for (i, (src_row, cli_row)) in src_dump
        .row_texts
        .iter()
        .zip(cli_dump.row_texts.iter())
        .enumerate()
    {
        assert_eq!(
            src_row.trim_end(),
            cli_row.trim_end(),
            "row {i} mismatch in PTY roundtrip"
        );
    }
}
