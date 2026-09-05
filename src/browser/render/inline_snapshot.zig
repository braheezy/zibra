//! Owns paint commands and local interaction bounds for an atomic inline box.
//! Temporary layout trees retire before these movable snapshots enter a line.
const std = @import("std");
const Node = @import("../../document/dom.zig").Node;
const commands = @import("display_list.zig");
const DisplayItem = commands.DisplayItem;
const Bounds = @import("layout_hit.zig").Bounds;

pub const BoundEntry = struct { node: *Node, bounds: Bounds };
pub const FragmentTarget = struct { node: *Node, y: i32 };

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayList(DisplayItem) = .empty,
    input_bounds: std.AutoHashMap(*Node, Bounds),
    image_bounds: std.AutoHashMap(*Node, Bounds),
    link_bounds: std.ArrayList(BoundEntry) = .empty,
    iframe_bounds: std.ArrayList(BoundEntry) = .empty,
    focus_bounds: std.ArrayList(BoundEntry) = .empty,
    accessibility_bounds: std.ArrayList(BoundEntry) = .empty,
    fragment_targets: std.ArrayList(FragmentTarget) = .empty,

    pub fn init(allocator: std.mem.Allocator) Snapshot {
        return .{
            .allocator = allocator,
            .input_bounds = std.AutoHashMap(*Node, Bounds).init(allocator),
            .image_bounds = std.AutoHashMap(*Node, Bounds).init(allocator),
        };
    }

    pub fn deinit(self: *Snapshot) void {
        DisplayItem.freeItems(self.allocator, self.commands.items);
        self.commands.deinit(self.allocator);
        self.input_bounds.deinit();
        self.image_bounds.deinit();
        self.link_bounds.deinit(self.allocator);
        self.iframe_bounds.deinit(self.allocator);
        self.focus_bounds.deinit(self.allocator);
        self.accessibility_bounds.deinit(self.allocator);
        self.fragment_targets.deinit(self.allocator);
    }

    /// Swap with the synchronous layout collector. Always pair with a deferred
    /// second swap, including on failure. No engine pointer is retained.
    pub fn swapCollectors(self: *Snapshot, engine: anytype) void {
        inline for (.{ "input_bounds", "image_bounds", "link_bounds", "iframe_bounds", "focus_bounds", "accessibility_bounds", "fragment_targets" }) |name| {
            std.mem.swap(@TypeOf(@field(self, name)), &@field(self, name), &@field(engine, name));
        }
    }

    /// Publish only final-position bounds; measurement-only callers must not
    /// call this. Every Node still borrows the surrounding document generation.
    pub fn mergeBounds(self: *const Snapshot, engine: anytype, dx: i32, dy: i32) !void {
        inline for (.{ "input_bounds", "image_bounds" }) |name| {
            var it = @field(self, name).iterator();
            while (it.next()) |entry| {
                try @field(engine, name).put(entry.key_ptr.*, offsetBounds(entry.value_ptr.*, dx, dy));
            }
        }
        inline for (.{ "link_bounds", "iframe_bounds", "focus_bounds", "accessibility_bounds" }) |name| {
            for (@field(self, name).items) |entry| {
                try @field(engine, name).append(engine.allocator, .{
                    .node = entry.node,
                    .bounds = offsetBounds(entry.bounds, dx, dy),
                });
            }
        }
        for (self.fragment_targets.items) |entry| try engine.fragment_targets.append(engine.allocator, .{
            .node = entry.node,
            .y = entry.y + dy,
        });
    }

    /// Move the command containers into the surrounding display generation.
    /// Sources must already have been rebound to its persistent layout owner.
    pub fn paintAt(self: *Snapshot, destination: *std.ArrayList(DisplayItem), x: i32, y: i32, source: ?commands.DisplayItemSource) !void {
        if (self.commands.items.len == 0) return;
        try destination.ensureUnusedCapacity(self.allocator, 1);
        const children = try self.commands.toOwnedSlice(self.allocator);
        destination.appendAssumeCapacity(.{ .transform = .{
            .translate_x = x,
            .translate_y = y,
            .children = children,
            .source = source,
        } });
    }
};

fn offsetBounds(bounds: Bounds, dx: i32, dy: i32) Bounds {
    return .{ .x = bounds.x + dx, .y = bounds.y + dy, .width = bounds.width, .height = bounds.height };
}
