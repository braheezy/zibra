//! Lazy HTML-image selection and pre/post-decode layout regressions.

const std = @import("std");
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

test "lazy image layout preserves authored size then reflows intrinsic size after decode" {
    const allocator = std.testing.allocator;
    var html_parser = try document.HTMLParser.init(
        allocator,
        "<main><img id=fixed loading=lazy src=fixed.ppm width=40 height=20>" ++
            "<br><img id=natural loading=lazy src=natural.ppm></main>",
    );
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    try document.style(allocator, &root, &.{});

    const fixed_node = findNodeById(&root, "fixed").?;
    const natural_node = findNodeById(&root, "natural").?;
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
    };
    try std.testing.expectEqual(@as(usize, 2), try image_loader.loadCandidates(
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
    try std.testing.expect(laid_out.height.get().* > height_before);
}
