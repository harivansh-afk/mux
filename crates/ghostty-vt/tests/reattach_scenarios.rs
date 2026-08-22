//! After a reattach replay, source and client must stay identical: the
//! same subsequent bytes have to land in the same cells and leave the
//! cursor in the same place, whether the screen was partly filled or had
//! already scrolled.

use ghostty_vt::Terminal;

fn assert_screens_match(source: &Terminal, client: &Terminal, context: &str) {
    for (i, (src_row, cli_row)) in source
        .row_texts()
        .iter()
        .zip(client.row_texts().iter())
        .enumerate()
    {
        assert_eq!(src_row.trim_end(), cli_row.trim_end(), "row {i}: {context}");
    }
    assert_eq!(
        source.cursor_position(),
        client.cursor_position(),
        "cursor: {context}"
    );
}

#[test]
fn subsequent_output_matches_after_partial_fill() {
    let mut source = Terminal::new(24, 80).expect("source terminal");
    // Partially filled: the cursor is not at the bottom, so the replay has
    // to place it rather than let it fall there.
    for i in 0..15 {
        source.feed(format!("startup line {i}\r\n").as_bytes());
    }

    let reattach = source.render_screen_bytes();
    let mut client = Terminal::new(24, 80).expect("client terminal");
    client.feed(&reattach);

    for line in [
        b"a line after the reattach\r\n" as &[u8],
        b"and another\r\n",
        b"and a third\r\n",
    ] {
        source.feed(line);
        client.feed(line);
    }

    assert_screens_match(
        &source,
        &client,
        "source and client diverged after reattach + new output",
    );
}

#[test]
fn subsequent_output_matches_after_scroll() {
    let mut source = Terminal::new(24, 80).expect("source terminal");
    // Filled and scrolled: the cursor is at the bottom, so every new line
    // must scroll both screens the same way.
    for i in 0..100 {
        source.feed(format!("log line {i}\r\n").as_bytes());
    }

    let reattach = source.render_screen_bytes();
    let mut client = Terminal::new(24, 80).expect("client terminal");
    client.feed(&reattach);

    for i in 100..110 {
        let line = format!("log line {i}\r\n");
        source.feed(line.as_bytes());
        client.feed(line.as_bytes());
    }

    assert_screens_match(&source, &client, "scrolled content diverged after reattach");
}
