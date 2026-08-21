//! Browser-session HTTP response cache and Cache-Control policy parsing.
//!
//! Entries own their URL key, decoded response body, CSP header, and final
//! redirect URL. They also retain response policies needed when recreating a
//! document fetch. `lookup` returns borrowed entry data; callers must copy any
//! fields that need to outlive the next cache mutation.

const std = @import("std");

/// The Referrer-Policy values understood by Zibra. `default` preserves the
/// tutorial's behavior of sending the source URL to any HTTP(S) destination.
pub const ReferrerPolicy = enum {
    default,
    no_referrer,
    same_origin,
};

/// The subset of Cache-Control understood by Zibra.
pub const CacheControl = union(enum) {
    /// No Cache-Control header was present. The exercise permits caching the
    /// response for the lifetime of this browser session.
    default,
    no_store,
    max_age: u64,
    /// At least one unsupported or malformed directive was present.
    unsupported,

    /// Merge one Cache-Control header value into this response's policy.
    /// Unsupported directives are sticky and prevent caching the response.
    pub fn apply(self: *CacheControl, value: []const u8) void {
        if (self.* == .unsupported) return;

        var saw_directive = false;
        var directives = std.mem.splitScalar(u8, value, ',');
        while (directives.next()) |raw_directive| {
            const directive = std.mem.trim(u8, raw_directive, " \t");
            if (directive.len == 0) {
                self.* = .unsupported;
                return;
            }
            saw_directive = true;

            if (std.mem.indexOfScalar(u8, directive, '=')) |equals| {
                const name = std.mem.trim(u8, directive[0..equals], " \t");
                var raw_value = std.mem.trim(u8, directive[equals + 1 ..], " \t");
                if (!std.ascii.eqlIgnoreCase(name, "max-age")) {
                    self.* = .unsupported;
                    return;
                }
                if (raw_value.len >= 2 and raw_value[0] == '"' and raw_value[raw_value.len - 1] == '"') {
                    raw_value = raw_value[1 .. raw_value.len - 1];
                }
                const seconds = std.fmt.parseInt(u64, raw_value, 10) catch {
                    self.* = .unsupported;
                    return;
                };

                self.* = switch (self.*) {
                    .default => .{ .max_age = seconds },
                    .max_age => |existing| .{ .max_age = @min(existing, seconds) },
                    .no_store => .no_store,
                    .unsupported => unreachable,
                };
            } else if (std.ascii.eqlIgnoreCase(directive, "no-store")) {
                self.* = .no_store;
            } else {
                self.* = .unsupported;
                return;
            }
        }

        if (!saw_directive) self.* = .unsupported;
    }

    pub fn isCacheable(self: CacheControl) bool {
        return switch (self) {
            .default, .max_age => true,
            .no_store, .unsupported => false,
        };
    }
};

pub const HttpCache = struct {
    const Entry = struct {
        body: []u8,
        csp_header: ?[]u8,
        final_url: ?[]u8,
        policy: CacheControl,
        referrer_policy: ReferrerPolicy,
        expires_at_ns: ?i96,
    };

    allocator: std.mem.Allocator,
    entries: std.StringHashMap(Entry),

    pub fn init(allocator: std.mem.Allocator) HttpCache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(Entry).init(allocator),
        };
    }

    pub fn deinit(self: *HttpCache) void {
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.freeEntry(entry.value_ptr.*);
        }
        self.entries.deinit();
    }

    /// Return a borrowed entry if it is still fresh. Expired entries are
    /// removed immediately so their allocations do not accumulate.
    pub fn lookup(self: *HttpCache, url: []const u8, now_ns: i96) ?Entry {
        const entry = self.entries.get(url) orelse return null;
        if (entry.expires_at_ns) |expires_at_ns| {
            if (now_ns >= expires_at_ns) {
                const removed = self.entries.fetchRemove(url).?;
                self.allocator.free(removed.key);
                self.freeEntry(removed.value);
                return null;
            }
        }
        return entry;
    }

    /// Store owned copies of the response metadata needed to reproduce a
    /// normal fetch result. Replacing an entry releases the previous value.
    pub fn store(
        self: *HttpCache,
        url: []const u8,
        body: []const u8,
        csp_header: ?[]const u8,
        final_url: ?[]const u8,
        policy: CacheControl,
        referrer_policy: ReferrerPolicy,
        now_ns: i96,
    ) !void {
        std.debug.assert(policy.isCacheable());

        const body_copy = try self.allocator.dupe(u8, body);
        errdefer self.allocator.free(body_copy);
        const csp_copy = if (csp_header) |header| try self.allocator.dupe(u8, header) else null;
        errdefer if (csp_copy) |header| self.allocator.free(header);
        const final_url_copy = if (final_url) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (final_url_copy) |value| self.allocator.free(value);

        const expires_at_ns: ?i96 = switch (policy) {
            .default => null,
            .max_age => |seconds| now_ns +| (@as(i96, @intCast(seconds)) * std.time.ns_per_s),
            .no_store, .unsupported => unreachable,
        };
        const new_entry = Entry{
            .body = body_copy,
            .csp_header = csp_copy,
            .final_url = final_url_copy,
            .policy = policy,
            .referrer_policy = referrer_policy,
            .expires_at_ns = expires_at_ns,
        };

        if (self.entries.getPtr(url)) |existing| {
            self.freeEntry(existing.*);
            existing.* = new_entry;
            return;
        }

        const url_copy = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(url_copy);
        try self.entries.put(url_copy, new_entry);
    }

    fn freeEntry(self: *HttpCache, entry: Entry) void {
        self.allocator.free(entry.body);
        if (entry.csp_header) |header| self.allocator.free(header);
        if (entry.final_url) |url| self.allocator.free(url);
    }
};

test "Cache-Control accepts only no-store and max-age" {
    var policy: CacheControl = .default;
    policy.apply("max-age = \"120\"");
    try std.testing.expectEqual(@as(u64, 120), policy.max_age);

    policy.apply("MAX-AGE=60");
    try std.testing.expectEqual(@as(u64, 60), policy.max_age);

    policy.apply("no-store");
    try std.testing.expectEqual(CacheControl.no_store, policy);

    var unsupported: CacheControl = .default;
    unsupported.apply("max-age=60, public");
    try std.testing.expectEqual(CacheControl.unsupported, unsupported);

    var malformed: CacheControl = .default;
    malformed.apply("max-age=tomorrow");
    try std.testing.expectEqual(CacheControl.unsupported, malformed);
}

test "HTTP cache expires max-age entries and retains default entries" {
    var cache = HttpCache.init(std.testing.allocator);
    defer cache.deinit();

    try cache.store("https://example.com/default", "default", null, null, .default, .same_origin, 10);
    try std.testing.expectEqualStrings("default", cache.lookup("https://example.com/default", 1_000_000).?.body);
    try std.testing.expectEqual(ReferrerPolicy.same_origin, cache.lookup("https://example.com/default", 1_000_000).?.referrer_policy);

    try cache.store("https://example.com/timed", "timed", null, null, .{ .max_age = 2 }, .default, 10);
    try std.testing.expect(cache.lookup("https://example.com/timed", 10 + std.time.ns_per_s) != null);
    try std.testing.expect(cache.lookup("https://example.com/timed", 10 + 2 * std.time.ns_per_s) == null);
}
