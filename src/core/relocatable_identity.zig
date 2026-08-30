//! Bidirectional identities for values that move in caller-owned storage.
//!
//! This primitive knows only how to map a pointer to an opaque scalar and
//! repair that map across one synchronous relocation. It deliberately does
//! not retain, destroy, or otherwise own the pointee. Callers must reserve
//! capacity before a non-fallible move, unpublish old addresses, and rebind
//! the same identities before a foreign callback can run.

const std = @import("std");

/// A type-erased, synchronous observer for identities whose pointee moves.
///
/// A caller installs this around a bounded operation that may relocate values
/// in caller-owned storage. `unpublish` returns an opaque scalar only when the
/// observer currently tracks the item; the caller must then either `rebind`
/// that scalar to the replacement address or `retire` it before a foreign
/// callback can observe the tree again. `item` is an address key only: a
/// capacity reservation may have made the old address non-dereferenceable
/// before the caller removes it from an identity map. The observer owns neither
/// the item nor the scalar's issuance policy.
///
/// This stays type-erased so document-local identities (for example parser
/// pins) can cross a script-owned mutation transaction without making this
/// core module depend on DOM or JavaScript types.
pub const RelocationObserver = struct {
    /// A nonzero scalar carried across exactly one synchronous move.
    pub const Token = u64;

    context: *anyopaque,
    unpublish: *const fn (context: *anyopaque, item: *anyopaque) ?Token,
    rebind: *const fn (context: *anyopaque, item: *anyopaque, token: Token) void,
    retire: *const fn (context: *anyopaque, token: Token) void,

    /// Remove `item`'s address from the observer immediately before it moves.
    /// A null return means this observer has no identity for that item.
    pub fn unpublishItem(self: RelocationObserver, item: *anyopaque) ?Token {
        return self.unpublish(self.context, item);
    }

    /// Publish `token` at `item`'s new address after a synchronous move.
    pub fn rebindItem(self: RelocationObserver, item: *anyopaque, token: Token) void {
        self.rebind(self.context, item, token);
    }

    /// Permanently invalidate an unpublished identity whose item was removed.
    pub fn retireToken(self: RelocationObserver, token: Token) void {
        self.retire(self.context, token);
    }
};

/// Construct a pointer/identity registry for one relocatable value type.
///
/// `Issuer` is intentionally duck-typed at `getOrCreate`: it needs only an
/// `issue() !Id` method. This keeps numeric lifetime policy with the domain
/// owner—for example, JavaScript handles remain unique across realms while a
/// future parser can mint independent opaque pins.
pub fn Registry(comptime Item: type, comptime Id: type) type {
    return struct {
        const Self = @This();

        pointer_to_id: std.AutoHashMap(*Item, Id),
        id_to_pointer: std.AutoHashMap(Id, *Item),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .pointer_to_id = std.AutoHashMap(*Item, Id).init(allocator),
                .id_to_pointer = std.AutoHashMap(Id, *Item).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.pointer_to_id.deinit();
            self.id_to_pointer.deinit();
        }

        /// Retire every published mapping. This never resets an issuer, so a
        /// scalar from one owner generation cannot resolve to a later one.
        pub fn clear(self: *Self) void {
            self.pointer_to_id.clearRetainingCapacity();
            self.id_to_pointer.clearRetainingCapacity();
        }

        /// Return the identity currently bound to `item`, or allocate a new
        /// one after reserving both map directions. `issuer` must provide
        /// `issue() !Id`; it is called only after allocation succeeds.
        pub fn getOrCreate(self: *Self, item: *Item, issuer: anytype) !Id {
            if (self.pointer_to_id.get(item)) |id| return id;

            try self.pointer_to_id.ensureUnusedCapacity(1);
            try self.id_to_pointer.ensureUnusedCapacity(1);
            const id = try issuer.issue();
            self.bindAssumeCapacity(item, id);
            return id;
        }

        pub fn identityFor(self: *const Self, item: *Item) ?Id {
            return self.pointer_to_id.get(item);
        }

        /// Compatibility spelling for domains that call the scalar an opaque
        /// handle. New generic callers should prefer `identityFor`.
        pub fn handleFor(self: *const Self, item: *Item) ?Id {
            return self.identityFor(item);
        }

        pub fn resolve(self: *const Self, id: Id) ?*Item {
            return self.id_to_pointer.get(id);
        }

        pub fn contains(self: *const Self, item: *Item) bool {
            return self.pointer_to_id.contains(item);
        }

        /// Remove an old pointer key immediately before moving its value. The
        /// reverse identity remains valid only until `bindAssumeCapacity`
        /// installs the replacement address synchronously.
        pub fn unpublishPointer(self: *Self, item: *Item) ?Id {
            return if (self.pointer_to_id.fetchRemove(item)) |entry| entry.value else null;
        }

        /// Install both map directions after a caller-controlled move. The
        /// caller must have reserved map capacity before its mutation phase.
        pub fn bindAssumeCapacity(self: *Self, item: *Item, id: Id) void {
            self.pointer_to_id.putAssumeCapacity(item, id);
            self.id_to_pointer.putAssumeCapacity(id, item);
        }

        /// Permanently retire one identity rather than preserving it across a
        /// relocation. Any external wrapper/pin becomes inert.
        pub fn retire(self: *Self, item: *Item) void {
            const id = self.identityFor(item) orelse return;
            self.retireIdentity(id);
        }

        /// Permanently retire `id`, whether its pointer is currently
        /// published or has already been unpublished for a relocation that
        /// will not complete. This removes both directions without
        /// dereferencing the stored pointer.
        pub fn retireIdentity(self: *Self, id: Id) void {
            if (self.id_to_pointer.fetchRemove(id)) |entry| {
                _ = self.pointer_to_id.remove(entry.value);
            }
        }
    };
}

test "registry preserves an issued identity across caller-controlled relocation" {
    const Issuer = struct {
        next: u32 = 1,

        fn issue(self: *@This()) !u32 {
            const value = self.next;
            self.next += 1;
            return value;
        }
    };

    var registry = Registry(u8, u32).init(std.testing.allocator);
    defer registry.deinit();
    var issuer = Issuer{};
    var before: u8 = 1;
    var after: u8 = 2;

    const id = try registry.getOrCreate(&before, &issuer);
    try std.testing.expectEqual(id, registry.identityFor(&before).?);
    try std.testing.expectEqual(id, registry.unpublishPointer(&before).?);
    registry.bindAssumeCapacity(&after, id);

    try std.testing.expect(registry.identityFor(&before) == null);
    try std.testing.expectEqual(&after, registry.resolve(id).?);
    registry.retire(&after);
    try std.testing.expect(registry.resolve(id) == null);
}

test "registry retires an identity after its pointer is unpublished" {
    var registry = Registry(u8, u32).init(std.testing.allocator);
    defer registry.deinit();
    const Issuer = struct {
        fn issue(_: *@This()) !u32 {
            return 17;
        }
    };
    var issuer = Issuer{};
    var value: u8 = 0;

    const id = try registry.getOrCreate(&value, &issuer);
    try std.testing.expectEqual(id, registry.unpublishPointer(&value).?);
    registry.retireIdentity(id);

    try std.testing.expect(registry.identityFor(&value) == null);
    try std.testing.expect(registry.resolve(id) == null);
}
