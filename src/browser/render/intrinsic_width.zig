//! Synchronous intrinsic inline-width measurement over a styled DOM borrow.
//! Owns no DOM/layout pointers; glyph resources remain in the FontManager.
const std = @import("std");
const dom = @import("../../document/dom.zig");
const length = @import("../../document/length.zig");
const font = @import("font.zig");
const grapheme = @import("grapheme");
const box_model = @import("box_model.zig");
const inline_format = @import("inline_format.zig");
const replaced_sizing = @import("replaced_sizing.zig");
const sizing = @import("sizing.zig");
const css_display = @import("../../document/css_display.zig");
const css_overflow = @import("../../document/css_overflow.zig");
const css_flex = @import("../../document/css_flex.zig");
const flex_format = @import("flex_format.zig");
const grid_format = @import("grid_format.zig");

pub const Width = struct {
    min: f64 = 0,
    max: f64 = 0,
    // Collapsible whitespace is resolved across adjacent inline node edges,
    // not independently trimmed out of every DOM text node.
    leading_space: f64 = 0,
    trailing_space: f64 = 0,
};
fn value(styles: ?dom.StyleMap, name: []const u8, default: []const u8) []const u8 {
    if (styles) |map| if (map.get(name)) |field| return field.get().*;
    return default;
}

/// Native input natural content width, shared with final control layout.
/// CSS preferred/min/max sizes and box edges are applied by the caller.
pub fn inputNaturalWidth(element: dom.Element, fonts: *font.FontManager, scale: f64) !f64 {
    if (std.ascii.eqlIgnoreCase(element.tag, "audio")) return @import("../../media/controls.zig").natural_width * scale;
    const size = length.parsePixel(value(element.style, "font-size", "16px")) orelse 16;
    const weight: font.FontWeight = if (font.isBoldWeight(value(element.style, "font-weight", "normal"))) .Bold else .Normal;
    const slant: font.FontSlant = if (std.ascii.eqlIgnoreCase(value(element.style, "font-style", "normal"), "italic")) .Italic else .Roman;
    const family = font.familyFromCss(value(element.style, "font-family", "sans-serif"));
    const raster_size = font.rasterSizeForCssPixels(size * scale);
    if (element.isInputType("submit") or element.isInputType("reset") or element.isInputType("button")) {
        const fallback: []const u8 = if (element.isInputType("submit")) "Submit" else if (element.isInputType("reset")) "Reset" else "";
        const label = if (element.attributes) |attrs| attrs.get("value") orelse fallback else fallback;
        var width: f64 = 8 * scale;
        var characters = grapheme.iterator(label);
        while (characters.next()) |character| {
            const glyph = try fonts.getStyledGlyph(character.bytes(label), weight, slant, raster_size, family);
            width += @floatFromInt(glyph.w);
        }
        return width;
    }
    if (element.attributes) |attrs| if (attrs.get("size")) |raw| {
        const count = std.fmt.parseInt(u32, std.mem.trim(u8, raw, " \t\r\n"), 10) catch 0;
        if (count > 0) {
            const glyph = try fonts.getStyledGlyph("0", weight, slant, raster_size, family);
            return @as(f64, @floatFromInt(glyph.w)) * @as(f64, @floatFromInt(@min(count, 100_000)));
        }
    };
    return 200 * scale;
}

/// Natural content widths ignore the root's width/min/max and its own edges.
/// Descendants contribute constrained outer sizes. Image roots intentionally
/// retain the shared replaced resolver's ratio/constraint policy.
/// The caller registers descendant style reads with a persistent layout owner.
pub fn measureContent(node: *const dom.Node, fonts: *font.FontManager, scale: f64) anyerror!Width {
    return measureImpl(node, fonts, scale, false);
}

/// Intrinsic keyword widths can transfer a definite height through a ratio.
/// `natural` remains the separate raw content suggestion for automatic minima;
/// it and `scale` describe this root, with authored zoom already composed.
pub fn keywordContent(node: *const dom.Node, natural: Width, scale: f64) Width {
    if (node.* != .element) return natural;
    return ratioContent(node.element, scale) orelse natural;
}

/// Constrained root content widths, excluding its padding, borders and margins.
/// `scale` already includes this root's authored zoom; descendants add theirs.
pub fn measure(node: *const dom.Node, fonts: *font.FontManager, scale: f64) anyerror!Width {
    return measureImpl(node, fonts, scale, true);
}

/// Constrained root contribution including padding, borders and margins once.
/// Intrinsic percentage sizes/edges have no containing-block basis here.
pub fn measureOuter(node: *const dom.Node, fonts: *font.FontManager, scale: f64) anyerror!Width {
    if (!participates(node)) return .{};
    var result = try measure(node, fonts, scale);
    if (node.* == .element) {
        const edges = rootEdges(node.element, scale);
        const extra: f64 = @floatFromInt(edges.margin.horizontal() + edges.padding.horizontal() + edges.border.horizontal());
        result.min = @max(result.min + extra, 0);
        result.max = @max(result.max + extra, result.min);
    }
    return result;
}

fn participates(node: *const dom.Node) bool {
    if (node.* != .element) return true;
    const element = &node.element;
    if (element.isHiddenInput() or element.isHiddenAudio() or std.ascii.eqlIgnoreCase(value(element.style, "display", "inline"), "none")) return false;
    const position = value(element.style, "position", "static");
    return !std.ascii.eqlIgnoreCase(position, "absolute") and !std.ascii.eqlIgnoreCase(position, "fixed");
}

fn rootEdges(element: dom.Element, scale: f64) box_model.BoxModelEdges {
    const size = length.parsePixel(value(element.style, "font-size", "16px")) orelse 16;
    return if (element.style) |styles| box_model.resolveBoxEdges(&styles, size, null, @floatCast(scale), 1) else .{ .margin = .{}, .padding = .{}, .border = .{} };
}

fn ratioContent(element: dom.Element, scale: f64) ?Width {
    // Replaced/native boxes retain their dedicated natural-size policies.
    if (element.image_data != null) return null;
    for ([_][]const u8{ "img", "input", "textarea", "audio", "svg", "iframe", "canvas", "select", "button" }) |tag| {
        if (std.ascii.eqlIgnoreCase(element.tag, tag)) return null;
    }
    const aspect = replaced_sizing.parseAspectRatio(value(element.style, "aspect-ratio", "auto")) orelse return null;
    const ratio = aspect.ratio orelse return null;
    const edges = rootEdges(element, scale);
    const x_edges: f64 = @floatFromInt(edges.padding.horizontal() + edges.border.horizontal());
    const y_edges: f64 = @floatFromInt(edges.padding.vertical() + edges.border.vertical());
    const border_box = std.ascii.eqlIgnoreCase(value(element.style, "box-sizing", "content-box"), "border-box");
    const context = sizing.ResolveContext{
        .font_size = length.parsePixel(value(element.style, "font-size", "16px")) orelse 16,
        .scale = scale,
        .insets = y_edges,
        .border_box = border_box,
    };
    // No percentage height basis exists during this synchronous traversal.
    const height = sizing.resolve(value(element.style, "height", "auto"), context) orelse return null;
    const limits = sizing.Constraints{
        .min = sizing.resolve(value(element.style, "min-height", "auto"), context) orelse 0,
        .max = sizing.resolve(value(element.style, "max-height", "none"), context) orelse std.math.inf(f64),
    };
    const use_border = border_box and !aspect.use_intrinsic;
    const width = std.math.clamp((limits.clamp(height) + if (use_border) y_edges else @as(f64, 0)) * ratio - if (use_border) x_edges else @as(f64, 0), 0, sizing.max_intrinsic_extent);
    return .{ .min = width, .max = width };
}

fn constrainedContent(element: dom.Element, natural: Width, scale: f64, blockified: bool) Width {
    // Ordinary inline boxes ignore width/min/max; atomic/replaced boxes and
    // blockified flex/grid roots use their own sizing policy instead.
    if (!blockified and std.ascii.eqlIgnoreCase(value(element.style, "display", "inline"), "inline") and
        std.ascii.eqlIgnoreCase(value(element.style, "float", "none"), "none") and
        !std.ascii.eqlIgnoreCase(element.tag, "input") and !std.ascii.eqlIgnoreCase(element.tag, "textarea") and
        !std.ascii.eqlIgnoreCase(element.tag, "audio") and !std.ascii.eqlIgnoreCase(element.tag, "svg")) return natural;
    const transferred = ratioContent(element, scale);
    const intrinsic = transferred orelse natural;
    var result = intrinsic;
    result.min = constrainedValue(element, natural, intrinsic, transferred != null, scale, intrinsic.min);
    result.max = @max(result.min, constrainedValue(element, natural, intrinsic, transferred != null, scale, intrinsic.max));
    return result;
}

fn constrainedValue(element: dom.Element, natural: Width, intrinsic: Width, transferred: bool, scale: f64, available: f64) f64 {
    const edges = rootEdges(element, scale);
    const context = sizing.ResolveContext{
        .font_size = length.parsePixel(value(element.style, "font-size", "16px")) orelse 16,
        .scale = scale,
        .insets = @floatFromInt(edges.padding.horizontal() + edges.border.horizontal()),
        .border_box = std.ascii.eqlIgnoreCase(value(element.style, "box-sizing", "content-box"), "border-box"),
        .intrinsic = .{ .min = intrinsic.min, .max = intrinsic.max },
        .available = available,
    };
    const maximum = sizing.resolve(value(element.style, "max-width", "none"), context) orelse std.math.inf(f64);
    const raw_width = value(element.style, "width", "auto");
    const overflow = css_overflow.parse(value(element.style, "overflow-x", "visible")) orelse .visible;
    const content_minimum = transferred and length.resolve(raw_width, .{ .font_size = context.font_size }) == null and
        std.ascii.eqlIgnoreCase(value(element.style, "min-width", "auto"), "auto") and
        !overflow.isScrollable();
    const limits = sizing.Constraints{
        .min = sizing.resolve(value(element.style, "min-width", "auto"), context) orelse if (content_minimum) @min(natural.min, maximum) else 0,
        .max = maximum,
    };
    const preferred = sizing.resolve(raw_width, context);
    return limits.clamp(preferred orelse available);
}

// Private generated boxes bracket authored children; they are not entries in
// the authored DOM array. This cursor borrows each node only during traversal.
const DirectChildren = struct {
    element: *const dom.Element,
    cursor: usize = 0,

    fn next(self: *DirectChildren) ?*const dom.Node {
        while (self.cursor < self.element.children.items.len + 2) {
            const index = self.cursor;
            self.cursor += 1;
            if (index > 0 and index <= self.element.children.items.len) return &self.element.children.items[index - 1];
            const generated = (if (index == 0) self.element.generated_before else self.element.generated_after) orelse continue;
            if (generated.* == .element and generated.element.generatedPseudoActive()) return generated;
        }
        return null;
    }
};

const FormattingItem = struct {
    flex: flex_format.IntrinsicItem,
    cross: Width,
    preferred: ?f64 = null,
    automatic_minimum: bool = false,
    scrollable: bool = false,
    insets: f64 = 0,
    order: i32 = 0,
};

fn formattingItem(node: *const dom.Node, natural_width: Width, scale: f64, definite_cross_height: ?f64) FormattingItem {
    if (node.* != .element) return .{
        .flex = .{ .item = .{ .basis = natural_width.max, .min = natural_width.min }, .min_content = natural_width.min, .max_content = natural_width.max, .content_basis = true },
        .cross = natural_width,
        .automatic_minimum = true,
    };
    const element = node.element;
    const styles = element.style;
    const edges = rootEdges(element, scale);
    const x_edges: f64 = @floatFromInt(edges.padding.horizontal() + edges.border.horizontal());
    const y_edges: f64 = @floatFromInt(edges.padding.vertical() + edges.border.vertical());
    const border_box = flex_format.eq(value(styles, "box-sizing", "content-box"), "border-box");
    const replaced = element.image_data != null or flex_format.eq(element.tag, "img");
    var natural = natural_width;
    if (element.image_data) |data| {
        const raw = @as(f64, @floatFromInt(data.image.width)) * scale;
        natural = .{ .min = raw, .max = raw };
    }
    const keywords = keywordContent(node, natural, scale);
    const context = sizing.ResolveContext{
        .font_size = length.parsePixel(value(styles, "font-size", "16px")) orelse 16,
        .scale = scale,
        .insets = x_edges,
        .border_box = border_box,
        .intrinsic = .{ .min = keywords.min, .max = keywords.max },
    };
    const preferred = sizing.resolve(value(styles, "width", "auto"), context);
    const minimum = sizing.resolve(value(styles, "min-width", "auto"), context);
    const maximum = sizing.resolve(value(styles, "max-width", "none"), context);
    const overflow = css_overflow.parse(value(styles, "overflow-x", "visible")) orelse .visible;
    const scrollable = overflow.isScrollable();
    const automatic = minimum == null and flex_format.eq(value(styles, "min-width", "auto"), "auto");

    const aspect = replaced_sizing.parseAspectRatio(value(styles, "aspect-ratio", "auto")) orelse replaced_sizing.AspectRatio.auto;
    var ratio = aspect.ratio;
    if (element.image_data) |data| if ((aspect.use_intrinsic or ratio == null) and data.image.height > 0) {
        ratio = @as(f64, @floatFromInt(data.image.width)) / @as(f64, @floatFromInt(data.image.height));
    };
    var transferred: ?f64 = null;
    if (ratio) |r| {
        const cross_context = sizing.ResolveContext{
            .font_size = context.font_size,
            .percentage_base = if (definite_cross_height) |height| height / scale else null,
            .scale = scale,
            .insets = y_edges,
            .border_box = border_box,
        };
        const cross_min = sizing.resolve(value(styles, "min-height", "auto"), cross_context);
        const cross_max = sizing.resolve(value(styles, "max-height", "none"), cross_context);
        const use_border = border_box and !replaced and !aspect.use_intrinsic;
        const content_bounds = sizing.Constraints{
            .min = if (cross_min) |h| @max((h + if (use_border) y_edges else @as(f64, 0)) * r - if (use_border) x_edges else @as(f64, 0), 0) else 0,
            .max = if (cross_max) |h| @max((h + if (use_border) y_edges else @as(f64, 0)) * r - if (use_border) x_edges else @as(f64, 0), 0) else std.math.inf(f64),
        };
        natural.min = content_bounds.clamp(natural.min);
        natural.max = @max(natural.min, content_bounds.clamp(natural.max));
        if (sizing.resolve(value(styles, "height", "auto"), cross_context)) |h| {
            const cross_limits = sizing.Constraints{ .min = cross_min orelse 0, .max = cross_max orelse std.math.inf(f64) };
            transferred = @max((cross_limits.clamp(h) + if (use_border) y_edges else @as(f64, 0)) * r - if (use_border) x_edges else @as(f64, 0), 0);
        }
    }
    const limits = sizing.Constraints{
        .min = minimum orelse if (automatic) sizing.automaticMinimum(.{
            .content = natural.min,
            .specified = preferred,
            .transferred = transferred,
            .maximum = maximum,
            .replaced = replaced,
            .scrollable = scrollable,
        }) else 0,
        .max = maximum orelse std.math.inf(f64),
    };
    const raw_basis = value(styles, "flex-basis", "auto");
    const specified_basis = sizing.resolve(raw_basis, context);
    const content_basis = !flex_format.eq(raw_basis, "auto") and specified_basis == null;
    const basis = specified_basis orelse (if (content_basis) transferred orelse natural.max else preferred orelse transferred orelse natural.max);
    const measured_basis = if (specified_basis != null)
        length.resolve(raw_basis, .{ .font_size = context.font_size }) == null
    else if ((content_basis or preferred == null) and transferred != null)
        false
    else if (content_basis)
        true
    else
        preferred == null or length.resolve(value(styles, "width", "auto"), .{ .font_size = context.font_size }) == null;
    // Raw natural image dimensions remain the content suggestion for the
    // automatic minimum. An auto-width item's intrinsic contribution follows
    // its resolved cross-size ratio, just as its content-based flex basis does.
    const contribution = if (preferred == null and transferred != null)
        Width{ .min = transferred.?, .max = transferred.? }
    else
        natural;
    const before: f64 = @floatFromInt(edges.margin.left);
    const after: f64 = @floatFromInt(edges.margin.right);
    var cross = constrainedContent(element, natural_width, scale, true);
    cross.min = @max(cross.min + x_edges + before + after, 0);
    cross.max = @max(cross.max + x_edges + before + after, cross.min);
    return .{
        .flex = .{
            .item = .{
                .basis = basis + x_edges,
                .inner_basis = basis,
                .min = limits.min + x_edges,
                .max = limits.max + x_edges,
                .grow = css_flex.factor(value(styles, "flex-grow", "0")) orelse 0,
                .shrink = css_flex.factor(value(styles, "flex-shrink", "1")) orelse 1,
                .before = before,
                .after = after,
            },
            .min_content = limits.clamp(@max(contribution.min, preferred orelse 0)) + x_edges,
            .max_content = limits.clamp(@max(contribution.max, preferred orelse 0)) + x_edges,
            .content_basis = measured_basis,
        },
        .cross = cross,
        .preferred = if (preferred) |width| width + x_edges else null,
        .automatic_minimum = automatic,
        .scrollable = scrollable,
        .insets = x_edges,
        .order = std.fmt.parseInt(i32, value(styles, "order", "0"), 10) catch 0,
    };
}

fn gridContribution(item: FormattingItem, track: grid_format.Track) grid_format.Contribution {
    const margins = item.flex.item.before + item.flex.item.after;
    var minimum = if (item.automatic_minimum and (track.min_kind != .auto or item.scrollable)) item.insets else item.flex.item.min;
    if (item.automatic_minimum and track.max_kind == .fixed) minimum = @max(item.insets, @min(minimum, (track.max orelse track.min) - margins));
    const limits = sizing.Constraints{ .min = minimum, .max = item.flex.item.max };
    var minimum_contribution = limits.clamp(item.preferred orelse minimum);
    if (item.automatic_minimum and track.max_kind == .fixed) minimum_contribution = @max(item.insets, @min(minimum_contribution, (track.max orelse track.min) - margins));
    return .{
        .minimum = minimum_contribution + margins,
        .min_content = limits.clamp(item.cross.min - margins) + margins,
        .max_content = limits.clamp(item.cross.max - margins) + margins,
    };
}

fn appendAnonymous(items: *std.ArrayList(FormattingItem), allocator: std.mem.Allocator, measured: Width, nowrap: bool) !void {
    if (measured.max == 0) return;
    var contribution = measured;
    if (nowrap) contribution.min = contribution.max;
    try items.append(allocator, .{
        .flex = .{ .item = .{ .basis = contribution.max, .min = contribution.min }, .min_content = contribution.min, .max_content = contribution.max, .content_basis = true },
        .cross = contribution,
        .automatic_minimum = true,
    });
}

fn measureFormatting(element: dom.Element, fonts: *font.FontManager, scale: f64, kind: css_display.FormattingKind) !Width {
    var items: std.ArrayList(FormattingItem) = .empty;
    defer items.deinit(fonts.allocator);
    const styles = element.style;
    const font_size = length.parsePixel(value(styles, "font-size", "16px")) orelse 16;
    const direction = value(styles, "flex-direction", "row");
    const column_direction = flex_format.eq(direction, "column") or flex_format.eq(direction, "column-reverse");
    const definite_cross_height: ?f64 = if (kind == .flex and !column_direction) blk: {
        const edges = rootEdges(element, scale);
        const context = sizing.ResolveContext{
            .font_size = font_size,
            .scale = scale,
            .insets = @floatFromInt(edges.padding.vertical() + edges.border.vertical()),
            .border_box = flex_format.eq(value(styles, "box-sizing", "content-box"), "border-box"),
        };
        // Only the root's resolvable authored height supplies this cross basis.
        // Its own percentage height still has no external containing basis.
        const height = sizing.resolve(value(styles, "height", "auto"), context) orelse break :blk null;
        const limits = sizing.Constraints{
            .min = sizing.resolve(value(styles, "min-height", "auto"), context) orelse 0,
            .max = sizing.resolve(value(styles, "max-height", "none"), context) orelse std.math.inf(f64),
        };
        break :blk limits.clamp(height);
    } else null;
    var children = DirectChildren{ .element = &element };
    var anonymous: Width = .{};
    var pending_space: f64 = 0;
    const nowrap = flex_format.eq(value(element.style, "white-space", "normal"), "nowrap");
    while (children.next()) |child| {
        if (child.* == .text) {
            const measured = try measureContent(child, fonts, scale);
            if (measured.max > 0) {
                if (anonymous.max > 0) anonymous.max += @max(pending_space, measured.leading_space);
                anonymous.max += measured.max;
                anonymous.min = @max(anonymous.min, measured.min);
                pending_space = measured.trailing_space;
            } else pending_space = @max(pending_space, measured.trailing_space);
            continue;
        }
        try appendAnonymous(&items, fonts.allocator, anonymous, nowrap);
        anonymous = .{};
        pending_space = 0;
        if (!participates(child)) continue;
        const child_scale = scale * box_model.parseCssZoom(value(child.element.style, "zoom", "1"));
        const natural = try measureContent(child, fonts, child_scale);
        try items.append(fonts.allocator, formattingItem(child, natural, child_scale, definite_cross_height));
    }
    try appendAnonymous(&items, fonts.allocator, anonymous, nowrap);
    const gap = (length.resolve(value(styles, "column-gap", "normal"), .{ .font_size = font_size }) orelse 0) * scale;
    if (kind == .flex) {
        if (column_direction) {
            var result: Width = .{};
            for (items.items) |item| {
                result.min = @max(result.min, item.cross.min);
                result.max = @max(result.max, item.cross.max);
            }
            return result;
        }
        const input = try fonts.allocator.alloc(flex_format.IntrinsicItem, items.items.len);
        defer fonts.allocator.free(input);
        for (items.items, input) |item, *entry| entry.* = item.flex;
        const result = flex_format.intrinsicSize(input, gap, !flex_format.eq(value(styles, "flex-wrap", "nowrap"), "nowrap"));
        return .{ .min = result.min, .max = result.max };
    }
    std.mem.sort(FormattingItem, items.items, {}, struct {
        fn less(_: void, a: FormattingItem, b: FormattingItem) bool {
            return a.order < b.order;
        }
    }.less);
    var columns: [grid_format.tracks.max_tracks]grid_format.Track = undefined;
    var count = grid_format.tracks.parse(value(styles, "grid-template-columns", "none"), .{ .font_size = font_size }, gap / scale, items.items.len, &columns) orelse 0;
    if (count == 0) {
        count = 1;
        columns[0] = grid_format.tracks.parseTrack(value(styles, "grid-auto-columns", "auto"), .{ .font_size = font_size }) orelse .{};
    }
    for (columns[0..count]) |*track| {
        track.min *= scale;
        if (track.max) |maximum| track.max = maximum * scale;
    }
    var contributions: [grid_format.tracks.max_tracks]grid_format.Contribution = @splat(.{});
    for (items.items, 0..) |item, i| {
        const column = i % count;
        const measured = gridContribution(item, columns[column]);
        contributions[column].minimum = @max(contributions[column].minimum, measured.minimum);
        contributions[column].min_content = @max(contributions[column].min_content, measured.min_content);
        contributions[column].max_content = @max(contributions[column].max_content, measured.max_content);
    }
    var scratch: [grid_format.tracks.max_tracks]f64 = undefined;
    const minimum = grid_format.intrinsicSize(columns[0..count], contributions[0..count], gap, .min_content, scratch[0..count]);
    const maximum = grid_format.intrinsicSize(columns[0..count], contributions[0..count], gap, .max_content, scratch[0..count]);
    return .{ .min = minimum, .max = @max(minimum, maximum) };
}

fn measureImpl(node: *const dom.Node, fonts: *font.FontManager, scale: f64, include_specified: bool) anyerror!Width {
    return switch (node.*) {
        .text => |text| blk: {
            if (text.text.len == 0) break :blk .{};
            const size = length.parsePixel(value(text.style, "font-size", "16px")) orelse 16;
            const weight: font.FontWeight = if (font.isBoldWeight(value(text.style, "font-weight", "normal"))) .Bold else .Normal;
            const style = value(text.style, "font-style", "normal");
            const slant: font.FontSlant = if (std.ascii.eqlIgnoreCase(style, "italic") or std.ascii.eqlIgnoreCase(style, "oblique")) .Italic else .Roman;
            const family = font.familyFromCss(value(text.style, "font-family", "sans-serif"));
            const raster_size = font.rasterSizeForCssPixels(size * scale);
            const space = try fonts.getStyledGlyph(" ", weight, slant, raster_size, family);
            const decoded = try text.decoded(fonts.allocator);
            defer if (decoded) |bytes| fonts.allocator.free(bytes);
            const bytes = decoded orelse text.text;
            if (bytes.len == 0) break :blk .{};
            var words = std.mem.tokenizeAny(u8, bytes, " \t\r\n\x0c");
            var result: Width = .{};
            if (std.ascii.isWhitespace(bytes[0])) result.leading_space = @floatFromInt(space.w);
            if (std.ascii.isWhitespace(bytes[bytes.len - 1])) result.trailing_space = @floatFromInt(space.w);
            while (words.next()) |word| {
                // Paint currently advances one grapheme at a time. Measuring
                // a kerned whole word here can under-allocate its atomic box.
                var width: f64 = 0;
                var characters = grapheme.iterator(word);
                while (characters.next()) |character| {
                    const glyph = try fonts.getStyledGlyph(character.bytes(word), weight, slant, raster_size, family);
                    width += @floatFromInt(glyph.w);
                }
                if (result.max > 0) result.max += @floatFromInt(space.w);
                result.max += width;
                result.min = @max(result.min, width);
            }
            if (std.ascii.eqlIgnoreCase(value(text.style, "white-space", "normal"), "nowrap")) result.min = result.max;
            break :blk result;
        },
        .element => |element| blk: {
            if (!participates(node)) break :blk .{};
            const size = length.parsePixel(value(element.style, "font-size", "16px")) orelse 16;
            if (std.ascii.eqlIgnoreCase(element.tag, "img") or element.image_data != null) {
                const edges = if (element.style) |styles| box_model.resolveBoxEdges(&styles, size, null, 1, 1) else box_model.BoxModelEdges{ .margin = .{}, .padding = .{}, .border = .{} };
                const natural: ?replaced_sizing.Size = if (element.image_data) |data| .{ .width = @intCast(data.image.width), .height = @intCast(data.image.height) } else null;
                // Cyclic percentages have no basis during intrinsic sizing.
                // Definite caps on either axis still transfer through the
                // image's ratio before flex/table measure their contents.
                const used = replaced_sizing.imageSizeWithContext(&element, natural, .{
                    .font_size = size,
                    .insets = .{ .width = edges.padding.horizontal() + edges.border.horizontal(), .height = edges.padding.vertical() + edges.border.vertical() },
                });
                const width = @as(f64, @floatFromInt(used.width)) * scale;
                break :blk .{ .min = width, .max = width };
            }
            if (std.ascii.eqlIgnoreCase(element.tag, "input") or std.ascii.eqlIgnoreCase(element.tag, "textarea") or std.ascii.eqlIgnoreCase(element.tag, "audio")) {
                const width = if (element.isCheckbox() or element.isInputType("radio")) size * scale else try inputNaturalWidth(element, fonts, scale);
                const natural = Width{ .min = width, .max = width };
                break :blk if (include_specified) constrainedContent(element, natural, scale, false) else natural;
            }
            if (std.ascii.eqlIgnoreCase(element.tag, "svg")) {
                const dimensions = @import("svg_inline.zig").size(&element, .{ .font_size = size });
                const width = @as(f64, @floatFromInt(dimensions.width)) * scale;
                const natural = Width{ .min = width, .max = width };
                break :blk if (include_specified) constrainedContent(element, natural, scale, false) else natural;
            }
            if (css_display.formattingKind(value(element.style, "display", "inline"))) |kind| {
                const natural = try measureFormatting(element, fonts, scale, kind);
                break :blk if (include_specified) constrainedContent(element, natural, scale, false) else natural;
            }
            var result: Width = .{};
            var inline_run: f64 = 0;
            var pending_space: f64 = 0;
            var float_run: f64 = 0;
            var children = DirectChildren{ .element = &element };
            while (children.next()) |child| {
                if (!participates(child)) continue;
                if (child.* == .element and std.ascii.eqlIgnoreCase(child.element.tag, "br")) {
                    result.max = @max(result.max, inline_run);
                    inline_run = 0;
                    pending_space = 0;
                    continue;
                }
                const child_scale = if (child.* == .element) scale * box_model.parseCssZoom(value(child.element.style, "zoom", "1")) else scale;
                const measured = try measureOuter(child, fonts, child_scale);
                const child_display = if (child.* == .element) value(child.element.style, "display", "inline") else "inline";
                if (child.* == .element and !std.ascii.eqlIgnoreCase(value(child.element.style, "float", "none"), "none")) {
                    if (!std.ascii.eqlIgnoreCase(value(child.element.style, "clear", "none"), "none")) {
                        result.max = @max(result.max, float_run);
                        float_run = 0;
                    }
                    float_run += measured.max;
                    result.min = @max(result.min, measured.min);
                    continue;
                }
                const table_row = std.ascii.eqlIgnoreCase(value(element.style, "display", "inline"), "table-row");
                const block = !table_row and !std.ascii.eqlIgnoreCase(child_display, "inline") and
                    !css_display.isAtomicInline(child_display) and
                    !std.ascii.eqlIgnoreCase(child_display, "none");
                if (table_row) result.min += measured.min else result.min = @max(result.min, measured.min);
                if (block) {
                    result.max = @max(result.max, @max(inline_run, measured.max));
                    inline_run = 0;
                    pending_space = 0;
                } else {
                    if (inline_run == 0 and result.max == 0) result.leading_space = @max(result.leading_space, measured.leading_space);
                    if (measured.max > 0) {
                        if (inline_run > 0) inline_run += @max(pending_space, measured.leading_space);
                        inline_run += measured.max;
                        pending_space = measured.trailing_space;
                    } else pending_space = @max(pending_space, measured.trailing_space);
                }
            }
            result.max = @max(result.max, inline_run + float_run);
            if (std.ascii.eqlIgnoreCase(value(element.style, "display", "inline"), "inline")) {
                result.trailing_space = pending_space;
            } else {
                result.leading_space = 0;
            }
            if (std.ascii.eqlIgnoreCase(value(element.style, "white-space", "normal"), "nowrap")) result.min = result.max;
            break :blk if (include_specified) constrainedContent(element, result, scale, false) else result;
        },
    };
}
