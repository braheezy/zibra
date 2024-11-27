const std = @import("std");
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const dbg = std.debug.print;
fn dbgln(comptime fmt: []const u8) void {
    dbg("{s}\n", .{fmt});
}

const Url = struct {
    scheme: ?[]const u8 = null,
    host: ?[]const u8 = null,
    path: ?[]const u8 = null,

    fn init(allocator: std.mem.Allocator, url: []const u8) !*Url {
        // make a copy of the url
        var local_url = ArrayList(u8).init(allocator);
        defer local_url.deinit();
        try local_url.appendSlice(url);

        // split the url by "://"
        var split_iter = std.mem.splitSequence(u8, local_url.items, "://");
        const scheme = split_iter.first();

        // delimter not found
        if (std.mem.eql(u8, scheme, local_url.items)) return error.NoSchemeFound;

        // we only support http
        if (!std.mem.eql(u8, scheme, "http")) return error.UnsupportedScheme;

        var u = try allocator.create(Url);

        // allocate memory for the scheme
        const scheme_alloc = try allocator.alloc(u8, scheme.len);
        @memcpy(scheme_alloc, scheme);
        u.scheme = scheme_alloc;

        // gather the rest of the url into a dynamic array
        var rest = ArrayList(u8).init(allocator);
        defer rest.deinit();
        try rest.appendSlice(split_iter.rest());

        // Append a '/' if it doesn't exist
        if (!std.mem.containsAtLeast(u8, rest.items, 1, "/")) {
            try rest.append('/');
        }

        // Split on '/' to find host
        split_iter = std.mem.splitSequence(u8, rest.items, "/");
        const host = split_iter.first();

        // allocate memory for the host
        const host_alloc = try allocator.alloc(u8, host.len);
        @memcpy(host_alloc, host);
        u.host = host_alloc;

        // everything else is the path
        // if the path is '/', then this will be an empty string
        const path = split_iter.rest();
        var path_alloc = try allocator.alloc(u8, path.len + 1);

        // Prepend a '/' to the path
        path_alloc[0] = '/';
        @memcpy(path_alloc[1..], path);

        // Allocate memory for the path
        u.path = path_alloc;

        return u;
    }

    fn free(self: *Url, allocator: std.mem.Allocator) void {
        if (self.scheme) |_| allocator.free(self.scheme.?);
        if (self.host) |_| allocator.free(self.host.?);
        if (self.path) |_| allocator.free(self.path.?);
        allocator.destroy(self);
    }
};

pub fn main() !void {
    // Memory allocation setup
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer if (gpa.deinit() == .leak) {
        std.process.exit(1);
    };

    // Read arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        // no args, exit
        std.log.err("Missing input url\n", .{});
        std.process.exit(64);
    }

    for (args[1..]) |arg| {
        const url = try Url.init(allocator, arg);
        defer url.free(allocator);
        if (url.scheme) |s| {
            dbg("Scheme: {s}\n", .{s});
            dbg("Host: {s}\n", .{url.host.?});
            dbg("Path: {s}\n", .{url.path.?});
        } else {
            dbgln("No scheme found");
            dbg("{any}\n", .{url});
        }
    }
}
