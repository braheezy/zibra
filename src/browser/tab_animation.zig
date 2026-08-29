//! CSS animation-tree advancement and compositor-update production.
//!
//! This module owns property classification and animation iteration. It does
//! not own a Tab, Frame, or Browser: callers provide the three effects that
//! cross those boundaries—publish a compositor scalar, dirty layout, and
//! request paint.

const std = @import("std");
const document = @import("../document/parser.zig");

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
            if (element.css_animation) |state| {
                if (!state.finished) break :blk true;
            }
            if (element.animations) |animations| {
                var iterator = animations.iterator();
                while (iterator.next()) |entry| {
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

fn restartCssAnimation(
    sink: Sink,
    element: *document.Element,
    state: *document.CssAnimationState,
) void {
    state.completed_iterations += 1;
    state.restart_pending = false;
    const should_reverse = state.direction == .alternate;
    if (element.animations) |*animations| {
        for (document.css_animation_properties) |property| {
            if (!state.contains(property)) continue;
            if (animations.getPtr(property)) |animation| {
                if (should_reverse) animation.reverse();
                animation.reset();
                publishValue(sink, element, property, animation, true);
            }
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
            var skip_css_tracks = false;
            if (element.css_animation) |*state| {
                if (state.restart_pending) {
                    if (state.hasAnotherIteration()) {
                        restartCssAnimation(sink, element, state);
                        any_running = true;
                    } else {
                        const property_mask = state.property_mask;
                        document.finishCssAnimationTracks(element);
                        invalidateRemovedCssAnimation(sink, element, property_mask);
                    }
                    skip_css_tracks = true;
                }
            }

            if (element.animations) |*animations| {
                const css_animation_active = if (element.css_animation) |state| !state.finished else false;
                var css_tracks_complete = css_animation_active;
                var iterator = animations.iterator();
                while (iterator.next()) |entry| {
                    const is_css_track = if (element.css_animation) |state|
                        !state.finished and state.contains(entry.key_ptr.*)
                    else
                        false;
                    if (is_css_track and skip_css_tracks) continue;

                    const animation = entry.value_ptr;
                    if (!animation.isComplete()) {
                        _ = animation.advance();
                        any_running = true;
                        publishValue(sink, element, entry.key_ptr.*, animation, is_css_track);
                    }
                    if (is_css_track and !animation.isComplete()) css_tracks_complete = false;
                }

                if (!skip_css_tracks and css_animation_active and css_tracks_complete) {
                    if (element.css_animation) |*state| {
                        state.restart_pending = true;
                        // Preserve the terminal endpoint for this render,
                        // then schedule one more frame to restart or restore.
                        any_running = true;
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
