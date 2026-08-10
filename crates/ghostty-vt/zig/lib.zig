const std = @import("std");
const terminal = @import("ghostty_src/terminal/main.zig");

const Allocator = std.mem.Allocator;

// ghostty terminal APIs take a std.Io since zig 0.16; a headless library
// gets one process-wide threaded instance, initialized lazily.
var io_impl: std.Io.Threaded = undefined;
/// 0 = uninitialized, 1 = initializing, 2 = ready.
var io_state = std.atomic.Value(u8).init(0);
fn getIo() std.Io {
    while (true) {
        switch (io_state.load(.acquire)) {
            2 => return io_impl.io(),
            0 => if (io_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
                io_impl = std.Io.Threaded.init(std.heap.c_allocator, .{});
                io_state.store(2, .release);
                return io_impl.io();
            },
            else => std.atomic.spinLoopHint(),
        }
    }
}

const TerminalHandle = struct {
    alloc: Allocator,
    terminal: terminal.Terminal,
    stream: terminal.TerminalStream,

    fn init(alloc: Allocator, cols: u16, rows: u16) !*TerminalHandle {
        const handle = try alloc.create(TerminalHandle);
        errdefer alloc.destroy(handle);

        var t = try terminal.Terminal.init(getIo(), alloc, .{
            .cols = cols,
            .rows = rows,
        });
        errdefer t.deinit(alloc);

        handle.* = .{
            .alloc = alloc,
            .terminal = t,
            .stream = undefined,
        };
        handle.stream = handle.terminal.vtStream();
        return handle;
    }

    fn deinit(self: *TerminalHandle) void {
        self.stream.deinit();
        self.terminal.deinit(self.alloc);
        self.alloc.destroy(self);
    }
};

// --- C exports ---

export fn ghostty_vt_terminal_new(cols: u16, rows: u16) callconv(.c) ?*anyopaque {
    const alloc = std.heap.c_allocator;
    const handle = TerminalHandle.init(alloc, cols, rows) catch return null;
    return @ptrCast(handle);
}

export fn ghostty_vt_terminal_free(terminal_ptr: ?*anyopaque) callconv(.c) void {
    if (terminal_ptr == null) return;
    const handle: *TerminalHandle = @ptrCast(@alignCast(terminal_ptr.?));
    handle.deinit();
}

export fn ghostty_vt_terminal_feed(
    terminal_ptr: ?*anyopaque,
    bytes: [*]const u8,
    len: usize,
) callconv(.c) c_int {
    if (terminal_ptr == null) return 1;
    const handle: *TerminalHandle = @ptrCast(@alignCast(terminal_ptr.?));

    handle.stream.nextSlice(bytes[0..len]);
    return 0;
}

export fn ghostty_vt_terminal_resize(
    terminal_ptr: ?*anyopaque,
    cols: u16,
    rows: u16,
) callconv(.c) c_int {
    if (terminal_ptr == null) return 1;
    const handle: *TerminalHandle = @ptrCast(@alignCast(terminal_ptr.?));

    handle.terminal.resize(handle.alloc, .{
        .cols = @as(terminal.size.CellCountInt, @intCast(cols)),
        .rows = @as(terminal.size.CellCountInt, @intCast(rows)),
    }) catch return 2;
    return 0;
}

export fn ghostty_vt_terminal_cursor_position(
    terminal_ptr: ?*anyopaque,
    col_out: ?*u16,
    row_out: ?*u16,
) callconv(.c) bool {
    if (terminal_ptr == null) return false;
    if (col_out == null or row_out == null) return false;
    const handle: *TerminalHandle = @ptrCast(@alignCast(terminal_ptr.?));

    col_out.?.* = @intCast(handle.terminal.screens.active.cursor.x + 1);
    row_out.?.* = @intCast(handle.terminal.screens.active.cursor.y + 1);
    return true;
}

export fn ghostty_vt_terminal_dump_viewport_row(
    terminal_ptr: ?*anyopaque,
    row: u16,
) callconv(.c) ghostty_vt_bytes_t {
    if (terminal_ptr == null) return .{ .ptr = null, .len = 0 };
    const handle: *TerminalHandle = @ptrCast(@alignCast(terminal_ptr.?));

    const pt: terminal.point.Point = .{ .viewport = .{ .x = 0, .y = row } };
    const tl = handle.terminal.screens.active.pages.pin(pt) orelse
        return .{ .ptr = null, .len = 0 };
    var br = tl;
    br.x = handle.terminal.cols -| 1;

    const alloc = std.heap.c_allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);

    handle.terminal.screens.active.dumpString(&builder.writer, .{
        .tl = tl,
        .br = br,
        .unwrap = false,
    }) catch {
        builder.deinit();
        return .{ .ptr = null, .len = 0 };
    };

    const slice = builder.toOwnedSlice() catch {
        builder.deinit();
        return .{ .ptr = null, .len = 0 };
    };
    return .{ .ptr = slice.ptr, .len = slice.len };
}

/// Return the cursor's pending wrap (Last Column Flag) state.
export fn ghostty_vt_terminal_cursor_pending_wrap(
    terminal_ptr: ?*anyopaque,
) callconv(.c) bool {
    if (terminal_ptr == null) return false;
    const handle: *TerminalHandle = @ptrCast(@alignCast(terminal_ptr.?));
    return handle.terminal.screens.active.cursor.pending_wrap;
}

/// Render complete terminal state as VT escape sequences for reattach.
///
/// Uses ghostty's ScreenFormatter for viewport content with per-cell SGR,
/// and emits terminal-level state (modes, scroll region, tabstops, etc.)
/// in an order that avoids cursor-homing side effects:
///
///   1. Clear screen + reset SGR
///   2. Non-default modes (except origin — homes cursor)
///   3. Viewport content with per-cell SGR (ScreenFormatter)
///   4. Scroll region (DECSTBM/DECSLRM — homes cursor)
///   5. Tab stops (CSI 3g clear + HTS per stop — moves cursor)
///   6. ModifyOtherKeys
///   7. PWD (OSC 7)
///   8. Screen extras: style, hyperlink, protection, kitty keyboard, charsets
///   9. Origin mode (CSI ?6h — homes cursor to scroll region)
///  10. CUP (DECOM-aware cursor positioning)
///  11. Pending wrap (re-print character at cursor to set LCF)
export fn ghostty_vt_terminal_render_reattach(
    terminal_ptr: ?*anyopaque,
) callconv(.c) ghostty_vt_bytes_t {
    if (terminal_ptr == null) return .{ .ptr = null, .len = 0 };
    const handle: *TerminalHandle = @ptrCast(@alignCast(terminal_ptr.?));

    const alloc = std.heap.c_allocator;
    return renderReattach(alloc, handle) catch .{ .ptr = null, .len = 0 };
}

fn renderReattach(
    alloc: Allocator,
    handle: *TerminalHandle,
) !ghostty_vt_bytes_t {
    const modespkg = terminal.modes;
    const t = &handle.terminal;
    const screen = t.screens.active;
    const cursor = &screen.cursor;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    errdefer builder.deinit();
    const writer = &builder.writer;

    // 0. Scrollback history: render all lines above the viewport so they
    //    scroll through the client's terminal, populating its scrollback
    //    buffer with historical output. Uses ghostty's native page list
    //    which preserves per-cell SGR attributes.
    if (screen.pages.getBottomRight(.history)) |history_br| {
        const history_tl = screen.pages.getTopLeft(.history);
        var history_fmt: terminal.formatter.PageListFormatter = .init(
            &screen.pages,
            .{ .emit = .vt, .unwrap = false, .trim = false },
        );
        history_fmt.top_left = history_tl;
        history_fmt.bottom_right = history_br;
        try history_fmt.format(writer);
        // Reset SGR after scrollback so viewport redraw starts clean.
        try writer.writeAll("\x1b[0m\r\n");
    }

    // 1. Clear screen, home cursor, reset SGR.
    try writer.writeAll("\x1b[H\x1b[2J\x1b[0m");

    // 2. Non-default modes, except origin (DECOM). Origin is emitted
    //    after scroll region and tabstops because it homes the cursor.
    inline for (@typeInfo(modespkg.Mode).@"enum".fields) |field| {
        const mode: modespkg.Mode = @enumFromInt(field.value);
        if (comptime std.mem.eql(u8, field.name, "origin")) continue;
        const current = t.modes.get(mode);
        const default_val = @field(t.modes.default, field.name);
        if (current != default_val) {
            const tag: modespkg.ModeTag = @bitCast(@intFromEnum(mode));
            const prefix = if (tag.ansi) "" else "?";
            const suffix = if (current) "h" else "l";
            try writer.print("\x1b[{s}{d}{s}", .{ prefix, tag.value, suffix });
        }
    }

    // 3. Viewport content with per-cell SGR via PageListFormatter.
    //    Bounded to viewport only (not scrollback). No cursor/extra
    //    state — we handle those separately below.
    const viewport_tl = screen.pages.getTopLeft(.viewport);
    const viewport_br = screen.pages.getBottomRight(.viewport) orelse viewport_tl;
    var list_fmt: terminal.formatter.PageListFormatter = .init(&screen.pages, .{
        .emit = .vt,
        .unwrap = false,
        .trim = false,
    });
    list_fmt.top_left = viewport_tl;
    list_fmt.bottom_right = viewport_br;
    try list_fmt.format(writer);

    // 4. Scroll region: DECSTBM / DECSLRM if non-default.
    //    These home the cursor, which is fine — CUP comes later.
    const region = &t.scrolling_region;
    if (region.top != 0 or region.bottom != t.rows - 1) {
        try writer.print("\x1b[{d};{d}r", .{ region.top + 1, region.bottom + 1 });
    }
    if (region.left != 0 or region.right != t.cols - 1) {
        try writer.print("\x1b[{d};{d}s", .{ region.left + 1, region.right + 1 });
    }

    // 5. Tab stops: clear all, then set each configured stop.
    //    HTS moves cursor, which is fine — CUP comes later.
    try writer.writeAll("\x1b[3g");
    for (0..t.cols) |col| {
        if (t.tabstops.get(col)) {
            try writer.print("\x1b[{d}G\x1bH", .{col + 1});
        }
    }

    // 6. ModifyOtherKeys level 2.
    if (t.flags.modify_other_keys_2) {
        try writer.writeAll("\x1b[>4;2m");
    }

    // 7. PWD via OSC 7.
    if (t.pwd.items.len > 0) {
        try writer.print("\x1b]7;{s}\x1b\\", .{t.pwd.items});
    }

    // 8. Screen extras that do NOT move the cursor: SGR style,
    //    hyperlink, protection, kitty keyboard, charsets.
    var extras_fmt: terminal.formatter.ScreenFormatter = .init(screen, .{
        .emit = .vt,
        .unwrap = false,
        .trim = false,
    });
    extras_fmt.content = .none;
    extras_fmt.extra = .{
        .cursor = false,
        .style = true,
        .hyperlink = true,
        .protection = true,
        .kitty_keyboard = true,
        .charsets = true,
    };
    try extras_fmt.format(writer);

    // 9. Origin mode (DECOM): emitted last among modes because
    //     CSI ?6h homes cursor to scroll region origin.
    if (t.modes.get(.origin)) {
        try writer.writeAll("\x1b[?6h");
    }

    // 10. CUP — DECOM-aware cursor positioning.
    if (t.modes.get(.origin)) {
        // DECOM on: cursor position is relative to scroll region.
        const rel_y = cursor.y -| region.top;
        try writer.print("\x1b[{d};{d}H", .{ rel_y + 1, cursor.x + 1 });
    } else {
        try writer.print("\x1b[{d};{d}H", .{ cursor.y + 1, cursor.x + 1 });
    }

    // 11. Pending wrap: re-print the character at cursor to set LCF.
    //     CUP clears pending_wrap, so we must restore it by writing
    //     the same character that originally triggered it.
    if (cursor.pending_wrap) {
        const pt: terminal.point.Point = .{ .viewport = .{ .x = cursor.x, .y = cursor.y } };
        if (handle.terminal.screens.active.pages.getCell(pt)) |cell| {
            const cp = cell.cell.codepoint();
            if (cp > 0) {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch 0;
                if (len > 0) try writer.writeAll(buf[0..len]);
            }
        }
    }

    const slice = try builder.toOwnedSlice();
    return .{ .ptr = slice.ptr, .len = slice.len };
}

const ghostty_vt_bytes_t = extern struct {
    ptr: ?[*]const u8,
    len: usize,
};

export fn ghostty_vt_bytes_free(bytes: ghostty_vt_bytes_t) callconv(.c) void {
    if (bytes.ptr == null or bytes.len == 0) return;
    std.heap.c_allocator.free(bytes.ptr.?[0..bytes.len]);
}
