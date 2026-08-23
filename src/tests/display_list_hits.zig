//! Display-list hit testing, provenance, and retained-frame commit regressions.

const std = @import("std");
const browser = @import("../browser/root.zig");
const Layout = @import("../browser/render/layout.zig");
const BrowserSession = @import("../browser/session_state.zig").BrowserSession;
const tab_module = @import("../browser/tab.zig");
const inspection = @import("../document/inspection.zig");
const parser = @import("../document/parser.zig");
const Url = @import("../network/url.zig").Url;
const ScriptJs = @import("../script/js.zig");

const DisplayItem = browser.DisplayItem;
const Node = parser.Node;
const test_color = browser.Color{ .r = 12, .g = 34, .b = 56, .a = 255 };

fn source(layout_object: anytype, node: ?*Node) browser.DisplayItemSource {
    return .{ .layout = @ptrCast(layout_object), .node = node };
}

const TestLayoutOrigin = struct {
    node_ptr: ?*Node,
};

fn resolveTestLayoutOrigin(raw_origin: *const anyopaque, fragment: ?*Node) ?*Node {
    const origin: *const TestLayoutOrigin = @ptrCast(@alignCast(raw_origin));
    const origin_node = origin.node_ptr orelse return null;
    if (fragment) |candidate| return if (candidate == origin_node) candidate else null;
    return origin_node;
}

fn sourceFromOrigin(origin: *const TestLayoutOrigin, fragment: ?*Node) browser.DisplayItemSource {
    return .{
        .layout = @ptrCast(origin),
        .node = fragment,
        .layout_node_resolver = &resolveTestLayoutOrigin,
    };
}

fn rect(
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,
    item_source: ?browser.DisplayItemSource,
) DisplayItem {
    return .{ .rect = .{
        .x1 = x1,
        .y1 = y1,
        .x2 = x2,
        .y2 = y2,
        .color = test_color,
        .source = item_source,
    } };
}

test "display list hit testing chooses the topmost overlapping primitive" {
    var lower_generator: u8 = 0;
    var upper_generator: u8 = 0;
    const items = [_]DisplayItem{
        rect(0, 0, 30, 30, source(&lower_generator, null)),
        rect(10, 10, 20, 20, source(&upper_generator, null)),
    };

    const overlap = DisplayItem.hitTest(&items, 15, 15, 1.0).?;
    try std.testing.expect(overlap.source.layout == @as(*const anyopaque, @ptrCast(&upper_generator)));

    const lower_only = DisplayItem.hitTest(&items, 5, 5, 1.0).?;
    try std.testing.expect(lower_only.source.layout == @as(*const anyopaque, @ptrCast(&lower_generator)));
}

test "rounded element corners fall through to painted content underneath" {
    var lower_generator: u8 = 0;
    var rounded_generator: u8 = 0;
    const items = [_]DisplayItem{
        rect(0, 0, 100, 60, source(&lower_generator, null)),
        .{ .rounded_rect = .{
            .x1 = 0,
            .y1 = 0,
            .x2 = 100,
            .y2 = 60,
            .radius = 24,
            .color = test_color,
            .source = source(&rounded_generator, null),
        } },
    };

    const rounded_center = DisplayItem.hitTestDevice(&items, 50, 30, 1.0).?;
    try std.testing.expect(rounded_center.source.layout == @as(*const anyopaque, @ptrCast(&rounded_generator)));

    // The point is inside the rounded element's border box but outside its
    // painted corner, so the rounded element must not become the click target.
    const clipped_corner = DisplayItem.hitTestDevice(&items, 2, 2, 1.0).?;
    try std.testing.expect(clipped_corner.source.layout == @as(*const anyopaque, @ptrCast(&lower_generator)));

    // Fractional zoom uses the same device-space geometry as rasterization.
    const scaled_corner = DisplayItem.hitTestDevice(&items, 2, 2, 1.25).?;
    try std.testing.expect(scaled_corner.source.layout == @as(*const anyopaque, @ptrCast(&lower_generator)));

    var translated_children = [_]DisplayItem{items[1]};
    const translated = [_]DisplayItem{
        items[0],
        .{ .transform = .{
            .translate_x = 10,
            .translate_y = 10,
            .children = &translated_children,
        } },
    };
    const translated_center = DisplayItem.hitTestDevice(&translated, 74, 49, 1.25).?;
    try std.testing.expect(translated_center.source.layout == @as(*const anyopaque, @ptrCast(&rounded_generator)));
    const translated_corner = DisplayItem.hitTestDevice(&translated, 14, 14, 1.25).?;
    try std.testing.expect(translated_corner.source.layout == @as(*const anyopaque, @ptrCast(&lower_generator)));
}

test "rounded element hit clip constrains descendant paint commands" {
    var lower_generator: u8 = 0;
    var rounded_generator: u8 = 0;
    var rounded_children = [_]DisplayItem{
        // Model text or another descendant whose primitive bounds extend into
        // the containing rectangle's rounded-off corner.
        rect(0, 0, 100, 60, source(&rounded_generator, null)),
    };
    const items = [_]DisplayItem{
        rect(0, 0, 100, 60, source(&lower_generator, null)),
        .{ .blend = .{
            .opacity = 1.0,
            .blend_mode = null,
            .hit_clip = .{ .x1 = 0, .y1 = 0, .x2 = 100, .y2 = 60, .radius = 24 },
            .children = &rounded_children,
        } },
    };

    const center = DisplayItem.hitTestDevice(&items, 50, 30, 1.0).?;
    try std.testing.expect(center.source.layout == @as(*const anyopaque, @ptrCast(&rounded_generator)));
    const corner = DisplayItem.hitTestDevice(&items, 2, 2, 1.0).?;
    try std.testing.expect(corner.source.layout == @as(*const anyopaque, @ptrCast(&lower_generator)));

    var transformed_children = [_]DisplayItem{items[1]};
    const transformed = [_]DisplayItem{
        items[0],
        .{ .transform = .{
            .translate_x = 10,
            .translate_y = 10,
            .children = &transformed_children,
        } },
    };
    const transformed_corner = DisplayItem.hitTestDevice(&transformed, 14, 14, 1.25).?;
    try std.testing.expect(transformed_corner.source.layout == @as(*const anyopaque, @ptrCast(&lower_generator)));
}

test "display list hit testing inverts translations" {
    var generator: u8 = 0;
    var children = [_]DisplayItem{
        rect(0, 0, 10, 10, source(&generator, null)),
    };
    const items = [_]DisplayItem{.{ .transform = .{
        .translate_x = 20,
        .translate_y = 30,
        .children = &children,
    } }};

    const hit = DisplayItem.hitTest(&items, 25, 35, 1.0).?;
    try std.testing.expectEqual(@as(i32, 5), hit.x);
    try std.testing.expectEqual(@as(i32, 5), hit.y);
    try std.testing.expect(DisplayItem.hitTest(&items, 5, 5, 1.0) == null);
}

test "blurred pixels do not expand the element hit target" {
    var generator: u8 = 0;
    var children = [_]DisplayItem{rect(10, 10, 20, 20, source(&generator, null))};
    const items = [_]DisplayItem{.{ .blend = .{
        .opacity = 1.0,
        .blend_mode = null,
        .blur_radius = 6.0,
        .children = &children,
        .needs_compositing = true,
    } }};

    try std.testing.expect(DisplayItem.hitTest(&items, 15, 15, 1.0) != null);
    // This point can contain blur output, but CSS hit testing still uses the
    // originating painted box rather than the filter's visual outset.
    try std.testing.expect(DisplayItem.hitTest(&items, 7, 15, 1.0) == null);
}

test "device hit testing matches truncating raster edges at fractional zoom" {
    var generator: u8 = 0;
    const item_source = source(&generator, null);
    const items = [_]DisplayItem{rect(10, 10, 20, 20, item_source)};

    // Raster scales CSS 10 to device 12 at 1.25x, not the floating 12.5.
    try std.testing.expect(DisplayItem.hitTestDevice(&items, 12, 12, 1.25) != null);
    try std.testing.expect(DisplayItem.hitTestDevice(&items, 11, 12, 1.25) == null);
    try std.testing.expect(DisplayItem.hitTestDevice(&items, 24, 12, 1.25) != null);
    try std.testing.expect(DisplayItem.hitTestDevice(&items, 25, 12, 1.25) == null);

    // The same contract holds below 1x: CSS 10 begins at device 7.
    try std.testing.expect(DisplayItem.hitTestDevice(&items, 7, 7, 0.75) != null);
    try std.testing.expect(DisplayItem.hitTestDevice(&items, 6, 7, 0.75) == null);

    var transformed_children = [_]DisplayItem{rect(0, 0, 10, 10, item_source)};
    const transformed = [_]DisplayItem{.{ .transform = .{
        .translate_x = 10,
        .translate_y = 10,
        .children = &transformed_children,
    } }};
    try std.testing.expect(DisplayItem.hitTestDevice(&transformed, 12, 12, 1.25) != null);
    try std.testing.expect(DisplayItem.hitTestDevice(&transformed, 11, 12, 1.25) == null);
}

test "one-child dst_in masks earlier siblings without becoming a target" {
    var generator: u8 = 0;
    var mask_children = [_]DisplayItem{.{ .rounded_rect = .{
        .x1 = 0,
        .y1 = 0,
        .x2 = 100,
        .y2 = 100,
        .radius = 20,
        .color = test_color,
    } }};
    const items = [_]DisplayItem{
        rect(0, 0, 100, 100, source(&generator, null)),
        .{ .blend = .{
            .opacity = 1.0,
            .blend_mode = "dst_in",
            .children = &mask_children,
        } },
    };

    try std.testing.expect(DisplayItem.hitTest(&items, 50, 50, 1.0) != null);
    try std.testing.expect(DisplayItem.hitTest(&items, 2, 2, 1.0) == null);
}

test "scroll transforms remain clipped and hit-test through nested translation" {
    var generator: u8 = 0;
    var content = [_]DisplayItem{rect(0, 40, 100, 100, source(&generator, null))};
    var mask_children = [_]DisplayItem{rect(0, 0, 100, 40, null)};
    var scroll_group = [_]DisplayItem{
        .{ .transform = .{
            .translate_x = 0,
            .translate_y = -30,
            .children = &content,
        } },
        .{ .blend = .{
            .opacity = 1.0,
            .blend_mode = "dst_in",
            .children = &mask_children,
            .needs_compositing = true,
        } },
    };
    var clipped = [_]DisplayItem{.{ .blend = .{
        .opacity = 1.0,
        .blend_mode = null,
        .hit_clip = .{ .x1 = 0, .y1 = 0, .x2 = 100, .y2 = 40, .radius = 0 },
        .children = &scroll_group,
        .needs_compositing = true,
    } }};
    const items = [_]DisplayItem{.{ .transform = .{
        .translate_x = 10,
        .translate_y = 20,
        .children = &clipped,
    } }};

    try std.testing.expect(DisplayItem.hitTestDevice(&items, 20, 35, 1.0) != null);
    // The translated content continues below the 40px scroll port, but the
    // outer hit clip and dst_in mask both reject that invisible portion.
    try std.testing.expect(DisplayItem.hitTestDevice(&items, 20, 70, 1.0) == null);
}

test "composited opacity updates transformed retained and flattened layer lists" {
    var generator: u8 = 0;
    var opacity_owner: u8 = 0;
    var children = [_]DisplayItem{rect(0, 0, 20, 20, source(&generator, null))};
    var transformed_children = [_]DisplayItem{.{ .blend = .{
        .opacity = 1.0,
        .blend_mode = null,
        .children = &children,
        .node = @ptrCast(&opacity_owner),
        .needs_compositing = true,
    } }};
    var items = [_]DisplayItem{.{ .transform = .{
        .translate_x = 5,
        .translate_y = 5,
        .children = &transformed_children,
    } }};

    try std.testing.expect(DisplayItem.hitTest(&items, 10, 10, 1.0) != null);
    try std.testing.expect(DisplayItem.applyCompositedOpacity(&items, @ptrCast(&opacity_owner), 0.0));
    try std.testing.expect(DisplayItem.hitTest(&items, 10, 10, 1.0) == null);

    // A nested effect cloned into an ancestor/iframe layer changes pixels,
    // unlike changing the opacity of the layer's own node.
    transformed_children[0].blend.opacity = 1.0;
    var layer = browser.CompositedLayer.init(
        &items,
        .{ .left = 0, .top = 0, .right = 25, .bottom = 25 },
        1.0,
        null,
        null,
    );
    layer.needs_raster = false;
    try std.testing.expect(layer.applyCompositedOpacity(@ptrCast(&opacity_owner), 0.0));
    try std.testing.expect(layer.needs_raster);
    try std.testing.expectEqual(@as(f64, 0.0), transformed_children[0].blend.opacity);
}

test "composited transform updates only the CSS transform wrapper" {
    var owner: u8 = 0;
    var primitive = [_]DisplayItem{rect(0, 0, 20, 20, null)};
    var css_transform = [_]DisplayItem{.{ .transform = .{
        .translate_x = 0,
        .translate_y = 0,
        .children = &primitive,
        .node = @ptrCast(&owner),
        .composited = true,
    } }};
    var items = [_]DisplayItem{.{ .transform = .{
        .translate_x = 0,
        .translate_y = -30,
        .children = &css_transform,
        .node = @ptrCast(&owner),
    } }};

    try std.testing.expect(DisplayItem.applyCompositedTransform(
        &items,
        @ptrCast(&owner),
        80,
        25,
    ));
    try std.testing.expectEqual(@as(i32, -30), items[0].transform.translate_y);
    try std.testing.expectEqual(@as(i32, 80), items[0].transform.children[0].transform.translate_x);
    try std.testing.expectEqual(@as(i32, 25), items[0].transform.children[0].transform.translate_y);
}

test "simultaneous transform and opacity commit is draw-only" {
    const allocator = std.testing.allocator;
    var owner: u8 = 0;
    const primitive = try allocator.alloc(DisplayItem, 1);
    primitive[0] = rect(0, 0, 20, 20, null);
    const opacity_group = try allocator.alloc(DisplayItem, 1);
    opacity_group[0] = .{ .blend = .{
        .opacity = 1.0,
        .blend_mode = null,
        .children = primitive,
        .node = @ptrCast(&owner),
        .needs_compositing = true,
        .compositor_id = @intFromPtr(&owner),
    } };
    const display_list = try allocator.alloc(DisplayItem, 1);
    display_list[0] = .{ .transform = .{
        .translate_x = 0,
        .translate_y = 0,
        .children = opacity_group,
        .node = @ptrCast(&owner),
        .composited = true,
        .compositor_id = @intFromPtr(&owner),
    } };
    defer DisplayItem.freeList(allocator, display_list);

    var tab: tab_module.Tab = undefined;
    var test_browser: browser.Browser = undefined;
    test_browser.allocator = allocator;
    test_browser.io = std.testing.io;
    test_browser.lock = .init(std.testing.io);
    test_browser.tabs = .empty;
    defer test_browser.tabs.deinit(allocator);
    try test_browser.tabs.append(allocator, &tab);
    test_browser.active_tab_index = 0;
    test_browser.active_tab_display_list = display_list;
    test_browser.pending_composited_updates = .empty;
    defer test_browser.pending_composited_updates.deinit(allocator);
    test_browser.active_tab_url = null;
    test_browser.active_tab_committed_url = null;
    test_browser.active_tab_committed_security = .none;
    test_browser.active_tab_scroll = 0;
    test_browser.active_tab_height = 100;
    test_browser.active_tab_zoom = 1.0;
    test_browser.active_tab_prefers_dark = false;
    test_browser.needs_composite = false;
    test_browser.needs_raster = false;
    test_browser.needs_draw = false;

    const updates = [_]tab_module.CompositedUpdate{
        .{ .node = @ptrCast(&owner), .value = .{ .transform = .{ .x = 70, .y = 15 } } },
        .{ .node = @ptrCast(&owner), .value = .{ .opacity = 0.4 } },
    };
    test_browser.commit(&tab, .{
        .url = null,
        .display_list = null,
        .scroll = null,
        .height = 100,
        .zoom = 1.0,
        .prefers_dark = false,
        .composited_updates = &updates,
    });

    // Prevent the manual ownership defer above from racing Browser ownership;
    // this minimal test Browser is not deinitialized.
    test_browser.active_tab_display_list = null;
    try std.testing.expect(!test_browser.needs_composite);
    try std.testing.expect(!test_browser.needs_raster);
    try std.testing.expect(test_browser.needs_draw);
    try std.testing.expectEqual(@as(usize, 2), test_browser.pending_composited_updates.items.len);
    try std.testing.expectEqual(@as(i32, 70), display_list[0].transform.translate_x);
    try std.testing.expectEqual(@as(i32, 15), display_list[0].transform.translate_y);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), display_list[0].transform.children[0].blend.opacity, 0.000001);
}

test "root scrolling inside the interest region is draw-only" {
    const allocator = std.testing.allocator;
    var tab: tab_module.Tab = undefined;
    var frame: tab_module.Frame = undefined;
    frame.scroll = 0;
    frame.content_height = 5000;
    frame.viewport_height = 534;
    tab.root_frame = &frame;
    tab.focused_frame = null;
    tab.tab_height = 534;
    tab.accessibility.zoom = 1.0;

    var test_browser: browser.Browser = undefined;
    test_browser.allocator = allocator;
    test_browser.io = std.testing.io;
    test_browser.lock = .init(std.testing.io);
    test_browser.tabs = .empty;
    defer test_browser.tabs.deinit(allocator);
    try test_browser.tabs.append(allocator, &tab);
    test_browser.active_tab_index = 0;
    test_browser.active_tab_scroll = 0;
    test_browser.active_tab_height = 5000;
    test_browser.active_tab_zoom = 1.0;
    test_browser.window_height = 600;
    test_browser.chrome.bottom = 66;
    test_browser.tab_interest_region = .{ .start_px = 0, .height_px = 2400 };
    test_browser.tab_interest_region_valid = true;
    test_browser.needs_composite = false;
    test_browser.needs_raster = false;
    test_browser.needs_draw = false;
    test_browser.needs_animation_frame = false;
    test_browser.animation_timer_active = false;
    test_browser.animation_timer_generation = 0;
    test_browser.animation_frame_deadline_ns = null;
    test_browser.shutting_down = true;

    test_browser.handleScroll(100);
    try std.testing.expectEqual(@as(i32, 100), frame.scroll);
    try std.testing.expectEqual(@as(i32, 100), test_browser.active_tab_scroll);
    try std.testing.expect(!test_browser.needs_composite);
    try std.testing.expect(!test_browser.needs_raster);
    try std.testing.expect(test_browser.needs_draw);
}

test "layout origin validates the fragment used for activation" {
    var expected_node: Node = undefined;
    var foreign_node: Node = undefined;
    const origin = TestLayoutOrigin{ .node_ptr = &expected_node };

    try std.testing.expect(sourceFromOrigin(&origin, &expected_node).originatingNode() == &expected_node);
    try std.testing.expect(sourceFromOrigin(&origin, null).originatingNode() == &expected_node);
    try std.testing.expect(sourceFromOrigin(&origin, &foreign_node).originatingNode() == null);
}

test "zoomed glyph hit testing uses device bitmap dimensions" {
    var generator: u8 = 0;
    const items = [_]DisplayItem{.{ .glyph = .{
        .x = 10,
        .y = 4,
        .glyph = .{
            .w = 20,
            .h = 12,
            .ascent = 9,
            .descent = 3,
        },
        .color = test_color,
        .source = source(&generator, null),
    } }};

    // At 2x, the 20-device-pixel bitmap occupies ten layout pixels.
    try std.testing.expect(DisplayItem.hitTest(&items, 19, 6, 2.0) != null);
    try std.testing.expect(DisplayItem.hitTest(&items, 20, 6, 2.0) == null);
}

fn findElement(root: *Node, tag: []const u8) !*Node {
    var nodes = std.ArrayList(*Node).empty;
    defer nodes.deinit(std.testing.allocator);
    try parser.treeToList(std.testing.allocator, root, &nodes);
    for (nodes.items) |node| {
        if (node.* == .element and std.ascii.eqlIgnoreCase(node.element.tag, tag)) return node;
    }
    return error.MissingElement;
}

test "inspection DOM repair keeps display-list ancestry valid after a page move" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<html><body><a href=target>visited text</a></body></html>",
    );
    defer html_parser.deinit(allocator);
    const parsed_root = try html_parser.parse();

    // Model Page.load's by-value return, then use the same repair seam as the
    // dump pipeline before visited paint walks a text node's parents.
    var page: inspection.Page = undefined;
    page.root = parsed_root;
    defer page.root.deinit(allocator);
    page.repairParentPointers();

    const link = try findElement(&page.root, "a");
    link.element.is_visited = true;
    const text_node = &link.element.children.items[0];
    try std.testing.expect(Layout.nodeIsInVisitedLink(text_node));
}

fn initQueueBrowser(
    result: *browser.Browser,
    allocator: std.mem.Allocator,
    session: *BrowserSession,
) void {
    result.allocator = allocator;
    result.io = std.testing.io;
    result.session_state = session;
    result.lock = .init(std.testing.io);
    result.tabs = .empty;
    result.active_tab_index = null;
    result.shutting_down = false;
    result.animation_timer_active = false;
    result.needs_animation_frame = false;
    result.pending_new_tabs = .empty;
}

fn deinitQueueBrowser(test_browser: *browser.Browser) void {
    for (test_browser.pending_new_tabs.items) |*url| url.free(test_browser.allocator);
    test_browser.pending_new_tabs.deinit(test_browser.allocator);
    test_browser.tabs.deinit(test_browser.allocator);
}

fn initClickTab(tab: *tab_module.Tab, allocator: std.mem.Allocator) void {
    tab.allocator = allocator;
    tab.accessibility = .{};
    tab.root_frame = null;
    tab.focused_frame = null;
    tab.frames_by_id = std.AutoHashMap(u32, *tab_module.Frame).init(allocator);
    tab.parent_window_ids = std.AutoHashMap(u32, u32).init(allocator);
}

fn deinitClickTab(tab: *tab_module.Tab) void {
    tab.frames_by_id.deinit();
    tab.parent_window_ids.deinit();
}

fn initMutationBrowser(
    result: *browser.Browser,
    allocator: std.mem.Allocator,
    session: *BrowserSession,
) void {
    initQueueBrowser(result, allocator, session);
    result.active_tab_url = null;
    result.active_tab_committed_url = null;
    result.active_tab_display_list = null;
    result.composited_layers = .empty;
    result.tab_draw_list = .empty;
    result.pending_composited_updates = .empty;
    result.shutting_down = true;
    result.needs_composite = false;
    result.needs_raster = false;
    result.needs_draw = false;
}

fn deinitMutationBrowser(test_browser: *browser.Browser) void {
    if (test_browser.active_tab_url) |url| test_browser.allocator.free(url);
    if (test_browser.active_tab_committed_url) |url| test_browser.allocator.free(url);
    if (test_browser.active_tab_display_list) |items| DisplayItem.freeList(test_browser.allocator, items);
    for (test_browser.composited_layers.items) |*layer| layer.deinit(test_browser.allocator);
    test_browser.composited_layers.deinit(test_browser.allocator);
    DisplayItem.freeItems(test_browser.allocator, test_browser.tab_draw_list.items);
    test_browser.tab_draw_list.deinit(test_browser.allocator);
    test_browser.pending_composited_updates.deinit(test_browser.allocator);
    deinitQueueBrowser(test_browser);
}

fn initMutationTab(tab: *tab_module.Tab, allocator: std.mem.Allocator, test_browser: *browser.Browser) void {
    initClickTab(tab, allocator);
    tab.browser = test_browser;
    tab.needs_style = false;
    tab.needs_layout = false;
    tab.needs_paint = false;
    tab.composited_updates = .empty;
    tab.accessibility_root = null;
    tab.accessibility_focused = null;
    tab.accessibility_hovered = null;
    tab.accessibility_polite_queue = .empty;
    tab.accessibility_highlight = null;
    tab.accessibility_strings = .empty;
}

fn deinitMutationTab(tab: *tab_module.Tab) void {
    tab.composited_updates.deinit(tab.allocator);
    tab.accessibility_polite_queue.deinit(tab.allocator);
    for (tab.accessibility_strings.items) |value| tab.allocator.free(value);
    tab.accessibility_strings.deinit(tab.allocator);
    deinitClickTab(tab);
}

test "structural mutation retires a painted link before DOM removal" {
    const allocator = std.testing.allocator;
    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();

    var test_browser: browser.Browser = undefined;
    initMutationBrowser(&test_browser, allocator, &session);
    defer deinitMutationBrowser(&test_browser);

    var tab: tab_module.Tab = undefined;
    initMutationTab(&tab, allocator, &test_browser);
    defer deinitMutationTab(&tab);
    try test_browser.tabs.append(allocator, &tab);
    test_browser.active_tab_index = 0;

    var frame = tab_module.Frame.init(allocator, &tab, null, null);
    defer frame.deinit();
    tab.root_frame = &frame;
    tab.focused_frame = &frame;

    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<html><body><a href=next.html>painted link</a></body></html>",
    );
    defer html_parser.deinit(allocator);
    frame.current_node = try html_parser.parse();
    parser.fixParentPointers(&frame.current_node.?, null);
    const body = try findElement(&frame.current_node.?, "body");
    const link = try findElement(&frame.current_node.?, "a");
    link.element.is_focused = true;
    frame.focus = link;
    link.element.setScrollGeometry(true, 20, 80);
    frame.scroll_focus = link;

    var current_url = try Url.init(allocator, "https://example.com/page.html");
    defer current_url.free(allocator);
    frame.current_url = &current_url;

    const generator = TestLayoutOrigin{ .node_ptr = link };
    const retained = try allocator.alloc(DisplayItem, 1);
    retained[0] = rect(10, 10, 80, 30, sourceFromOrigin(&generator, link));
    frame.display_list = retained;
    try frame.input_bounds.put(link, .{ .x = 10, .y = 10, .width = 70, .height = 20 });
    try frame.link_bounds.append(allocator, .{
        .node = link,
        .bounds = .{ .x = 10, .y = 10, .width = 70, .height = 20 },
    });
    try frame.focus_bounds.append(allocator, .{
        .node = link,
        .bounds = .{ .x = 10, .y = 10, .width = 70, .height = 20 },
    });

    const committed_children = try allocator.alloc(DisplayItem, 1);
    committed_children[0] = rect(10, 10, 80, 30, null);
    const committed = try allocator.alloc(DisplayItem, 1);
    committed[0] = .{ .blend = .{
        .opacity = 1.0,
        .blend_mode = null,
        .children = committed_children,
        .node = @ptrCast(&link.element),
        .needs_compositing = true,
    } };
    test_browser.active_tab_display_list = committed;

    tab.prepareForDomMutation(&test_browser, &frame, body);
    try std.testing.expect(frame.display_list == null);
    try std.testing.expect(frame.focus == null);
    try std.testing.expect(frame.scroll_focus == null);
    try std.testing.expectEqual(@as(usize, 0), frame.input_bounds.count());
    try std.testing.expectEqual(@as(usize, 0), frame.link_bounds.items.len);
    try std.testing.expectEqual(@as(usize, 0), frame.focus_bounds.items.len);
    try std.testing.expect(test_browser.active_tab_display_list == null);
    try std.testing.expect(tab.needs_style and tab.needs_layout and tab.needs_paint);
    try std.testing.expect(frame.resources_dirty);
    try std.testing.expect(test_browser.needs_animation_frame);

    for (body.element.children.items) |*child| child.deinit(allocator);
    body.element.children.clearRetainingCapacity();
    body.element.children_dirty = true;
    parser.fixParentPointers(&frame.current_node.?, null);

    try std.testing.expect(!try frame.click(&test_browser, 20, 20, .middle));
    try std.testing.expectEqual(@as(usize, 0), test_browser.pending_new_tabs.items.len);
}

test "first contenteditable append preserves focus for subsequent typing" {
    const allocator = std.testing.allocator;
    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();

    var test_browser: browser.Browser = undefined;
    initMutationBrowser(&test_browser, allocator, &session);
    defer deinitMutationBrowser(&test_browser);

    var tab: tab_module.Tab = undefined;
    initMutationTab(&tab, allocator, &test_browser);
    defer deinitMutationTab(&tab);
    try test_browser.tabs.append(allocator, &tab);
    test_browser.active_tab_index = 0;

    var frame = tab_module.Frame.init(allocator, &tab, null, null);
    defer frame.deinit();
    tab.root_frame = &frame;
    tab.focused_frame = &frame;

    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<html><body><div contenteditable></div></body></html>",
    );
    defer html_parser.deinit(allocator);
    frame.current_node = try html_parser.parse();
    parser.fixParentPointers(&frame.current_node.?, null);
    const editable = try findElement(&frame.current_node.?, "div");
    editable.element.is_focused = true;
    frame.focus = editable;

    try tab.keypress(&test_browser, 'a');
    try std.testing.expect(frame.focus == editable);
    try std.testing.expectEqual(@as(usize, 1), editable.element.children.items.len);
    try std.testing.expectEqualStrings("a", editable.element.children.items[0].text.text);

    try tab.keypress(&test_browser, 'b');
    try std.testing.expect(frame.focus == editable);
    try std.testing.expectEqualStrings("ab", editable.element.children.items[0].text.text);
}

test "frame clicks use painted link fragments when link bounds are empty" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<html><body><a href=next.html>two fragments</a></body></html>",
    );
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);
    const link = try findElement(&root, "a");

    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();
    var test_browser: browser.Browser = undefined;
    initQueueBrowser(&test_browser, allocator, &session);
    defer deinitQueueBrowser(&test_browser);

    var tab: tab_module.Tab = undefined;
    initClickTab(&tab, allocator);
    defer deinitClickTab(&tab);
    var frame = tab_module.Frame.init(allocator, &tab, null, null);
    defer frame.deinit();
    tab.root_frame = &frame;

    var current_url = try Url.init(allocator, "https://example.com/docs/page.html");
    defer current_url.free(allocator);
    frame.current_url = &current_url;
    const generator = TestLayoutOrigin{ .node_ptr = link };
    const list = try allocator.alloc(DisplayItem, 2);
    list[0] = rect(10, 20, 30, 30, sourceFromOrigin(&generator, link));
    list[1] = rect(50, 20, 70, 30, sourceFromOrigin(&generator, link));
    frame.display_list = list;

    try std.testing.expectEqual(@as(usize, 0), frame.link_bounds.items.len);
    // The old unioned per-line bounds treated this unpainted gap as a link.
    try std.testing.expect(!try frame.click(&test_browser, 40, 25, .middle));
    try std.testing.expectEqual(@as(usize, 0), test_browser.pending_new_tabs.items.len);

    try std.testing.expect(try frame.click(&test_browser, 15, 25, .middle));
    try std.testing.expectEqual(@as(usize, 1), test_browser.pending_new_tabs.items.len);
    try std.testing.expectEqualStrings("/docs/next.html", test_browser.pending_new_tabs.items[0].path);
}

test "primary painted click focuses the innermost scroll container" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<body><div><div><span>painted child</span></div></div></body>",
    );
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);

    var divs = std.ArrayList(*Node).empty;
    defer divs.deinit(allocator);
    var all_nodes = std.ArrayList(*Node).empty;
    defer all_nodes.deinit(allocator);
    try parser.treeToList(allocator, &root, &all_nodes);
    var painted: ?*Node = null;
    for (all_nodes.items) |node| switch (node.*) {
        .element => |element| {
            if (std.ascii.eqlIgnoreCase(element.tag, "div")) try divs.append(allocator, node);
            if (std.ascii.eqlIgnoreCase(element.tag, "span")) painted = node;
        },
        .text => {},
    };
    try std.testing.expectEqual(@as(usize, 2), divs.items.len);
    const outer = divs.items[0];
    const inner = divs.items[1];
    const painted_node = painted orelse return error.TestPaintedNodeMissing;
    outer.element.setScrollGeometry(true, 100, 300);
    inner.element.setScrollGeometry(true, 50, 200);

    var tab: tab_module.Tab = undefined;
    initClickTab(&tab, allocator);
    defer deinitClickTab(&tab);
    var frame = tab_module.Frame.init(allocator, &tab, null, null);
    defer frame.deinit();
    tab.root_frame = &frame;

    const generator = TestLayoutOrigin{ .node_ptr = painted_node };
    const display_list = try allocator.alloc(DisplayItem, 1);
    display_list[0] = rect(0, 0, 80, 30, sourceFromOrigin(&generator, painted_node));
    frame.display_list = display_list;

    var unused_browser: browser.Browser = undefined;
    try std.testing.expect(try frame.clickDevice(&unused_browser, 10, 10, .primary, 1.0));
    try std.testing.expect(frame.scroll_focus == inner);
    try std.testing.expect(tab.focused_frame == &frame);

    inner.element.setScrollGeometry(false, 0, 0);
    try std.testing.expect(try frame.clickDevice(&unused_browser, 10, 10, .primary, 1.0));
    try std.testing.expect(frame.scroll_focus == outer);
}

test "painted ordinary elements dispatch click events from target through ancestors" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<main><div id=ancestor><span id=painted>click me</span></div>" ++
            "<a><strong id=paintedLinkChild>link child</strong></a></main>",
    );
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);
    const painted = try findElement(&root, "span");
    const painted_link_child = try findElement(&root, "strong");

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try ScriptJs.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(73, &root);
    defer js.setNodes(73, null);
    _ = try js.evaluate(73,
        \\var clicks = [];
        \\painted.addEventListener('click', function(event) {
        \\  clicks.push(event.target.getAttribute('id'));
        \\});
        \\ancestor.addEventListener('click', function() { clicks.push('ancestor'); });
        \\document.querySelectorAll('main')[0].addEventListener('click', function() {
        \\  clicks.push('main');
        \\});
        \\var linkClicks = [];
        \\paintedLinkChild.addEventListener('click', function() { linkClicks.push('target'); });
        \\document.querySelectorAll('a')[0].addEventListener('click', function() {
        \\  linkClicks.push('link');
        \\});
    );

    var tab: tab_module.Tab = undefined;
    initClickTab(&tab, allocator);
    defer deinitClickTab(&tab);
    var frame = tab_module.Frame.init(allocator, &tab, null, null);
    defer frame.deinit();
    tab.root_frame = &frame;
    frame.js_context = js;
    frame.window_id = 73;

    const generator = TestLayoutOrigin{ .node_ptr = painted };
    const link_generator = TestLayoutOrigin{ .node_ptr = painted_link_child };
    const display_list = try allocator.alloc(DisplayItem, 2);
    display_list[0] = rect(10, 10, 80, 30, sourceFromOrigin(&generator, painted));
    display_list[1] = rect(
        90,
        10,
        160,
        30,
        sourceFromOrigin(&link_generator, painted_link_child),
    );
    frame.display_list = display_list;

    var unused_browser: browser.Browser = undefined;
    try std.testing.expect(try frame.clickDevice(&unused_browser, 20, 20, .primary, 1.0));
    const result = try js.evaluate(73, "clicks.join(',') === 'painted,ancestor,main'");
    try std.testing.expect(result.toBoolean());

    try std.testing.expect(try frame.clickDevice(&unused_browser, 100, 20, .primary, 1.0));
    const link_result = try js.evaluate(73, "linkClicks.join(',') === 'target,link'");
    try std.testing.expect(link_result.toBoolean());
}

test "iframe display hit translates into the child frame list" {
    const allocator = std.testing.allocator;
    var parent_parser = try parser.HTMLParser.init(
        allocator,
        "<html><body><iframe src=child.html></iframe></body></html>",
    );
    defer parent_parser.deinit(allocator);
    var parent_root = try parent_parser.parse();
    defer parent_root.deinit(allocator);
    parser.fixParentPointers(&parent_root, null);
    const iframe_node = try findElement(&parent_root, "iframe");

    var child_parser = try parser.HTMLParser.init(
        allocator,
        "<html><body><a href=target.html>target</a></body></html>",
    );
    defer child_parser.deinit(allocator);
    var child_root = try child_parser.parse();
    defer child_root.deinit(allocator);
    parser.fixParentPointers(&child_root, null);
    const link = try findElement(&child_root, "a");

    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();
    var test_browser: browser.Browser = undefined;
    initQueueBrowser(&test_browser, allocator, &session);
    defer deinitQueueBrowser(&test_browser);

    var tab: tab_module.Tab = undefined;
    initClickTab(&tab, allocator);
    defer deinitClickTab(&tab);
    var parent = tab_module.Frame.init(allocator, &tab, null, null);
    defer parent.deinit();
    tab.root_frame = &parent;

    const child = try allocator.create(tab_module.Frame);
    child.* = tab_module.Frame.init(allocator, &tab, &parent, iframe_node);
    try parent.children.append(allocator, child);
    child.scroll = 7;
    var child_url = try Url.init(allocator, "https://example.com/frame/child.html");
    defer child_url.free(allocator);
    child.current_url = &child_url;

    var parent_generator: u8 = 0;
    const parent_list = try allocator.alloc(DisplayItem, 1);
    parent_list[0] = .{ .iframe = .{
        .rect = .{ .left = 10, .top = 20, .right = 110, .bottom = 80 },
        .node = iframe_node,
        .source = source(&parent_generator, iframe_node),
    } };
    parent.display_list = parent_list;

    var child_generator: u8 = 0;
    const child_list = try allocator.alloc(DisplayItem, 1);
    child_list[0] = rect(10, 20, 30, 30, source(&child_generator, link));
    child.display_list = child_list;

    // Parent (25,35) -> child (15,22) after iframe origin and child scroll.
    try std.testing.expect(try parent.click(&test_browser, 25, 35, .middle));
    try std.testing.expectEqual(@as(usize, 1), test_browser.pending_new_tabs.items.len);
    try std.testing.expectEqualStrings("/frame/target.html", test_browser.pending_new_tabs.items[0].path);

    // At .75x, scaling top and scroll separately would map this device point
    // to child y=0. The compositor scales their combined translation
    // (top-scroll) once, producing child y=1 where the link is painted.
    parent_list[0].iframe.rect = .{ .left = 2, .top = 2, .right = 20, .bottom = 20 };
    child.scroll = 1;
    child_list[0] = rect(0, 2, 4, 4, source(&child_generator, link));
    try std.testing.expect(try parent.clickDevice(&test_browser, 1, 1, .middle, 0.75));
    try std.testing.expectEqual(@as(usize, 2), test_browser.pending_new_tabs.items.len);
}

test "activating a clean tab republishes its retained list and committed URL" {
    const allocator = std.testing.allocator;
    var session = BrowserSession.init(allocator, std.testing.io);
    defer session.deinit();

    var test_browser: browser.Browser = undefined;
    test_browser.allocator = allocator;
    test_browser.io = std.testing.io;
    test_browser.session_state = &session;
    test_browser.lock = .init(std.testing.io);
    test_browser.tabs = .empty;
    defer test_browser.tabs.deinit(allocator);
    test_browser.active_tab_index = null;
    test_browser.active_tab_url = null;
    test_browser.active_tab_committed_url = null;
    defer if (test_browser.active_tab_url) |url| allocator.free(url);
    defer if (test_browser.active_tab_committed_url) |url| allocator.free(url);
    test_browser.active_tab_display_list = null;
    defer if (test_browser.active_tab_display_list) |items| DisplayItem.freeList(allocator, items);
    test_browser.composited_layers = .empty;
    defer test_browser.composited_layers.deinit(allocator);
    test_browser.tab_draw_list = .empty;
    defer test_browser.tab_draw_list.deinit(allocator);
    test_browser.pending_composited_updates = .empty;
    defer test_browser.pending_composited_updates.deinit(allocator);
    test_browser.shutting_down = true; // Suppress timer threads; run the worker step directly.
    test_browser.animation_timer_active = false;
    test_browser.animation_timer_generation = 0;
    test_browser.animation_frame_deadline_ns = null;
    test_browser.needs_animation_frame = false;
    test_browser.needs_composite = false;
    test_browser.needs_raster = false;
    test_browser.needs_draw = false;

    var tab: tab_module.Tab = undefined;
    initClickTab(&tab, allocator);
    defer deinitClickTab(&tab);
    tab.browser = &test_browser;
    tab.needs_style = false;
    tab.needs_layout = false;
    tab.needs_paint = false;
    tab.visited_generation = session.currentVisitedGeneration();
    tab.activation_commit_requested = std.atomic.Value(bool).init(false);
    tab.scroll_changed_in_tab = false;
    tab.composited_updates = .empty;
    defer tab.composited_updates.deinit(allocator);

    var frame = tab_module.Frame.init(allocator, &tab, null, null);
    defer frame.deinit();
    tab.root_frame = &frame;
    frame.scroll = 37;
    frame.content_height = 900;
    var current_url = try Url.init(allocator, "https://example.com/clean");
    defer current_url.free(allocator);
    frame.current_url = &current_url;
    var generator: u8 = 0;
    const retained = try allocator.alloc(DisplayItem, 1);
    retained[0] = rect(0, 0, 20, 20, source(&generator, null));
    frame.display_list = retained;

    try test_browser.tabs.append(allocator, &tab);
    test_browser.setActiveTab(&tab);
    try std.testing.expect(tab.activation_commit_requested.load(.acquire));
    try std.testing.expect(test_browser.active_tab_display_list == null);

    tab.runAnimationFrame(0);

    try std.testing.expect(frame.display_list != null);
    try std.testing.expect(frame.display_list.?[0].source() != null);
    try std.testing.expect(test_browser.active_tab_display_list != null);
    try std.testing.expect(test_browser.active_tab_display_list.?[0].source() == null);
    try std.testing.expectEqual(@as(i32, 37), test_browser.active_tab_scroll);
    try std.testing.expectEqualStrings("https://example.com/clean", test_browser.active_tab_url.?);
    try std.testing.expectEqualStrings("https://example.com/clean", test_browser.active_tab_committed_url.?);
}
