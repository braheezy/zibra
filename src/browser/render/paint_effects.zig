//! Resolves element paint effects and builds owning display-command wrappers.
//!
//! Layout owners decide when caches are dirty and provide generation-bound
//! identity. This module consumes an already-owned command slice and returns
//! one recursively owned effect tree; it never owns a layout object or cache.

const std = @import("std");
const dom = @import("../../document/dom.zig");
const ProtectedField = @import("../../core/protected_field.zig").ProtectedField;
const box_model = @import("box_model.zig");
const display_list = @import("display_list.zig");
const css_overflow = @import("../../document/css_overflow.zig");

const DisplayItem = display_list.DisplayItem;
const ScrollAttachment = display_list.ScrollAttachment;

pub const Offset = struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const ResolvedEffects = struct {
    opacity: f64 = 1.0,
    opacity_animated: bool = false,
    /// Borrowed only through `wrapOwned`, which copies a non-null value.
    blend_mode: ?[]const u8 = null,
    blur_radius: f64 = 0.0,
    border_radius: f64 = 0.0,
    clip_x: bool = false,
    clip_y: bool = false,
    translation: ?Offset = null,
    transform_animation_active: bool = false,

    pub fn clipsOverflow(self: ResolvedEffects) bool {
        return self.clip_x or self.clip_y;
    }

    pub fn needsBlendGroup(self: ResolvedEffects) bool {
        return self.opacity_animated or self.opacity < 1.0 or
            self.blend_mode != null or self.blur_radius > 0.0 or
            self.border_radius > 0.0 or self.clipsOverflow();
    }
};

pub const WrapContext = struct {
    bounds: display_list.Rect,
    position_offset: Offset = .{},
    /// Fixed-position boxes retain ordinary layout geometry, but their
    /// complete paint subtree is resolved against the owning frame viewport.
    scroll_attachment: ScrollAttachment = .document,
    identity: ?*anyopaque = null,
    source: ?display_list.DisplayItemSource = null,
};

/// Resolve live style and animation scalars without retaining the Element.
pub fn resolveElement(
    element: ?*const dom.Element,
    effective_zoom: f32,
    page_zoom: f32,
) ResolvedEffects {
    const value = element orelse return .{};
    const styles = if (value.style) |*style_map| style_map else return .{};
    var result = ResolvedEffects{};

    if (value.animations) |animations| {
        if (animations.get("opacity")) |animation| switch (animation) {
            .numeric => |numeric| {
                result.opacity = std.math.clamp(numeric.getValue(), 0.0, 1.0);
                result.opacity_animated = true;
            },
            .pixel, .color, .transform => {},
        };
    }
    if (value.svg_animation) |sample| if (sample.values.get("opacity")) |raw| {
        result.opacity = std.math.clamp(std.fmt.parseFloat(f64, raw) catch 1, 0, 1);
        result.opacity_animated = true;
    };
    if (!result.opacity_animated) {
        if (styleValue(styles, "opacity")) |raw| {
            result.opacity = std.math.clamp(
                std.fmt.parseFloat(f64, raw) catch 1.0,
                0.0,
                1.0,
            );
        }
    }

    if (styleValue(styles, "mix-blend-mode")) |mode| {
        if (mode.len > 0 and !std.mem.eql(u8, mode, "normal")) result.blend_mode = mode;
    }
    if (styleValue(styles, "filter")) |filter| {
        result.blur_radius = box_model.scaleCssFloat(
            parseBlurFilter(filter) orelse 0.0,
            effective_zoom,
            page_zoom,
        );
    }
    if (styleValue(styles, "border-radius")) |radius| {
        result.border_radius = box_model.scaleCssFloat(
            box_model.parseCssPixelRadius(radius),
            effective_zoom,
            page_zoom,
        );
    }
    // Used policy is layout output: viewport donors remain visible locally
    // without rewriting computed CSSOM values or searching the DOM in paint.
    const overflow = value.used_overflow orelse css_overflow.compute(.{
        .x = css_overflow.parse(styleValue(styles, "overflow-x") orelse "visible") orelse .visible,
        .y = css_overflow.parse(styleValue(styles, "overflow-y") orelse "visible") orelse .visible,
    });
    result.clip_x = overflow.x.clips();
    result.clip_y = overflow.y.clips();

    var animated_translation: ?dom.Translation = null;
    if (value.animations) |animations| {
        if (animations.get("transform")) |animation| {
            result.transform_animation_active = if (value.css_animation) |state|
                if (state.contains("transform")) state.isRunning() else !animation.isComplete()
            else
                !animation.isComplete();
            animated_translation = switch (animation) {
                .transform => |track| track.getValue(),
                .numeric, .pixel, .color => null,
            };
        }
    }
    if (animated_translation) |translation| {
        const pixels = translation.layoutPixels();
        result.translation = .{
            .x = box_model.scaleCssPixel(pixels.x, effective_zoom, page_zoom),
            .y = box_model.scaleCssPixel(pixels.y, effective_zoom, page_zoom),
        };
    } else if (styleValue(styles, "transform")) |transform| {
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, transform, " \t\r\n"), "none")) {
            if (dom.parseTranslate(transform)) |translation| {
                const pixels = translation.layoutPixels();
                result.translation = .{
                    .x = box_model.scaleCssPixel(pixels.x, effective_zoom, page_zoom),
                    .y = box_model.scaleCssPixel(pixels.y, effective_zoom, page_zoom),
                };
            }
        }
    }
    return result;
}

/// Parse the supported single-function CSS filter subset.
pub fn parseBlurFilter(value: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "none")) return null;

    const prefix = "blur(";
    if (!std.mem.startsWith(u8, trimmed, prefix) or !std.mem.endsWith(u8, trimmed, ")")) return null;
    const argument = std.mem.trim(u8, trimmed[prefix.len .. trimmed.len - 1], " \t\r\n");
    if (argument.len == 0) return null;

    const number = if (std.mem.endsWith(u8, argument, "px"))
        std.mem.trim(u8, argument[0 .. argument.len - 2], " \t\r\n")
    else if (std.mem.eql(u8, argument, "0"))
        argument
    else
        return null;
    const radius = std.fmt.parseFloat(f64, number) catch return null;
    if (!std.math.isFinite(radius) or radius < 0) return null;
    return radius;
}

/// Consume `commands` on both success and error. The returned slice owns all
/// recursive containers and copied mode strings; `effects.blend_mode` is only
/// borrowed for the duration of this call.
pub fn wrapOwned(
    allocator: std.mem.Allocator,
    commands: []DisplayItem,
    effects: ResolvedEffects,
    context: WrapContext,
) std.mem.Allocator.Error![]DisplayItem {
    var current = commands;

    if (effects.blur_radius > 0.0) {
        const result = allocator.alloc(DisplayItem, 1) catch |err| {
            DisplayItem.freeList(allocator, current);
            return err;
        };
        result[0] = .{ .blend = .{
            .opacity = 1.0,
            .blend_mode = null,
            .blur_radius = effects.blur_radius,
            .children = current,
            .needs_compositing = true,
            .source = context.source,
        } };
        current = result;
    }

    if (effects.needsBlendGroup()) {
        const owned_mode: ?[]u8 = if (effects.blend_mode) |mode|
            allocator.dupe(u8, mode) catch |err| {
                DisplayItem.freeList(allocator, current);
                return err;
            }
        else
            null;
        const result = allocator.alloc(DisplayItem, 1) catch |err| {
            if (owned_mode) |mode| allocator.free(mode);
            DisplayItem.freeList(allocator, current);
            return err;
        };
        const needs_compositing = effects.opacity_animated or effects.opacity < 1.0 or
            owned_mode != null or effects.blur_radius > 0.0;
        result[0] = .{ .blend = .{
            .opacity = effects.opacity,
            .blend_mode = owned_mode,
            .children = current,
            .node = context.identity,
            .needs_compositing = needs_compositing,
            .compositor_id = if (context.identity) |identity| @intFromPtr(identity) else null,
            .source = context.source,
        } };
        current = result;
    }

    if (effects.translation) |translation| {
        current = wrapTransformOwned(
            allocator,
            current,
            translation,
            context.identity,
            context.source,
            true,
            effects.transform_animation_active,
            .document,
        ) catch |err| return err;
    }
    if (context.position_offset.x != 0 or context.position_offset.y != 0) {
        current = wrapTransformOwned(
            allocator,
            current,
            context.position_offset,
            null,
            context.source,
            false,
            false,
            .document,
        ) catch |err| return err;
    }
    if (context.scroll_attachment == .frame_viewport) {
        // This must be the outermost wrapper: it discards document scroll and
        // ancestor translations before position, animation, and clipping are
        // evaluated within the fixed subtree.
        current = wrapTransformOwned(
            allocator,
            current,
            .{},
            null,
            context.source,
            false,
            false,
            .frame_viewport,
        ) catch |err| return err;
    }
    return current;
}

/// Move the content suffix under one scroll translation, leaving preceding
/// background commands stationary. Failure leaves `commands` unchanged.
pub fn wrapScrolledSuffix(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(DisplayItem),
    content_start: usize,
    scroll_x: i32,
    scroll_y: i32,
    identity: ?*anyopaque,
    source: ?display_list.DisplayItemSource,
) std.mem.Allocator.Error!void {
    if ((scroll_x <= 0 and scroll_y <= 0) or content_start >= commands.items.len) return;
    const children = try allocator.alloc(DisplayItem, commands.items.len - content_start);
    @memcpy(children, commands.items[content_start..]);
    commands.shrinkRetainingCapacity(content_start);
    commands.appendAssumeCapacity(.{ .transform = .{
        .translate_x = -scroll_x,
        .translate_y = -scroll_y,
        .children = children,
        .node = identity,
        .source = source,
    } });
}

/// Move a content suffix into an owning axis clip, preserving the caller's
/// stationary background/border prefix. Failure leaves the list unchanged.
pub fn wrapOverflowSuffix(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(DisplayItem),
    content_start: usize,
    clip: display_list.AxisClip,
    source: ?display_list.DisplayItemSource,
) std.mem.Allocator.Error!void {
    if ((!clip.clip_x and !clip.clip_y) or content_start >= commands.items.len) return;
    const children = try allocator.alloc(DisplayItem, commands.items.len - content_start);
    @memcpy(children, commands.items[content_start..]);
    commands.shrinkRetainingCapacity(content_start);
    commands.appendAssumeCapacity(.{ .blend = .{
        .opacity = 1.0,
        .blend_mode = null,
        .overflow_clip = clip,
        .children = children,
        .needs_compositing = true,
        .source = source,
    } });
}

fn styleValue(style_map: *const dom.StyleMap, property: []const u8) ?[]const u8 {
    const field = @constCast(style_map).getPtr(property) orelse return null;
    return field.get().*;
}

fn wrapTransformOwned(
    allocator: std.mem.Allocator,
    children: []DisplayItem,
    offset: Offset,
    identity: ?*anyopaque,
    source: ?display_list.DisplayItemSource,
    composited: bool,
    animation_active: bool,
    scroll_attachment: ScrollAttachment,
) std.mem.Allocator.Error![]DisplayItem {
    const result = allocator.alloc(DisplayItem, 1) catch |err| {
        DisplayItem.freeList(allocator, children);
        return err;
    };
    result[0] = .{ .transform = .{
        .translate_x = offset.x,
        .translate_y = offset.y,
        .scroll_attachment = scroll_attachment,
        .children = children,
        .node = identity,
        .composited = composited,
        .animation_active = animation_active,
        .compositor_id = if (identity) |value| @intFromPtr(value) else null,
        .source = source,
    } };
    return result;
}

test "blur parser accepts only the supported single pixel filter" {
    try std.testing.expectEqual(@as(?f64, 4.5), parseBlurFilter(" blur( 4.5px ) "));
    try std.testing.expectEqual(@as(?f64, 0.0), parseBlurFilter("blur(0)"));
    try std.testing.expect(parseBlurFilter("blur(-1px)") == null);
    try std.testing.expect(parseBlurFilter("grayscale(1)") == null);
    try std.testing.expect(parseBlurFilter("blur(2em)") == null);
    try std.testing.expect(parseBlurFilter("blur(2px) opacity(.5)") == null);
}

test "overflow effects use the committed axis policy without requiring scroll range" {
    const allocator = std.testing.allocator;
    var element = try dom.Element.init(allocator, "div", null);
    defer element.deinit(allocator);
    element.style = dom.StyleMap.init(allocator);

    var overflow = ProtectedField([]const u8).init("hidden");
    overflow.set("hidden");
    var overflow_installed = false;
    errdefer if (!overflow_installed) overflow.deinit(allocator);
    try element.style.?.put("overflow-x", overflow);
    overflow_installed = true;

    const effects = resolveElement(&element, 1.0, 1.0);
    try std.testing.expect(effects.clip_x and effects.clip_y);
    try std.testing.expect(effects.needsBlendGroup());
    element.used_overflow = .{};
    try std.testing.expect(!resolveElement(&element, 1.0, 1.0).clipsOverflow());
    element.used_overflow = .{ .x = .clip, .y = .visible };
    const single = resolveElement(&element, 1.0, 1.0);
    try std.testing.expect(single.clip_x and !single.clip_y);
}

test "whole-box effect wrappers preserve filter blend transform and position order" {
    var identity: u8 = 0;
    const commands = try std.testing.allocator.alloc(DisplayItem, 1);
    commands[0] = .{ .rect = .{
        .x1 = 0,
        .y1 = 0,
        .x2 = 20,
        .y2 = 20,
        .color = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
    } };
    const result = try wrapOwned(std.testing.allocator, commands, .{
        .opacity = 0.5,
        .blend_mode = "multiply",
        .blur_radius = 2.0,
        .border_radius = 4.0,
        .translation = .{ .x = 3, .y = 4 },
        .transform_animation_active = true,
    }, .{
        .bounds = .{ .left = 0, .top = 0, .right = 20, .bottom = 20 },
        .position_offset = .{ .x = 1, .y = 2 },
        .identity = @ptrCast(&identity),
    });
    defer DisplayItem.freeList(std.testing.allocator, result);

    const positioned = result[0].transform;
    try std.testing.expectEqual(@as(i32, 1), positioned.translate_x);
    const transformed = positioned.children[0].transform;
    try std.testing.expect(transformed.animation_active);
    try std.testing.expectEqual(@as(i32, 3), transformed.translate_x);
    const outer = transformed.children[0].blend;
    try std.testing.expectEqualStrings("multiply", outer.blend_mode.?);
    try std.testing.expect(outer.hit_clip == null);
    try std.testing.expectEqual(@as(usize, 1), outer.children.len);
    try std.testing.expectEqual(@as(f64, 2.0), outer.children[0].blend.blur_radius);
}

test "viewport-attached effects wrap the complete subtree outermost" {
    const commands = try std.testing.allocator.alloc(DisplayItem, 1);
    commands[0] = .{ .rect = .{
        .x1 = 0,
        .y1 = 0,
        .x2 = 20,
        .y2 = 20,
        .color = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
    } };
    const result = try wrapOwned(std.testing.allocator, commands, .{
        .translation = .{ .x = 3, .y = 4 },
    }, .{
        .bounds = .{ .left = 0, .top = 0, .right = 20, .bottom = 20 },
        .position_offset = .{ .x = 1, .y = 2 },
        .scroll_attachment = .frame_viewport,
    });
    defer DisplayItem.freeList(std.testing.allocator, result);

    const viewport = result[0].transform;
    try std.testing.expectEqual(ScrollAttachment.frame_viewport, viewport.scroll_attachment);
    const positioned = viewport.children[0].transform;
    try std.testing.expectEqual(@as(i32, 1), positioned.translate_x);
    const transformed = positioned.children[0].transform;
    try std.testing.expectEqual(@as(i32, 3), transformed.translate_x);
}

test "border radius does not clip visible descendants and cached edges remain shallow" {
    var retained = std.ArrayList(DisplayItem).empty;
    defer retained.deinit(std.testing.allocator);
    try retained.append(std.testing.allocator, .{ .rect = .{
        .x1 = 0,
        .y1 = 0,
        .x2 = 5,
        .y2 = 5,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    } });
    const commands = try std.testing.allocator.alloc(DisplayItem, 1);
    commands[0] = .{ .cached_subtree = .{ .list = &retained } };
    const result = try wrapOwned(std.testing.allocator, commands, .{
        .border_radius = 3,
    }, .{ .bounds = .{ .left = 0, .top = 0, .right = 5, .bottom = 5 } });
    defer DisplayItem.freeList(std.testing.allocator, result);
    try std.testing.expect(!result[0].blend.needs_compositing);
    try std.testing.expect(result[0].blend.hit_clip == null);
    try std.testing.expect(result[0].blend.overflow_clip == null);
    try std.testing.expect(result[0].blend.children[0] == .cached_subtree);
    try std.testing.expect(result[0].blend.children[0].cached_subtree.list == &retained);
}

test "scroll wrapping leaves the background stationary" {
    var commands = std.ArrayList(DisplayItem).empty;
    defer {
        DisplayItem.freeItems(std.testing.allocator, commands.items);
        commands.deinit(std.testing.allocator);
    }
    for (0..2) |index| try commands.append(std.testing.allocator, .{ .rect = .{
        .x1 = @intCast(index * 10),
        .y1 = 0,
        .x2 = @intCast(index * 10 + 10),
        .y2 = 10,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    } });
    try wrapScrolledSuffix(std.testing.allocator, &commands, 1, 0, 12, null, null);
    try std.testing.expect(commands.items[0] == .rect);
    try std.testing.expect(commands.items[1] == .transform);
    try std.testing.expectEqual(@as(i32, -12), commands.items[1].transform.translate_y);
    try std.testing.expectEqual(@as(i32, 10), commands.items[1].transform.children[0].rect.x1);
}

fn allocationFailureCase(allocator: std.mem.Allocator) !void {
    const commands = try allocator.alloc(DisplayItem, 1);
    commands[0] = .{ .rect = .{
        .x1 = 0,
        .y1 = 0,
        .x2 = 20,
        .y2 = 20,
        .color = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
    } };
    const result = try wrapOwned(allocator, commands, .{
        .opacity = 0.5,
        .blend_mode = "multiply",
        .blur_radius = 2,
        .border_radius = 4,
        .translation = .{ .x = 3, .y = 4 },
    }, .{
        .bounds = .{ .left = 0, .top = 0, .right = 20, .bottom = 20 },
        .position_offset = .{ .x = 1, .y = 2 },
    });
    defer DisplayItem.freeList(allocator, result);
}

test "full effect wrapping cleans every allocation-failure path" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailureCase,
        .{},
    );
}

fn suffixAllocationFailureCase(allocator: std.mem.Allocator) !void {
    var commands = std.ArrayList(DisplayItem).empty;
    defer {
        DisplayItem.freeItems(allocator, commands.items);
        commands.deinit(allocator);
    }
    for (0..2) |index| try commands.append(allocator, .{ .rect = .{
        .x1 = @intCast(index * 10),
        .y1 = 0,
        .x2 = 20,
        .y2 = 20,
        .color = .{ .r = 255, .g = 0, .b = 0 },
    } });
    wrapOverflowSuffix(allocator, &commands, 1, .{
        .x1 = 5,
        .y1 = 5,
        .x2 = 15,
        .y2 = 15,
        .clip_y = false,
    }, null) catch |err| {
        try std.testing.expectEqual(@as(usize, 2), commands.items.len);
        try std.testing.expect(commands.items[0] == .rect and commands.items[1] == .rect);
        return err;
    };
    try std.testing.expect(commands.items[0] == .rect);
    try std.testing.expect(commands.items[1].blend.overflow_clip.?.clip_x);
    try std.testing.expect(!commands.items[1].blend.overflow_clip.?.clip_y);
    try std.testing.expectEqual(@as(i32, 10), commands.items[1].blend.children[0].rect.x1);
}

test "overflow suffix preserves the stationary shell on success and allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, suffixAllocationFailureCase, .{});
}
