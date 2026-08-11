//! Terminal state tracking for VM console reattach.
//!
//! Backed by ghostty's Zig VT terminal emulator via C FFI. Tracks the full
//! screen grid by processing VT sequences from workload output. On reattach
//! the current viewport is dumped and sent to the client.

#![expect(unsafe_code, reason = "FFI wrapper around ghostty C API")]

use std::ptr::NonNull;

mod ffi {
    #[repr(C)]
    pub struct Bytes {
        pub ptr: *const u8,
        pub len: usize,
    }

    unsafe extern "C" {
        pub fn ghostty_vt_terminal_new(cols: u16, rows: u16) -> *mut core::ffi::c_void;
        pub fn ghostty_vt_terminal_free(terminal: *mut core::ffi::c_void);
        pub fn ghostty_vt_terminal_feed(
            terminal: *mut core::ffi::c_void,
            bytes: *const u8,
            len: usize,
        ) -> core::ffi::c_int;
        pub fn ghostty_vt_terminal_resize(
            terminal: *mut core::ffi::c_void,
            cols: u16,
            rows: u16,
        ) -> core::ffi::c_int;
        pub fn ghostty_vt_terminal_cursor_position(
            terminal: *mut core::ffi::c_void,
            col_out: *mut u16,
            row_out: *mut u16,
        ) -> bool;
        pub fn ghostty_vt_terminal_render_reattach(terminal: *mut core::ffi::c_void) -> Bytes;
        pub fn ghostty_vt_terminal_dump_viewport_row(
            terminal: *mut core::ffi::c_void,
            row: u16,
        ) -> Bytes;
        pub fn ghostty_vt_terminal_cursor_pending_wrap(terminal: *mut core::ffi::c_void) -> bool;
        pub fn ghostty_vt_bytes_free(bytes: Bytes);
    }
}

/// Cursor position in the terminal grid (1-based).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CursorPosition {
    pub row: u16,
    pub col: u16,
}

/// Serialized screen state for reattach redraw.
#[derive(serde::Serialize)]
pub struct ScreenDump {
    pub rows: u16,
    pub cols: u16,
    pub cursor_row: u16,
    pub cursor_col: u16,
    /// Plain text content of each viewport row.
    pub row_texts: Vec<String>,
}

/// Terminal state tracker backed by ghostty VT.
pub struct Terminal {
    handle: NonNull<core::ffi::c_void>,
    rows: u16,
    cols: u16,
}

// SAFETY: The ghostty terminal handle is single-threaded but we ensure
// exclusive access through &mut self on all mutating methods.
unsafe impl Send for Terminal {}

impl Terminal {
    /// Create a new terminal with the given dimensions.
    ///
    /// Dimensions are clamped to a minimum of 1×1 (see [`resize`]).
    #[must_use]
    pub fn new(rows: u16, cols: u16) -> Option<Self> {
        let rows = rows.max(1);
        let cols = cols.max(1);
        // SAFETY: FFI call to create a new terminal handle. Dimensions ≥ 1.
        let ptr = unsafe { ffi::ghostty_vt_terminal_new(cols, rows) };
        NonNull::new(ptr).map(|handle| Self { handle, rows, cols })
    }

    /// Feed raw workload output bytes to update terminal state.
    pub fn feed(&mut self, bytes: &[u8]) {
        // SAFETY: handle is valid, bytes pointer and len are from a slice.
        unsafe {
            ffi::ghostty_vt_terminal_feed(self.handle.as_ptr(), bytes.as_ptr(), bytes.len());
        }
    }

    /// Resize the terminal grid.
    ///
    /// Dimensions are clamped to a minimum of 1×1 because ghostty's
    /// `Screen.init` dereferences internal page structures that require
    /// at least one row and one column — passing 0 causes a null-pointer
    /// segfault in the Zig allocator path.
    pub fn resize(&mut self, rows: u16, cols: u16) {
        let rows = rows.max(1);
        let cols = cols.max(1);
        // SAFETY: handle is valid, cols/rows are clamped ≥ 1.
        unsafe {
            ffi::ghostty_vt_terminal_resize(self.handle.as_ptr(), cols, rows);
        }
        self.rows = rows;
        self.cols = cols;
    }

    /// Get current cursor position (1-based row, col).
    #[must_use]
    pub fn cursor_position(&self) -> CursorPosition {
        let mut col: u16 = 1;
        let mut row: u16 = 1;
        // SAFETY: handle is valid, col/row are valid mut pointers.
        unsafe {
            ffi::ghostty_vt_terminal_cursor_position(
                self.handle.as_ptr(),
                std::ptr::addr_of_mut!(col),
                std::ptr::addr_of_mut!(row),
            );
        }
        CursorPosition { row, col }
    }

    /// Whether the cursor has the Last Column Flag set (pending wrap).
    ///
    /// When true, the next printing character will trigger a line wrap.
    /// CUP escape sequences clear this flag, so reattach must handle it
    /// specially to preserve cursor behavior.
    #[must_use]
    pub fn cursor_pending_wrap(&self) -> bool {
        // SAFETY: handle is valid.
        unsafe { ffi::ghostty_vt_terminal_cursor_pending_wrap(self.handle.as_ptr()) }
    }

    /// Capture current screen state for reattach redraw.
    #[must_use]
    pub fn screen_dump(&self) -> ScreenDump {
        let CursorPosition {
            row: cursor_row,
            col: cursor_col,
        } = self.cursor_position();

        let mut row_texts = Vec::with_capacity(usize::from(self.rows));
        for r in 0..self.rows {
            // SAFETY: handle is valid, row index is within bounds.
            let bytes =
                unsafe { ffi::ghostty_vt_terminal_dump_viewport_row(self.handle.as_ptr(), r) };
            let text = if bytes.ptr.is_null() || bytes.len == 0 {
                String::new()
            } else {
                // SAFETY: ghostty returns valid UTF-8 from dumpStringAlloc.
                let slice = unsafe { std::slice::from_raw_parts(bytes.ptr, bytes.len) };
                let s = String::from_utf8_lossy(slice).into_owned();
                // SAFETY: freeing the ghostty-allocated buffer.
                unsafe {
                    ffi::ghostty_vt_bytes_free(bytes);
                }
                s
            };
            row_texts.push(text);
        }

        ScreenDump {
            rows: self.rows,
            cols: self.cols,
            cursor_row,
            cursor_col,
            row_texts,
        }
    }

    /// Render complete terminal state as VT escape sequences for reattach.
    ///
    /// Uses ghostty's native `ScreenFormatter` for viewport content with
    /// per-cell SGR attributes, and emits terminal-level state (modes, scroll
    /// region, tabstops, charsets, etc.) in an order that avoids cursor-homing
    /// side effects. See `renderReattach` in `zig/lib.zig` for emission order.
    #[must_use]
    pub fn render_screen_bytes(&self) -> Vec<u8> {
        // SAFETY: handle is valid.
        let bytes = unsafe { ffi::ghostty_vt_terminal_render_reattach(self.handle.as_ptr()) };

        if bytes.ptr.is_null() || bytes.len == 0 {
            return Vec::new();
        }

        // SAFETY: ghostty returns a valid buffer.
        let slice = unsafe { std::slice::from_raw_parts(bytes.ptr, bytes.len) };
        let owned = slice.to_vec();
        // SAFETY: freeing the ghostty-allocated buffer.
        unsafe {
            ffi::ghostty_vt_bytes_free(bytes);
        }
        owned
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        // SAFETY: handle was created by ghostty_vt_terminal_new and is valid.
        unsafe {
            ffi::ghostty_vt_terminal_free(self.handle.as_ptr());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn feed_and_read_back() {
        let mut term = Terminal::new(24, 80).expect("terminal creation");
        term.feed(b"Hello, world!");

        let dump = term.screen_dump();
        assert_eq!(dump.rows, 24);
        assert_eq!(dump.cols, 80);

        // First row should contain "Hello, world!"
        assert!(
            dump.row_texts[0].contains("Hello, world!"),
            "row 0: {:?}",
            dump.row_texts[0]
        );
    }

    #[test]
    fn resize_updates_dimensions() {
        let mut term = Terminal::new(24, 80).expect("terminal creation");
        term.resize(40, 120);

        let dump = term.screen_dump();
        assert_eq!(dump.rows, 40);
        assert_eq!(dump.cols, 120);
    }

    #[test]
    fn new_with_zero_dimensions_clamps_to_1x1() {
        let term = Terminal::new(0, 0).expect("terminal creation with 0x0");
        assert_eq!(term.rows, 1);
        assert_eq!(term.cols, 1);
    }

    #[test]
    fn resize_zero_dimensions_clamps_to_1x1() {
        let mut term = Terminal::new(24, 80).expect("terminal creation");
        term.resize(0, 0);
        assert_eq!(term.rows, 1);
        assert_eq!(term.cols, 1);
        // Should still be functional after resize to clamped 1x1
        term.feed(b"X");
        let dump = term.screen_dump();
        assert_eq!(dump.rows, 1);
        assert_eq!(dump.cols, 1);
    }

    #[test]
    fn render_screen_bytes_not_empty() {
        let mut term = Terminal::new(4, 10).expect("terminal creation");
        term.feed(b"test");

        let bytes = term.render_screen_bytes();
        assert!(!bytes.is_empty());
        // Should start with clear screen: cursor home + erase display + reset SGR
        assert!(bytes.starts_with(b"\x1b[H\x1b[2J\x1b[0m"));
    }

    #[test]
    fn render_screen_bytes_does_not_replay_palette_changes() {
        let mut term = Terminal::new(24, 80).expect("terminal creation");
        term.feed(b"\x1b]4;4;rgb:77/88/99\x1b\\");
        term.feed(b"\x1b[34mblue by index");

        let bytes = term.render_screen_bytes();

        assert!(
            !bytes.windows(b"\x1b]4;".len()).any(|w| w == b"\x1b]4;"),
            "reattach must not mutate the client terminal palette"
        );
    }

    #[test]
    fn render_screen_bytes_preserves_truecolor_sgr() {
        let mut term = Terminal::new(24, 80).expect("terminal creation");
        term.feed(b"\x1b[38;2;10;200;30mrgb text");

        let bytes = term.render_screen_bytes();
        let text = String::from_utf8_lossy(&bytes);

        // Direct-color cells must replay as 24-bit SGR (either the
        // semicolon or colon sub-parameter form), never quantized to
        // a palette index.
        assert!(
            text.contains("38;2;10;200;30") || text.contains("38:2::10:200:30"),
            "truecolor SGR lost in replay: {text:?}"
        );
    }

    #[test]
    fn render_screen_bytes_uses_crlf() {
        let mut term = Terminal::new(4, 40).expect("terminal creation");
        // Feed two lines via CR+LF (as a PTY with ONLCR would produce)
        term.feed(b"line one\r\nline two\r\n");

        let bytes = term.render_screen_bytes();

        // VT format emits \r\n for row boundaries. No bare \n allowed.
        for (i, &b) in bytes.iter().enumerate() {
            if b == b'\n' {
                assert!(
                    i > 0 && bytes[i - 1] == b'\r',
                    "bare \\n at byte offset {i} in screen dump (surrounding: {:?})",
                    String::from_utf8_lossy(
                        &bytes[i.saturating_sub(10)..std::cmp::min(i + 10, bytes.len())]
                    ),
                );
            }
        }

        // Verify the content is actually present
        let text = String::from_utf8_lossy(&bytes);
        assert!(text.contains("line one"), "missing line one: {text:?}");
        assert!(text.contains("line two"), "missing line two: {text:?}");
    }
}
