//! Lazy HTML-image selection and pre/post-decode layout regressions.

const std = @import("std");
const browser = @import("../browser/root.zig");
const image_loader = @import("../browser/image_loader.zig");
const Layout = @import("../browser/render/layout.zig");
const document = @import("../document/parser.zig");
const url_module = @import("../network/url.zig");
const Url = url_module.Url;

const TestContext = struct {
    allocator: std.mem.Allocator,
    fetch_count: usize = 0,
    fail_fetch: bool = false,
};

const TestCallbacks = struct {
    pub fn allowed(_: *TestContext, _: Url, _: *const Url) bool {
        return true;
    }

    pub fn fetch(
        context: *TestContext,
        _: Url,
        _: Url,
        _: url_module.ReferrerPolicy,
    ) !url_module.HttpResponse {
        context.fetch_count += 1;
        if (context.fail_fetch) return error.TestImageFetchFailed;
        const header = "P6\n30 12\n255\n";
        const body = try context.allocator.alloc(u8, header.len + 30 * 12 * 3);
        @memcpy(body[0..header.len], header);
        @memset(body[header.len..], 0x5a);
        return .{ .body = body };
    }
};

fn findNodeById(node: *document.Node, id: []const u8) ?*document.Node {
    return switch (node.*) {
        .text => null,
        .element => |*element| blk: {
            if (element.attributes) |attributes| {
                if (attributes.get("id")) |candidate| {
                    if (std.mem.eql(u8, candidate, id)) break :blk node;
                }
            }
            for (element.children.items) |*child| {
                if (findNodeById(child, id)) |found| break :blk found;
            }
            break :blk null;
        },
    };
}

fn findImageDisplayItem(
    items: []const browser.DisplayItem,
    node: *document.Node,
) ?*const browser.ImageDisplayItem {
    for (items) |*item| switch (item.*) {
        .cached_subtree => |cached| {
            if (findImageDisplayItem(cached.list.items, node)) |found| return found;
        },
        .image => |*image| {
            const source = image.source orelse continue;
            if (source.node == node) return image;
        },
        .blend => |blend| {
            if (findImageDisplayItem(blend.children, node)) |found| return found;
        },
        .transform => |transform| {
            if (findImageDisplayItem(transform.children, node)) |found| return found;
        },
        .draw_composited_layer => |draw| {
            if (findImageDisplayItem(draw.layer.display_items, node)) |found| return found;
        },
        else => {},
    };
    return null;
}

test "failed lazy image installs one stable broken-image result" {
    const allocator = std.testing.allocator;
    var image = try document.Element.init(allocator, "img loading=lazy src=missing.ppm", null);
    defer image.deinit(allocator);
    var page_url = try Url.init(allocator, "https://example.test/page.html");
    defer page_url.free(allocator);
    var context = TestContext{ .allocator = allocator, .fail_fetch = true };
    const candidates = [_]image_loader.Candidate{.{
        .element = &image,
        .bounds = .{ .x = 0, .y = 10, .width = 1, .height = 1 },
    }};
    const selection = image_loader.Selection{ .lazy_near = .{
        .scroll = 0,
        .height = 600,
        .preload_margin = 600,
    } };

    try std.testing.expectEqual(@as(usize, 1), try image_loader.loadCandidates(
        allocator,
        &candidates,
        selection,
        &page_url,
        .default,
        &context,
        TestCallbacks,
    ));
    try std.testing.expect(image.image_data.?.is_broken);
    try std.testing.expectEqual(@as(usize, 16), image.image_data.?.image.width);
    try std.testing.expectEqual(@as(usize, 16), image.image_data.?.image.height);
    try std.testing.expectEqual(@as(usize, 0), try image_loader.loadCandidates(
        allocator,
        &candidates,
        selection,
        &page_url,
        .default,
        &context,
        TestCallbacks,
    ));
    try std.testing.expectEqual(@as(usize, 1), context.fetch_count);
}

test "unloaded and decorative broken images preserve only authored placeholder axes" {
    const allocator = std.testing.allocator;
    var html_parser = try document.HTMLParser.init(
        allocator,
        "<main>" ++
            "<img id=none loading=lazy src=none.ppm>" ++
            "<br><img id=wide loading=lazy src=wide.ppm width=80>" ++
            "<br><img id=tall loading=lazy src=tall.ppm height=45>" ++
            "<br><img id=empty-alt loading=lazy src=empty.ppm width=32 height=20 alt=''>" ++
            "<br><img id=described loading=lazy src=described.ppm alt='Missing portrait'>" ++
            "</main>",
    );
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    try document.style(allocator, &root, &.{});

    const none = findNodeById(&root, "none").?;
    const wide = findNodeById(&root, "wide").?;
    const tall = findNodeById(&root, "tall").?;
    const empty_alt = findNodeById(&root, "empty-alt").?;
    const described = findNodeById(&root, "described").?;

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    const layout = try Layout.init(allocator, std.testing.io, &environ, 800, 600, false);
    defer layout.deinit();
    const laid_out = try layout.buildDocument(&root);
    defer {
        laid_out.deinit();
        allocator.destroy(laid_out);
    }

    const expected_nodes = [_]struct {
        node: *document.Node,
        width: i32,
        height: i32,
    }{
        .{ .node = none, .width = 1, .height = 1 },
        .{ .node = wide, .width = 80, .height = 0 },
        .{ .node = tall, .width = 0, .height = 45 },
        .{ .node = empty_alt, .width = 32, .height = 20 },
        .{ .node = described, .width = 1, .height = 1 },
    };
    for (expected_nodes) |expected| {
        const bounds = layout.image_bounds.get(expected.node).?;
        try std.testing.expectEqual(expected.width, bounds.width);
        try std.testing.expectEqual(expected.height, bounds.height);
    }

    const before = try layout.paintDocument(laid_out);
    defer browser.DisplayItem.freeList(allocator, before);
    try std.testing.expect(findImageDisplayItem(before, none) == null);
    try std.testing.expectEqual(@as(usize, 0), findImageDisplayItem(before, wide).?.pixels.len);
    try std.testing.expectEqual(@as(usize, 0), findImageDisplayItem(before, tall).?.pixels.len);
    try std.testing.expectEqual(@as(usize, 0), findImageDisplayItem(before, empty_alt).?.pixels.len);
    try std.testing.expect(findImageDisplayItem(before, described) == null);

    var page_url = try Url.init(allocator, "https://example.test/page.html");
    defer page_url.free(allocator);
    var context = TestContext{ .allocator = allocator, .fail_fetch = true };
    var candidates: [expected_nodes.len]image_loader.Candidate = undefined;
    for (expected_nodes, 0..) |expected, index| {
        const bounds = layout.image_bounds.get(expected.node).?;
        candidates[index] = .{
            .element = &expected.node.element,
            .bounds = .{
                .x = bounds.x,
                .y = bounds.y,
                .width = bounds.width,
                .height = bounds.height,
            },
        };
    }
    try std.testing.expectEqual(@as(usize, expected_nodes.len), try image_loader.loadCandidates(
        allocator,
        &candidates,
        .{ .lazy_near = .{ .scroll = 0, .height = 600, .preload_margin = 600 } },
        &page_url,
        .default,
        &context,
        TestCallbacks,
    ));

    laid_out.mark();
    try laid_out.layout(layout);
    for (expected_nodes[0 .. expected_nodes.len - 1]) |expected| {
        const bounds = layout.image_bounds.get(expected.node).?;
        try std.testing.expectEqual(expected.width, bounds.width);
        try std.testing.expectEqual(expected.height, bounds.height);
    }
    const described_bounds = layout.image_bounds.get(described).?;
    try std.testing.expectEqual(@as(i32, 16), described_bounds.width);
    try std.testing.expectEqual(@as(i32, 16), described_bounds.height);

    const after = try layout.paintDocument(laid_out);
    defer browser.DisplayItem.freeList(allocator, after);
    try std.testing.expect(findImageDisplayItem(after, none) == null);
    try std.testing.expectEqual(@as(usize, 0), findImageDisplayItem(after, wide).?.pixels.len);
    try std.testing.expectEqual(@as(usize, 0), findImageDisplayItem(after, tall).?.pixels.len);
    try std.testing.expectEqual(@as(usize, 0), findImageDisplayItem(after, empty_alt).?.pixels.len);
    const described_image = findImageDisplayItem(after, described).?;
    try std.testing.expectEqual(@as(i32, 16), described_image.source_width);
    try std.testing.expectEqual(@as(i32, 16), described_image.source_height);
    try std.testing.expectEqual(@as(usize, 16 * 16 * 4), described_image.pixels.len);
}

test "eager and lazy image batches fetch only their selected candidates" {
    const allocator = std.testing.allocator;
    var eager = try document.Element.init(allocator, "img src=eager.ppm", null);
    defer eager.deinit(allocator);
    var near = try document.Element.init(allocator, "img loading=lazy src=near.ppm", null);
    defer near.deinit(allocator);
    var far = try document.Element.init(allocator, "img loading=lazy src=far.ppm", null);
    defer far.deinit(allocator);

    var page_url = try Url.init(allocator, "https://example.test/page.html");
    defer page_url.free(allocator);
    var context = TestContext{ .allocator = allocator };
    const candidates = [_]image_loader.Candidate{
        .{ .element = &eager, .bounds = .{ .x = 0, .y = 10, .width = 30, .height = 12 } },
        .{ .element = &near, .bounds = .{ .x = 0, .y = 900, .width = 30, .height = 12 } },
        .{ .element = &far, .bounds = .{ .x = 0, .y = 2400, .width = 30, .height = 12 } },
    };

    try std.testing.expectEqual(@as(usize, 1), try image_loader.loadCandidates(
        allocator,
        &candidates,
        .eager,
        &page_url,
        .default,
        &context,
        TestCallbacks,
    ));
    try std.testing.expect(eager.image_data != null);
    try std.testing.expect(near.image_data == null);
    try std.testing.expect(far.image_data == null);

    try std.testing.expectEqual(@as(usize, 1), try image_loader.loadCandidates(
        allocator,
        &candidates,
        .{ .lazy_near = .{ .scroll = 0, .height = 600, .preload_margin = 600 } },
        &page_url,
        .default,
        &context,
        TestCallbacks,
    ));
    try std.testing.expect(near.image_data != null);
    try std.testing.expect(far.image_data == null);

    try std.testing.expectEqual(@as(usize, 1), try image_loader.loadCandidates(
        allocator,
        &candidates,
        .{ .lazy_near = .{ .scroll = 1800, .height = 600, .preload_margin = 600 } },
        &page_url,
        .default,
        &context,
        TestCallbacks,
    ));
    try std.testing.expect(far.image_data != null);
    try std.testing.expectEqual(@as(usize, 3), context.fetch_count);
}

test "lazy image layout preserves authored and fallback ratios then reflows intrinsic auto ratio" {
    const allocator = std.testing.allocator;
    var html_parser = try document.HTMLParser.init(
        allocator,
        "<main><img id=fixed loading=lazy src=fixed.ppm width=40 height=20>" ++
            "<br><img id=natural loading=lazy src=natural.ppm>" ++
            "<br><img id=fallback loading=lazy src=fallback.ppm width=160 " ++
            "style='aspect-ratio: auto 16 / 9'>" ++
            "<br><img id=forced loading=lazy src=forced.ppm width=160 " ++
            "style='aspect-ratio: 16 / 9'></main>",
    );
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    try document.style(allocator, &root, &.{});

    const fixed_node = findNodeById(&root, "fixed").?;
    const natural_node = findNodeById(&root, "natural").?;
    const fallback_node = findNodeById(&root, "fallback").?;
    const forced_node = findNodeById(&root, "forced").?;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    const layout = try Layout.init(allocator, std.testing.io, &environ, 800, 600, false);
    defer layout.deinit();
    const laid_out = try layout.buildDocument(&root);
    defer {
        laid_out.deinit();
        allocator.destroy(laid_out);
    }

    const fixed_before = layout.image_bounds.get(fixed_node).?;
    try std.testing.expectEqual(@as(i32, 40), fixed_before.width);
    try std.testing.expectEqual(@as(i32, 20), fixed_before.height);
    const natural_before = layout.image_bounds.get(natural_node).?;
    try std.testing.expectEqual(@as(i32, 1), natural_before.width);
    try std.testing.expectEqual(@as(i32, 1), natural_before.height);
    const fallback_before = layout.image_bounds.get(fallback_node).?;
    try std.testing.expectEqual(@as(i32, 160), fallback_before.width);
    try std.testing.expectEqual(@as(i32, 90), fallback_before.height);
    const forced_before = layout.image_bounds.get(forced_node).?;
    try std.testing.expectEqual(@as(i32, 160), forced_before.width);
    try std.testing.expectEqual(@as(i32, 90), forced_before.height);
    const height_before = laid_out.height.get().*;

    var page_url = try Url.init(allocator, "https://example.test/page.html");
    defer page_url.free(allocator);
    var context = TestContext{ .allocator = allocator };
    const candidates = [_]image_loader.Candidate{
        .{ .element = &fixed_node.element, .bounds = .{
            .x = fixed_before.x,
            .y = fixed_before.y,
            .width = fixed_before.width,
            .height = fixed_before.height,
        } },
        .{ .element = &natural_node.element, .bounds = .{
            .x = natural_before.x,
            .y = natural_before.y,
            .width = natural_before.width,
            .height = natural_before.height,
        } },
        .{ .element = &fallback_node.element, .bounds = .{
            .x = fallback_before.x,
            .y = fallback_before.y,
            .width = fallback_before.width,
            .height = fallback_before.height,
        } },
        .{ .element = &forced_node.element, .bounds = .{
            .x = forced_before.x,
            .y = forced_before.y,
            .width = forced_before.width,
            .height = forced_before.height,
        } },
    };
    try std.testing.expectEqual(@as(usize, 4), try image_loader.loadCandidates(
        allocator,
        &candidates,
        .{ .lazy_near = .{ .scroll = 0, .height = 600, .preload_margin = 600 } },
        &page_url,
        .default,
        &context,
        TestCallbacks,
    ));

    laid_out.mark();
    try laid_out.layout(layout);
    const fixed_after = layout.image_bounds.get(fixed_node).?;
    try std.testing.expectEqual(@as(i32, 40), fixed_after.width);
    try std.testing.expectEqual(@as(i32, 20), fixed_after.height);
    const natural_after = layout.image_bounds.get(natural_node).?;
    try std.testing.expectEqual(@as(i32, 30), natural_after.width);
    try std.testing.expectEqual(@as(i32, 12), natural_after.height);
    const fallback_after = layout.image_bounds.get(fallback_node).?;
    try std.testing.expectEqual(@as(i32, 160), fallback_after.width);
    try std.testing.expectEqual(@as(i32, 64), fallback_after.height);
    const forced_after = layout.image_bounds.get(forced_node).?;
    try std.testing.expectEqual(@as(i32, 160), forced_after.width);
    try std.testing.expectEqual(@as(i32, 90), forced_after.height);
    try std.testing.expect(laid_out.height.get().* != height_before);
}
