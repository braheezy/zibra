//! CSS animation-tree advancement and compositor-update production.
//!
//! This module owns property classification and animation iteration. It does
//! not own a Tab, Frame, or Browser: callers provide the three effects that
//! cross those boundaries—publish a compositor scalar, dirty layout, and
//! request paint.

const std = @import("std");
const document = @import("../document/parser.zig");
const svg_animation = @import("../document/svg_animation.zig");

pub const CompositedUpdate = struct {
    node: *anyopaque,
    value: union(enum) {
        opacity: f64,
        transform: struct { x: i32, y: i32 },
    },
};

/// Narrow host boundary for effects owned by the Tab/layout/compositor. The
/// callbacks are synchronous and may borrow `Element` only for their duration.
pub const Sink = struct {
    now_seconds: f64 = 0,
    allocator: std.mem.Allocator = std.heap.smp_allocator,
    context: *anyopaque,
    publish_composited: *const fn (*anyopaque, CompositedUpdate) void,
    mark_layout: *const fn (*anyopaque, *document.Element) void,
    request_paint: *const fn (*anyopaque) void,

    fn publish(self: Sink, update: CompositedUpdate) void {
        self.publish_composited(self.context, update);
    }

    fn markLayout(self: Sink, element: *document.Element) void {
        self.mark_layout(self.context, element);
    }

    fn requestPaint(self: Sink) void {
        self.request_paint(self.context);
    }
};

pub fn hasActive(node: *const document.Node) bool {
    return switch (node.*) {
        .text => false,
        .element => |*element| blk: {
            if (svg_animation.isRoot(element) and svg_animation.active(element, element.svg_time_seconds)) break :blk true;
            if (element.css_animation) |state| {
                if (state.isRunning()) break :blk true;
            }
            if (element.animations) |animations| {
                var iterator = animations.iterator();
                while (iterator.next()) |entry| {
                    if (element.css_animation) |state| if (state.contains(entry.key_ptr.*)) continue;
                    if (!entry.value_ptr.isComplete()) break :blk true;
                }
            }
            for (element.children.items) |*child| {
                if (hasActive(child)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn publishValue(
    sink: Sink,
    element: *document.Element,
    property: []const u8,
    animation: *document.Animation,
    css_keyframe_animation: bool,
) void {
    if (std.mem.eql(u8, property, "opacity")) {
        switch (animation.*) {
            .numeric => |numeric| {
                const opacity = numeric.getValue();
                // Transitions publish through the computed style's
                // Element-owned buffer. A finite keyframe animation leaves
                // the underlying value untouched so it can be restored.
                if (!css_keyframe_animation) {
                    if (element.style) |*style_map| {
                        if (style_map.getPtr("opacity")) |field| {
                            const value = std.fmt.bufPrint(
                                &element.opacity_anim_value,
                                "{d:.3}",
                                .{opacity},
                            ) catch null;
                            if (value) |text| field.set(text);
                        }
                    }
                }
                sink.publish(.{
                    .node = @ptrCast(element),
                    .value = .{ .opacity = opacity },
                });
            },
            .pixel, .color, .transform => {},
        }
    } else if (std.mem.eql(u8, property, "background-color")) {
        switch (animation.*) {
            .color => {
                sink.requestPaint();
                sink.markLayout(element);
            },
            .numeric, .pixel, .transform => {},
        }
    } else if (std.mem.eql(u8, property, "transform")) {
        switch (animation.*) {
            .transform => |transform| {
                const pixels = transform.getValue().layoutPixels();
                sink.publish(.{
                    .node = @ptrCast(element),
                    .value = .{ .transform = .{ .x = pixels.x, .y = pixels.y } },
                });
            },
            .numeric, .pixel, .color => {},
        }
    } else if (std.mem.eql(u8, property, "width") or std.mem.eql(u8, property, "height")) {
        switch (animation.*) {
            .pixel => sink.markLayout(element),
            .numeric, .color, .transform => {},
        }
    }
}

fn invalidateRemovedCssAnimation(
    sink: Sink,
    element: *document.Element,
    property_mask: u8,
) void {
    for (document.css_animation_properties) |property| {
        if ((property_mask & document.cssAnimationPropertyBit(property)) == 0) continue;
        if (std.mem.eql(u8, property, "background-color") or
            std.mem.eql(u8, property, "width") or
            std.mem.eql(u8, property, "height"))
        {
            sink.markLayout(element);
            if (std.mem.eql(u8, property, "background-color")) sink.requestPaint();
        } else {
            // Opacity and transform mutate retained effect wrappers. Restore
            // the underlying computed style by rebuilding this paint owner.
            document.markPaintForElement(element);
            sink.requestPaint();
        }
    }
}

/// Advance transitions and named keyframe animations in DOM preorder. Returns
/// true while any track needs another animation frame.
pub fn advance(sink: Sink, node: *document.Node) bool {
    var any_running = false;

    switch (node.*) {
        .element => |*element| {
            if (svg_animation.isRoot(element) and (element.svg_epoch_seconds != null or svg_animation.hasTracks(element))) svg: {
                if (element.svg_epoch_seconds == null) element.svg_epoch_seconds = sink.now_seconds;
                element.svg_time_seconds = @max(0, sink.now_seconds - element.svg_epoch_seconds.?);
                const had_size = svg_animation.hasSampledSize(element);
                svg_animation.sample(sink.allocator, element, element.svg_time_seconds) catch {
                    any_running = true;
                    break :svg;
                };
                // Resample completed timelines on a DOM-triggered frame too:
                // removing a track must restore its underlying authored value.
                if (had_size or svg_animation.hasSampledSize(element)) sink.markLayout(element);
                document.markPaintForElement(element);
                sink.requestPaint();
                if (svg_animation.active(element, element.svg_time_seconds)) any_running = true;
            }
            if (element.css_animation) |*state| {
                if (state.isRunning()) {
                    const previous = state.progress;
                    state.elapsed_frames += 1;
                    state.publish(&element.animations.?);
                    if (state.progress == null and previous != null) invalidateRemovedCssAnimation(sink, element, state.property_mask);
                    if (state.progress != null and state.progress != previous) {
                        for (document.css_animation_properties) |property| {
                            if (state.contains(property)) {
                                if (element.animations.?.getPtr(property)) |track| publishValue(sink, element, property, track, true);
                            }
                        }
                    }
                    any_running = state.isRunning() or any_running;
                }
            }
            if (element.animations) |*animations| {
                var iterator = animations.iterator();
                while (iterator.next()) |entry| {
                    if (element.css_animation) |state| if (state.contains(entry.key_ptr.*)) continue;
                    const track = entry.value_ptr;
                    if (!track.isComplete()) {
                        _ = track.advance();
                        any_running = true;
                        publishValue(sink, element, entry.key_ptr.*, track, false);
                    }
                }
            }

            for (element.children.items) |*child| {
                if (advance(sink, child)) any_running = true;
            }
        },
        .text => {},
    }
    return any_running;
}
