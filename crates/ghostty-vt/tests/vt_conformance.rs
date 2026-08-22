//! The 1-based `cursor_position` conversion, over the FFI out-params.
//!
//! Everything else about CUP and relative movement is ghostty's terminal
//! package, tested there. What this crate can get wrong is the row/col
//! order and the origin of the two `u16`s it reads back.

use ghostty_vt::{CursorPosition, Terminal};

#[test]
fn cup_moves_cursor() {
    let mut term = Terminal::new(24, 80).expect("terminal creation");
    // CUP: \x1b[row;colH (1-based)
    term.feed(b"\x1b[5;10Hhello");
    let rows = term.row_texts();
    assert!(rows[4].contains("hello"), "row 4: {:?}", rows[4]);
    assert_eq!(
        term.cursor_position(),
        CursorPosition { row: 5, col: 15 },
        "col is 10 + len(\"hello\")"
    );
}

#[test]
fn cup_default_is_home() {
    let mut term = Terminal::new(24, 80).expect("terminal creation");
    term.feed(b"\x1b[10;10Hfoo");
    term.feed(b"\x1b[H"); // no args = home (1,1)
    assert_eq!(term.cursor_position(), CursorPosition { row: 1, col: 1 });
}

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
