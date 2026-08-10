//! Reattach scenario tests: subsequent output correctness and real-world patterns.
//!
//! Validates that after roundtrip, subsequent output fed to both source and
//! client terminals produces identical viewports.

use ghostty_vt::{ScreenDump, Terminal};

fn assert_rows_match(source: &ScreenDump, client: &ScreenDump, context: &str) {
    for (i, (src_row, cli_row)) in source
        .row_texts
        .iter()
        .zip(client.row_texts.iter())
        .enumerate()
    {
        assert_eq!(src_row.trim_end(), cli_row.trim_end(), "row {i}: {context}");
    }
}

#[test]
fn subsequent_output_matches_after_partial_fill() {
    let mut source = Terminal::new(24, 80).expect("source terminal");
    // Partially fill: cursor NOT at bottom (simulates Minecraft startup).
    for i in 0..15 {
        source.feed(format!("[Server] startup line {i}\r\n").as_bytes());
    }

    let reattach = source.render_screen_bytes();
    let mut client = Terminal::new(24, 80).expect("client terminal");
    client.feed(&reattach);

    // New output arrives (simulates Minecraft player joining).
    let new_lines = [
        b"[Server] Player joined the game\r\n" as &[u8],
        b"[Server] Setting player gamemode\r\n",
        b"[Server] Loading chunks\r\n",
    ];
    for line in &new_lines {
        source.feed(line);
        client.feed(line);
    }

    assert_rows_match(
        &source.screen_dump(),
        &client.screen_dump(),
        "source and client diverged after reattach + new output",
    );
}

#[test]
fn subsequent_output_matches_after_scroll() {
    let mut source = Terminal::new(24, 80).expect("source terminal");
    // Fill + scroll: cursor at bottom.
    for i in 0..100 {
        source.feed(format!("log line {i}\r\n").as_bytes());
    }

    let reattach = source.render_screen_bytes();
    let mut client = Terminal::new(24, 80).expect("client terminal");
    client.feed(&reattach);

    // More output after reattach -- must scroll identically.
    for i in 100..110 {
        let line = format!("log line {i}\r\n");
        source.feed(line.as_bytes());
        client.feed(line.as_bytes());
    }

    assert_rows_match(
        &source.screen_dump(),
        &client.screen_dump(),
        "scrolled content diverged after reattach",
    );
}

/// Simulate the exact Minecraft server scenario: startup output partially
/// fills the terminal, user types, disconnects, more output while away,
/// then reattach + verify new output goes to the right place.
#[test]
fn minecraft_server_scenario() {
    let mut source = Terminal::new(24, 80).expect("source terminal");

    // Minecraft startup log: ~15 lines.
    let startup_lines = [
        "Starting net.minecraft.server.Main\r\n",
        "WARNING: A restricted method in java.lang.System has been called\r\n",
        "WARNING: java.lang.System::load has been called\r\n",
        "WARNING: Use --enable-native-access=ALL-UNNAMED\r\n",
        "WARNING: A terminally deprecated method has been called\r\n",
        "WARNING: sun.misc.Unsafe::objectFieldOffset has been called\r\n",
        "Environment: Environment[sessionHost=...]\r\n",
        "Loaded 1470 recipes\r\n",
        "Loaded 1584 advancements\r\n",
        "Starting minecraft server version 1.21.11\r\n",
        "Loading properties\r\n",
        "Starting Minecraft server on *:25565\r\n",
        "Preparing level \"world\"\r\n",
        "Done (0.243s)! For help, type \"help\"\r\n",
        "Starting remote control listener\r\n",
    ];
    for line in &startup_lines {
        source.feed(line.as_bytes());
    }

    // User types "say hi" -- echoed back by server.
    source.feed(b"[Server] hi\r\n");

    // --- User detaches here. Take the snapshot. ---
    let reattach = source.render_screen_bytes();

    // While disconnected, more server output occurs.
    source.feed(b"Server empty for 60 seconds, pausing\r\n");

    // --- User reattaches. Client gets the dump from BEFORE the new output. ---
    let mut client = Terminal::new(24, 80).expect("client terminal");
    client.feed(&reattach);

    // Feed the missed output to the client too (simulating a correct impl
    // that doesn't lose bytes). The point is to verify the dump left the
    // client in a state where this output goes to the right place.
    client.feed(b"Server empty for 60 seconds, pausing\r\n");

    assert_rows_match(
        &source.screen_dump(),
        &client.screen_dump(),
        "Minecraft reattach content diverged",
    );

    let src_cursor = source.cursor_position();
    let cli_cursor = client.cursor_position();
    assert_eq!(
        src_cursor, cli_cursor,
        "cursor position diverged in Minecraft scenario"
    );
}

/// Verify that output missed between dump and client registration causes
/// divergence. This tests that the race condition EXISTS and matters.
#[test]
fn missed_output_causes_divergence() {
    let mut source = Terminal::new(24, 80).expect("source terminal");
    for i in 0..15 {
        source.feed(format!("line {i}\r\n").as_bytes());
    }

    // Take dump at this point.
    let reattach = source.render_screen_bytes();

    // Source gets MORE output that the client will never see.
    source.feed(b"MISSED BY CLIENT\r\n");
    source.feed(b"ALSO MISSED\r\n");

    // Client gets the dump but NOT the missed output.
    let mut client = Terminal::new(24, 80).expect("client terminal");
    client.feed(&reattach);

    // Then both get the same new output.
    let shared_output = b"SHARED OUTPUT\r\n";
    source.feed(shared_output);
    client.feed(shared_output);

    // Source and client must differ because client missed 2 lines.
    let src_dump = source.screen_dump();
    let cli_dump = client.screen_dump();

    let any_diff = src_dump
        .row_texts
        .iter()
        .zip(cli_dump.row_texts.iter())
        .any(|(s, c)| s.trim_end() != c.trim_end());

    assert!(
        any_diff,
        "expected divergence due to missed output, but screens matched"
    );
}
