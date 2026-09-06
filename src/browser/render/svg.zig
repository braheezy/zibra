//! SVG rasterization over a synchronous live or temporary DOM borrow.
//! z2d surfaces and reference indexes retire before the owned RGBA result
//! returns. Fetching and animation scheduling belong to the Browser/Tab.

const std = @import("std");
const z2d = @import("z2d");
const zigimg = @import("zigimg");
const dom = @import("../../document/dom.zig");
const xml = @import("../../document/xml_parser.zig");
const path = @import("svg_path.zig");
const values = @import("svg_values.zig");
const Numbers = path.Numbers;
const Matrix = z2d.Transformation;
const attr = values.attr;
const property = values.property;
const equal = values.equal;
const tag = values.tag;
const coordinate = values.coordinate;
const opacity = values.opacity;
const transform = values.transform;
const Viewport = values.Viewport;
const Style = values.Style;
const max_pixels = values.max_pixels;

fn shape(context: *z2d.Context, element: *const dom.Element, name: []const u8, viewport: Viewport, fill: bool) !void {
    const w = viewport.user_width;
    const h = viewport.user_height;
    if (equal(name, "path")) {
        try path.append(context, attr(element, "d") orelse "", fill);
    } else if (equal(name, "rect")) {
        const x = try coordinate(element, "x", w, 0);
        const y = try coordinate(element, "y", h, 0);
        const width = try coordinate(element, "width", w, 0);
        const height = try coordinate(element, "height", h, 0);
        if (width <= 0 or height <= 0) return;
        var rx = try coordinate(element, "rx", w, 0);
        var ry = try coordinate(element, "ry", h, rx);
        if (property(element, "rx") == null) rx = ry;
        rx = std.math.clamp(rx, 0, width / 2);
        ry = std.math.clamp(ry, 0, height / 2);
        const k = 0.5522847498307936;
        try context.moveTo(x + rx, y);
        try context.lineTo(x + width - rx, y);
        try context.curveTo(x + width - rx + k * rx, y, x + width, y + ry - k * ry, x + width, y + ry);
        try context.lineTo(x + width, y + height - ry);
        try context.curveTo(x + width, y + height - ry + k * ry, x + width - rx + k * rx, y + height, x + width - rx, y + height);
        try context.lineTo(x + rx, y + height);
        try context.curveTo(x + rx - k * rx, y + height, x, y + height - ry + k * ry, x, y + height - ry);
        try context.lineTo(x, y + ry);
        try context.curveTo(x, y + ry - k * ry, x + rx - k * rx, y, x + rx, y);
        try context.closePath();
    } else if (equal(name, "circle") or equal(name, "ellipse")) {
        const cx = try coordinate(element, "cx", w, 0);
        const cy = try coordinate(element, "cy", h, 0);
        const rx = if (equal(name, "circle")) try coordinate(element, "r", @sqrt((w * w + h * h) / 2), 0) else try coordinate(element, "rx", w, 0);
        const ry = if (equal(name, "circle")) rx else try coordinate(element, "ry", h, 0);
        if (rx <= 0 or ry <= 0) return;
        const saved = context.getTransformation();
        defer context.setTransformation(saved);
        context.translate(cx, cy);
        context.scale(rx, ry);
        try context.arc(0, 0, 1, 0, 2 * std.math.pi);
        try context.closePath();
    } else if (equal(name, "line")) {
        try context.moveTo(try coordinate(element, "x1", w, 0), try coordinate(element, "y1", h, 0));
        try context.lineTo(try coordinate(element, "x2", w, 0), try coordinate(element, "y2", h, 0));
        if (fill) try context.closePath();
    } else if (equal(name, "polygon") or equal(name, "polyline")) {
        var numbers = Numbers{ .source = attr(element, "points") orelse "" };
        if (numbers.done()) return;
        try context.moveTo(try numbers.number(), try numbers.number());
        var count: usize = 0;
        while (!numbers.done()) {
            count += 1;
            if (count > 32768) return error.SvgTooComplex;
            try context.lineTo(try numbers.number(), try numbers.number());
        }
        if (fill or equal(name, "polygon")) try context.closePath();
    }
}

const paints = @import("svg_paint.zig");
const filters = @import("svg_filter.zig");

const Renderer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    viewport: Viewport,
    references: *const paints.References,
    layer_pixels: usize = 0,
    depth: usize = 0,
    visits: usize = 0,
    clip_mode: bool = false,
    use_instance: bool = false,
    external_opacity: ?*const dom.Element = null,

    fn geometry(self: *Renderer, context: *z2d.Context, element: *const dom.Element, depth: usize) anyerror!void {
        self.visits += 1;
        if (depth > 32 or self.visits > 65536) return error.SvgTooComplex;
        const saved = context.getTransformation();
        defer context.setTransformation(saved);
        if (attr(element, "transform")) |raw| context.setTransformation(saved.mul(try transform(raw)));
        const name = tag(element) orelse return;
        try shape(context, element, name, self.viewport, true);
        if (equal(name, "use")) {
            if (self.references.get(paints.href(element) orelse "")) |target| {
                context.translate(try coordinate(element, "x", self.viewport.user_width, 0), try coordinate(element, "y", self.viewport.user_height, 0));
                try self.geometry(context, target, depth + 1);
            }
        } else if (equal(name, "g") or equal(name, "svg") or equal(name, "a") or equal(name, "symbol")) {
            for (element.children.items) |*child| if (child.* == .element) try self.geometry(context, &child.element, depth + 1);
        }
    }

    fn box(self: *Renderer, element: *const dom.Element, surface: *z2d.Surface) !paints.Bounds {
        var context = z2d.Context.init(self.io, self.allocator, surface);
        defer context.deinit();
        // The caller's element transform is outside this local object box.
        try shape(&context, element, tag(element) orelse "", self.viewport, true);
        if (context.path.nodes.items.len == 0) {
            for (element.children.items) |*child| if (child.* == .element) try self.geometry(&context, &child.element, 0);
        }
        return paints.bounds(&context);
    }

    fn paintPath(self: *Renderer, context: *z2d.Context, paint: values.Paint, style: Style, alpha: f64, stroke: bool) !void {
        try validatePath(context);
        var gradient: ?z2d.Gradient = null;
        defer if (gradient) |*owned| owned.deinit(self.allocator);
        if (paint.pixel(style.color, alpha)) |pixel| {
            context.setSourceToPixel(.{ .rgba = pixel.multiply() });
        } else if (paint == .server) {
            gradient = try paints.gradient(self.allocator, self.references, paint.server, try paints.bounds(context), self.viewport, context.getTransformation(), alpha);
            if (gradient) |*owned| {
                // The paint server already includes object-box and gradient
                // transforms; setSource would replace those with the CTM.
                context.pattern = .{ .gradient = owned };
            } else {
                const end = std.mem.indexOfScalar(u8, paint.server, ')') orelse return;
                const fallback = values.Paint.parse(std.mem.trim(u8, paint.server[end + 1 ..], " \t\r\n")) orelse return;
                const pixel = fallback.pixel(style.color, alpha) orelse return;
                context.setSourceToPixel(.{ .rgba = pixel.multiply() });
            }
        } else return;
        if (stroke) try context.stroke() else try context.fill();
    }

    fn draw(self: *Renderer, surface: *z2d.Surface, element: *const dom.Element, inherited: Style, parent_matrix: Matrix, root: bool) anyerror!void {
        self.visits += 1;
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > 64 or self.visits > 65536) return error.SvgTooComplex;
        const name = tag(element) orelse return;
        const is_use = equal(name, "use");
        const is_text = equal(name, "text");
        const is_image = equal(name, "image");
        const group = equal(name, "g") or equal(name, "a") or equal(name, "svg") or
            (root and (equal(name, "symbol") or std.ascii.eqlIgnoreCase(name, "clipPath")));
        if (!group and !is_use and !is_text and !is_image and !equal(name, "path") and !equal(name, "rect") and !equal(name, "circle") and !equal(name, "ellipse") and !equal(name, "line") and !equal(name, "polygon") and !equal(name, "polyline")) return;
        if (property(element, "display")) |value| if (equal(value, "none")) return;
        var style = if (self.use_instance or !root) try inherited.deriveCascaded(element, self.viewport) else try inherited.derive(element, self.viewport);
        if (self.clip_mode) {
            style.fill = .{ .color = .{ .r = 255, .g = 255, .b = 255 } };
            style.stroke = .none;
            style.fill_opacity = 1;
            style.fill_rule = if (equal(property(element, "clip-rule") orelse "", "evenodd")) .even_odd else .non_zero;
        }
        const alpha = if (self.clip_mode or self.external_opacity == element) 1 else if (property(element, "opacity")) |value| try opacity(value) else 1;
        if (alpha == 0) return;
        const transform_value = if (equal(name, "svg")) attr(element, "transform") else property(element, "transform");
        const local = if (transform_value) |value| try transform(value) else Matrix.identity;
        var matrix = parent_matrix.mul(local);
        const saved_viewport = self.viewport;
        defer self.viewport = saved_viewport;
        if (!root and equal(name, "svg")) {
            const w = try coordinate(element, "width", saved_viewport.user_width, saved_viewport.user_width);
            const h = try coordinate(element, "height", saved_viewport.user_height, saved_viewport.user_height);
            if (w <= 0 or h <= 0) return;
            self.viewport = try Viewport.parseSize(element, .{ w, h });
            matrix = matrix.translate(try coordinate(element, "x", saved_viewport.user_width, 0), try coordinate(element, "y", saved_viewport.user_height, 0)).mul(self.viewport.matrix);
        }
        inline for (std.meta.fields(Matrix)) |field| {
            const value = @field(matrix, field.name);
            if (!std.math.isFinite(value) or @abs(value) > 1e6) return error.InvalidSvgTransform;
        }
        if (@abs(matrix.determinant()) < 1e-12) return;
        const clip = self.references.get(property(element, "clip-path") orelse "");
        const filter = if (self.clip_mode) null else self.references.get(property(element, "filter") orelse "");
        var layer: ?z2d.Surface = null;
        const pixel_count = surface.image_surface_rgba.buf.len;
        if (alpha < 1 or clip != null or filter != null) {
            if (self.layer_pixels + pixel_count > 4 * max_pixels) return error.SvgTooComplex;
            layer = try z2d.Surface.init(.image_surface_rgba, self.allocator, surface.getWidth(), surface.getHeight());
            self.layer_pixels += pixel_count;
        }
        defer if (layer) |*owned| {
            owned.deinit(self.allocator);
            self.layer_pixels -= pixel_count;
        };
        const target = if (layer) |*owned| owned else surface;
        if (is_use) {
            if (self.references.get(paints.href(element) orelse "")) |reference| {
                var use_matrix = matrix.translate(try coordinate(element, "x", self.viewport.user_width, 0), try coordinate(element, "y", self.viewport.user_height, 0));
                if (equal(reference.tag, "symbol") or equal(reference.tag, "svg")) {
                    const w = try coordinate(element, "width", self.viewport.user_width, self.viewport.user_width);
                    const h = try coordinate(element, "height", self.viewport.user_height, self.viewport.user_height);
                    if (w <= 0 or h <= 0) return;
                    self.viewport = try Viewport.parseSize(reference, .{ w, h });
                    use_matrix = use_matrix.mul(self.viewport.matrix);
                }
                const previous_instance = self.use_instance;
                self.use_instance = true;
                defer self.use_instance = previous_instance;
                try self.draw(target, reference, style, use_matrix, true);
            }
        } else if (group) {
            for (element.children.items) |*child| if (child.* == .element) {
                try self.draw(target, &child.element, style, matrix, false);
            };
        } else if (style.visible) {
            var context = z2d.Context.init(self.io, self.allocator, target);
            defer context.deinit();
            context.setTransformation(matrix);
            context.setFillRule(style.fill_rule);
            if (is_text) {
                if (style.fill.pixel(style.color, style.fill_opacity)) |pixel| {
                    context.setSourceToPixel(.{ .rgba = pixel.multiply() });
                    try @import("svg_text.zig").draw(&context, element, self.viewport);
                }
            } else if (is_image) {
                if (!self.clip_mode) if (element.image_data) |data| if (!data.is_broken) {
                    try self.image(target, element, data.image, matrix);
                };
            } else {
                try shape(&context, element, name, self.viewport, true);
                try self.paintPath(&context, style.fill, style, style.fill_opacity, false);
                context.resetPath();
                if (style.stroke_width > 0 and style.stroke != .none) {
                    try shape(&context, element, name, self.viewport, false);
                    const extent = style.stroke_width * style.miter_limit * @max(@abs(matrix.ax) + @abs(matrix.by), @abs(matrix.cx) + @abs(matrix.dy));
                    if (!std.math.isFinite(extent) or extent > 1e6) return error.SvgTooComplex;
                    context.setLineWidth(style.stroke_width);
                    context.setLineCapMode(style.cap);
                    context.setLineJoinMode(style.join);
                    context.setMiterLimit(style.miter_limit);
                    try self.paintPath(&context, style.stroke, style, style.stroke_opacity, true);
                }
            }
        }
        if (layer) |*owned| {
            if (filter) |definition| if (equal(definition.tag, "filter")) try filters.apply(self.allocator, owned, definition, matrix, try self.box(element, surface), self.viewport);
            if (clip) |definition| {
                if (self.layer_pixels + pixel_count > 4 * max_pixels) return error.SvgTooComplex;
                var mask = try z2d.Surface.init(.image_surface_rgba, self.allocator, surface.getWidth(), surface.getHeight());
                self.layer_pixels += pixel_count;
                defer {
                    mask.deinit(self.allocator);
                    self.layer_pixels -= pixel_count;
                }
                const old_mode = self.clip_mode;
                self.clip_mode = true;
                defer self.clip_mode = old_mode;
                const object_units = equal(attr(definition, "clipPathUnits") orelse "", "objectBoundingBox");
                const clip_matrix = matrix.mul(if (object_units) (try self.box(element, surface)).matrix() else Matrix.identity);
                if (std.ascii.eqlIgnoreCase(definition.tag, "clipPath")) try self.draw(&mask, definition, .{}, clip_matrix, true);
                for (owned.image_surface_rgba.buf, mask.image_surface_rgba.buf) |*pixel, mask_pixel| {
                    inline for (.{ "r", "g", "b", "a" }) |field| @field(pixel, field) = @intCast((@as(u16, @field(pixel, field)) * mask_pixel.a + 127) / 255);
                }
            }
            for (owned.image_surface_rgba.buf) |*pixel| {
                inline for (.{ "r", "g", "b", "a" }) |field| @field(pixel, field) = @intFromFloat(@round(@as(f64, @floatFromInt(@field(pixel, field))) * alpha));
            }
            z2d.Surface.composite(surface, owned, .src_over, 0, 0, .{});
        }
    }

    fn image(self: *Renderer, surface: *z2d.Surface, element: *const dom.Element, bitmap: zigimg.Image, matrix: Matrix) !void {
        const x = try coordinate(element, "x", self.viewport.user_width, 0);
        const y = try coordinate(element, "y", self.viewport.user_height, 0);
        const w = try coordinate(element, "width", self.viewport.user_width, 0);
        const h = try coordinate(element, "height", self.viewport.user_height, 0);
        if (w <= 0 or h <= 0 or bitmap.width == 0 or bitmap.height == 0) return;
        const iw: f64 = @floatFromInt(bitmap.width);
        const ih: f64 = @floatFromInt(bitmap.height);
        var sx = w / iw;
        var sy = h / ih;
        const none = equal(attr(element, "preserveAspectRatio") orelse "", "none");
        if (!none) {
            sx = @min(sx, sy);
            sy = sx;
        }
        const inverse = try matrix.translate(x + (w - iw * sx) / 2, y + (h - ih * sy) / 2).scale(sx, sy).inverse();
        const width: usize = @intCast(surface.getWidth());
        const pixels = bitmap.rawBytes();
        for (surface.image_surface_rgba.buf, 0..) |*destination, i| {
            var px: f64 = @as(f64, @floatFromInt(i % width)) + 0.5;
            var py: f64 = @as(f64, @floatFromInt(i / width)) + 0.5;
            inverse.userToDevice(&px, &py);
            if (px < 0 or py < 0 or px >= iw or py >= ih) continue;
            const index = (@as(usize, @intFromFloat(py)) * bitmap.width + @as(usize, @intFromFloat(px))) * 4;
            const p = (z2d.pixel.RGBA{ .r = pixels[index], .g = pixels[index + 1], .b = pixels[index + 2], .a = pixels[index + 3] }).multiply();
            const inv: u16 = 255 - p.a;
            inline for (.{ "r", "g", "b", "a" }) |field| @field(destination, field) = @intCast(@as(u16, @field(p, field)) + (@as(u16, @field(destination, field)) * inv + 127) / 255);
        }
    }
};

fn validatePoint(point: anytype) !void {
    if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y) or @abs(point.x) > 1e6 or @abs(point.y) > 1e6) return error.SvgTooComplex;
}

// Bound device coordinates too: individually finite source coordinates and
// matrices can multiply beyond the rasterizer's integer scan-conversion range.
fn validatePath(context: *const z2d.Context) !void {
    for (context.path.nodes.items) |node| switch (node) {
        .move_to => |move| try validatePoint(move.point),
        .line_to => |line| try validatePoint(line.point),
        .curve_to => |curve| {
            try validatePoint(curve.p1);
            try validatePoint(curve.p2);
            try validatePoint(curve.p3);
        },
        .close_path => {},
    };
}

/// Borrow encoded XML until return; transfer an owned straight-alpha RGBA
/// image on success. No XML node, surface, or input borrow escapes the decode.
pub fn decode(allocator: std.mem.Allocator, io: std.Io, source: []const u8) !zigimg.Image {
    if (source.len > 2 * 1024 * 1024) return error.SvgTooComplex;
    var parser = xml.Parser.init(allocator, source);
    parser.max_depth = 128;
    parser.max_elements = 16384;
    defer parser.deinit();
    var root = try parser.parse();
    defer root.deinit(allocator);
    dom.fixParentPointers(&root, null);
    if (root != .element or !equal(tag(&root.element) orelse return error.NotSvg, "svg")) return error.NotSvg;
    try @import("../../document/svg_animation.zig").sample(allocator, &root.element, 0);
    return render(allocator, io, &root.element, .{});
}

pub const RenderOptions = struct {
    size: ?[2]f64 = null,
    /// A block display-command wrapper applies the outer SVG's opacity once.
    root_opacity_in_paint: bool = false,
};

/// Synchronously borrow a live SVG DOM and transfer an independent straight
/// RGBA snapshot. Size is the used CSS viewport, before accessibility zoom.
pub fn render(allocator: std.mem.Allocator, io: std.Io, root: *const dom.Element, options: RenderOptions) !zigimg.Image {
    const viewport = try Viewport.parseSize(root, options.size);
    const width: i32 = @intFromFloat(@ceil(viewport.width));
    const height: i32 = @intFromFloat(@ceil(viewport.height));
    var surface = try z2d.Surface.init(.image_surface_rgba, allocator, width, height);
    defer surface.deinit(allocator);
    var references = try paints.References.init(allocator, root);
    defer references.deinit();
    var renderer = Renderer{ .allocator = allocator, .io = io, .viewport = viewport, .references = &references, .external_opacity = if (options.root_opacity_in_paint) root else null };
    try renderer.draw(&surface, root, .{}, viewport.matrix, true);
    const pixels = try allocator.alloc(u8, surface.image_surface_rgba.buf.len * 4);
    errdefer allocator.free(pixels);
    for (surface.image_surface_rgba.buf, 0..) |pixel, i| {
        const straight = pixel.demultiply();
        pixels[i * 4 ..][0..4].* = .{ straight.r, straight.g, straight.b, straight.a };
    }
    return zigimg.Image.fromRawPixelsOwned(@intCast(width), @intCast(height), pixels, .rgba32);
}

fn expectPixel(image: zigimg.Image, x: usize, y: usize, expected: [4]u8) !void {
    const index = (y * image.width + x) * 4;
    try std.testing.expectEqualSlices(u8, &expected, image.rawBytes()[index..][0..4]);
}

test "SVG paint servers resolve stops, object boxes, transforms and inherited gradients" {
    var image = try decode(std.testing.allocator, std.testing.io, "<svg width='40' height='20'><defs>" ++
        "<linearGradient id='base'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient>" ++
        "<linearGradient id='reverse' href='#base' gradientTransform='translate(1 0) scale(-1 1)'/>" ++
        "<radialGradient id='radial'><stop stop-color='white'/><stop offset='1' stop-color='black'/></radialGradient>" ++
        "</defs><rect width='20' height='20' fill='url(#reverse)'/><circle cx='30' cy='10' r='10' fill='url(#radial)'/></svg>");
    defer image.deinit(std.testing.allocator);
    const left = image.rawBytes()[(10 * 40 + 2) * 4 ..][0..4];
    const right = image.rawBytes()[(10 * 40 + 17) * 4 ..][0..4];
    try std.testing.expect(left[2] > left[0]);
    try std.testing.expect(right[0] > right[2]);
    try std.testing.expect(image.rawBytes()[(10 * 40 + 30) * 4] > 220);
    try std.testing.expect(image.rawBytes()[(10 * 40 + 38) * 4] < 80);
}

test "SVG clip paths use geometric coverage and object bounding box units" {
    var image = try decode(std.testing.allocator, std.testing.io, "<svg width='40' height='20'><defs><clipPath id='half' clipPathUnits='objectBoundingBox'>" ++
        "<rect width='.5' height='1' fill='none'/></clipPath></defs>" ++
        "<g transform='translate(10)' clip-path='url(#half)' opacity='.5'><rect width='20' height='20' fill='red'/></g></svg>");
    defer image.deinit(std.testing.allocator);
    try expectPixel(image, 15, 10, .{ 255, 0, 0, 128 });
    try expectPixel(image, 25, 10, .{ 0, 0, 0, 0 });
    try expectPixel(image, 5, 10, .{ 0, 0, 0, 0 });
}

test "SVG use reuses symbols with independent instances and bounded cycles" {
    var image = try decode(std.testing.allocator, std.testing.io, "<svg width='40' height='20'><defs><symbol id='tile' viewBox='0 0 10 10'><rect width='10' height='10'/></symbol></defs>" ++
        "<use href='#tile' width='20' height='20' fill='red'/><use href='#tile' x='20' width='20' height='20' fill='blue'/></svg>");
    defer image.deinit(std.testing.allocator);
    try expectPixel(image, 5, 10, .{ 255, 0, 0, 255 });
    try expectPixel(image, 25, 10, .{ 0, 0, 255, 255 });
    try std.testing.expectError(error.SvgTooComplex, decode(std.testing.allocator, std.testing.io, "<svg width='1' height='1'><use id='loop' href='#loop'/></svg>"));
}

test "SVG object-box traversal bounds repeated references in hidden geometry" {
    const allocator = std.testing.allocator;
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try source.writer.writeAll("<svg width='1' height='1'><defs><clipPath id='clip' clipPathUnits='objectBoundingBox'><rect width='1' height='1'/></clipPath><g id='n0'><rect width='1' height='1'/></g>");
    for (1..16) |i| try source.writer.print("<g id='n{d}'><use href='#n{d}'/><use href='#n{d}'/></g>", .{ i, i - 1, i - 1 });
    try source.writer.writeAll("</defs><g clip-path='url(#clip)'><use href='#n15' display='none'/></g></svg>");
    try std.testing.expectError(error.SvgTooComplex, decode(allocator, std.testing.io, source.written()));
}

test "SVG filter graph preserves named SourceAlpha and merges an offset shadow" {
    var image = try decode(std.testing.allocator, std.testing.io, "<svg width='30' height='20'><defs><filter id='shadow' x='-100%' y='-100%' width='300%' height='300%'>" ++
        "<feOffset in='SourceAlpha' dx='10' result='shadow'/><feMerge><feMergeNode in='shadow'/><feMergeNode in='SourceGraphic'/></feMerge>" ++
        "</filter></defs><rect x='2' y='2' width='8' height='8' fill='red' filter='url(#shadow)'/></svg>");
    defer image.deinit(std.testing.allocator);
    try expectPixel(image, 5, 5, .{ 255, 0, 0, 255 });
    try expectPixel(image, 15, 5, .{ 0, 0, 0, 255 });
    try expectPixel(image, 25, 5, .{ 0, 0, 0, 0 });
}

test "SVG animation samples geometry and transform without changing authored attributes" {
    const allocator = std.testing.allocator;
    var parser = xml.Parser.init(allocator, "<svg width='40' height='10'><rect x='0' width='10' height='10' fill='red'>" ++
        "<animate attributeName='x' values='0;20' dur='2s' fill='freeze'/>" ++
        "<animate attributeName='fill' from='red' to='blue' dur='2s' fill='freeze'/></rect></svg>");
    defer parser.deinit();
    var root = try parser.parse();
    defer root.deinit(allocator);
    dom.fixParentPointers(&root, null);
    const animation = @import("../../document/svg_animation.zig");
    try animation.sample(allocator, &root.element, 2);
    var image = try render(allocator, std.testing.io, &root.element, .{});
    defer image.deinit(allocator);
    try expectPixel(image, 25, 5, .{ 0, 0, 255, 255 });
    try expectPixel(image, 5, 5, .{ 0, 0, 0, 0 });
    try std.testing.expectEqualStrings("0", root.element.children.items[0].element.attributes.?.get("x").?);
    try std.testing.expect(!animation.active(&root.element, 2));
}

test "SVG extended renderer frees all temporary owners on allocation failure" {
    const Runner = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var image = try decode(allocator, std.testing.io, "<svg width='4' height='4'><defs><linearGradient id='g'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient>" ++
                "<clipPath id='c'><rect width='3' height='4'/></clipPath><filter id='f'><feOffset dx='0'/></filter></defs>" ++
                "<g opacity='.5' clip-path='url(#c)' filter='url(#f)'><rect width='4' height='4' fill='url(#g)'/></g></svg>");
            defer image.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Runner.run, .{});
}

test "SVG text uses a baseline and z2d font outlines" {
    var image = try decode(std.testing.allocator, std.testing.io, "<svg width='100' height='40'><text x='5' y='30' font-size='24' fill='blue'>SVG</text></svg>");
    defer image.deinit(std.testing.allocator);
    var ink: usize = 0;
    for (0..image.height) |y| for (0..image.width) |x| {
        const pixel = image.rawBytes()[(y * image.width + x) * 4 ..][0..4];
        if (pixel[3] != 0) {
            ink += 1;
            try std.testing.expect(y < 32);
            try std.testing.expect(pixel[2] > 200);
        }
    };
    try std.testing.expect(ink > 100);
}

test "SVG degenerate gradients and missing paint server fallbacks stay defined" {
    var image = try decode(std.testing.allocator, std.testing.io, "<svg width='20' height='10'><defs><linearGradient id='g' x1='0' x2='0'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient></defs>" ++
        "<rect width='10' height='10' fill='url(#%67)'/><rect x='10' width='10' height='10' fill='url(#missing) green'/></svg>");
    defer image.deinit(std.testing.allocator);
    try expectPixel(image, 5, 5, .{ 0, 0, 255, 255 });
    try expectPixel(image, 15, 5, .{ 0, 128, 0, 255 });
}

test "SVG XML detection, namespaces, viewBox origin and straight alpha" {
    var image = try decode(std.testing.allocator, std.testing.io, "\xef\xbb\xbf<?xml version='1.0'?><!-- icon -->" ++
        "<s:svg xmlns:s='http://www.w3.org/2000/svg' width='40' height='20' viewBox='10 20 10 10'>" ++
        "<s:rect x='10' y='20' width='10' height='10' fill='red' fill-opacity='.5'/>" ++
        "</s:svg>");
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 40), image.width);
    try std.testing.expectEqual(@as(usize, 20), image.height);
    try expectPixel(image, 2, 10, .{ 0, 0, 0, 0 });
    try expectPixel(image, 20, 10, .{ 255, 0, 0, 128 });
    try expectPixel(image, 38, 10, .{ 0, 0, 0, 0 });
}

test "SVG group opacity composites overlapping children once and inherits paint" {
    var image = try decode(std.testing.allocator, std.testing.io, "<svg width='30' height='20'><g color='red' fill='currentColor' opacity='.5'>" ++
        "<rect width='20' height='20'/><rect x='10' width='20' height='20'/>" ++
        "</g></svg>");
    defer image.deinit(std.testing.allocator);
    try expectPixel(image, 5, 10, .{ 255, 0, 0, 128 });
    try expectPixel(image, 15, 10, .{ 255, 0, 0, 128 });
    try expectPixel(image, 25, 10, .{ 255, 0, 0, 128 });
}

test "SVG paths close fill subpaths, preserve holes, and compose transforms" {
    var image = try decode(std.testing.allocator, std.testing.io, "<svg width='40' height='40'><g transform='translate(10 10) scale(2)' fill='blue'>" ++
        "<path fill-rule='evenodd' d='M0 0h10v10h-10z M2 2 8 2 8 8 2 8'/>" ++
        "</g></svg>");
    defer image.deinit(std.testing.allocator);
    try expectPixel(image, 2, 2, .{ 0, 0, 0, 0 });
    try expectPixel(image, 12, 12, .{ 0, 0, 255, 255 });
    try expectPixel(image, 20, 20, .{ 0, 0, 0, 0 });
    try expectPixel(image, 28, 28, .{ 0, 0, 255, 255 });
}

test "SVG elliptical arcs, quadratic and smooth cubic paths rasterize" {
    var image = try decode(std.testing.allocator, std.testing.io, "<svg width='80' height='20' fill='lime'>" ++
        "<path d='M2 10A8 8 0 0118 10A8 8 0 012 10z'/>" ++
        "<path d='M22 10Q30 -6 38 10T54 10L54 20H22Z'/>" ++
        "<path d='M60 10C60 0 70 0 70 10S80 20 80 10V20H60Z'/>" ++
        "</svg>");
    defer image.deinit(std.testing.allocator);
    try expectPixel(image, 10, 10, .{ 0, 255, 0, 255 });
    try expectPixel(image, 30, 12, .{ 0, 255, 0, 255 });
    try expectPixel(image, 65, 12, .{ 0, 255, 0, 255 });
}

test "SVG strokes keep open ends and inline style overrides attributes" {
    var image = try decode(std.testing.allocator, std.testing.io, "<svg width='30' height='20'>" ++
        "<path d='M5 10H25' fill='none' stroke='red' stroke-width='4' style='stroke: blue; stroke-linecap: butt'/>" ++
        "</svg>");
    defer image.deinit(std.testing.allocator);
    try expectPixel(image, 15, 10, .{ 0, 0, 255, 255 });
    try expectPixel(image, 3, 10, .{ 0, 0, 0, 0 });
    try expectPixel(image, 15, 5, .{ 0, 0, 0, 0 });
}

test "SVG shape primitives, hidden and unsupported subtrees" {
    var image = try decode(std.testing.allocator, std.testing.io, "<svg width='60' height='20' fill='red'>" ++
        "<defs><rect width='60' height='20'/></defs>" ++
        "<g display='none'><rect width='60' height='20'/></g>" ++
        "<foreignObject><rect width='60' height='20'/></foreignObject>" ++
        "<circle cx='10' cy='10' r='6'/><ellipse cx='30' cy='10' rx='7' ry='4'/>" ++
        "<polygon points='44,4 56,4 56,16 44,16'/>" ++
        "</svg>");
    defer image.deinit(std.testing.allocator);
    try expectPixel(image, 10, 10, .{ 255, 0, 0, 255 });
    try expectPixel(image, 30, 10, .{ 255, 0, 0, 255 });
    try expectPixel(image, 50, 10, .{ 255, 0, 0, 255 });
    try expectPixel(image, 1, 1, .{ 0, 0, 0, 0 });
}

test "SVG intrinsic fallback sizes and preserveAspectRatio none" {
    var sized = try decode(std.testing.allocator, std.testing.io, "<svg viewBox='0 0 20 10' width='1in'/>");
    defer sized.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 96), sized.width);
    try std.testing.expectEqual(@as(usize, 48), sized.height);
    var fallback = try decode(std.testing.allocator, std.testing.io, "<svg viewBox='0 0 10 10'/>");
    defer fallback.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 150), fallback.width);
    try std.testing.expectEqual(@as(usize, 150), fallback.height);
    var stretched = try decode(std.testing.allocator, std.testing.io, "<svg width='40' height='20' viewBox='0 0 10 10' preserveAspectRatio='none'>" ++
        "<rect width='10' height='10' fill='red'/></svg>");
    defer stretched.deinit(std.testing.allocator);
    try expectPixel(stretched, 2, 10, .{ 255, 0, 0, 255 });
    try expectPixel(stretched, 38, 10, .{ 255, 0, 0, 255 });
}

test "SVG malformed, nonfinite and excessive input fails without retaining resources" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.NotSvg, decode(allocator, std.testing.io, "<html/>"));
    try std.testing.expectError(error.NotSvg, decode(allocator, std.testing.io, "<svg xmlns='urn:foreign'/>"));
    try std.testing.expectError(error.MalformedXml, decode(allocator, std.testing.io, "<svg><rect></svg>"));
    try std.testing.expectError(error.InvalidSvgSize, decode(allocator, std.testing.io, "<svg width='10000'/>"));
    try std.testing.expectError(error.InvalidSvgNumber, decode(allocator, std.testing.io, "<svg width='1e99'/>"));
    try std.testing.expectError(error.InvalidSvgViewBox, decode(allocator, std.testing.io, "<svg viewBox='0 0 -1 1'/>"));
    try std.testing.expectError(error.InvalidSvgPath, decode(allocator, std.testing.io, "<svg><path d='L0 0'/></svg>"));
    try std.testing.expectError(error.InvalidSvgNumber, decode(allocator, std.testing.io, "<svg><path d='M0 0L'/></svg>"));
    const deep = "<svg>" ++ "<g>" ** 128 ++ "</g>" ** 128 ++ "</svg>";
    try std.testing.expectError(error.XmlLimitExceeded, decode(allocator, std.testing.io, deep));
    try std.testing.expectError(error.SvgTooComplex, decode(allocator, std.testing.io, "<svg><path transform='scale(1000000)' d='M0 0L1000000 0L0 1Z'/></svg>"));
    var tiny = try decode(allocator, std.testing.io, "<svg width='1' height='1'><path d='M0 0A1 1 0 0 1 1e-200 0'/></svg>");
    defer tiny.deinit(allocator);
}

fn allocationFailureDecode(allocator: std.mem.Allocator) !void {
    var image = try decode(allocator, std.testing.io, "<svg width='4' height='4'><g opacity='.5'>" ++
        "<path fill='red' d='M0 0H4V4H0Z'/></g></svg>");
    defer image.deinit(allocator);
    try expectPixel(image, 2, 2, .{ 255, 0, 0, 128 });
}

test "SVG allocation failures retire XML, paths, surfaces and output pixels" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureDecode, .{});
}
