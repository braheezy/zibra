//! Joint root/iframe session-history ownership and index transitions.
//!
//! Entries own their URLs, request bodies, frame paths, and prior subtree
//! snapshots. `State` is independent of live `Frame` pointers so document
//! replacement cannot leave history pointing into a retired frame tree.

const std = @import("std");
const Url = @import("../network/url.zig").Url;

pub const Direction = enum {
    back,
    forward,
};

pub const Navigation = enum {
    push,
    replay,
};

pub const Method = enum {
    get,
    post,
};

/// Owned request state for one frame subtree immediately before navigation.
/// Child indexes are implicit in `children` order and survive Frame moves.
pub const FrameSnapshot = struct {
    url: *Url,
    method: Method,
    post_body: ?[]u8,
    children: std.ArrayList(*FrameSnapshot),

    pub fn deinit(self: *FrameSnapshot, allocator: std.mem.Allocator) void {
        for (self.children.items) |child| child.deinit(allocator);
        self.children.deinit(allocator);
        if (self.post_body) |body| allocator.free(body);
        self.url.*.free(allocator);
        allocator.destroy(self.url);
        allocator.destroy(self);
    }

    pub fn containsPost(self: *const FrameSnapshot) bool {
        if (self.method == .post) return true;
        for (self.children.items) |child| {
            if (child.containsPost()) return true;
        }
        return false;
    }
};

/// One replayable navigation. Frame identity is an owned child-index path
/// from the root rather than a raw pointer into a replaceable frame tree.
pub const Entry = struct {
    url: *Url,
    method: Method,
    post_body: ?[]u8,
    target_path: []usize,
    replaces_document: bool,
    previous: ?*FrameSnapshot,

    pub fn prepare(
        allocator: std.mem.Allocator,
        url: *const Url,
        payload: ?[]const u8,
        target_path: []const usize,
        replaces_document: bool,
        previous: ?*FrameSnapshot,
    ) !*Entry {
        const entry = try allocator.create(Entry);
        errdefer allocator.destroy(entry);

        const url_ptr = try allocator.create(Url);
        errdefer allocator.destroy(url_ptr);
        url_ptr.* = try url.*.clone(allocator);
        errdefer url_ptr.*.free(allocator);

        const body_copy = if (payload) |body| try allocator.dupe(u8, body) else null;
        errdefer if (body_copy) |body| allocator.free(body);
        const path_copy = try allocator.dupe(usize, target_path);
        entry.* = .{
            .url = url_ptr,
            .method = if (payload == null) .get else .post,
            .post_body = body_copy,
            .target_path = path_copy,
            .replaces_document = replaces_document,
            .previous = previous,
        };
        return entry;
    }

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        if (self.post_body) |body| allocator.free(body);
        if (self.previous) |snapshot| snapshot.deinit(allocator);
        allocator.free(self.target_path);
        self.url.*.free(allocator);
        allocator.destroy(self.url);
        allocator.destroy(self);
    }
};

/// A history mutation whose fallible URL/body/path copies were completed
/// before the caller began retiring the currently installed document.
pub const PreparedNavigation = struct {
    entry: ?*Entry,

    pub fn deinit(self: *PreparedNavigation, allocator: std.mem.Allocator) void {
        const entry = self.entry orelse return;
        entry.deinit(allocator);
        self.entry = null;
    }
};

pub const TraversalTarget = struct {
    index: usize,
    generation: u64,
    method: Method,
};

/// Standalone owner for the tab-wide joint session history. Atomic
/// availability flags are the only history state read by the UI thread; all
/// list/index mutations stay on the serialized Tab worker.
pub const State = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(*Entry) = .empty,
    index: ?usize = null,
    can_go_back: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    can_go_forward: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Invalidates a pending native POST-resubmission decision when history
    /// changes while the dialog is open.
    generation: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        for (self.entries.items) |entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn reserveEntry(self: *State) !void {
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
    }

    pub fn canGoBack(self: *const State) bool {
        return self.can_go_back.load(.acquire);
    }

    pub fn canGoForward(self: *const State) bool {
        return self.can_go_forward.load(.acquire);
    }

    pub fn isAdjacentTarget(self: *const State, target: usize) bool {
        const current = self.index orelse return false;
        return (current > 0 and target == current - 1) or
            (current + 1 < self.entries.items.len and target == current + 1);
    }

    pub fn traversalTarget(self: *const State, direction: Direction) ?TraversalTarget {
        const current = self.index orelse return null;
        const index = switch (direction) {
            .back => if (current > 0) current - 1 else null,
            .forward => if (current + 1 < self.entries.items.len) current + 1 else null,
        } orelse return null;
        const action = self.entries.items[if (direction == .back) current else index];
        const method: Method = if (!action.replaces_document)
            .get
        else if (direction == .forward)
            action.method
        else if (action.previous) |snapshot|
            if (snapshot.containsPost()) .post else .get
        else
            self.entries.items[index].method;
        return .{
            .index = index,
            .generation = self.generation,
            .method = method,
        };
    }

    /// Transfer a reserved, fully prepared entry without allocation and
    /// discard the obsolete forward branch.
    pub fn commit(self: *State, prepared: *PreparedNavigation) void {
        const entry = prepared.entry orelse return;
        const retained_len = if (self.index) |index| index + 1 else 0;
        while (self.entries.items.len > retained_len) {
            const stale = self.entries.pop().?;
            stale.deinit(self.allocator);
        }
        self.entries.appendAssumeCapacity(entry);
        self.index = self.entries.items.len - 1;
        prepared.entry = null;
        self.advanceGeneration();
        self.publishAvailability();
    }

    /// Publish a successfully reconstructed adjacent history state. The
    /// index changes only after every frame replay has completed.
    pub fn finishTraversal(self: *State, target: usize, generation: u64) bool {
        if (generation != self.generation or !self.isAdjacentTarget(target)) return false;
        self.index = target;
        self.advanceGeneration();
        self.publishAvailability();
        return true;
    }

    fn advanceGeneration(self: *State) void {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
    }

    fn publishAvailability(self: *State) void {
        const current = self.index;
        self.can_go_back.store(current != null and current.? > 0, .release);
        self.can_go_forward.store(
            current != null and current.? + 1 < self.entries.items.len,
            .release,
        );
    }
};

pub fn pathsEqual(left: []const usize, right: []const usize) bool {
    return std.mem.eql(usize, left, right);
}

pub fn pathIsPrefix(prefix: []const usize, path: []const usize) bool {
    return prefix.len <= path.len and std.mem.eql(usize, prefix, path[0..prefix.len]);
}

test "state truncates the forward branch and advances its generation" {
    const allocator = std.testing.allocator;
    var state = State.init(allocator);
    defer state.deinit();

    var first_url = try Url.init(allocator, "https://example.com/one");
    defer first_url.free(allocator);
    var second_url = try Url.init(allocator, "https://example.com/two");
    defer second_url.free(allocator);
    var replacement_url = try Url.init(allocator, "https://example.com/three");
    defer replacement_url.free(allocator);

    inline for (.{ &first_url, &second_url }) |url| {
        try state.reserveEntry();
        var prepared = PreparedNavigation{ .entry = try Entry.prepare(
            allocator,
            url,
            null,
            &.{},
            true,
            null,
        ) };
        defer prepared.deinit(allocator);
        state.commit(&prepared);
    }
    const old_generation = state.generation;
    try std.testing.expect(state.finishTraversal(0, state.generation));

    try state.reserveEntry();
    var replacement = PreparedNavigation{ .entry = try Entry.prepare(
        allocator,
        &replacement_url,
        null,
        &.{},
        true,
        null,
    ) };
    defer replacement.deinit(allocator);
    state.commit(&replacement);

    try std.testing.expectEqual(@as(usize, 2), state.entries.items.len);
    try std.testing.expectEqualStrings("/three", state.entries.items[1].url.path);
    try std.testing.expect(state.generation != old_generation);
    try std.testing.expect(state.canGoBack());
    try std.testing.expect(!state.canGoForward());
}
