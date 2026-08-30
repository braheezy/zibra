//! Owns immutable HTML source chunks for one document generation.
//!
//! Parser-created DOM strings may borrow a chunk for the lifetime of the
//! document. Later parser-inserted input therefore becomes a separate owned
//! chunk instead of resizing or replacing earlier bytes.

const std = @import("std");

/// A document-local, append-only collection of independently allocated HTML
/// source chunks. Callers transfer ownership of adopted chunks exactly once.
pub const Store = struct {
    allocator: std.mem.Allocator,
    chunks: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        self.clear();
        self.chunks.deinit(self.allocator);
    }

    /// Release every source chunk after all DOM consumers of this generation
    /// have retired. This invalidates every slice previously returned by the
    /// store.
    pub fn clear(self: *Store) void {
        for (self.chunks.items) |chunk| self.allocator.free(chunk);
        self.chunks.clearRetainingCapacity();
    }

    /// Reserve chunk-list capacity before a non-fallible ownership transfer.
    /// This lets a parser finish building a DOM that borrows `source` before
    /// the source becomes this document's permanent owner.
    pub fn ensureUnusedCapacity(self: *Store, additional: usize) !void {
        try self.chunks.ensureUnusedCapacity(self.allocator, additional);
    }

    /// Transfer an already allocated source chunk into this document. The
    /// caller must not free or mutate `source` after a successful call.
    pub fn adopt(self: *Store, source: []u8) !usize {
        try self.chunks.append(self.allocator, source);
        return self.chunks.items.len - 1;
    }

    /// Like `adopt`, but requires capacity reserved by
    /// `ensureUnusedCapacity`. The caller transfers `source` exactly once.
    pub fn adoptAssumeCapacity(self: *Store, source: []u8) usize {
        self.chunks.appendAssumeCapacity(source);
        return self.chunks.items.len - 1;
    }

    /// Copy transient input into a new stable chunk and return its document
    /// local index. This is the entry point parser-active `document.write`
    /// will use once ParserSession consumes more than the initial input.
    pub fn appendCopy(self: *Store, source: []const u8) !usize {
        const owned = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(owned);
        return self.adopt(owned);
    }

    /// Borrow one stable source chunk by its document-local index.
    pub fn get(self: *const Store, index: usize) []const u8 {
        return self.chunks.items[index];
    }

    /// Borrow the initial network/document source, if one has been installed.
    pub fn initial(self: *const Store) ?[]const u8 {
        if (self.chunks.items.len == 0) return null;
        return self.chunks.items[0];
    }
};

test "HTML source chunks retain earlier DOM borrows across later appends" {
    var source = Store.init(std.testing.allocator);
    defer source.deinit();

    const initial = try std.testing.allocator.dupe(u8, "<p>before");
    const initial_index = try source.adopt(initial);
    const initial_borrow = source.get(initial_index);

    const written_index = try source.appendCopy(" after</p>");

    try std.testing.expectEqualStrings("<p>before", initial_borrow);
    try std.testing.expectEqualStrings(" after</p>", source.get(written_index));
    try std.testing.expectEqualStrings("<p>before", source.initial().?);
}
