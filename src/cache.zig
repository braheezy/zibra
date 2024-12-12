// To support caching web pages that don't change often, we'll use an in-memory
// key-value store. The key will be the URL and the value will be a struct holdig the body,
// timestamp, and max-age of the response.
// To prevent growing too large...
const std = @import("std");
const StringHashMap = std.StringHashMap;

const dbg = std.debug.print;

fn dbgln(comptime fmt: []const u8) void {
    dbg("{s}\n", .{fmt});
}

pub const CacheEntry = struct {
    body: []const u8,
    timestampe: u64,
    max_age: ?u64,
};

pub const Cache = struct {
    // key is the URL
    map: std.StringHashMap(CacheEntry),

    pub fn init(allocator: std.mem.Allocator) !Cache {
        return Cache{
            .map = StringHashMap(CacheEntry).init(allocator),
        };
    }

    pub fn free(self: *Cache) void {
        self.map.deinit();
    }

    pub fn get(self: *Cache, url: []const u8) ?CacheEntry {
        return self.map.get(url);
    }

    pub fn set(self: *Cache, url: []const u8, entry: CacheEntry) !void {
        try self.map.put(url, entry);
    }

    pub fn evict_if_needed(self: *Cache, max_size: usize) void {
        if (self.map.count() == 0) {
            return;
        }
        while (self.map.count() > max_size) {
            // Remove entries with oldest timestamp
            var oldest_key: []const u8 = undefined;
            var oldest_timestamp: u64 = std.math.maxInt(u64);
            var it = self.map.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const value = entry.value_ptr.*;
                if (value.timestampe < oldest_timestamp) {
                    oldest_key = key;
                    oldest_timestamp = value.timestampe;
                }
            }
            _ = self.map.remove(oldest_key);
        }
    }
};
