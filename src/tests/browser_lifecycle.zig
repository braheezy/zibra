//! Browser-facing document lifecycle generation tests.

const std = @import("std");
const browser = @import("../browser/root.zig");
const document_lifecycle = @import("../browser/document_lifecycle.zig");
const tab_module = @import("../browser/tab.zig");
const tab_tasks = @import("../browser/tab_tasks.zig");

const DocumentHandle = tab_tasks.Contexts(browser.Browser).DocumentHandle;

test "navigation makes a queued lifecycle dispatch and document handle stale" {
    const allocator = std.testing.allocator;

    // This is the same scalar identity carried by LifecycleTaskContext. It
    // deliberately resolves through the Tab registry rather than retaining a
    // Frame pointer while a navigation replaces the document generation.
    var tab: tab_module.Tab = undefined;
    tab.next_document_generation = 41;
    tab.frames_by_id = std.AutoHashMap(u32, *tab_module.Frame).init(allocator);
    defer tab.frames_by_id.deinit();

    var frame: tab_module.Frame = undefined;
    frame.window_id = 9;
    frame.lifecycle = .{};
    frame.document_generation = 0;
    frame.js_render_context = .{};
    try tab.frames_by_id.put(frame.window_id, &frame);

    const first_generation = tab.activateDocumentGeneration(&frame);
    const stale_handle = DocumentHandle.fromFrame(&frame);
    try std.testing.expect(stale_handle.resolve(&tab) == &frame);

    try std.testing.expect(frame.lifecycle.enterInteractive(first_generation));
    try std.testing.expect(frame.lifecycle.markLoadEligible(first_generation));
    const stale_dispatch = frame.lifecycle.claimNextDispatch(first_generation) orelse unreachable;
    try std.testing.expectEqual(document_lifecycle.Event.dom_content_loaded, stale_dispatch.event);

    // A replacement happens after the first event was queued but before its
    // task runs. Neither its document handle nor its lifecycle claim can
    // affect the replacement document.
    const second_generation = tab.activateDocumentGeneration(&frame);
    try std.testing.expect(stale_handle.resolve(&tab) == null);
    try std.testing.expect(!frame.lifecycle.finishDispatch(stale_dispatch));
    try std.testing.expect(!frame.lifecycle.releaseDispatch(stale_dispatch));

    // The replacement follows the normal readyState progression and emits
    // each lifecycle event once, in order, despite the stale queued work.
    try std.testing.expect(frame.lifecycle.enterInteractive(second_generation));
    try std.testing.expect(frame.lifecycle.markLoadEligible(second_generation));

    const dom_content_loaded = frame.lifecycle.claimNextDispatch(second_generation) orelse unreachable;
    try std.testing.expectEqual(document_lifecycle.Event.dom_content_loaded, dom_content_loaded.event);
    try std.testing.expect(frame.lifecycle.finishDispatch(dom_content_loaded));

    const load = frame.lifecycle.claimNextDispatch(second_generation) orelse unreachable;
    try std.testing.expectEqual(document_lifecycle.Event.load, load.event);
    try std.testing.expect(frame.lifecycle.finishDispatch(load));
    try std.testing.expectEqual(document_lifecycle.Phase.complete, frame.lifecycle.phase);
    try std.testing.expect(frame.lifecycle.claimNextDispatch(second_generation) == null);
}
