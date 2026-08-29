//! Owns stable numeric JavaScript identities for one DOM window generation.
//!
//! DOM Nodes live by value in relocatable child arrays. Structural mutations
//! may temporarily unpublish pointer keys, move storage, and then bind the same
//! handle to the new address before JavaScript runs again.

const std = @import("std");
const Node = @import("../document/parser.zig").Node;

pub const Store = struct {
    node_to_handle: std.AutoHashMap(*Node, u32),
    handle_to_node: std.AutoHashMap(u32, *Node),
    next_handle: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .node_to_handle = std.AutoHashMap(*Node, u32).init(allocator),
            .handle_to_node = std.AutoHashMap(u32, *Node).init(allocator),
        };
    }

    pub fn deinit(self: *Store) void {
        self.node_to_handle.deinit();
        self.handle_to_node.deinit();
    }

    /// Retire every wrapper mapping when a window installs a new document.
    pub fn clear(self: *Store) void {
        self.node_to_handle.clearRetainingCapacity();
        self.handle_to_node.clearRetainingCapacity();
        self.next_handle = 0;
    }

    /// Return the stable handle for `node`, publishing both map directions if
    /// this is the first JavaScript observation of that address.
    pub fn getOrCreate(self: *Store, node: *Node) !u32 {
        if (self.node_to_handle.get(node)) |handle| return handle;

        // Reserve both directions before publishing either half. Failure must
        // not leave a one-way identity or consume a numeric handle.
        try self.node_to_handle.ensureUnusedCapacity(1);
        try self.handle_to_node.ensureUnusedCapacity(1);
        const handle = self.next_handle;
        self.next_handle += 1;
        self.bindAssumeCapacity(node, handle);
        return handle;
    }

    pub fn handleFor(self: *const Store, node: *Node) ?u32 {
        return self.node_to_handle.get(node);
    }

    pub fn resolve(self: *const Store, handle: u32) ?*Node {
        return self.handle_to_node.get(handle);
    }

    pub fn contains(self: *const Store, node: *Node) bool {
        return self.node_to_handle.contains(node);
    }

    /// Remove only an address key immediately before moving its Node value.
    /// The reverse handle remains live and must be rebound synchronously with
    /// `bindAssumeCapacity` before control can return to JavaScript.
    pub fn unpublishPointer(self: *Store, node: *Node) ?u32 {
        return if (self.node_to_handle.fetchRemove(node)) |entry| entry.value else null;
    }

    /// Install both directions after storage has moved. Callers must have
    /// reserved capacity by creating the original handle or explicitly sizing
    /// the maps before entering their non-fallible mutation phase.
    pub fn bindAssumeCapacity(self: *Store, node: *Node, handle: u32) void {
        self.node_to_handle.putAssumeCapacity(node, handle);
        self.handle_to_node.putAssumeCapacity(handle, node);
    }

    /// Permanently make a wrapper inert rather than preserving its identity
    /// across a synchronous relocation.
    pub fn retire(self: *Store, node: *Node) void {
        if (self.unpublishPointer(node)) |handle| {
            _ = self.handle_to_node.remove(handle);
        }
    }
};

test "DOM handles survive synchronous pointer relocation" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    var before: Node = undefined;
    var after: Node = undefined;
    const handle = try store.getOrCreate(&before);
    try std.testing.expectEqual(handle, try store.getOrCreate(&before));
    try std.testing.expectEqual(&before, store.resolve(handle).?);

    try std.testing.expectEqual(handle, store.unpublishPointer(&before).?);
    store.bindAssumeCapacity(&after, handle);
    try std.testing.expect(store.handleFor(&before) == null);
    try std.testing.expectEqual(&after, store.resolve(handle).?);

    store.retire(&after);
    try std.testing.expect(store.resolve(handle) == null);
}
