//! Performs synchronous DOM ownership transfers for JavaScript mutation APIs.
//!
//! Every fallible allocation is staged before invalidation or pointer movement.
//! During the non-fallible mutation phase, numeric handles may be temporarily
//! one-way but are rebound before any callback can return to JavaScript.

const std = @import("std");
const kiesel = @import("kiesel");
const parser = @import("../document/parser.zig");
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
    detached_nodes: *std.AutoHashMap(*Node, void),
    can_retain_layout_insert: bool,
    host_context: ?*anyopaque,
    hooks: Hooks,
};

const DirectChildHandle = struct {
    old_ptr: *Node,
    old_index: usize,
    handle: u32,
};

fn snapshotDirectChildHandles(
    self: *Context,
    parent: *Node,
) !std.ArrayList(DirectChildHandle) {
    var bindings = std.ArrayList(DirectChildHandle).empty;
    errdefer bindings.deinit(self.allocator);

    switch (parent.*) {
        .text => {},
        .element => |*element| {
            for (element.children.items, 0..) |*child, index| {
                if (self.handles.handleFor(child)) |handle| {
                    try bindings.append(self.allocator, .{
                        .old_ptr = child,
                        .old_index = index,
                        .handle = handle,
                    });
                }
            }
        },
    }
    return bindings;
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
    var bindings = try snapshotDirectChildHandles(self, parent);
    defer bindings.deinit(self.allocator);

    const parent_is_attached = isAttachedToCurrentDocument(self.current_nodes, parent);
    const parent_parent = nodeParent(parent);
    const child_handle = self.handles.handleFor(child).?;
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
    for (bindings.items) |binding| {
        _ = self.handles.unpublishPointer(binding.old_ptr);
    }
    _ = self.handles.unpublishPointer(child);

    mutation_started = true;
    element.children.insertAssumeCapacity(insert_index, child.*);
    _ = self.detached_nodes.remove(child);
    self.allocator.destroy(child);

    for (bindings.items) |binding| {
        const new_index = binding.old_index + @intFromBool(binding.old_index >= insert_index);
        const new_ptr = &element.children.items[new_index];
        self.handles.bindAssumeCapacity(new_ptr, binding.handle);
    }

    const installed_child = &element.children.items[insert_index];
    self.handles.bindAssumeCapacity(installed_child, child_handle);
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
    var bindings = try snapshotDirectChildHandles(self, parent);
    defer bindings.deinit(self.allocator);

    const detached = try self.allocator.create(Node);
    var detached_owned = true;
    errdefer if (detached_owned) self.allocator.destroy(detached);
    try self.detached_nodes.ensureUnusedCapacity(1);

    const parent_is_attached = isAttachedToCurrentDocument(self.current_nodes, parent);
    const parent_parent = nodeParent(parent);
    const child_handle = self.handles.handleFor(child).?;
    const element = &parent.element;

    if (parent_is_attached) try self.hooks.clear_named(self.host_context, self.window_id);

    element.markChildrenDirty();
    parser.dirtyStyleForElement(element);
    markElementLayoutDirty(element);
    if (parent_is_attached) self.hooks.prepare(self.host_context, parent, .structural);

    // orderedRemove shifts later children, invalidating their pointer keys.
    // Remove every published direct-child address before performing the move.
    for (bindings.items) |binding| {
        _ = self.handles.unpublishPointer(binding.old_ptr);
    }

    detached.* = element.children.orderedRemove(remove_index);
    self.detached_nodes.putAssumeCapacity(detached, {});
    detached_owned = false;

    for (bindings.items) |binding| {
        if (binding.old_index == remove_index) continue;
        const new_index = binding.old_index - @intFromBool(binding.old_index > remove_index);
        const new_ptr = &element.children.items[new_index];
        self.handles.bindAssumeCapacity(new_ptr, binding.handle);
    }

    self.handles.bindAssumeCapacity(detached, child_handle);
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

    var retained_index: usize = 0;
    for (element.children.items) |*child| {
        if (retained_index < retained.items.len and
            retained.items[retained_index].old_ptr == child)
        {
            const stable_ptr = retained.items[retained_index].stable_ptr;
            retained_index += 1;

            const root_handle = self.handles.handleFor(child);
            if (root_handle != null) _ = self.handles.unpublishPointer(child);

            stable_ptr.* = child.*;
            if (root_handle) |handle| {
                self.handles.bindAssumeCapacity(stable_ptr, handle);
            }
            parser.fixParentPointers(stable_ptr, null);
            clearDetachedLayoutPointers(stable_ptr);
            parser.dirtyStyleSubtree(stable_ptr);
            self.detached_nodes.putAssumeCapacity(stable_ptr, {});
        } else {
            removeHandlesForSubtree(self.handles, child);
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
    bindings: std.ArrayList(DirectChildHandle),
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

fn directChildHandle(bindings: []const DirectChildHandle, child_index: usize) ?u32 {
    for (bindings) |binding| {
        if (binding.old_index == child_index) return binding.handle;
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

    var bindings = try snapshotDirectChildHandles(self, node);
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

        for (parent_state.bindings.items) |binding| {
            _ = self.handles.unpublishPointer(binding.old_ptr);
        }

        var removed_slot_index: usize = 0;
        for (element.children.items, 0..) |*child, child_index| {
            if (replacementArgumentAt(arguments.items, parent, child_index)) |argument_index| {
                const argument = &arguments.items[argument_index];
                std.debug.assert(!argument.has_value);
                argument.transfer.* = child.*;
                argument.has_value = true;
                self.handles.bindAssumeCapacity(argument.transfer, argument.handle);
                parser.fixParentPointers(argument.transfer, null);
                clearDetachedLayoutPointers(argument.transfer);
                parser.dirtyStyleSubtree(argument.transfer);
                continue;
            }

            if (parent_state.is_target) {
                const removed = &removed_target_children.items[removed_slot_index];
                removed_slot_index += 1;
                std.debug.assert(removed.old_index == child_index);
                const root_handle = directChildHandle(parent_state.bindings.items, child_index);
                const retain = root_handle != null or subtreeHasPublishedHandle(self.handles, child);
                if (retain) {
                    removed.stable_ptr.* = child.*;
                    if (root_handle) |handle| {
                        self.handles.bindAssumeCapacity(removed.stable_ptr, handle);
                    }
                    parser.fixParentPointers(removed.stable_ptr, null);
                    clearDetachedLayoutPointers(removed.stable_ptr);
                    parser.dirtyStyleSubtree(removed.stable_ptr);
                    self.detached_nodes.putAssumeCapacity(removed.stable_ptr, {});
                    removed.consumed = true;
                } else {
                    removeHandlesForSubtree(self.handles, child);
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
                self.handles.bindAssumeCapacity(new_ptr, binding.handle);
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
        _ = self.handles.unpublishPointer(argument.transfer);
        _ = self.detached_nodes.remove(argument.transfer);
        replacement.appendAssumeCapacity(argument.transfer.*);
        self.allocator.destroy(argument.transfer);

        const installed = &replacement.items[replacement.items.len - 1];
        self.handles.bindAssumeCapacity(installed, argument.handle);
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
