//! Performs synchronous DOM ownership transfers for JavaScript mutation APIs.
//!
//! Every fallible allocation is staged before invalidation or pointer movement.
//! During the non-fallible mutation phase, numeric handles may be temporarily
//! one-way but are rebound before any callback can return to JavaScript.

const std = @import("std");
const kiesel = @import("kiesel");
const parser = @import("../document/parser.zig");
const RelocationObserver = @import("../core/relocatable_identity.zig").RelocationObserver;
const DomHandles = @import("dom_handles.zig").Store;

const Agent = kiesel.execution.Agent;
const Node = parser.Node;

pub const Kind = enum {
    structural,
    retained_insert,
};

pub const Hooks = struct {
    prepare: *const fn (?*anyopaque, *Node, Kind) void,
    complete: *const fn (?*anyopaque, *Node) void,
    clear_named: *const fn (?*anyopaque, u32) Agent.Error!void,
    sync_named: *const fn (?*anyopaque, u32) Agent.Error!void,
    request_render: *const fn (?*anyopaque) void,
};

/// A synchronous borrow of one WindowContext's identity and detached-owner
/// stores. `host_context` and every borrowed pointer must outlive the mutation.
pub const Context = struct {
    allocator: std.mem.Allocator,
    window_id: u32,
    current_nodes: ?*Node,
    handles: *DomHandles,
    /// An optional parser- or embedder-owned identity registry. Its callbacks
    /// are synchronous, type-erased, and must never enter JavaScript.
    relocation_observer: ?RelocationObserver = null,
    detached_nodes: *std.AutoHashMap(*Node, void),
    can_retain_layout_insert: bool,
    host_context: ?*anyopaque,
    hooks: Hooks,
};

/// Every identity published for one Node before it moves. JavaScript handles
/// and a parser-owned opaque token must make the same transition together.
const NodeIdentity = struct {
    handle: ?u32 = null,
    observer_token: ?RelocationObserver.Token = null,
};

const DirectChildIdentity = struct {
    old_ptr: *Node,
    old_index: usize,
    identity: NodeIdentity = .{},
};

/// Reserve storage for every direct child that has a JavaScript handle, and
/// for every direct child whenever an external relocation observer is active.
/// The observer is deliberately not consulted until immediately before the
/// move, so no identity is transiently unpublished while setup can still fail.
fn snapshotDirectChildIdentities(
    self: *Context,
    parent: *Node,
) !std.ArrayList(DirectChildIdentity) {
    var bindings = std.ArrayList(DirectChildIdentity).empty;
    errdefer bindings.deinit(self.allocator);

    switch (parent.*) {
        .text => {},
        .element => |*element| {
            for (element.children.items, 0..) |*child, index| {
                const handle = self.handles.handleFor(child);
                if (handle == null and self.relocation_observer == null) continue;
                try bindings.append(self.allocator, .{
                    .old_ptr = child,
                    .old_index = index,
                    .identity = .{ .handle = handle },
                });
            }
        },
    }
    return bindings;
}

fn unpublishNodeIdentity(self: *Context, node: *Node) NodeIdentity {
    return .{
        .handle = self.handles.unpublishPointer(node),
        .observer_token = if (self.relocation_observer) |observer|
            observer.unpublishItem(@ptrCast(node))
        else
            null,
    };
}

fn unpublishDirectChildIdentities(
    self: *Context,
    bindings: []DirectChildIdentity,
) void {
    for (bindings) |*binding| {
        binding.identity = unpublishNodeIdentity(self, binding.old_ptr);
    }
}

fn bindNodeIdentity(self: *Context, node: *Node, identity: NodeIdentity) void {
    bindHandleIdentity(self, node, identity);
    if (identity.observer_token) |token| {
        const observer = self.relocation_observer orelse unreachable;
        observer.rebindItem(@ptrCast(node), token);
    }
}

fn bindHandleIdentity(self: *Context, node: *Node, identity: NodeIdentity) void {
    if (identity.handle) |handle| self.handles.bindAssumeCapacity(node, handle);
}

fn retireNodeIdentity(self: *Context, identity: NodeIdentity) void {
    if (identity.handle) |handle| self.handles.retireIdentity(handle);
    if (identity.observer_token) |token| {
        const observer = self.relocation_observer orelse unreachable;
        observer.retireToken(token);
    }
}

/// A JavaScript-visible node can outlive `replaceChildren` as a detached root,
/// but a parser pin must not. Parser insertion-point pins describe the active
/// document tree, not JavaScript's detached-node retention. Rebind the JS
/// root handle while retiring only the observer identities for the removed
/// subtree; descendant JS handles stay at their existing addresses.
fn retainDetachedRootAndRetireObserverIdentities(
    self: *Context,
    root: *Node,
    root_identity: NodeIdentity,
) void {
    bindHandleIdentity(self, root, root_identity);
    retireObserverIdentitiesForSubtree(self, root, root_identity.observer_token);
}

/// Retire optional external identities without affecting JavaScript handles.
/// `known_root_token` is supplied when the direct root was already unpublished
/// before its by-value storage was copied to a detached allocation.
fn retireObserverIdentitiesForSubtree(
    self: *Context,
    node: *Node,
    known_root_token: ?RelocationObserver.Token,
) void {
    const observer = self.relocation_observer orelse return;
    switch (node.*) {
        .element => |*element| {
            for (element.children.items) |*child| {
                retireObserverIdentitiesForSubtree(self, child, null);
            }
        },
        .text => {},
    }
    const token = known_root_token orelse observer.unpublishItem(@ptrCast(node)) orelse return;
    observer.retireToken(token);
}

fn directChildIdentity(
    bindings: []const DirectChildIdentity,
    child_index: usize,
) ?NodeIdentity {
    for (bindings) |binding| {
        if (binding.old_index == child_index) return binding.identity;
    }
    return null;
}

pub fn nodeParent(node: *Node) ?*Node {
    return switch (node.*) {
        .text => |text| text.parent,
        .element => |element| element.parent,
    };
}

pub fn isAttachedToCurrentDocument(current_root: ?*Node, node: *Node) bool {
    const root = current_root orelse return false;
    var current = node;
    while (nodeParent(current)) |parent| current = parent;
    return current == root;
}

pub fn isInclusiveAncestor(ancestor: *Node, node: *Node) bool {
    var current: ?*Node = node;
    while (current) |candidate| {
        if (candidate == ancestor) return true;
        current = nodeParent(candidate);
    }
    return false;
}

/// A newly attached style sheet can change the block/inline classification of
/// retained nodes. Keep those mutations on the full dependency-
/// retirement path; ordinary appended content cannot replace author rules.
pub fn subtreeCanChangeAuthorStyleRules(node: *const Node) bool {
    return switch (node.*) {
        .text => false,
        .element => |*element| blk: {
            if (std.ascii.eqlIgnoreCase(element.tag, "style") or
                std.ascii.eqlIgnoreCase(element.tag, "link")) break :blk true;
            for (element.children.items) |*child| {
                if (subtreeCanChangeAuthorStyleRules(child)) break :blk true;
            }
            break :blk false;
        },
    };
}

/// An inserted h6 immediately before existing content can become a run-in
/// heading and share one anonymous layout object with its following sibling.
/// Keep that shape change on the conservative structural path.
pub fn insertionCanMergeRunIn(node: *const Node, insert_index: usize, child_count: usize) bool {
    if (insert_index >= child_count) return false;
    return switch (node.*) {
        .element => |element| std.ascii.eqlIgnoreCase(element.tag, "h6"),
        .text => false,
    };
}

pub fn directChildIndex(parent: *Node, child: *Node) ?usize {
    return switch (parent.*) {
        .text => null,
        .element => |*element| index: {
            for (element.children.items, 0..) |*candidate, i| {
                if (candidate == child) break :index i;
            }
            break :index null;
        },
    };
}

/// Move a window-owned detached root into an element's by-value child array.
/// All mutation-related allocations happen before handle maps or detached
/// ownership change. Republishing named globals can still fail afterward, but
/// stale globals have already been removed before any node moves.
pub fn insertDetachedChild(
    self: *Context,
    parent: *Node,
    child: *Node,
    insert_index: usize,
) !void {
    var bindings = try snapshotDirectChildIdentities(self, parent);
    defer bindings.deinit(self.allocator);

    const parent_is_attached = isAttachedToCurrentDocument(self.current_nodes, parent);
    const parent_parent = nodeParent(parent);
    const element = &parent.element;
    const retains_layout_children = parent_is_attached and
        self.can_retain_layout_insert and
        !subtreeCanChangeAuthorStyleRules(child) and
        !insertionCanMergeRunIn(child, insert_index, element.children.items.len) and
        element.canReuseLayoutForInsert(insert_index);

    if (retains_layout_children) {
        element.markChildInserted();
    } else {
        element.markChildrenDirty();
    }
    parser.dirtyStyleForElement(element);
    markElementLayoutDirty(element);
    if (parent_is_attached) {
        if (retains_layout_children) {
            self.hooks.prepare(self.host_context, parent, .retained_insert);
        } else {
            self.hooks.prepare(self.host_context, parent, .structural);
        }
    }

    if (parent_is_attached) try self.hooks.clear_named(self.host_context, self.window_id);
    var mutation_started = false;
    errdefer if (parent_is_attached and !mutation_started) {
        self.hooks.sync_named(self.host_context, self.window_id) catch {};
    };

    // Capacity growth may relocate the by-value children. No JavaScript call
    // may occur between this operation and the handle-map repair below.
    try element.children.ensureUnusedCapacity(self.allocator, 1);

    // Capacity growth and insertion can relocate or shift every immediate
    // child. Remove all old pointer keys before any new address is installed.
    // `ensureUnusedCapacity` may already have retired the previous backing
    // allocation, so observer implementations must treat `old_ptr` as an
    // opaque key and never dereference it here.
    unpublishDirectChildIdentities(self, bindings.items);
    const child_identity = unpublishNodeIdentity(self, child);

    mutation_started = true;
    element.children.insertAssumeCapacity(insert_index, child.*);
    _ = self.detached_nodes.remove(child);
    self.allocator.destroy(child);

    for (bindings.items) |binding| {
        const new_index = binding.old_index + @intFromBool(binding.old_index >= insert_index);
        const new_ptr = &element.children.items[new_index];
        bindNodeIdentity(self, new_ptr, binding.identity);
    }

    const installed_child = &element.children.items[insert_index];
    bindNodeIdentity(self, installed_child, child_identity);
    parser.fixParentPointers(parent, parent_parent);
    parser.dirtyStyleSubtree(installed_child);

    if (retains_layout_children and !element.rebindLayoutAfterInsert(parent)) {
        @panic("verified retained layout children could not be rebound after insertion");
    }

    if (parent_is_attached) {
        self.hooks.complete(self.host_context, parent);
        try self.hooks.sync_named(self.host_context, self.window_id);
        self.hooks.request_render(self.host_context);
    }
}

pub fn clearDetachedLayoutPointers(node: *Node) void {
    switch (node.*) {
        .text => {},
        .element => |*element| {
            element.clearLayoutOwner();
            element.markChildrenDirty();
            for (element.children.items) |*child| clearDetachedLayoutPointers(child);
        },
    }
}

/// Move one by-value child into a heap-stable, window-owned detached root.
/// Allocation for the ownership move precedes the child-array mutation. ID
/// globals are cleared before pointer relocation and republished afterward.
pub fn detachChild(
    self: *Context,
    parent: *Node,
    child: *Node,
    remove_index: usize,
) !void {
    var bindings = try snapshotDirectChildIdentities(self, parent);
    defer bindings.deinit(self.allocator);
    std.debug.assert(&parent.element.children.items[remove_index] == child);

    const detached = try self.allocator.create(Node);
    var detached_owned = true;
    errdefer if (detached_owned) self.allocator.destroy(detached);
    try self.detached_nodes.ensureUnusedCapacity(1);

    const parent_is_attached = isAttachedToCurrentDocument(self.current_nodes, parent);
    const parent_parent = nodeParent(parent);
    const element = &parent.element;

    if (parent_is_attached) try self.hooks.clear_named(self.host_context, self.window_id);

    element.markChildrenDirty();
    parser.dirtyStyleForElement(element);
    markElementLayoutDirty(element);
    if (parent_is_attached) self.hooks.prepare(self.host_context, parent, .structural);

    // orderedRemove shifts later children, invalidating their pointer keys.
    // Remove every published direct-child address before performing the move.
    unpublishDirectChildIdentities(self, bindings.items);

    detached.* = element.children.orderedRemove(remove_index);
    self.detached_nodes.putAssumeCapacity(detached, {});
    detached_owned = false;

    for (bindings.items) |binding| {
        if (binding.old_index == remove_index) continue;
        const new_index = binding.old_index - @intFromBool(binding.old_index > remove_index);
        const new_ptr = &element.children.items[new_index];
        bindNodeIdentity(self, new_ptr, binding.identity);
    }

    const child_identity = directChildIdentity(bindings.items, remove_index) orelse unreachable;
    bindNodeIdentity(self, detached, child_identity);
    parser.fixParentPointers(parent, parent_parent);
    parser.fixParentPointers(detached, null);
    clearDetachedLayoutPointers(detached);
    parser.dirtyStyleSubtree(detached);

    if (parent_is_attached) {
        self.hooks.complete(self.host_context, parent);
        try self.hooks.sync_named(self.host_context, self.window_id);
        self.hooks.request_render(self.host_context);
    }
}

pub fn removeHandlesForSubtree(handles: *DomHandles, node: *Node) void {
    switch (node.*) {
        .element => |*element| {
            for (element.children.items) |*child| {
                removeHandlesForSubtree(handles, child);
            }
        },
        .text => {},
    }

    handles.retire(node);
}

/// Retire every JavaScript and optional observer identity in a subtree before
/// its Node storage is destroyed. The observer is a non-owning participant:
/// it does not keep an otherwise unobservable subtree alive.
pub fn retireIdentitiesForSubtree(self: *Context, node: *Node) void {
    switch (node.*) {
        .element => |*element| {
            for (element.children.items) |*child| {
                retireIdentitiesForSubtree(self, child);
            }
        },
        .text => {},
    }
    retireNodeIdentity(self, unpublishNodeIdentity(self, node));
}

/// As `retireIdentitiesForSubtree`, but the caller has already unpublished the
/// root while repairing a containing child array. Descendants remain
/// published and are retired normally.
fn retireUnpublishedIdentityForSubtree(
    self: *Context,
    node: *Node,
    root_identity: NodeIdentity,
) void {
    switch (node.*) {
        .element => |*element| {
            for (element.children.items) |*child| {
                retireIdentitiesForSubtree(self, child);
            }
        },
        .text => {},
    }
    retireNodeIdentity(self, root_identity);
}

fn subtreeHasPublishedHandle(handles: *const DomHandles, node: *Node) bool {
    if (handles.contains(node)) return true;
    return switch (node.*) {
        .text => false,
        .element => |*element| child_handle: {
            for (element.children.items) |*child| {
                if (subtreeHasPublishedHandle(handles, child)) break :child_handle true;
            }
            break :child_handle false;
        },
    };
}

const DetachedReplacementChild = struct {
    old_ptr: *Node,
    stable_ptr: *Node,
};

/// Remove every child in one structural-mutation transaction. A subtree with
/// a published JavaScript handle remains alive as a detached, heap-stable
/// root; an unobservable subtree can be reclaimed immediately. All allocations
/// needed by those ownership moves precede invalidation and child destruction.
pub fn emptyElementChildren(
    self: *Context,
    node: *Node,
) !void {
    const element = switch (node.*) {
        .element => |*value| value,
        .text => unreachable,
    };
    if (element.children.items.len == 0) return;

    var bindings = try snapshotDirectChildIdentities(self, node);
    defer bindings.deinit(self.allocator);

    var retained_count: usize = 0;
    for (element.children.items) |*child| {
        if (subtreeHasPublishedHandle(self.handles, child)) retained_count += 1;
    }

    var retained = std.ArrayList(DetachedReplacementChild).empty;
    defer retained.deinit(self.allocator);
    try retained.ensureTotalCapacity(self.allocator, retained_count);
    const retained_capacity = std.math.cast(u32, retained_count) orelse return error.OutOfMemory;
    try self.detached_nodes.ensureUnusedCapacity(retained_capacity);

    var stable_roots_owned = true;
    defer if (stable_roots_owned) {
        for (retained.items) |entry| self.allocator.destroy(entry.stable_ptr);
    };
    for (element.children.items) |*child| {
        if (!subtreeHasPublishedHandle(self.handles, child)) continue;
        const stable_ptr = try self.allocator.create(Node);
        retained.appendAssumeCapacity(.{
            .old_ptr = child,
            .stable_ptr = stable_ptr,
        });
    }

    const is_attached = isAttachedToCurrentDocument(self.current_nodes, node);
    if (is_attached) try self.hooks.clear_named(self.host_context, self.window_id);

    element.markChildrenDirty();
    parser.dirtyStyleForElement(element);
    markElementLayoutDirty(element);
    if (is_attached) self.hooks.prepare(self.host_context, node, .structural);

    // All direct roots leave this child array, either into detached ownership
    // or destruction. Unpublish them before any root is copied or destroyed.
    unpublishDirectChildIdentities(self, bindings.items);

    var retained_index: usize = 0;
    for (element.children.items, 0..) |*child, child_index| {
        const root_identity = directChildIdentity(bindings.items, child_index) orelse NodeIdentity{};
        if (retained_index < retained.items.len and
            retained.items[retained_index].old_ptr == child)
        {
            const stable_ptr = retained.items[retained_index].stable_ptr;
            retained_index += 1;

            stable_ptr.* = child.*;
            retainDetachedRootAndRetireObserverIdentities(self, stable_ptr, root_identity);
            parser.fixParentPointers(stable_ptr, null);
            clearDetachedLayoutPointers(stable_ptr);
            parser.dirtyStyleSubtree(stable_ptr);
            self.detached_nodes.putAssumeCapacity(stable_ptr, {});
        } else {
            retireUnpublishedIdentityForSubtree(self, child, root_identity);
            child.deinit(self.allocator);
        }
    }
    std.debug.assert(retained_index == retained.items.len);
    element.children.deinit(self.allocator);
    element.children = std.ArrayList(Node).empty;
    stable_roots_owned = false;

    if (is_attached) {
        self.hooks.complete(self.host_context, node);
        // The pre-mutation callback already publishes a replacement frame;
        // keep the ordinary render callback observable even if rebuilding ID
        // globals subsequently runs out of memory.
        self.hooks.request_render(self.host_context);
        try self.hooks.sync_named(self.host_context, self.window_id);
    }
}

const ReplacementArgument = struct {
    handle: u32,
    source_parent: ?*Node,
    source_index: ?usize,
    transfer: *Node,
    transfer_allocated: bool,
    has_value: bool,
};

const ReplacementParent = struct {
    node: *Node,
    depth: usize,
    is_target: bool,
    bindings: std.ArrayList(DirectChildIdentity),
    remaining: std.ArrayList(Node),
};

const RemovedTargetChild = struct {
    old_index: usize,
    stable_ptr: *Node,
    consumed: bool = false,
};

fn nodeDepth(node: *Node) usize {
    var depth: usize = 0;
    var current = nodeParent(node);
    while (current) |parent| {
        depth += 1;
        current = nodeParent(parent);
    }
    return depth;
}

fn nearestCommonAncestor(first: *Node, second: *Node) *Node {
    var candidate: ?*Node = first;
    while (candidate) |node| {
        if (isInclusiveAncestor(node, second)) return node;
        candidate = nodeParent(node);
    }
    unreachable;
}

fn replacementArgumentAt(
    arguments: []const ReplacementArgument,
    parent: *Node,
    child_index: usize,
) ?usize {
    for (arguments, 0..) |argument, index| {
        if (argument.source_parent == parent and argument.source_index == child_index) return index;
    }
    return null;
}

fn selectedChildrenBefore(
    arguments: []const ReplacementArgument,
    parent: *Node,
    child_index: usize,
) usize {
    var count: usize = 0;
    for (arguments) |argument| {
        if (argument.source_parent == parent and argument.source_index.? < child_index) count += 1;
    }
    return count;
}

fn addReplacementParent(
    self: *Context,
    parents: *std.ArrayList(ReplacementParent),
    node: *Node,
    is_target: bool,
) !void {
    for (parents.items) |*parent| {
        if (parent.node != node) continue;
        parent.is_target = parent.is_target or is_target;
        return;
    }

    var bindings = try snapshotDirectChildIdentities(self, node);
    errdefer bindings.deinit(self.allocator);
    try parents.append(self.allocator, .{
        .node = node,
        .depth = nodeDepth(node),
        .is_target = is_target,
        .bindings = bindings,
        .remaining = std.ArrayList(Node).empty,
    });
}

/// Replace an Element's children with existing Element roots in one ownership
/// transaction. Every fallible allocation precedes DOM invalidation. Affected
/// parents are processed deepest-first so moving a by-value ancestor cannot
/// invalidate a descendant parent that still needs mutation.
pub fn transferElementChildren(
    self: *Context,
    target: *Node,
    argument_nodes: []const *Node,
) !void {
    std.debug.assert(argument_nodes.len > 0);
    const target_handle = self.handles.handleFor(target).?;

    var arguments = std.ArrayList(ReplacementArgument).empty;
    defer arguments.deinit(self.allocator);
    try arguments.ensureTotalCapacity(self.allocator, argument_nodes.len);
    var transfer_boxes_owned = true;
    defer if (transfer_boxes_owned) {
        for (arguments.items) |argument| {
            if (argument.transfer_allocated) self.allocator.destroy(argument.transfer);
        }
    };

    // `convert nodes into a node` appends arguments to a temporary fragment.
    // Repeating a node therefore keeps only its last occurrence.
    for (argument_nodes, 0..) |node, index| {
        var appears_later = false;
        for (argument_nodes[index + 1 ..]) |later| {
            if (later == node) {
                appears_later = true;
                break;
            }
        }
        if (appears_later) continue;

        const is_detached = self.detached_nodes.contains(node);
        const source_parent = if (is_detached) null else nodeParent(node);
        const source_index = if (source_parent) |parent|
            directChildIndex(parent, node)
        else
            null;
        const transfer = if (is_detached) node else try self.allocator.create(Node);
        arguments.appendAssumeCapacity(.{
            .handle = self.handles.handleFor(node).?,
            .source_parent = source_parent,
            .source_index = source_index,
            .transfer = transfer,
            .transfer_allocated = !is_detached,
            .has_value = is_detached,
        });
    }

    var mutation_started = false;

    var parents = std.ArrayList(ReplacementParent).empty;
    defer {
        for (parents.items) |*parent| {
            parent.bindings.deinit(self.allocator);
            parent.remaining.deinit(self.allocator);
        }
        parents.deinit(self.allocator);
    }
    try addReplacementParent(self, &parents, target, true);
    for (arguments.items) |argument| {
        if (argument.source_parent) |parent| {
            try addReplacementParent(self, &parents, parent, false);
        }
    }

    for (parents.items) |*parent| {
        if (parent.is_target) continue;
        var selected_count: usize = 0;
        for (arguments.items) |argument| {
            if (argument.source_parent == parent.node) selected_count += 1;
        }
        try parent.remaining.ensureTotalCapacity(
            self.allocator,
            parent.node.element.children.items.len - selected_count,
        );
    }

    // Post-order mutation keeps every stored parent pointer valid until its
    // own child array has been rebuilt.
    var sort_index: usize = 1;
    while (sort_index < parents.items.len) : (sort_index += 1) {
        var cursor = sort_index;
        while (cursor > 0 and parents.items[cursor - 1].depth < parents.items[cursor].depth) {
            std.mem.swap(ReplacementParent, &parents.items[cursor - 1], &parents.items[cursor]);
            cursor -= 1;
        }
    }

    var removed_target_children = std.ArrayList(RemovedTargetChild).empty;
    defer {
        for (removed_target_children.items) |removed| {
            if (!removed.consumed) self.allocator.destroy(removed.stable_ptr);
        }
        removed_target_children.deinit(self.allocator);
    }
    const target_child_count = target.element.children.items.len;
    try removed_target_children.ensureTotalCapacity(self.allocator, target_child_count);
    for (target.element.children.items, 0..) |_, child_index| {
        if (replacementArgumentAt(arguments.items, target, child_index) != null) continue;
        const stable_ptr = try self.allocator.create(Node);
        removed_target_children.appendAssumeCapacity(.{
            .old_index = child_index,
            .stable_ptr = stable_ptr,
        });
    }
    const detached_capacity = std.math.cast(u32, removed_target_children.items.len) orelse
        return error.OutOfMemory;
    try self.detached_nodes.ensureUnusedCapacity(detached_capacity);

    var replacement = std.ArrayList(Node).empty;
    defer replacement.deinit(self.allocator);
    try replacement.ensureTotalCapacity(self.allocator, arguments.items.len);

    const target_was_attached = isAttachedToCurrentDocument(self.current_nodes, target);
    var document_mutation_root: ?*Node = if (target_was_attached) target else null;
    for (arguments.items) |argument| {
        const parent = argument.source_parent orelse continue;
        if (!isAttachedToCurrentDocument(self.current_nodes, parent)) continue;
        document_mutation_root = if (document_mutation_root) |root|
            nearestCommonAncestor(root, parent)
        else
            parent;
    }
    const mutates_document = document_mutation_root != null;

    if (mutates_document) try self.hooks.clear_named(self.host_context, self.window_id);
    errdefer if (mutates_document and !mutation_started) {
        self.hooks.sync_named(self.host_context, self.window_id) catch {};
    };

    for (parents.items) |parent| {
        const element = &parent.node.element;
        element.markChildrenDirty();
        parser.dirtyStyleForElement(element);
        markElementLayoutDirty(element);
    }
    if (document_mutation_root) |mutation_root| self.hooks.prepare(self.host_context, mutation_root, .structural);
    mutation_started = true;

    for (parents.items) |*parent_state| {
        const parent = parent_state.node;
        const parent_parent = nodeParent(parent);
        const element = &parent.element;

        unpublishDirectChildIdentities(self, parent_state.bindings.items);

        var removed_slot_index: usize = 0;
        for (element.children.items, 0..) |*child, child_index| {
            if (replacementArgumentAt(arguments.items, parent, child_index)) |argument_index| {
                const argument = &arguments.items[argument_index];
                std.debug.assert(!argument.has_value);
                const identity = directChildIdentity(parent_state.bindings.items, child_index) orelse unreachable;
                std.debug.assert(identity.handle == argument.handle);
                argument.transfer.* = child.*;
                argument.has_value = true;
                bindNodeIdentity(self, argument.transfer, identity);
                parser.fixParentPointers(argument.transfer, null);
                clearDetachedLayoutPointers(argument.transfer);
                parser.dirtyStyleSubtree(argument.transfer);
                continue;
            }

            if (parent_state.is_target) {
                const removed = &removed_target_children.items[removed_slot_index];
                removed_slot_index += 1;
                std.debug.assert(removed.old_index == child_index);
                const root_identity = directChildIdentity(parent_state.bindings.items, child_index) orelse NodeIdentity{};
                const retain = root_identity.handle != null or subtreeHasPublishedHandle(self.handles, child);
                if (retain) {
                    removed.stable_ptr.* = child.*;
                    retainDetachedRootAndRetireObserverIdentities(self, removed.stable_ptr, root_identity);
                    parser.fixParentPointers(removed.stable_ptr, null);
                    clearDetachedLayoutPointers(removed.stable_ptr);
                    parser.dirtyStyleSubtree(removed.stable_ptr);
                    self.detached_nodes.putAssumeCapacity(removed.stable_ptr, {});
                    removed.consumed = true;
                } else {
                    retireUnpublishedIdentityForSubtree(self, child, root_identity);
                    child.deinit(self.allocator);
                    self.allocator.destroy(removed.stable_ptr);
                    removed.consumed = true;
                }
                continue;
            }

            parent_state.remaining.appendAssumeCapacity(child.*);
        }

        element.children.deinit(self.allocator);
        if (parent_state.is_target) {
            element.children = std.ArrayList(Node).empty;
            std.debug.assert(removed_slot_index == removed_target_children.items.len);
        } else {
            element.children = parent_state.remaining;
            parent_state.remaining = std.ArrayList(Node).empty;
            for (parent_state.bindings.items) |binding| {
                if (replacementArgumentAt(arguments.items, parent, binding.old_index) != null) continue;
                const new_index = binding.old_index - selectedChildrenBefore(
                    arguments.items,
                    parent,
                    binding.old_index,
                );
                const new_ptr = &element.children.items[new_index];
                bindNodeIdentity(self, new_ptr, binding.identity);
            }
        }
        parser.fixParentPointers(parent, parent_parent);
    }

    const installed_target = self.handles.resolve(target_handle).?;
    std.debug.assert(installed_target.* == .element);
    for (arguments.items) |*argument| {
        std.debug.assert(argument.has_value);
        clearDetachedLayoutPointers(argument.transfer);
        parser.dirtyStyleSubtree(argument.transfer);
        const transfer_identity = unpublishNodeIdentity(self, argument.transfer);
        std.debug.assert(transfer_identity.handle == argument.handle);
        _ = self.detached_nodes.remove(argument.transfer);
        replacement.appendAssumeCapacity(argument.transfer.*);
        self.allocator.destroy(argument.transfer);

        const installed = &replacement.items[replacement.items.len - 1];
        bindNodeIdentity(self, installed, transfer_identity);
    }
    transfer_boxes_owned = false;

    installed_target.element.children = replacement;
    replacement = std.ArrayList(Node).empty;
    parser.fixParentPointers(installed_target, nodeParent(installed_target));

    if (mutates_document) {
        const completion_root = if (target_was_attached)
            installed_target
        else
            self.current_nodes.?;
        self.hooks.complete(self.host_context, completion_root);
        self.hooks.request_render(self.host_context);
        try self.hooks.sync_named(self.host_context, self.window_id);
    }
}

/// Dirty the retained layout object associated with an Element, if present.
pub fn markElementLayoutDirty(element: *parser.Element) void {
    if (element.layout_ptr) |ptr| {
        if (element.layout_mark) |mark_fn| mark_fn(ptr);
    }
}
