//! Browser-free native CSS integration, responsive selection and stylesheet
//! publication regressions against a styled DOM with reclaiming allocators.

const std = @import("std");
const inspection = @import("../document/inspection.zig");
const dom = @import("../document/dom.zig");
const CSSParser = @import("../document/css_parser.zig");
const lengths = @import("../document/length.zig");
const Page = inspection.Page;
const allocator = std.testing.allocator;

fn findById(node: *dom.Node, id: []const u8) ?*dom.Node {
    switch (node.*) {
        .text => return null,
        .element => |*element| {
            if (element.attributes) |attributes| {
                if (attributes.get("id")) |actual| {
                    if (std.mem.eql(u8, id, actual)) return node;
                }
            }
            for (element.children.items) |*child| {
                if (findById(child, id)) |match| return match;
            }
        },
    }
    return null;
}

fn value(node: *dom.Node, property: []const u8) []const u8 {
    return node.element.style.?.getPtr(property).?.get().*;
}

fn previousValue(node: *dom.Node, property: []const u8) []const u8 {
    return node.element.style.?.getPtr(property).?.lastValue().*;
}

const narrow: CSSParser.MediaEnvironment = .{ .viewport_width_css = 400, .viewport_height_css = 600 };
const wide: CSSParser.MediaEnvironment = .{ .viewport_width_css = 800, .viewport_height_css = 600 };

test "Native CSS inspection shares stylesheet and inline declaration precedence" {
    const html =
        "<style>#target { color:red; width:23px; width:unsupported; margin:2px; }</style>" ++
        "<div id=target style='color:green; color:unsupported; " ++
        "background-color:blue; margin:3px !important; margin-left:9px'></div>";
    var page = try Page.fromHtml(allocator, html, .{ .media = narrow });
    defer page.deinit();
    page.repairParentPointers();
    const target = findById(&page.root, "target").?;
    try std.testing.expectEqual(@as(usize, 2), page.sheetCount());
    try std.testing.expectEqualStrings("green", value(target, "color"));
    try std.testing.expectEqualStrings("blue", value(target, "background-color"));
    try std.testing.expectEqualStrings("23px", value(target, "width"));
    try std.testing.expectEqualStrings("3px", value(target, "margin-left"));
    try std.testing.expect(!dom.styleTreeNeedsUpdate(&page.root));
}

const responsive_html =
    "<style>#target { width:41px; color:green; }" ++
    "@keyframes pulse { from { opacity:0.2 } to { opacity:0.8 } }" ++
    "@media (min-width:600px) { #target { width:91px; color:blue; }" ++
    "@keyframes pulse { from { opacity:0.4 } to { opacity:1 } } }</style>" ++
    "<main id=target><span id=child>inherited</span></main>";

test "Native CSS inspection reselects media from retained source and restyles descendants" {
    var page = try Page.fromHtml(allocator, responsive_html, .{ .media = narrow });
    defer page.deinit();
    page.repairParentPointers();
    const target = findById(&page.root, "target").?;
    const child = findById(&page.root, "child").?;
    const source = page.sheetSource(1);
    const ua_source = page.sheetSource(0);
    try std.testing.expectEqualStrings("41px", value(target, "width"));
    try std.testing.expectEqualStrings("green", value(child, "color"));
    try std.testing.expectEqual(@as(usize, 1), page.keyframes.items.len);

    try page.reselectMedia(wide);
    try std.testing.expectEqual(source.ptr, page.sheetSource(1).ptr);
    try std.testing.expectEqual(ua_source.ptr, page.sheetSource(0).ptr);
    try std.testing.expectEqual(@as(usize, 2), page.keyframes.items.len);
    try std.testing.expect(dom.styleTreeNeedsUpdate(&page.root));
    try std.testing.expectEqualStrings("41px", previousValue(target, "width"));
    try std.testing.expectEqualStrings("green", previousValue(child, "color"));
    try page.restyle();
    try std.testing.expectEqualStrings("91px", value(target, "width"));
    try std.testing.expectEqualStrings("blue", value(child, "color"));
    try std.testing.expect(!dom.styleTreeNeedsUpdate(&page.root));

    try page.reselectMedia(narrow);
    try page.restyle();
    try std.testing.expectEqual(source.ptr, page.sheetSource(1).ptr);
    try std.testing.expectEqualStrings("41px", value(target, "width"));
    try std.testing.expectEqualStrings("green", value(child, "color"));
    try std.testing.expectEqual(@as(usize, 1), page.keyframes.items.len);
}

test "Native CSS stylesheet replacement retires source while historical computed strings remain valid" {
    var page = try Page.fromHtml(allocator, responsive_html, .{ .media = narrow });
    defer page.deinit();
    page.repairParentPointers();
    const target = findById(&page.root, "target").?;
    const child = findById(&page.root, "child").?;
    const old_source = page.sheetSource(1);
    const old_width = value(target, "width");
    const old_color = value(child, "color");
    const old_start = @intFromPtr(old_source.ptr);
    const old_end = old_start + old_source.len;
    try std.testing.expect(@intFromPtr(old_width.ptr) < old_start or @intFromPtr(old_width.ptr) >= old_end);
    try std.testing.expect(@intFromPtr(old_color.ptr) < old_start or @intFromPtr(old_color.ptr) >= old_end);

    const replacement = try allocator.dupe(u8, "#target { width:73px; color:purple; padding:7px !important; }");
    page.replaceStylesheet(1, replacement) catch |err| {
        allocator.free(replacement);
        return err;
    };
    @memset(replacement, '?');
    allocator.free(replacement);
    try std.testing.expectEqual(@as(usize, 2), page.sheetCount());
    try std.testing.expectEqual(@as(usize, 0), page.keyframes.items.len);
    try std.testing.expect(dom.styleTreeNeedsUpdate(&page.root));
    try std.testing.expectEqualStrings("41px", old_width);
    try std.testing.expectEqualStrings("green", old_color);
    try std.testing.expectEqualStrings("41px", previousValue(target, "width"));
    try std.testing.expectEqualStrings("green", previousValue(child, "color"));
    try std.testing.expectEqualStrings("#target { width:73px; color:purple; padding:7px !important; }", page.sheetSource(1));
    try page.restyle();
    try std.testing.expectEqualStrings("73px", value(target, "width"));
    try std.testing.expectEqualStrings("purple", value(child, "color"));
    try std.testing.expectEqualStrings("7px", value(target, "padding-left"));
    try std.testing.expectEqualStrings("41px", old_width);
    try std.testing.expectEqualStrings("green", old_color);
    try std.testing.expect(!dom.styleTreeNeedsUpdate(&page.root));
}

const Publication = enum { replace, reselect, replace_supports, replace_layers };

fn publicationAllocationFailures(operation: Publication) !void {
    // Keep the allocator context at one address throughout Page construction,
    // retries and destruction; every nested stylesheet/map allocator borrows it.
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var page = try Page.fromHtml(failing.allocator(), responsive_html, .{ .media = narrow });
    defer page.deinit();
    page.repairParentPointers();
    const target = findById(&page.root, "target").?;
    const child = findById(&page.root, "child").?;
    const source = page.sheetSource(1);
    const rules_pointer = page.rules.items.ptr;
    const rules_count = page.rules.items.len;
    const keyframes_pointer = page.keyframes.items.ptr;
    const keyframes_count = page.keyframes.items.len;
    const live_bytes = failing.allocated_bytes - failing.freed_bytes;
    var failure_count: usize = 0;
    for (0..8192) |offset| {
        failing.fail_index = failing.alloc_index + offset;
        failing.resize_fail_index = failing.resize_index;
        failing.has_induced_failure = false;
        const result = switch (operation) {
            .replace => page.replaceStylesheet(1, "#target { width:73px; color:purple; }"),
            .replace_supports => page.replaceStylesheet(1, "@supports (color:purple) and selector(:is(#target, .card)) {" ++
                "@keyframes supported {from {opacity:0} to {opacity:1}}" ++
                "@supports not future() {#target {width:73px;color:purple}}}"),
            .replace_layers => page.replaceStylesheet(1, "@layer base, theme; @layer theme {#target{width:73px;color:purple}}" ++
                "@layer base.child {#target{width:1px;color:red}@keyframes pulse{from,to{opacity:0.5}}}"),
            .reselect => page.reselectMedia(wide),
        };
        result catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            failure_count += 1;
            try std.testing.expectEqual(source.ptr, page.sheetSource(1).ptr);
            try std.testing.expectEqual(rules_pointer, page.rules.items.ptr);
            try std.testing.expectEqual(rules_count, page.rules.items.len);
            try std.testing.expectEqual(keyframes_pointer, page.keyframes.items.ptr);
            try std.testing.expectEqual(keyframes_count, page.keyframes.items.len);
            try std.testing.expectEqualDeep(narrow, page.media);
            try std.testing.expectEqualStrings("41px", value(target, "width"));
            try std.testing.expectEqualStrings("green", value(child, "color"));
            try std.testing.expect(!dom.styleTreeNeedsUpdate(&page.root));
            try std.testing.expectEqual(live_bytes, failing.allocated_bytes - failing.freed_bytes);
            continue;
        };
        try std.testing.expect(failure_count > 0);
        try std.testing.expect(dom.styleTreeNeedsUpdate(&page.root));
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        try page.restyle();
        try std.testing.expectEqualStrings(if (operation != .reselect) "73px" else "91px", value(target, "width"));
        try std.testing.expectEqualStrings(if (operation != .reselect) "purple" else "blue", value(child, "color"));
        if (operation == .replace_supports) {
            try std.testing.expectEqual(@as(usize, 1), page.keyframes.items.len);
            try std.testing.expectEqualStrings("supported", page.keyframes.items[0].name);
        }
        try std.testing.expect(!dom.styleTreeNeedsUpdate(&page.root));
        return;
    }
    return error.PublicationAllocationTrialsExceeded;
}

test "Native CSS inspection stylesheet publication preserves the styled generation at every allocation failure" {
    try publicationAllocationFailures(.replace);
}

test "CSS supports publication preserves the styled generation at every query or nested rule allocation failure" {
    try publicationAllocationFailures(.replace_supports);
}

test "CSS layer publication preserves the styled generation at every allocation failure" {
    try publicationAllocationFailures(.replace_layers);
}

test "Native CSS inspection media publication preserves the styled generation at every allocation failure" {
    try publicationAllocationFailures(.reselect);
}

test "Native CSS inspection can retry styling after a published replacement runs out of memory" {
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var page = try Page.fromHtml(failing.allocator(), responsive_html, .{ .media = narrow });
    defer page.deinit();
    page.repairParentPointers();
    const target = findById(&page.root, "target").?;
    const child = findById(&page.root, "child").?;
    try page.replaceStylesheet(1, "#target { width:73px; color:purple; }");
    const published_source = page.sheetSource(1);
    const published_rules = page.rules.items.ptr;
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, page.restyle());
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(published_source.ptr, page.sheetSource(1).ptr);
    try std.testing.expectEqual(published_rules, page.rules.items.ptr);
    try std.testing.expect(dom.styleTreeNeedsUpdate(&page.root));
    try std.testing.expectEqualStrings("41px", previousValue(target, "width"));
    try std.testing.expectEqualStrings("green", previousValue(child, "color"));

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try page.restyle();
    try std.testing.expectEqualStrings("73px", value(target, "width"));
    try std.testing.expectEqualStrings("purple", value(child, "color"));
    try std.testing.expect(!dom.styleTreeNeedsUpdate(&page.root));
}

const retry_html =
    "<html id=root><style>html {font-size:10px;color:red;--tone:green}" ++
    "#target {font-size:5px;width:11px} #child {width:2rem;background-color:var(--tone)}" ++
    "</style><main id=target>inherited<span id=child></span></main></html>";

const retry_replacement =
    "html {font-size:20px;color:purple;--tone:blue}" ++
    "html.tone {--tone:green} html.ink {color:orange} html.size {font-size:30px}" ++
    "#target {font-size:5px;width:73px} #child {width:2rem;background-color:var(--tone)}" ++
    "#child::before, #child::after {content:'';display:block;width:1rem;height:2px;background-color:var(--tone)}";

fn expectRetriedStyles(page: *Page, color: []const u8, tone: []const u8, root_size: f64) !void {
    const target = findById(&page.root, "target").?;
    const child = findById(&page.root, "child").?;
    try std.testing.expectEqualStrings("73px", value(target, "width"));
    try std.testing.expectEqual(@as(?f64, 5), lengths.parsePixel(value(target, "font-size")));
    try std.testing.expectEqual(@as(?f64, 5), lengths.parsePixel(value(child, "font-size")));
    try std.testing.expectEqualStrings(color, value(target, "color"));
    try std.testing.expectEqualStrings(color, value(child, "color"));
    try std.testing.expectEqualStrings(color, target.element.children.items[0].text.style.?.getPtr("color").?.get().*);
    try std.testing.expectEqualStrings(tone, value(child, "background-color"));
    try std.testing.expectEqual(@as(?f64, 2 * root_size), lengths.parsePixel(value(child, "width")));
    try std.testing.expectEqual(@as(usize, 0), child.element.children.items.len);
    for ([_]?*dom.Node{ child.element.generated_before, child.element.generated_after }) |generated| {
        try std.testing.expect(generated != null);
        const node = generated.?;
        try std.testing.expect(node.element.generatedPseudoActive());
        try std.testing.expectEqual(child, node.element.parent.?);
        try std.testing.expectEqualStrings("block", value(node, "display"));
        try std.testing.expectEqualStrings(color, value(node, "color"));
        try std.testing.expectEqualStrings(tone, value(node, "background-color"));
        try std.testing.expectEqual(@as(?f64, root_size), lengths.parsePixel(value(node, "width")));
        try std.testing.expectEqual(@as(?f64, 2), lengths.parsePixel(value(node, "height")));
    }
    try std.testing.expect(!dom.styleTreeNeedsUpdate(&page.root));
}

fn expectRetriedDependencies(page: *Page) !void {
    const root = findById(&page.root, "root").?;
    const changes = [_]struct { classes: []const u8, color: []const u8, tone: []const u8, root_size: f64 }{
        .{ .classes = "tone", .color = "purple", .tone = "green", .root_size = 20 },
        .{ .classes = "tone ink", .color = "orange", .tone = "green", .root_size = 20 },
        .{ .classes = "tone ink size", .color = "orange", .tone = "green", .root_size = 30 },
    };
    for (changes) |change| {
        try root.element.attributes.?.put("class", change.classes);
        // Each pass changes only one publisher. A whole-tree invalidation here
        // would hide subscriptions lost while rebuilding after allocation failure.
        dom.dirtyStyleForElement(&root.element);
        try page.restyle();
        try expectRetriedStyles(page, change.color, change.tone, change.root_size);
    }
}

test "Native CSS inspection retries every restyle allocation failure with inherited values and new generated boxes" {
    // Each trial rebuilds a fresh DOM, UA sheet and dependency graph. Keep
    // reclaiming/leak checks, but omit allocation stack capture across those
    // repeated owners so exhaustive failure coverage stays practical in Debug.
    var backing: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    defer std.testing.expect(backing.deinit() == .ok) catch @panic("restyle allocation trial leaked");
    var failures: usize = 0;
    for (0..8192) |offset| {
        // A fresh page prevents earlier retries from reserving capacity and
        // hiding later failure sites. All owners borrow this stable allocator.
        var failing = std.testing.FailingAllocator.init(backing.allocator(), .{});
        var page = try Page.fromHtml(failing.allocator(), retry_html, .{ .media = narrow });
        defer page.deinit();
        page.repairParentPointers();
        const child = findById(&page.root, "child").?;
        try std.testing.expect(child.element.generated_before == null);
        try std.testing.expect(child.element.generated_after == null);
        try page.replaceStylesheet(1, retry_replacement);
        const published_source = page.sheetSource(1);
        const published_rules = page.rules.items.ptr;
        const published_rule_count = page.rules.items.len;
        failing.fail_index = failing.alloc_index + offset;
        failing.resize_fail_index = failing.resize_index;
        failing.has_induced_failure = false;
        var failed = false;
        page.restyle() catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(published_source.ptr, page.sheetSource(1).ptr);
            try std.testing.expectEqualStrings(retry_replacement, page.sheetSource(1));
            try std.testing.expectEqual(published_rules, page.rules.items.ptr);
            try std.testing.expectEqual(published_rule_count, page.rules.items.len);
            try std.testing.expectEqualDeep(narrow, page.media);
            try std.testing.expect(dom.styleTreeNeedsUpdate(&page.root));
            // Earlier nodes may already contain new values; retry must finish
            // their descendants and pseudos without rolling publication back.
            failed = true;
            failures += 1;
        };
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        if (failed) try page.restyle();
        try expectRetriedStyles(&page, "purple", "blue", 20);
        try expectRetriedDependencies(&page);
        if (!failed) {
            try std.testing.expect(failures > 1);
            return;
        }
    }
    return error.RestyleAllocationTrialsExceeded;
}

test "Native structural recovery survives source replacement and media reselection" {
    var page = try Page.fromHtml(
        allocator,
        "<style>@media (min-width:600px) { #target {width:100px</style>" ++
            "<div id=target style='@unknown { nested:[a;{b:c}]; } color:green'></div>",
        .{ .media = wide },
    );
    defer page.deinit();
    page.repairParentPointers();
    const target = findById(&page.root, "target").?;
    try std.testing.expectEqualStrings("100px", value(target, "width"));
    try std.testing.expectEqualStrings("green", value(target, "color"));
    try page.replaceStylesheet(1, "@media (min-width:600px) { #target {width:120px");
    try page.restyle();
    try std.testing.expectEqualStrings("120px", value(target, "width"));
    try page.reselectMedia(narrow);
    try page.restyle();
    try std.testing.expectEqualStrings("auto", value(target, "width"));
    try page.reselectMedia(wide);
    try page.restyle();
    try std.testing.expectEqualStrings("120px", value(target, "width"));
}

test "inspection stylesheet media attributes compose with nested conditions on reselection" {
    var page = try Page.fromHtml(allocator, "<style>#target{color:green;width:20px}</style>" ++
        "<style media=print>#target{color:red}</style>" ++
        "<style media='(min-width:600px)'>#target{width:80px}" ++
        "@media(max-height:500px){#target{width:90px}}</style><div id=target></div>", .{ .media = narrow });
    defer page.deinit();
    page.repairParentPointers();
    const target = findById(&page.root, "target").?;
    try std.testing.expectEqual(@as(usize, 4), page.sheetCount());
    try std.testing.expectEqualStrings("green", value(target, "color"));
    try std.testing.expectEqualStrings("20px", value(target, "width"));
    try page.reselectMedia(wide);
    try page.restyle();
    try std.testing.expectEqualStrings("80px", value(target, "width"));
    try page.reselectMedia(.{ .viewport_width_css = 800, .viewport_height_css = 400 });
    try page.restyle();
    try std.testing.expectEqualStrings("90px", value(target, "width"));
    try page.replaceStylesheet(2, "#target{color:orange}");
    try page.restyle();
    try std.testing.expectEqualStrings("green", value(target, "color"));
    try page.reselectMedia(narrow);
    try page.restyle();
    try std.testing.expectEqualStrings("20px", value(target, "width"));
}
