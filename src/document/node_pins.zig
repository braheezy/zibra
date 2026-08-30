//! Opaque parser-local identities for relocatable DOM Nodes.
//!
//! A live parser may need to remember a tree-builder insertion point while a
//! script synchronously mutates `Element.children`, whose by-value Node
//! storage can move. `Store` owns only the bidirectional identity maps and a
//! parser-local issuer; it never retains a Node, source chunk, or parser.
//! Pins are valid solely while their Store is live and must not escape a
//! parser callback or be used after document retirement.

const std = @import("std");
const Node = @import("dom.zig").Node;
const relocatable_identity = @import("../core/relocatable_identity.zig");

/// An opaque identity for one Node within one live parser Store.
///
/// Zero is invalid. Numeric values are intentionally local to a Store: a pin
/// is meaningful only when resolved through the parser that issued it.
pub const Pin = enum(u32) {
    invalid = 0,
    _,
};

const IdentityRegistry = relocatable_identity.Registry(Node, Pin);

/// Mints pins without reuse for the lifetime of one Store.
///
/// `retireAll` clears bindings but does not reset this issuer, so an old pin
/// cannot accidentally resolve to a node from a later parser document using
/// the same Store.
const Issuer = struct {
    next: u32 = 1,

    pub fn issue(self: *Issuer) std.mem.Allocator.Error!Pin {
        if (self.next == std.math.maxInt(u32)) return error.OutOfMemory;
        const value = self.next;
        self.next += 1;
        return @enumFromInt(value);
    }
};

/// A scalar token held only across a synchronous Node-storage relocation.
///
/// Call `rebindAfterRelocation` with this token before allowing a parser,
/// script, or another callback to observe the tree. If the moved node is
/// discarded instead, call `retireRelocation`.
pub const Relocation = struct {
    pin: Pin,
};

/// Parser-owned pin table for one live document tree.
///
/// The table is non-owning: DOM retirement must call `retireAll` or `deinit`
/// before the DOM/source generation is destroyed. Every structural move must
/// unpublish the old pointer before storage moves and rebind the returned
/// token to its new address synchronously. The table must never be consulted
/// during that gap.
pub const Store = struct {
    identities: IdentityRegistry,
    issuer: Issuer = .{},

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .identities = IdentityRegistry.init(allocator) };
    }

    /// Release map storage. The Store owns no Node or HTML-source memory.
    pub fn deinit(self: *Store) void {
        self.identities.deinit();
    }

    /// Return the existing pin for `node`, or mint one for this parser Store.
    ///
    /// The caller must not retain `node` beyond the current synchronous DOM
    /// transaction; retain the returned Pin instead and resolve it only while
    /// the Store remains live and no relocation is in progress.
    pub fn pin(self: *Store, node: *Node) std.mem.Allocator.Error!Pin {
        return self.identities.getOrCreate(node, &self.issuer);
    }

    /// Return the currently published pin for `node` without allocating.
    pub fn pinFor(self: *const Store, node: *Node) ?Pin {
        return self.identities.identityFor(node);
    }

    /// Resolve a live pin to its current synchronous Node borrow.
    ///
    /// Do not call this after `unpublishForRelocation` until the matching
    /// `rebindAfterRelocation`, even though the registry temporarily retains
    /// the old pointer to preserve the pin identity.
    pub fn resolve(self: *const Store, node_pin: Pin) ?*Node {
        if (node_pin == .invalid) return null;
        return self.identities.resolve(node_pin);
    }

    /// Unpublish `node` immediately before its containing storage moves.
    ///
    /// The returned scalar contains no raw pointer and is safe to carry across
    /// the move. No foreign callback may run until it is rebound or retired.
    pub fn unpublishForRelocation(self: *Store, node: *Node) ?Relocation {
        const node_pin = self.identities.unpublishPointer(node) orelse return null;
        return .{ .pin = node_pin };
    }

    /// Bind an unpublished relocation token to `node`'s new address.
    ///
    /// The caller must invoke this synchronously after the move and before
    /// yielding control. `unpublishForRelocation` leaves capacity available
    /// for this replacement binding, so this operation cannot allocate.
    pub fn rebindAfterRelocation(self: *Store, node: *Node, relocation: Relocation) void {
        std.debug.assert(relocation.pin != .invalid);
        std.debug.assert(self.identities.identityFor(node) == null);
        std.debug.assert(self.identities.resolve(relocation.pin) != null);
        self.identities.bindAssumeCapacity(node, relocation.pin);
    }

    /// Permanently retire the pin currently published for `node`.
    pub fn retireNode(self: *Store, node: *Node) void {
        self.identities.retire(node);
    }

    /// Permanently retire a relocation whose node will not be rebound.
    ///
    /// This is the required failure/deletion path after
    /// `unpublishForRelocation`; it removes the reverse mapping too, so a
    /// stale parser token cannot resolve through this Store.
    pub fn retireRelocation(self: *Store, relocation: Relocation) void {
        self.identities.retireIdentity(relocation.pin);
    }

    /// Retire every live parser pin while preserving the no-reuse issuer.
    ///
    /// Call this before the source DOM generation is destroyed or whenever a
    /// parser session abandons its partially built tree.
    pub fn retireAll(self: *Store) void {
        self.identities.clear();
    }

    /// Expose this Store through the generic synchronous relocation contract.
    ///
    /// A live parser can install the returned observer only while directly
    /// evaluating one parser-blocking script. The script host carries opaque
    /// scalar tokens across child-array moves; it never receives a parser
    /// pointer or imports this module.
    pub fn relocationObserver(self: *Store) relocatable_identity.RelocationObserver {
        return .{
            .context = self,
            .unpublish = observerUnpublish,
            .rebind = observerRebind,
            .retire = observerRetire,
        };
    }
};

fn observerStore(context: *anyopaque) *Store {
    const unaligned: *align(1) Store = @ptrCast(context);
    return @alignCast(unaligned);
}

fn observerNode(item: *anyopaque) *Node {
    const unaligned: *align(1) Node = @ptrCast(item);
    return @alignCast(unaligned);
}

fn observerPin(token: relocatable_identity.RelocationObserver.Token) Pin {
    std.debug.assert(token > 0);
    std.debug.assert(token <= std.math.maxInt(u32));
    return @enumFromInt(@as(u32, @intCast(token)));
}

fn observerUnpublish(
    context: *anyopaque,
    item: *anyopaque,
) ?relocatable_identity.RelocationObserver.Token {
    const relocation = observerStore(context).unpublishForRelocation(observerNode(item)) orelse return null;
    return @intFromEnum(relocation.pin);
}

fn observerRebind(
    context: *anyopaque,
    item: *anyopaque,
    token: relocatable_identity.RelocationObserver.Token,
) void {
    observerStore(context).rebindAfterRelocation(observerNode(item), .{ .pin = observerPin(token) });
}

fn observerRetire(
    context: *anyopaque,
    token: relocatable_identity.RelocationObserver.Token,
) void {
    observerStore(context).retireRelocation(.{ .pin = observerPin(token) });
}

fn textNode(text: []const u8) Node {
    return .{ .text = .{ .text = text } };
}

test "parser pins preserve identity through a synchronous relocation" {
    var pins = Store.init(std.testing.allocator);
    defer pins.deinit();
    var before = textNode("before");
    var after = textNode("after");

    const pin = try pins.pin(&before);
    try std.testing.expectEqual(pin, try pins.pin(&before));
    const relocation = pins.unpublishForRelocation(&before).?;
    try std.testing.expectEqual(pin, relocation.pin);
    try std.testing.expect(pins.pinFor(&before) == null);

    pins.rebindAfterRelocation(&after, relocation);
    try std.testing.expectEqual(pin, pins.pinFor(&after).?);
    try std.testing.expectEqual(&after, pins.resolve(pin).?);

    pins.retireNode(&after);
    try std.testing.expect(pins.resolve(pin) == null);
}

test "parser pins retire an abandoned relocation" {
    var pins = Store.init(std.testing.allocator);
    defer pins.deinit();
    var node = textNode("discarded");

    const pin = try pins.pin(&node);
    const relocation = pins.unpublishForRelocation(&node).?;
    pins.retireRelocation(relocation);

    try std.testing.expect(pins.pinFor(&node) == null);
    try std.testing.expect(pins.resolve(pin) == null);
}

test "parser pin retirement does not reuse stale identities" {
    var pins = Store.init(std.testing.allocator);
    defer pins.deinit();
    var first = textNode("first");
    var second = textNode("second");

    const first_pin = try pins.pin(&first);
    pins.retireAll();
    const second_pin = try pins.pin(&second);

    try std.testing.expect(first_pin != second_pin);
    try std.testing.expect(pins.resolve(first_pin) == null);
    try std.testing.expectEqual(&second, pins.resolve(second_pin).?);
}

test "parser pins adapt to the generic relocation observer" {
    var pins = Store.init(std.testing.allocator);
    defer pins.deinit();
    var before = textNode("before");
    var moved = textNode("moved");
    var discarded = textNode("discarded");

    const retained_pin = try pins.pin(&before);
    const discarded_pin = try pins.pin(&discarded);
    const observer = pins.relocationObserver();

    const retained_token = observer.unpublishItem(@ptrCast(&before)).?;
    observer.rebindItem(@ptrCast(&moved), retained_token);
    try std.testing.expectEqual(retained_pin, pins.pinFor(&moved).?);
    try std.testing.expectEqual(&moved, pins.resolve(retained_pin).?);

    const discarded_token = observer.unpublishItem(@ptrCast(&discarded)).?;
    observer.retireToken(discarded_token);
    try std.testing.expect(pins.resolve(discarded_pin) == null);
}
