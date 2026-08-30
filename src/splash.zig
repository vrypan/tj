//! Short, deliberate confirmation that a journal writer is about to start.
//!
//! This lives in `tjctl`, not the shell plugin: every supported shell and an
//! explicitly supplied child command get the same indication. Zooi owns the
//! raw-mode and alternate-screen lifecycle, including resize handling.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const zooi = @import("zooi");

pub const Choice = enum { proceed, cancel };

const fatal_signals = [_]posix.SIG{ .TERM, .HUP, .INT, .QUIT };

pub fn show(gpa: std.mem.Allocator, journal: []const u8, next: u32) !Choice {
    var previous: [fatal_signals.len]posix.Sigaction = undefined;
    installSignalHandlers(&previous);
    defer restoreSignalHandlers(&previous);

    var ui = try zooi.Ui.init(gpa, .{});
    defer ui.deinit();

    try render(journal, next, ui.screen());
    while (try ui.nextEvent()) |event| switch (event) {
        .resize => try render(journal, next, ui.screen()),
        .key => |key| switch (key) {
            .enter => return .proceed,
            .ctrl_c, .escape => return .cancel,
            else => {},
        },
    };
    return .cancel;
}

const title_style: zooi.Style = .{ .bold = true, .fg = .{ .ansi = 6 } };
const detail_style: zooi.Style = .{ .dim = true };

fn render(journal: []const u8, next: u32, screen: *zooi.Screen) !void {
    var next_buf: [32]u8 = undefined;
    const next_line = try std.fmt.bufPrint(&next_buf, "Next entry: @{d}", .{next});

    screen.begin();
    const rows = screen.size.rows;
    const first_row: u16 = if (rows > 7) (rows - 7) / 2 else 0;
    centered(screen, first_row, "TJ", title_style);
    centered(screen, first_row +| 2, "Recording journal", .{});
    centered(screen, first_row +| 3, journal, title_style);
    centered(screen, first_row +| 4, next_line, detail_style);
    centered(screen, first_row +| 6, "Press ENTER to continue", .{ .bold = true });
    try screen.present();
}

fn centered(screen: *zooi.Screen, row: u16, text: []const u8, style: zooi.Style) void {
    if (row >= screen.size.rows) return;
    const width = zooi.displayWidth(text);
    const col: u16 = if (width < screen.size.cols)
        @intCast((@as(usize, screen.size.cols) - width) / 2)
    else
        0;
    screen.move(row, col);
    screen.writeStyled(text, style);
}

fn installSignalHandlers(previous: *[fatal_signals.len]posix.Sigaction) void {
    const action: posix.Sigaction = .{
        .handler = .{ .handler = onFatalSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    for (fatal_signals, 0..) |signal, i| posix.sigaction(signal, &action, &previous[i]);
}

fn restoreSignalHandlers(previous: *const [fatal_signals.len]posix.Sigaction) void {
    for (fatal_signals, 0..) |signal, i| posix.sigaction(signal, &previous[i], null);
}

fn onFatalSignal(signal: posix.SIG) callconv(.c) void {
    zooi.restore();
    c._exit(@intCast(128 + @intFromEnum(signal)));
}
