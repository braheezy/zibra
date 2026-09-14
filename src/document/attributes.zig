//! Element-owned ordered attribute storage. Names and values borrow document
//! source or Element.owned_strings; this owner only allocates the index/list.
const std = @import("std");

pub const Map = struct {
    const Storage = std.array_hash_map.String([]const u8);
    allocator: std.mem.Allocator,
    storage: Storage = .empty,
    /// Changes even when authored style text is replaced with identical bytes.
    /// CSSOM may retain pending substitutions that text cannot represent.
    style_revision: u64 = 0,
    /// Attached stylesheets reselect their retained program after a media
    /// attribute mutation. The revision owns no DOM or attribute-string borrow.
    media_revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Map {
        return .{ .allocator = allocator };
    }

    /// Retire the list/index, not its borrowed strings.
    pub fn deinit(self: *Map) void {
        self.storage.deinit(self.allocator);
    }

    pub fn count(self: Map) usize {
        return self.storage.count();
    }

    pub fn get(self: Map, name: []const u8) ?[]const u8 {
        return self.storage.get(name);
    }

    pub fn contains(self: Map, name: []const u8) bool {
        return self.storage.contains(name);
    }

    /// Iteration borrows the ordered entries until any storage mutation.
    pub fn iterator(self: *const Map) Storage.Iterator {
        return self.storage.iterator();
    }

    /// Reserve before committing Element-owned strings to this borrowed view.
    pub fn ensureUnusedCapacity(self: *Map, additional: usize) !void {
        try self.storage.ensureUnusedCapacity(self.allocator, additional);
    }

    /// A replacement preserves its list position; a new name appends.
    pub fn put(self: *Map, name: []const u8, value: []const u8) !void {
        try self.storage.put(self.allocator, name, value);
        self.changed(name);
    }

    /// Requires pre-reserved capacity; does not transfer string ownership.
    pub fn putAssumeCapacity(self: *Map, name: []const u8, value: []const u8) void {
        self.storage.putAssumeCapacity(name, value);
        self.changed(name);
    }

    /// Remove without reordering the surviving attributes.
    pub fn orderedRemove(self: *Map, name: []const u8) bool {
        const removed = self.storage.orderedRemove(name);
        if (removed) self.changed(name);
        return removed;
    }

    fn changed(self: *Map, name: []const u8) void {
        if (std.mem.eql(u8, name, "style")) self.style_revision +%= 1;
        if (std.mem.eql(u8, name, "media")) self.media_revision +%= 1;
    }
};

test "attribute storage preserves insertion replacement and removal order" {
    var attributes = Map.init(std.testing.allocator);
    defer attributes.deinit();
    try attributes.put("data-z", "first");
    try attributes.put("data-a", "middle");
    try attributes.put("data-b", "last");
    try attributes.put("data-z", "updated");
    try std.testing.expect(attributes.orderedRemove("data-a"));
    try attributes.put("data-a", "reinserted");
    var it = attributes.iterator();
    try std.testing.expectEqualStrings("data-z", it.next().?.key_ptr.*);
    try std.testing.expectEqualStrings("data-b", it.next().?.key_ptr.*);
    try std.testing.expectEqualStrings("data-a", it.next().?.key_ptr.*);
    try std.testing.expectEqualStrings("updated", attributes.get("data-z").?);
    try std.testing.expect(it.next() == null);
}
