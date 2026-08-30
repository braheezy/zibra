//! Owns stable numeric JavaScript identities for one DOM window generation.
//!
//! DOM Nodes live by value in relocatable child arrays. Structural mutations
//! may temporarily unpublish pointer keys, move storage, and then bind the same
//! handle to the new address before JavaScript runs again.

const std = @import("std");
const Node = @import("../document/parser.zig").Node;
const relocatable_identity = @import("../core/relocatable_identity.zig");

/// A JavaScript-safe opaque node identity. All u32 values are exactly
/// representable by a JavaScript Number.
pub const Id = u32;

/// Mints node identities for one JavaScript host. The issuer deliberately
/// outlives individual WindowRealms and document generations so a stale page
/// wrapper can never resolve to a later document's node.
pub const IdIssuer = struct {
    next: Id = 1,

    pub fn issue(self: *IdIssuer) std.mem.Allocator.Error!Id {
        // Reserve zero as an invalid/default value in host-facing diagnostics.
        if (self.next == std.math.maxInt(Id)) return error.OutOfMemory;
        const id = self.next;
        self.next += 1;
        return id;
    }
};

/// Stable JavaScript-handle mapping over the shared relocatable identity
/// primitive. The host-wide `IdIssuer` supplies its no-reuse policy.
pub const Store = relocatable_identity.Registry(Node, Id);

test "DOM handles survive synchronous pointer relocation" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    var issuer = IdIssuer{};

    var before: Node = undefined;
    var after: Node = undefined;
    const handle = try store.getOrCreate(&before, &issuer);
    try std.testing.expectEqual(handle, try store.getOrCreate(&before, &issuer));
    try std.testing.expectEqual(&before, store.resolve(handle).?);

    try std.testing.expectEqual(handle, store.unpublishPointer(&before).?);
    store.bindAssumeCapacity(&after, handle);
    try std.testing.expect(store.handleFor(&before) == null);
    try std.testing.expectEqual(&after, store.resolve(handle).?);

    store.retire(&after);
    try std.testing.expect(store.resolve(handle) == null);
}

test "DOM handles never retarget across document retirement" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    var issuer = IdIssuer{};

    var first: Node = undefined;
    var second: Node = undefined;
    const first_handle = try store.getOrCreate(&first, &issuer);
    store.clear();

    const second_handle = try store.getOrCreate(&second, &issuer);
    try std.testing.expect(second_handle != first_handle);
    try std.testing.expect(store.resolve(first_handle) == null);
    try std.testing.expectEqual(&second, store.resolve(second_handle).?);
}

test "one issuer makes handles unique across WindowRealm stores" {
    var first_store = Store.init(std.testing.allocator);
    defer first_store.deinit();
    var second_store = Store.init(std.testing.allocator);
    defer second_store.deinit();
    var issuer = IdIssuer{};

    var first: Node = undefined;
    var second: Node = undefined;
    const first_handle = try first_store.getOrCreate(&first, &issuer);
    const second_handle = try second_store.getOrCreate(&second, &issuer);

    try std.testing.expect(first_handle != second_handle);
    try std.testing.expect(second_store.resolve(first_handle) == null);
    try std.testing.expectEqual(&second, second_store.resolve(second_handle).?);
}
