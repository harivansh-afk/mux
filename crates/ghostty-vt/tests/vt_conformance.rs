//! VT escape sequence conformance tests.
//!
//! Feeds known ANSI/VT sequences and asserts exact screen state.
//! Reference: <https://invisible-island.net/xterm/ctlseqs/ctlseqs.html>

use ghostty_vt::{CursorPosition, Terminal};

#[expect(clippy::panic, reason = "test assertion helper")]
fn dump_row(term: &Terminal, row: usize) -> String {
    let dump = term.screen_dump();
    let Some(text) = dump.row_texts.get(row) else {
        panic!(
            "row {row} out of bounds (screen has {} rows)",
            dump.row_texts.len()
        );
    };
    text.clone()
}

// --- Cursor positioning ---

#[test]
fn cup_moves_cursor() {
    let mut term = Terminal::new(24, 80).expect("terminal creation");
    // CUP: \x1b[row;colH (1-based)
    term.feed(b"\x1b[5;10Hhello");
    let row = dump_row(&term, 4); // 0-indexed
    assert!(row.contains("hello"), "row 4: {row:?}");
    let pos = term.cursor_position();
    assert_eq!(pos.row, 5);
    assert_eq!(pos.col, 15); // 10 + len("hello")
}

#[test]
fn cup_default_is_home() {
    let mut term = Terminal::new(24, 80).expect("terminal creation");
    term.feed(b"\x1b[10;10Hfoo");
    term.feed(b"\x1b[H"); // no args = home (1,1)
    let pos = term.cursor_position();
    assert_eq!(pos, CursorPosition { row: 1, col: 1 });
}

// --- Cursor movement (relative) ---

#[test]
fn cuu_cud_cuf_cub() {
    let mut term = Terminal::new(24, 80).expect("terminal creation");
    term.feed(b"\x1b[10;10H"); // start at (10, 10)

    term.feed(b"\x1b[3A"); // CUU: up 3
    assert_eq!(term.cursor_position(), CursorPosition { row: 7, col: 10 });

    term.feed(b"\x1b[5B"); // CUD: down 5
    assert_eq!(term.cursor_position(), CursorPosition { row: 12, col: 10 });

    term.feed(b"\x1b[4C"); // CUF: forward 4
    assert_eq!(term.cursor_position(), CursorPosition { row: 12, col: 14 });

    term.feed(b"\x1b[2D"); // CUB: back 2
    assert_eq!(term.cursor_position(), CursorPosition { row: 12, col: 12 });
}

// --- Erase display ---

#[test]
fn erase_display_clears_screen() {
    let mut term = Terminal::new(4, 20).expect("terminal creation");
    term.feed(b"line one\r\nline two\r\nline three");
    term.feed(b"\x1b[2J"); // ED: erase entire display

    let dump = term.screen_dump();
    for (i, row) in dump.row_texts.iter().enumerate() {
        let trimmed = row.trim();
        assert!(trimmed.is_empty(), "row {i} not empty after ED: {row:?}");
    }
}

// --- Erase line ---

#[test]
fn erase_line_variants() {
    let mut term = Terminal::new(4, 20).expect("terminal creation");

    // EL 0: erase from cursor to end of line
    term.feed(b"\x1b[1;1H");
    term.feed(b"ABCDEFGHIJ");
    term.feed(b"\x1b[1;4H"); // cursor at col 4
    term.feed(b"\x1b[K"); // EL 0
    let row = dump_row(&term, 0);
    assert!(row.starts_with("ABC"), "EL0 row: {row:?}");
    assert!(
        !row.contains("DEFGHIJ"),
        "EL0 should erase from cursor: {row:?}"
    );

    // EL 2: erase entire line
    term.feed(b"\x1b[2;1HXXXXXXXXXXXX");
    term.feed(b"\x1b[2;5H"); // cursor somewhere in middle
    term.feed(b"\x1b[2K"); // EL 2
    let row = dump_row(&term, 1);
    assert!(row.trim().is_empty(), "EL2 row: {row:?}");
}

// --- Scrolling ---

#[test]
fn scroll_on_newline_past_bottom() {
    let mut term = Terminal::new(4, 40).expect("terminal creation");
    // Fill all 4 rows, then add one more to trigger scroll
    term.feed(b"row1\r\nrow2\r\nrow3\r\nrow4\r\nrow5");

    let dump = term.screen_dump();
    // row1 should have scrolled off; row2 should now be first
    assert!(
        dump.row_texts[0].contains("row2"),
        "row 0: {:?}",
        dump.row_texts[0]
    );
    assert!(
        dump.row_texts[3].contains("row5"),
        "row 3: {:?}",
        dump.row_texts[3]
    );
}

// --- Line wrapping ---

#[test]
fn line_wrapping_at_right_margin() {
    let mut term = Terminal::new(4, 10).expect("terminal creation");
    // Write 15 chars into a 10-col terminal — should wrap
    term.feed(b"1234567890ABCDE");

    let dump = term.screen_dump();
    assert!(
        dump.row_texts[0].contains("1234567890"),
        "row 0: {:?}",
        dump.row_texts[0]
    );
    assert!(
        dump.row_texts[1].contains("ABCDE"),
        "row 1: {:?}",
        dump.row_texts[1]
    );
}

// --- Alternate screen ---

#[test]
fn alternate_screen_buffer() {
    let mut term = Terminal::new(4, 40).expect("terminal creation");
    term.feed(b"normal screen content");

    // Enter alternate screen
    term.feed(b"\x1b[?1049h");
    term.feed(b"alt screen content");

    let dump = term.screen_dump();
    assert!(
        dump.row_texts[0].contains("alt screen"),
        "should show alt screen: {:?}",
        dump.row_texts[0]
    );

    // Exit alternate screen — normal content restored
    term.feed(b"\x1b[?1049l");
    let dump = term.screen_dump();
    assert!(
        dump.row_texts[0].contains("normal screen"),
        "should restore normal: {:?}",
        dump.row_texts[0]
    );
}

// --- Tab stops ---

#[test]
fn horizontal_tab() {
    let mut term = Terminal::new(4, 40).expect("terminal creation");
    term.feed(b"A\tB");
    let row = dump_row(&term, 0);
    // Default tab stop is every 8 columns. "A" at col 1, tab to col 9, "B" at col 9.
    assert!(row.contains('A'), "row: {row:?}");
    assert!(row.contains('B'), "row: {row:?}");
    let a_pos = row.find('A').expect("A");
    let b_pos = row.find('B').expect("B");
    assert!(
        b_pos >= 8,
        "tab should advance to col 8+: A={a_pos} B={b_pos}"
    );
}

// --- Carriage return / line feed ---

#[test]
fn cr_lf_behavior() {
    let mut term = Terminal::new(4, 40).expect("terminal creation");
    term.feed(b"hello\rworld");
    // CR moves to column 1, "world" overwrites "hello"
    let row = dump_row(&term, 0);
    assert!(row.starts_with("world"), "CR overwrite: {row:?}");
}

// --- Backspace ---

#[test]
fn backspace_moves_cursor_left() {
    let mut term = Terminal::new(4, 40).expect("terminal creation");
    term.feed(b"ABCD\x08X"); // backspace then overwrite
    let row = dump_row(&term, 0);
    assert!(row.starts_with("ABCX"), "backspace overwrite: {row:?}");
}

// --- Save/restore cursor ---

#[test]
fn save_restore_cursor() {
    let mut term = Terminal::new(24, 80).expect("terminal creation");
    term.feed(b"\x1b[5;10H"); // move to (5, 10)
    term.feed(b"\x1b7"); // DECSC: save cursor
    term.feed(b"\x1b[1;1H"); // move to home
    assert_eq!(term.cursor_position(), CursorPosition { row: 1, col: 1 });
    term.feed(b"\x1b8"); // DECRC: restore cursor
    assert_eq!(term.cursor_position(), CursorPosition { row: 5, col: 10 });
}
