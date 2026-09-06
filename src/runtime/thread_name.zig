//! Native diagnostic names for the calling thread. No thread handle is owned
//! or retained; callers invoke this from their worker entry point.

const std = @import("std");
const builtin = @import("builtin");

/// Apply a bounded native label without changing thread execution or lifetime.
/// Unsupported naming is optional; unexpected native failures remain visible.
/// Trace metadata should retain the original, unshortened label.
pub fn setCurrent(name: []const u8) void {
    setCurrentImpl(name) catch |err| switch (err) {
        error.Unsupported => {},
        else => std.log.warn("Failed to name {s}: {}", .{ name, err }),
    };
}

fn setCurrentImpl(name: []const u8) std.Thread.SetNameError!void {
    if (std.Thread.max_name_len == 0) return error.Unsupported;
    // Keep the byte-limited native name valid when a label contains UTF-8.
    var len = @min(name.len, std.Thread.max_name_len);
    while (len > 0 and len < name.len and name[len] & 0xc0 == 0x80) len -= 1;
    var buffer: [std.Thread.max_name_len:0]u8 = undefined;
    @memcpy(buffer[0..len], name[0..len]);
    buffer[len] = 0;
    const label = buffer[0..len :0];

    switch (builtin.os.tag) {
        .linux => {
            _ = try std.posix.prctl(.SET_NAME, .{@intFromPtr(label.ptr)});
            return;
        },
        .windows => {
            const windows = std.os.windows;
            var wide_buffer: [std.Thread.max_name_len]u16 = undefined;
            const wide_len = try std.unicode.wtf8ToWtf16Le(&wide_buffer, label);
            switch (windows.ntdll.NtSetInformationThread(
                windows.GetCurrentThread(),
                .NameInformation,
                &windows.UNICODE_STRING.init(wide_buffer[0..wide_len]),
                @sizeOf(windows.UNICODE_STRING),
            )) {
                .SUCCESS => return,
                .NOT_IMPLEMENTED => return error.Unsupported,
                else => |status| return windows.unexpectedStatus(status),
            }
        },
        else => {},
    }
    if (!std.Thread.use_pthreads) return error.Unsupported;
    const result = switch (builtin.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => std.c.pthread_setname_np(label.ptr),
        .serenity, .dragonfly => std.c.pthread_setname_np(std.c.pthread_self(), label.ptr),
        .netbsd, .illumos => std.c.pthread_setname_np(std.c.pthread_self(), label.ptr, null),
        .freebsd, .openbsd => {
            std.c.pthread_set_name_np(std.c.pthread_self(), label.ptr);
            return;
        },
        else => return error.Unsupported,
    };
    switch (@as(std.posix.E, @enumFromInt(result))) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
}
