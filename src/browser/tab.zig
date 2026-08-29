//! Per-tab navigation, frame ownership, and serialized page work.
//!
//! `Browser` owns each heap-allocated `Tab`. A tab must reach its final address
//! before `start`, because its task runner retains a pointer to the tab-owned
//! state. Frames own DOM, stylesheet, layout, and display-list generations.

const std = @import("std");
const browser_mod = @import("root.zig");
const frame_module = @import("frame.zig");
const forced_colors = @import("render/forced_colors.zig");
const url_module = @import("../network/url.zig");
const parser = @import("../document/parser.zig");
const dom_focus = @import("../document/focus.zig");
const Layout = @import("render/layout.zig");
const CSSParser = @import("../document/css_parser.zig");
const task = @import("../runtime/task.zig");
const sync = @import("../runtime/sync.zig");
const scroll_model = @import("scroll.zig");
const history_module = @import("history.zig");
const tab_animation = @import("tab_animation.zig");
const AccessibilitySpeech = @import("accessibility_speech.zig").Worker;
const MeasureTime = @import("../runtime/measure_time.zig").MeasureTime;
const js_module = @import("../script/js.zig");
const ProtectedField = @import("../core/protected_field.zig").ProtectedField;

const Url = url_module.Url;
const Browser = browser_mod.Browser;
const DisplayItem = browser_mod.DisplayItem;
const AccessibilitySettings = browser_mod.AccessibilitySettings;
const TaskRunner = task.TaskRunner;
const Node = parser.Node;
const Bounds = Layout.Bounds;
pub const ClickButton = frame_module.ClickButton;
/// Latest pointer location in content-viewport device pixels. The UI thread
/// copies this scalar snapshot into a Tab task; the worker adds its live root
/// scroll and zoom only when resolving after layout.
pub const HoverPosition = struct {
    device_x: i32,
    viewport_device_y: i32,
};

/// JavaScript event helpers normally acquire the Js mutex. A synchronous
/// native host callback already runs under that mutex and must use the
/// callback-only entry points instead.
const JsEventAccess = enum {
    acquire_lock,
    native_callback,
};

pub const HistoryDirection = history_module.Direction;
pub const HistoryNavigation = history_module.Navigation;
pub const HistoryMethod = history_module.Method;
pub const HistoryState = history_module.State;
pub const FrameHistorySnapshot = history_module.FrameSnapshot;
pub const HistoryEntry = history_module.Entry;
pub const PreparedHistoryNavigation = history_module.PreparedNavigation;
pub const HistoryTraversalTarget = history_module.TraversalTarget;

pub const CompositedUpdate = tab_animation.CompositedUpdate;

pub const AccessibilityNode = struct {
    role: []const u8,
    name: []const u8,
    bounds: Bounds,
    children: std.ArrayList(*AccessibilityNode),
    dom_node: ?*Node,
    live: ?LiveSetting = null,
    last_announced: ?[]const u8 = null,

    pub fn deinit(self: *AccessibilityNode, allocator: std.mem.Allocator) void {
        for (self.children.items) |child| {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self.children.deinit(allocator);
    }
};

pub const LiveSetting = enum {
    polite,
    assertive,
};

const IntervalKey = struct {
    window_id: u32,
    document_generation: u64,
    handle: u32,
};

pub const Frame = frame_module.FrameType(Tab, Browser, JsEventAccess);
const FrameHoverTarget = Frame.FrameHoverTarget;
// Tab represents a single web page
pub const Tab = @This();
// Memory allocator
allocator: std.mem.Allocator,
browser: *Browser,
accessibility: AccessibilitySettings = .{},
// Available height for tab content (window height minus chrome height)
tab_width: i32 = 0,
tab_height: i32 = 0,
// Standalone replayable joint root/iframe history owner. It contains no live
// Frame pointers; UI-thread readers observe only its atomic availability bits.
history: history_module.State,
// Owned, sentinel-terminated title from the current root document.
title: ?[:0]u8 = null,
// Dynamically allocated text strings (e.g., from JavaScript results) that need to be freed
dynamic_texts: std.ArrayList([]const u8),
// JS contexts keyed by origin string
js_contexts: std.StringHashMap(*js_module),
// Monotonic identity assigned to every installed root/child document.
next_document_generation: u64 = 1,
// Generation for tab-wide animation/render work.
js_generation: u64 = 0,
// Root frame for this tab
root_frame: ?*Frame = null,
focused_frame: ?*Frame = null,
// Modality inherited by synchronous JavaScript focus() calls. The focused
// Element stores the resulting visibility bit for selectors and paint.
focus_modality: dom_focus.Modality = .keyboard,
frames_by_id: std.AutoHashMap(u32, *Frame),
parent_window_ids: std.AutoHashMap(u32, u32),
next_window_id: u32 = 1,
// Pending asynchronous work for this tab
task_runner: TaskRunner,
// Serialized speech owns copied utterances and never borrows this Tab's tree.
accessibility_speech: AccessibilitySpeech,
async_thread_refs: usize = 0,
async_thread_mutex: sync.Mutex,
async_thread_condition: sync.Condition,
// Native cancellation registry for sleeping setInterval helpers. The key is a
// complete document identity so reused per-window JavaScript handles cannot
// cancel a timer from another frame or navigation generation.
intervals: std.AutoHashMap(IntervalKey, void),
interval_mutex: sync.Mutex,
shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
// Paint is the only coarse render flag. Style readiness is protected by each
// Frame.document, while layout dirtiness lives in the retained layout graph.
needs_paint: bool = true,
// Mouse motion publishes only scalar content-viewport coordinates. The next
// worker-side render applies live scroll/zoom after any required layout, then
// queues a second style generation if the hovered DOM path changed.
hover_position: ?HoverPosition = null,
pending_hover: bool = false,
// Author rules were filtered under an older color/viewport media environment.
media_environment_dirty: bool = false,
// Browser-session visited generation reflected by the current display list.
visited_generation: u64 = 0,
// Cross-thread activation request. Browser.setActiveTab publishes it, and the
// serialized tab worker consumes it to republish a clean retained frame list.
activation_commit_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
scroll_changed_in_tab: bool = false,
// Composited visual effect updates for the current frame
composited_updates: std.ArrayList(CompositedUpdate),
// Root of the accessibility tree
accessibility_root: ?*AccessibilityNode = null,
// Focused accessibility node
accessibility_focused: ?*AccessibilityNode = null,
// Hovered accessibility node (for screen reader hover)
accessibility_hovered: ?*AccessibilityNode = null,
// Pending polite announcements
accessibility_polite_queue: std.ArrayList(*AccessibilityNode),
// Persistent highlighted accessibility node for voice and reading interaction
accessibility_highlight: ?*AccessibilityNode = null,
// Current node in the incremental screen-reader reading traversal.
accessibility_reading: ?*AccessibilityNode = null,
// Owned strings for accessibility names/labels
accessibility_strings: std.ArrayList([]const u8),

pub fn init(allocator: std.mem.Allocator, tab_width: i32, tab_height: i32, measure: *MeasureTime) Tab {
    return Tab{
        .allocator = allocator,
        .browser = undefined,
        .accessibility = .{ .dark_palette = .{} },
        .tab_width = tab_width,
        .tab_height = tab_height,
        .history = history_module.State.init(allocator),
        .title = null,
        .focus_modality = .keyboard,
        .dynamic_texts = std.ArrayList([]const u8).empty,
        .js_contexts = std.StringHashMap(*js_module).init(allocator),
        .task_runner = TaskRunner.init(allocator, measure),
        .accessibility_speech = AccessibilitySpeech.init(std.heap.smp_allocator, measure),
        .async_thread_mutex = .init(measure.io),
        .async_thread_condition = .init(measure.io),
        .intervals = std.AutoHashMap(IntervalKey, void).init(allocator),
        .interval_mutex = .init(measure.io),
        .visited_generation = 0,
        .media_environment_dirty = false,
        .activation_commit_requested = std.atomic.Value(bool).init(false),
        .composited_updates = std.ArrayList(CompositedUpdate).empty,
        .accessibility_root = null,
        .accessibility_focused = null,
        .accessibility_hovered = null,
        .accessibility_polite_queue = std.ArrayList(*AccessibilityNode).empty,
        .accessibility_highlight = null,
        .accessibility_reading = null,
        .accessibility_strings = std.ArrayList([]const u8).empty,
        .frames_by_id = std.AutoHashMap(u32, *Frame).init(allocator),
        .parent_window_ids = std.AutoHashMap(u32, u32).init(allocator),
    };
}

pub fn logAccessibilitySettings(self: *const Tab, reason: []const u8) void {
    std.log.info(
        "Accessibility settings ({s}): zoom={d:.2} prefers_dark={} forced_colors={} reduce_motion={} screen_reader={}",
        .{
            reason,
            self.accessibility.zoom,
            self.accessibility.prefers_dark,
            self.accessibility.forced_colors,
            self.accessibility.reduce_motion,
            self.accessibility.screen_reader,
        },
    );
}

pub fn setZoom(self: *Tab, zoom: f32) void {
    if (!self.updateZoomState(zoom)) return;
    self.browser.previewActiveTabZoom(self, self.accessibility.zoom);
    self.browser.setNeedsAnimationFrame(self);
    self.browser.scheduleAnimationFrame();
}

fn updateZoomState(self: *Tab, zoom: f32) bool {
    const clamped = std.math.clamp(zoom, 0.5, 3.0);
    if (self.accessibility.zoom == clamped) return false;
    self.accessibility.zoom = clamped;

    // Mark all frame layouts as dirty for layout recalculation
    if (self.root_frame) |frame| {
        markFrameLayoutDirty(frame);
        markFrameStyleDirty(frame);
    }

    self.media_environment_dirty = true;
    self.needs_paint = true;
    return true;
}

/// Convert a native viewport width to the CSS-pixel width used by media
/// queries. Zoom enlarges each CSS pixel, so fewer of them fit in the same
/// device-space viewport.
pub fn viewportWidthInCssPixels(device_width: i32, zoom_value: f32) f64 {
    const safe_width = @max(device_width, 1);
    const safe_zoom = if (std.math.isFinite(zoom_value) and zoom_value > 0) zoom_value else 1.0;
    return @as(f64, @floatFromInt(safe_width)) / @as(f64, safe_zoom);
}

pub fn mediaEnvironmentChanged(self: *Tab) void {
    self.media_environment_dirty = true;
    if (self.root_frame) |frame| markFramePaintDirty(frame);
    self.setNeedsRender();
}

fn updateForcedColorsState(self: *Tab, enabled: bool) bool {
    if (self.accessibility.forced_colors == enabled) return false;
    self.accessibility.forced_colors = enabled;
    self.media_environment_dirty = true;
    if (self.root_frame) |frame| {
        markFrameStyleDirty(frame);
        markFramePaintDirty(frame);
    }
    self.needs_paint = true;
    return true;
}

pub fn setForcedColors(self: *Tab, enabled: bool) void {
    if (!self.updateForcedColorsState(enabled)) return;
    self.browser.setNeedsAnimationFrame(self);
    self.browser.scheduleAnimationFrame();
}

fn markFrameLayoutDirty(frame: *Frame) void {
    if (frame.document.lastValue().*) |doc| {
        doc.mark();
    }
    for (frame.children.items) |child| {
        markFrameLayoutDirty(child);
    }
}

fn markFramePaintDirty(frame: *Frame) void {
    if (frame.document.lastValue().*) |document| document.markPaintSubtree();
    for (frame.children.items) |child| markFramePaintDirty(child);
}

fn markFrameStyleDirty(frame: *Frame) void {
    frame.markDocumentStyleDirty();
    for (frame.children.items) |child| markFrameStyleDirty(child);
}

fn desiredHoverTarget(path: []const FrameHoverTarget, frame: *Frame) ?*Node {
    for (path) |entry| {
        if (entry.frame == frame) return entry.node;
    }
    return null;
}

fn applyHoverPath(frame: *Frame, path: []const FrameHoverTarget) bool {
    var changed = frame.updateHoveredNode(desiredHoverTarget(path, frame));
    for (frame.children.items) |child| {
        changed = applyHoverPath(child, path) or changed;
    }
    return changed;
}

fn frameTreeNeedsStyle(frame: *const Frame) bool {
    if (frame.styleNeeded()) return true;
    for (frame.children.items) |child| {
        if (frameTreeNeedsStyle(child)) return true;
    }
    return false;
}

fn frameTreeNeedsLayout(frame: *const Frame) bool {
    if (frame.layoutNeeded()) return true;
    for (frame.children.items) |child| {
        if (frameTreeNeedsLayout(child)) return true;
    }
    return false;
}

fn cssZoomFactorsDiffer(left: f32, right: f32) bool {
    const magnitude = @max(@max(@abs(left), @abs(right)), 1.0);
    return @abs(left - right) > magnitude * 0.00001;
}

fn refreshInheritedFrameZoom(frame: *Frame) bool {
    var changed = false;
    for (frame.children.items) |child| {
        const local_zoom = if (child.frame_element) |element|
            Layout.effectiveCssZoomForNode(element)
        else
            1.0;
        const inherited = std.math.clamp(
            frame.inherited_css_zoom * local_zoom,
            @as(f32, 0.01),
            @as(f32, 1024.0),
        );
        if (cssZoomFactorsDiffer(child.inherited_css_zoom, inherited)) {
            const old_zoom = child.inherited_css_zoom;
            const scale_from = if (old_zoom > 0.0) old_zoom else 1.0;
            child.inherited_css_zoom = inherited;
            if (child.viewport_width > 0) {
                child.viewport_width = Layout.scaleCssPixelByFactor(
                    child.viewport_width,
                    inherited / scale_from,
                );
            }
            if (child.viewport_height > 0) {
                child.viewport_height = Layout.scaleCssPixelByFactor(
                    child.viewport_height,
                    inherited / scale_from,
                );
            }
            markFrameLayoutDirty(child);
            changed = true;
        }
        changed = refreshInheritedFrameZoom(child) or changed;
    }
    return changed;
}

fn invalidateFrameTreeForViewportResize(frame: *Frame) void {
    if (frame.document.lastValue().*) |doc| {
        doc.mark();
    }
    for (frame.children.items) |child| {
        invalidateFrameTreeForViewportResize(child);
    }
}

/// Apply a native viewport change on the tab worker. The next animation frame
/// performs layout and paint using the new root-frame dimensions.
pub fn resizeViewport(self: *Tab, width: i32, height: i32) void {
    const new_width = @max(width, 1);
    const width_changed = self.tab_width != new_width;
    self.tab_width = new_width;
    self.tab_height = @max(height, 0);

    if (self.root_frame) |frame| {
        frame.viewport_width = self.tab_width;
        frame.viewport_height = self.tab_height;
        invalidateFrameTreeForViewportResize(frame);

        const clamped_scroll = self.clampScrollForFrame(frame, frame.scroll);
        if (clamped_scroll != frame.scroll) {
            frame.scroll = clamped_scroll;
            self.scroll_changed_in_tab = true;
        }
    }

    if (width_changed) {
        self.media_environment_dirty = true;
        if (self.root_frame) |frame| markFrameStyleDirty(frame);
    }
    self.needs_paint = true;
}

pub fn adjustZoom(self: *Tab, delta: f32) void {
    self.setZoom(self.accessibility.zoom + delta);
}

test "zoom changes CSS viewport width and invalidates media rules" {
    var tab: Tab = undefined;
    tab.accessibility = .{ .zoom = 1.0, .dark_palette = .{} };
    tab.root_frame = null;
    tab.needs_paint = false;
    tab.pending_hover = false;
    tab.media_environment_dirty = false;

    try std.testing.expectEqual(@as(f64, 800), viewportWidthInCssPixels(800, 1.0));
    try std.testing.expectEqual(@as(f64, 400), viewportWidthInCssPixels(800, 2.0));
    try std.testing.expect(tab.updateZoomState(2.0));
    try std.testing.expectEqual(@as(f32, 2.0), tab.accessibility.zoom);
    try std.testing.expect(tab.media_environment_dirty);
    try std.testing.expect(tab.needs_paint);
    try std.testing.expect(tab.renderPhasesNeeded());

    tab.media_environment_dirty = false;
    try std.testing.expect(!tab.updateZoomState(2.0));
    try std.testing.expect(!tab.media_environment_dirty);
}

test "iframe CSS zoom comparison ignores floating-point round trips" {
    try std.testing.expect(!cssZoomFactorsDiffer(1.5, 1.500001));
    try std.testing.expect(!cssZoomFactorsDiffer(3.0, 3.00001));
    try std.testing.expect(cssZoomFactorsDiffer(1.5, 1.6));
}

test "forced colors changes invalidate media rules and the complete render pipeline" {
    var tab: Tab = undefined;
    tab.accessibility = .{};
    tab.root_frame = null;
    tab.needs_paint = false;
    tab.pending_hover = false;
    tab.media_environment_dirty = false;

    try std.testing.expect(tab.updateForcedColorsState(true));
    try std.testing.expect(tab.accessibility.forced_colors);
    try std.testing.expect(tab.media_environment_dirty);
    try std.testing.expect(tab.needs_paint);
    try std.testing.expect(tab.renderPhasesNeeded());

    tab.media_environment_dirty = false;
    try std.testing.expect(!tab.updateForcedColorsState(true));
    try std.testing.expect(!tab.media_environment_dirty);
}

/// Start both embedded runner threads after the Tab reaches its final address.
pub fn start(self: *Tab) !void {
    try self.task_runner.start();
    errdefer self.task_runner.shutdown();
    try self.accessibility_speech.start();
}

/// Stop every producer of tab work and wait until no worker/helper can borrow
/// tab, frame, JavaScript, or Browser storage. Document destruction must happen
/// only after this boundary.
pub fn shutdown(self: *Tab) void {
    self.shutting_down.store(true, .seq_cst);
    self.interval_mutex.lock();
    self.intervals.clearRetainingCapacity();
    self.interval_mutex.unlock();

    // Joining the serialized worker first prevents an active task from
    // launching a new helper or speech request after its producer boundary.
    self.task_runner.shutdown();
    self.accessibility_speech.shutdown();
    self.waitForAsyncThreads();
    self.invalidateJsContext();
}

pub fn deinit(self: *Tab) void {
    self.shutdown();

    if (self.root_frame) |frame| {
        frame.deinit();
        self.allocator.destroy(frame);
        self.root_frame = null;
    }
    self.frames_by_id.deinit();
    self.parent_window_ids.deinit();
    self.intervals.deinit();

    var js_it = self.js_contexts.iterator();
    while (js_it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        entry.value_ptr.*.deinit(self.allocator);
    }
    self.js_contexts.deinit();

    // Clean up dynamically allocated text strings
    for (self.dynamic_texts.items) |text| {
        self.allocator.free(text);
    }
    self.dynamic_texts.deinit(self.allocator);

    if (self.title) |title| {
        self.allocator.free(title);
        self.title = null;
    }

    self.clearAccessibilityTree();
    for (self.accessibility_strings.items) |value| {
        self.allocator.free(value);
    }
    self.accessibility_strings.deinit(self.allocator);

    self.history.deinit();

    self.task_runner.deinit();
    self.accessibility_speech.deinit();
    self.accessibility_polite_queue.deinit(self.allocator);
}

pub fn clearAllowedOrigins(self: *Tab) void {
    if (self.root_frame) |frame| {
        frame.clearAllowedOrigins();
    }
}

pub fn registerFrame(self: *Tab, frame: *Frame) void {
    const id = self.next_window_id;
    self.next_window_id += 1;
    frame.window_id = id;
    self.frames_by_id.put(id, frame) catch {};
}

pub fn unregisterFrame(self: *Tab, frame: *Frame) void {
    if (self.frames_by_id.fetchRemove(frame.window_id)) |_| {}
    _ = self.parent_window_ids.fetchRemove(frame.window_id);
    if (frame.js_context) |ctx| {
        ctx.setParentWindow(frame.window_id, null);
    }
}

fn originKey(self: *Tab, url: *Url) ![]const u8 {
    if (std.mem.eql(u8, url.*.scheme, "file")) {
        return try self.allocator.dupe(u8, "file://");
    }
    if (std.mem.eql(u8, url.*.scheme, "about") or std.mem.eql(u8, url.*.scheme, "data")) {
        return try std.fmt.allocPrint(self.allocator, "{s}:", .{url.*.scheme});
    }
    const host = url.*.host orelse "";
    return try std.fmt.allocPrint(self.allocator, "{s}://{s}:{d}", .{ url.*.scheme, host, url.*.port });
}

pub fn getJs(self: *Tab, url: *Url) !*js_module {
    const key = try self.originKey(url);
    var key_owned = true;
    defer if (key_owned) self.allocator.free(key);

    if (self.js_contexts.get(key)) |ctx| {
        return ctx;
    }

    const ctx = try js_module.init(
        self.allocator,
        self.task_runner.measure.io,
        self.task_runner.measure.environ,
    );
    errdefer ctx.deinit(self.allocator);
    ctx.setInterruptHandler(self, interruptJavaScriptOnShutdown);
    try self.js_contexts.put(key, ctx);
    key_owned = false;
    return ctx;
}

fn interruptJavaScriptOnShutdown(context: ?*anyopaque) bool {
    const raw_context = context orelse return false;
    const unaligned: *align(1) Tab = @ptrCast(raw_context);
    const tab: *Tab = @alignCast(unaligned);
    return tab.isShuttingDown();
}

pub fn activateDocumentGeneration(self: *Tab, frame: *Frame) u64 {
    const generation = self.next_document_generation;
    self.next_document_generation +%= 1;
    if (self.next_document_generation == 0) self.next_document_generation = 1;
    frame.document_generation = generation;
    frame.js_render_context.setGeneration(generation);
    return generation;
}

pub fn frameForWindowId(self: *Tab, window_id: u32) ?*Frame {
    return self.frames_by_id.get(window_id);
}

pub fn setParentWindow(self: *Tab, child_window_id: u32, parent_window_id: ?u32) void {
    if (parent_window_id) |parent_id| {
        self.parent_window_ids.put(child_window_id, parent_id) catch {};
    } else {
        _ = self.parent_window_ids.fetchRemove(child_window_id);
    }
}

pub fn invalidateJsContext(self: *Tab) void {
    self.js_generation +%= 1;
    self.parent_window_ids.clearRetainingCapacity();
    var it = self.frames_by_id.valueIterator();
    while (it.next()) |frame_ptr| {
        self.clearIntervalsForDocument(
            frame_ptr.*.window_id,
            frame_ptr.*.document_generation,
        );
        frame_ptr.*.document_generation = 0;
        frame_ptr.*.js_render_context.setGeneration(0);
        frame_ptr.*.js_render_context.setPointers(null, null, null, 0);
        frame_ptr.*.js_render_context_initialized = false;
        if (frame_ptr.*.js_context) |ctx| {
            ctx.setNodes(frame_ptr.*.window_id, null);
        }
    }
}

pub fn retainAsyncThread(self: *Tab) void {
    self.async_thread_mutex.lock();
    self.async_thread_refs += 1;
    self.async_thread_mutex.unlock();
}

pub fn ensureInterval(
    self: *Tab,
    window_id: u32,
    document_generation: u64,
    handle: u32,
) !void {
    if (self.isShuttingDown()) return error.TabShuttingDown;
    self.interval_mutex.lock();
    defer self.interval_mutex.unlock();
    if (self.isShuttingDown()) return error.TabShuttingDown;
    try self.intervals.put(.{
        .window_id = window_id,
        .document_generation = document_generation,
        .handle = handle,
    }, {});
}

pub fn clearInterval(
    self: *Tab,
    window_id: u32,
    document_generation: u64,
    handle: u32,
) void {
    self.interval_mutex.lock();
    defer self.interval_mutex.unlock();
    _ = self.intervals.remove(.{
        .window_id = window_id,
        .document_generation = document_generation,
        .handle = handle,
    });
}

pub fn intervalIsActive(
    self: *Tab,
    window_id: u32,
    document_generation: u64,
    handle: u32,
) bool {
    self.interval_mutex.lock();
    defer self.interval_mutex.unlock();
    return self.intervals.contains(.{
        .window_id = window_id,
        .document_generation = document_generation,
        .handle = handle,
    });
}

pub fn clearIntervalsForDocument(
    self: *Tab,
    window_id: u32,
    document_generation: u64,
) void {
    self.interval_mutex.lock();
    defer self.interval_mutex.unlock();

    while (true) {
        var found: ?IntervalKey = null;
        var it = self.intervals.keyIterator();
        while (it.next()) |key| {
            if (key.window_id == window_id and
                key.document_generation == document_generation)
            {
                found = key.*;
                break;
            }
        }
        if (found) |key| {
            _ = self.intervals.remove(key);
        } else {
            break;
        }
    }
}

pub fn releaseAsyncThread(self: *Tab) void {
    self.async_thread_mutex.lock();
    std.debug.assert(self.async_thread_refs > 0);
    self.async_thread_refs -= 1;
    if (self.async_thread_refs == 0) self.async_thread_condition.broadcast();
    self.async_thread_mutex.unlock();
}

/// Return whether both serialized workers and all detached helpers are idle.
/// Screenshot mode uses this to keep shared SDL_ttf state single-threaded.
pub fn isQuiescent(self: *Tab) bool {
    if (!self.task_runner.isIdle()) return false;
    if (!self.accessibility_speech.isIdle()) return false;
    self.async_thread_mutex.lock();
    defer self.async_thread_mutex.unlock();
    return self.async_thread_refs == 0;
}

fn waitForAsyncThreads(self: *Tab) void {
    self.async_thread_mutex.lock();
    while (self.async_thread_refs != 0) {
        self.async_thread_condition.wait(&self.async_thread_mutex);
    }
    self.async_thread_mutex.unlock();
}

pub fn isShuttingDown(self: *const Tab) bool {
    return self.shutting_down.load(.seq_cst);
}

pub fn canGoBack(self: *const Tab) bool {
    return self.history.canGoBack();
}

pub fn canGoForward(self: *const Tab) bool {
    return self.history.canGoForward();
}

/// Return an owned child-index path from the root browsing context. Raw Frame
/// pointers cannot enter history because root and parent-frame navigation
/// destroys those allocations before a later traversal.
pub fn historyFramePath(self: *const Tab, target: *const Frame) ![]usize {
    var reversed = std.ArrayList(usize).empty;
    defer reversed.deinit(self.allocator);

    var current = target;
    while (current.parent) |parent| {
        var child_index: ?usize = null;
        for (parent.children.items, 0..) |child, i| {
            if (child == current) {
                child_index = i;
                break;
            }
        }
        try reversed.append(self.allocator, child_index orelse return error.DetachedHistoryFrame);
        current = parent;
    }
    if (self.root_frame == null or self.root_frame.? != current) {
        return error.DetachedHistoryFrame;
    }

    const path = try self.allocator.alloc(usize, reversed.items.len);
    for (reversed.items, 0..) |index, i| {
        path[path.len - i - 1] = index;
    }
    return path;
}

fn captureFrameHistorySnapshot(self: *Tab, frame: *Frame) !*FrameHistorySnapshot {
    const current_url = frame.current_url orelse return error.HistoryFrameMissingUrl;
    const payload = try self.currentHistoryPayloadForFrame(frame);

    var cloned_url = try current_url.*.clone(self.allocator);
    var cloned_url_owned = true;
    errdefer if (cloned_url_owned) cloned_url.free(self.allocator);

    const url_ptr = try self.allocator.create(Url);
    var url_ptr_owned = true;
    errdefer if (url_ptr_owned) self.allocator.destroy(url_ptr);
    url_ptr.* = cloned_url;
    cloned_url_owned = false;
    var url_contents_owned = true;
    errdefer if (url_contents_owned) url_ptr.*.free(self.allocator);

    const body_copy = if (payload) |body| try self.allocator.dupe(u8, body) else null;
    var body_owned = body_copy != null;
    errdefer if (body_owned) self.allocator.free(body_copy.?);

    const snapshot = try self.allocator.create(FrameHistorySnapshot);
    var snapshot_allocation_owned = true;
    errdefer if (snapshot_allocation_owned) self.allocator.destroy(snapshot);
    snapshot.* = .{
        .url = url_ptr,
        .method = if (payload == null) .get else .post,
        .post_body = body_copy,
        .children = .empty,
    };
    url_ptr_owned = false;
    url_contents_owned = false;
    body_owned = false;
    snapshot_allocation_owned = false;
    errdefer snapshot.deinit(self.allocator);

    try snapshot.children.ensureTotalCapacity(self.allocator, frame.children.items.len);
    for (frame.children.items) |child_frame| {
        const child = try self.captureFrameHistorySnapshot(child_frame);
        snapshot.children.appendAssumeCapacity(child);
    }
    return snapshot;
}

fn prepareHistoryNavigationForPath(
    self: *Tab,
    url: *const Url,
    payload: ?[]const u8,
    target_path: []const usize,
    replaces_document: bool,
    previous: ?*FrameHistorySnapshot,
) !PreparedHistoryNavigation {
    try self.history.reserveEntry();
    return .{ .entry = try HistoryEntry.prepare(
        self.allocator,
        url,
        payload,
        target_path,
        replaces_document,
        previous,
    ) };
}

/// Reserve and copy every fallible part of a history mutation before a caller
/// retires the currently installed document. A null target is valid only for
/// the initial root navigation, whose path is empty.
pub fn prepareHistoryNavigation(
    self: *Tab,
    target: ?*Frame,
    url: *const Url,
    payload: ?[]const u8,
    replaces_document: bool,
) !PreparedHistoryNavigation {
    const path = if (target) |frame|
        try self.historyFramePath(frame)
    else
        try self.allocator.alloc(usize, 0);
    defer self.allocator.free(path);
    const previous = if (target) |frame|
        try self.captureFrameHistorySnapshot(frame)
    else
        null;
    var previous_owned = previous != null;
    errdefer if (previous_owned) previous.?.deinit(self.allocator);
    const prepared = try self.prepareHistoryNavigationForPath(
        url,
        payload,
        path,
        replaces_document,
        previous,
    );
    previous_owned = false;
    return prepared;
}

/// Transfer a fully prepared entry into history without allocation.
pub fn commitPreparedHistoryNavigation(
    self: *Tab,
    prepared: *PreparedHistoryNavigation,
) void {
    self.history.commit(prepared);
}

/// Testable/direct entry point for recording a completed navigation whose
/// target path is already known. History owns independent URL, body, and path
/// copies; the caller retains every argument.
pub fn commitHistoryNavigationForPath(
    self: *Tab,
    url: *const Url,
    payload: ?[]const u8,
    target_path: []const usize,
    replaces_document: bool,
) !void {
    var prepared = try self.prepareHistoryNavigationForPath(
        url,
        payload,
        target_path,
        replaces_document,
        null,
    );
    defer prepared.deinit(self.allocator);
    self.commitPreparedHistoryNavigation(&prepared);
}

pub fn historyTraversalTarget(
    self: *const Tab,
    direction: HistoryDirection,
) ?HistoryTraversalTarget {
    return self.history.traversalTarget(direction);
}

pub fn requestHistoryTraversal(self: *Tab, b: *Browser, direction: HistoryDirection) void {
    b.scheduleTabHistoryTraversal(self, direction);
}

/// Runs on the serialized tab worker.
pub fn traverseHistory(self: *Tab, b: *Browser, direction: HistoryDirection) !void {
    const target = self.historyTraversalTarget(direction) orelse return;
    if (target.method == .post) {
        b.requestPostResubmission(self, target.index, target.generation);
        return;
    }
    try self.loadHistoryEntry(b, target.index, target.generation);
}

/// Continue a POST traversal only if the confirmed entry is still the same
/// history generation that was presented to the user.
pub fn resubmitHistoryEntry(
    self: *Tab,
    b: *Browser,
    target: usize,
    generation: u64,
) !void {
    if (generation != self.history.generation or !self.history.isAdjacentTarget(target)) return;
    const current = self.history.index orelse return;
    const direction: HistoryDirection = if (target < current) .back else .forward;
    const planned = self.historyTraversalTarget(direction) orelse return;
    if (planned.index != target or planned.method != .post) return;
    try self.loadHistoryEntry(b, target, generation);
}

fn frameAtHistoryPath(self: *Tab, path: []const usize) ?*Frame {
    var frame = self.root_frame orelse return null;
    for (path) |child_index| {
        if (child_index >= frame.children.items.len) return null;
        frame = frame.children.items[child_index];
    }
    return frame;
}

/// Resolve the request body that produced a frame's current document. An
/// ancestor replacement resets every descendant to its authored initial GET,
/// so an older exact-path POST must not leak through that boundary.
pub fn currentHistoryPayloadForFrame(self: *Tab, frame: *Frame) !?[]const u8 {
    const current_index = self.history.index orelse return null;
    const path = try self.historyFramePath(frame);
    defer self.allocator.free(path);

    var cursor = current_index + 1;
    while (cursor > 0) {
        cursor -= 1;
        const entry = self.history.entries.items[cursor];
        if (history_module.pathsEqual(entry.target_path, path)) return entry.post_body;
        if (entry.replaces_document and history_module.pathIsPrefix(entry.target_path, path)) return null;
    }
    return null;
}

fn replayHistoryRequest(
    self: *Tab,
    b: *Browser,
    frame: *Frame,
    url: *const Url,
    payload: ?[]const u8,
) !*Frame {
    if (frame.parent == null) {
        const cloned_url = try url.*.clone(self.allocator);
        const url_ptr = self.allocator.create(Url) catch |err| {
            cloned_url.free(self.allocator);
            return err;
        };
        url_ptr.* = cloned_url;
        var url_owned = true;
        defer if (url_owned) {
            url_ptr.*.free(self.allocator);
            self.allocator.destroy(url_ptr);
        };

        try b.loadInTab(self, url_ptr, payload, .replay);
        url_owned = false;
        return self.root_frame orelse error.HistoryRootFrameMissing;
    }

    var cloned_url = try url.*.clone(self.allocator);
    defer cloned_url.free(self.allocator);
    try b.loadInFrame(frame, &cloned_url, payload, .replay);
    return frame;
}

fn replaySameDocumentHistoryRequest(
    self: *Tab,
    b: *Browser,
    frame: *Frame,
    url: *const Url,
) !void {
    const cloned_url = try url.*.clone(self.allocator);
    try frame.navigateSameDocumentHistory(b, cloned_url, .replay);
}

fn restoreFrameHistorySnapshot(
    self: *Tab,
    b: *Browser,
    frame: *Frame,
    snapshot: *const FrameHistorySnapshot,
) !void {
    const live_frame = try self.replayHistoryRequest(
        b,
        frame,
        snapshot.url,
        snapshot.post_body,
    );
    for (snapshot.children.items, 0..) |child_snapshot, child_index| {
        if (child_index >= live_frame.children.items.len) {
            return error.HistoryFramePathMissing;
        }
        try self.restoreFrameHistorySnapshot(
            b,
            live_frame.children.items[child_index],
            child_snapshot,
        );
    }
}

/// Publish a successfully reconstructed adjacent history state. Keeping this
/// mutation separate from network/document replay makes the old index remain
/// authoritative until every root and child-frame action has completed.
pub fn finishHistoryTraversal(self: *Tab, target: usize, generation: u64) bool {
    return self.history.finishTraversal(target, generation);
}

fn loadHistoryEntry(
    self: *Tab,
    b: *Browser,
    target: usize,
    generation: u64,
) !void {
    if (generation != self.history.generation or !self.history.isAdjacentTarget(target)) return;
    const current = self.history.index orelse return;
    const is_back = target < current;
    const entry = self.history.entries.items[if (is_back) current else target];
    const frame = self.frameAtHistoryPath(entry.target_path) orelse
        return error.HistoryFramePathMissing;

    if (is_back) {
        const previous = entry.previous orelse return error.HistorySnapshotMissing;
        if (entry.replaces_document) {
            try self.restoreFrameHistorySnapshot(b, frame, previous);
        } else {
            try self.replaySameDocumentHistoryRequest(b, frame, previous.url);
        }
    } else if (entry.replaces_document) {
        _ = try self.replayHistoryRequest(b, frame, entry.url, entry.post_body);
    } else {
        try self.replaySameDocumentHistoryRequest(b, frame, entry.url);
    }

    _ = self.finishHistoryTraversal(target, generation);
}

pub fn setNeedsRender(self: *Tab) void {
    if (self.root_frame) |frame| markFrameStyleDirty(frame);
    self.needs_paint = true;
    self.browser.setNeedsAnimationFrame(self);
    self.browser.scheduleAnimationFrame();
}

/// Synchronous structural-mutation boundary. The caller marks the mutating
/// element dirty, then invokes this before a child array can move or any child
/// can be destroyed. Scheduling is published before control returns, so an
/// allocation failure in the mutation still rebuilds the retired state.
pub fn prepareForDomMutation(self: *Tab, b: *Browser, frame: *Frame, mutation_root: *Node) void {
    std.debug.assert(frame.tab == self);

    self.needs_paint = true;
    self.pending_hover = true;
    frame.resources_dirty = true;
    frame.markDocumentStyleDirty();

    frame.retireDomMutationBorrows(mutation_root);
    self.composited_updates.clearRetainingCapacity();
    self.clearAccessibilityTree();
    b.retireRenderStateForTab(self);

    // Structural mutation can invalidate arbitrary raw style/layout
    // subscriptions and Node addresses inside the retained tree. Once every
    // display consumer is retired, destroy this frame's complete layout while
    // the old DOM is still alive; the next full render builds a fresh graph.
    frame.destroyDocumentLayout();
    frame.markDocumentStyleDirty();
    // Descendant frames own independent DOM/layout trees but still need dirty
    // propagation when an ancestor iframe element changes.
    markFrameLayoutDirty(frame);

    b.setNeedsAnimationFrame(self);
    b.scheduleAnimationFrame();
}

/// Narrow structural boundary for a layout-verified child insertion. Display, hit,
/// accessibility, compositor, and iframe borrows are retired exactly as for a
/// general mutation, but the installed style dependency graph and
/// DocumentLayout stay alive. The JavaScript host synchronously rebinds every
/// retained direct-child Node pointer after the child array reaches its final
/// address and before completion callbacks or script resume.
pub fn prepareForDomInsert(self: *Tab, b: *Browser, frame: *Frame, mutation_root: *Node) void {
    std.debug.assert(frame.tab == self);

    // The compatibility check that selected this path requires a live layout
    // owner. Mark it once more at the ownership boundary so callers cannot
    // accidentally preserve a clean layout-child cache after DOM growth.
    switch (mutation_root.*) {
        .element => |*element| {
            const layout_ptr = element.layout_ptr orelse
                @panic("retained insertion missing layout owner");
            const mark = element.layout_mark orelse
                @panic("retained insertion missing layout marker");
            mark(layout_ptr);
        },
        .text => @panic("retained insertion requires an Element"),
    }

    self.needs_paint = true;
    self.pending_hover = true;
    frame.resources_dirty = true;
    frame.markDocumentStyleDirty();

    frame.retireDomMutationBorrows(mutation_root);
    self.composited_updates.clearRetainingCapacity();
    self.clearAccessibilityTree();
    b.retireRenderStateForTab(self);

    b.setNeedsAnimationFrame(self);
    b.scheduleAnimationFrame();
}

/// Synchronous post-mutation half of the structural boundary. Parent pointers
/// and JavaScript node handles have already been repaired, so stable iframe
/// window IDs can rebind surviving Frame pointers. Removed child contexts are
/// quiesced here, before JavaScript can enqueue work against them; network
/// loading for marker-free new iframes remains deferred to resource refresh.
pub fn completeDomMutation(self: *Tab, frame: *Frame) void {
    std.debug.assert(frame.tab == self);
    frame.reconcileAttachedChildFrames();
}

pub fn setNeedsPaint(self: *Tab) void {
    self.needs_paint = true;
    self.browser.setNeedsAnimationFrame(self);
    self.browser.scheduleAnimationFrame();
}

fn refreshFocusState(self: *Tab) !void {
    const frame = self.focused_frame orelse self.root_frame orelse return;
    var frames = std.ArrayList(*Frame).empty;
    defer frames.deinit(self.allocator);
    try self.collectFramesPostOrder(frame, &frames);

    for (frames.items) |target| {
        if (target.focus == null or target.current_node == null) continue;
        var node_list = std.ArrayList(*Node).empty;
        defer node_list.deinit(self.allocator);

        var root_mut = target.current_node.?;
        try parser.treeToList(self.allocator, &root_mut, &node_list);

        var found = false;
        for (node_list.items) |node_ptr| {
            if (node_ptr == target.focus.?) {
                found = true;
                switch (node_ptr.*) {
                    .element => |*e| {
                        e.is_focused = true;
                        parser.dirtyStyleForElement(e);
                    },
                    else => {},
                }
                break;
            }
        }

        if (!found) {
            if (target.focus) |focus_node| {
                switch (focus_node.*) {
                    .element => |*e| {
                        e.is_focused = false;
                        e.is_focus_visible = false;
                        parser.dirtyStyleForElement(e);
                    },
                    else => {},
                }
            }
            target.focus = null;
        }
    }
}

pub fn clampScrollForFrame(self: *const Tab, frame: *const Frame, scroll: i32) i32 {
    const zoom = if (self.accessibility.zoom > 0) self.accessibility.zoom else 1.0;
    const viewport_height = if (frame.viewport_height > 0) frame.viewport_height else self.tab_height;
    return clampScrollOffset(scroll, frame.content_height, viewport_height, zoom);
}

/// Clamp a CSS-pixel scroll offset to the document range visible at `zoom`.
pub fn clampScrollOffset(scroll: i32, content_height: i32, viewport_height: i32, zoom: f32) i32 {
    return scroll_model.clampOffset(content_height, viewport_height, scroll, zoom);
}

fn collectFramesPostOrder(self: *Tab, frame: *Frame, out: *std.ArrayList(*Frame)) !void {
    for (frame.children.items) |child| {
        try self.collectFramesPostOrder(child, out);
    }
    try out.append(self.allocator, frame);
}

const IframeComposeError = error{OutOfMemory};

/// Build the browser-facing snapshot without consuming any frame's
/// authoritative, uncomposed hit-test list. The returned list owns its nested
/// containers and carries no layout/DOM provenance.
pub fn composeDisplayList(self: *Tab, root: *Frame) IframeComposeError!?[]DisplayItem {
    const root_list = root.display_list orelse return null;

    var combined = std.ArrayList(DisplayItem).empty;
    defer combined.deinit(self.allocator);
    errdefer DisplayItem.freeItems(self.allocator, combined.items);

    try self.replaceIframesInList(root, root_list, &combined);
    const composed = try combined.toOwnedSlice(self.allocator);
    DisplayItem.clearSources(composed);
    return composed;
}

fn replaceIframesInList(
    self: *Tab,
    root: *Frame,
    items: []DisplayItem,
    out: *std.ArrayList(DisplayItem),
) IframeComposeError!void {
    for (items) |item| {
        switch (item) {
            .cached_subtree => |cached| {
                try self.replaceIframesInList(root, cached.list.items, out);
            },
            .iframe => |iframe_item| {
                try self.appendIframeContent(root, .{ .iframe = iframe_item }, out);
            },
            .blend => |blend_item| {
                var children = std.ArrayList(DisplayItem).empty;
                defer children.deinit(self.allocator);
                errdefer DisplayItem.freeItems(self.allocator, children.items);
                try self.replaceIframesInList(root, blend_item.children, &children);

                const child_slice = try children.toOwnedSlice(self.allocator);
                var child_slice_owned = true;
                errdefer if (child_slice_owned) DisplayItem.freeList(self.allocator, child_slice);

                const mode_copy = if (blend_item.blend_mode) |mode|
                    try self.allocator.dupe(u8, mode)
                else
                    null;
                var mode_copy_owned = mode_copy != null;
                errdefer if (mode_copy_owned) self.allocator.free(mode_copy.?);

                try out.append(self.allocator, .{
                    .blend = .{
                        .opacity = blend_item.opacity,
                        .blend_mode = mode_copy,
                        .blur_radius = blend_item.blur_radius,
                        .hit_clip = blend_item.hit_clip,
                        .children = child_slice,
                        .node = blend_item.node,
                        .parent = null,
                        .needs_compositing = blend_item.needs_compositing,
                        .compositor_id = blend_item.compositor_id,
                        .source = null,
                    },
                });
                child_slice_owned = false;
                mode_copy_owned = false;
            },
            .transform => |transform_item| {
                var children = std.ArrayList(DisplayItem).empty;
                defer children.deinit(self.allocator);
                errdefer DisplayItem.freeItems(self.allocator, children.items);
                try self.replaceIframesInList(root, transform_item.children, &children);

                const child_slice = try children.toOwnedSlice(self.allocator);
                var child_slice_owned = true;
                errdefer if (child_slice_owned) DisplayItem.freeList(self.allocator, child_slice);

                try out.append(self.allocator, .{
                    .transform = .{
                        .translate_x = transform_item.translate_x,
                        .translate_y = transform_item.translate_y,
                        .scroll_attachment = transform_item.scroll_attachment,
                        .children = child_slice,
                        .node = transform_item.node,
                        .composited = transform_item.composited,
                        .animation_active = transform_item.animation_active,
                        .compositor_id = transform_item.compositor_id,
                        .source = null,
                    },
                });
                child_slice_owned = false;
            },
            .canvas => |canvas_item| {
                const pixels = try self.allocator.dupe(u8, canvas_item.pixels);
                var pixels_owned = true;
                errdefer if (pixels_owned) self.allocator.free(pixels);
                var copy = canvas_item;
                copy.pixels = pixels;
                copy.owns_pixels = true;
                copy.source = null;
                try out.append(self.allocator, .{ .canvas = copy });
                pixels_owned = false;
            },
            else => try out.append(self.allocator, item),
        }
    }
}

fn appendIframeContent(
    self: *Tab,
    root: *Frame,
    iframe_item: DisplayItem,
    out: *std.ArrayList(DisplayItem),
) IframeComposeError!void {
    const border_color = forced_colors.map(
        .{ .r = 0x33, .g = 0x33, .b = 0x33, .a = 0xff },
        .border,
        self.accessibility.forced_colors,
    );
    const bg_color = forced_colors.map(
        .{ .r = 0xf2, .g = 0xf2, .b = 0xf2, .a = 0xff },
        .background,
        self.accessibility.forced_colors,
    );

    const iframe_data = iframe_item.iframe;
    try out.append(self.allocator, .{
        .rect = .{
            .x1 = iframe_data.rect.left,
            .y1 = iframe_data.rect.top,
            .x2 = iframe_data.rect.right,
            .y2 = iframe_data.rect.bottom,
            .color = bg_color,
        },
    });

    const child_frame = root.findFrameByElement(iframe_data.node);
    if (child_frame == null or child_frame.?.display_list == null) {
        try out.append(self.allocator, .{
            .outline = .{
                .rect = iframe_data.rect,
                .color = border_color,
                .thickness = 1,
            },
        });
        return;
    }

    const child_width = iframe_data.rect.right - iframe_data.rect.left;
    const child_height = iframe_data.rect.bottom - iframe_data.rect.top;
    if (cssZoomFactorsDiffer(child_frame.?.inherited_css_zoom, iframe_data.css_zoom)) {
        child_frame.?.inherited_css_zoom = iframe_data.css_zoom;
        markFrameLayoutDirty(child_frame.?);
        self.browser.setNeedsAnimationFrame(self);
        self.browser.scheduleAnimationFrame();
    }
    const viewport_change = child_frame.?.updateViewportFromParent(child_width, child_height);
    if (viewport_change.width_changed) {
        // Reparse retained child stylesheets under the iframe's new width.
        self.mediaEnvironmentChanged();
    } else if (viewport_change.height_changed) {
        // Height is not a supported media feature yet, but child layout and
        // scroll geometry still consume the containing viewport.
        self.needs_paint = true;
        self.browser.setNeedsAnimationFrame(self);
        self.browser.scheduleAnimationFrame();
    }

    const child_list = child_frame.?.display_list.?;

    var expanded_children = std.ArrayList(DisplayItem).empty;
    defer expanded_children.deinit(self.allocator);
    errdefer DisplayItem.freeItems(self.allocator, expanded_children.items);
    try self.replaceIframesInList(root, child_list, &expanded_children);
    const expanded_slice = try expanded_children.toOwnedSlice(self.allocator);
    var expanded_slice_owned = true;
    errdefer if (expanded_slice_owned) DisplayItem.freeList(self.allocator, expanded_slice);

    const transform_item = DisplayItem{
        .transform = .{
            .translate_x = iframe_data.rect.left,
            .translate_y = iframe_data.rect.top -| child_frame.?.scroll,
            .children = expanded_slice,
            .node = null,
        },
    };
    const mask_item = DisplayItem{
        .rect = .{
            .x1 = iframe_data.rect.left,
            .y1 = iframe_data.rect.top,
            .x2 = iframe_data.rect.right,
            .y2 = iframe_data.rect.bottom,
            .color = browser_mod.Color{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff },
        },
    };
    const clip_children = try self.allocator.alloc(DisplayItem, 2);
    clip_children[0] = transform_item;
    clip_children[1] = mask_item;
    expanded_slice_owned = false;
    var clip_children_owned = true;
    errdefer if (clip_children_owned) DisplayItem.freeList(self.allocator, clip_children);
    const clip_blend_mode = try self.allocator.alloc(u8, 6);
    @memcpy(clip_blend_mode, "dst_in");
    var clip_blend_mode_owned = true;
    errdefer if (clip_blend_mode_owned) self.allocator.free(clip_blend_mode);
    try out.append(self.allocator, .{
        .blend = .{
            .opacity = 1.0,
            .blend_mode = clip_blend_mode,
            .children = clip_children,
            .node = null,
            .needs_compositing = true,
        },
    });
    clip_children_owned = false;
    clip_blend_mode_owned = false;

    try out.append(self.allocator, .{
        .outline = .{
            .rect = iframe_data.rect,
            .color = border_color,
            .thickness = 1,
        },
    });
}

test "iframe composition replacement preserves transform scroll attachment" {
    const allocator = std.testing.allocator;
    var tab: Tab = undefined;
    tab.allocator = allocator;
    var root: Frame = undefined;

    var children = [_]DisplayItem{.{ .rect = .{
        .x1 = 0,
        .y1 = 0,
        .x2 = 10,
        .y2 = 10,
        .color = .{ .r = 1, .g = 2, .b = 3 },
    } }};
    var source = [_]DisplayItem{.{ .transform = .{
        .translate_x = 7,
        .translate_y = 9,
        .scroll_attachment = .frame_viewport,
        .children = &children,
    } }};
    var output = std.ArrayList(DisplayItem).empty;
    defer {
        DisplayItem.freeItems(allocator, output.items);
        output.deinit(allocator);
    }

    try tab.replaceIframesInList(&root, source[0..], &output);
    try std.testing.expectEqual(@as(usize, 1), output.items.len);
    try std.testing.expectEqual(
        @import("render/display_list.zig").ScrollAttachment.frame_viewport,
        output.items[0].transform.scroll_attachment,
    );
}

// Re-render the page without reloading (style, layout, paint)
pub fn visitedLinksNeedRefresh(self: *const Tab, session_generation: u64) bool {
    return self.visited_generation != session_generation;
}

/// RAF dirty gate. Session generation must participate before the frame
/// decides whether a full render is needed; Tab.render's later check alone is
/// too late for an otherwise-clean tab.
pub fn animationFrameNeedsFullRender(self: *Tab, b: *Browser) bool {
    const visited_generation = b.session_state.currentVisitedGeneration();
    if (self.visitedLinksNeedRefresh(visited_generation)) self.needs_paint = true;
    return self.renderPhasesNeeded();
}

pub fn renderPhasesNeeded(self: *const Tab) bool {
    if (self.pending_hover) return true;
    if (self.needs_paint) return true;
    const frame = self.root_frame orelse return false;
    return frameTreeNeedsStyle(frame) or frameTreeNeedsLayout(frame);
}

fn sameHoverPosition(left: ?HoverPosition, right: ?HoverPosition) bool {
    if (left == null or right == null) return left == null and right == null;
    return left.?.device_x == right.?.device_x and
        left.?.viewport_device_y == right.?.viewport_device_y;
}

/// Worker-side half of mouse motion. Publishing a point never reads layout;
/// `render` consumes it only after completing any pending geometry work.
pub fn hover(self: *Tab, position: ?HoverPosition) void {
    if (sameHoverPosition(self.hover_position, position) and !self.pending_hover) return;
    self.hover_position = position;
    self.pending_hover = true;
    self.browser.setNeedsAnimationFrame(self);
    self.browser.scheduleAnimationFrame();
}

fn resolveHoverAfterLayout(self: *Tab, refresh: bool) !bool {
    if (!self.pending_hover and !refresh) return false;

    var path = std.ArrayList(FrameHoverTarget).empty;
    defer path.deinit(self.allocator);

    if (self.root_frame) |frame| {
        if (self.hover_position) |position| {
            const zoom = self.accessibility.zoom;
            const page_device_y = position.viewport_device_y +|
                DisplayItem.scaleLayoutPx(frame.scroll, zoom);
            try frame.collectHoverPathDevice(
                position.device_x,
                page_device_y,
                zoom,
                &path,
            );
        }
    }

    const changed = if (self.root_frame) |frame|
        applyHoverPath(frame, path.items)
    else
        false;

    const accessibility_hit = if (self.accessibility.screen_reader)
        if (self.hover_position) |position|
            if (self.root_frame) |frame| blk: {
                const zoom = self.accessibility.zoom;
                const page_device_y = position.viewport_device_y +|
                    DisplayItem.scaleLayoutPx(frame.scroll, zoom);
                break :blk self.accessibilityHitTest(
                    DisplayItem.deviceToLayoutPx(position.device_x, zoom),
                    DisplayItem.deviceToLayoutPx(page_device_y, zoom),
                );
            } else null
        else
            null
    else
        null;
    self.updateAccessibilityHover(accessibility_hit);
    self.pending_hover = false;
    return changed;
}

pub fn requestActivationCommit(self: *Tab) void {
    self.activation_commit_requested.store(true, .release);
}

pub fn render(self: *Tab, b: *Browser) !void {
    const visited_generation = b.session_state.currentVisitedGeneration();
    if (self.visitedLinksNeedRefresh(visited_generation)) self.needs_paint = true;

    if (!self.renderPhasesNeeded()) return;

    const profiling = b.profiling_enabled;
    const render_start = if (profiling) std.Io.Clock.awake.now(b.io).nanoseconds else 0;
    var style_ns: u64 = 0;
    var layout_ns: u64 = 0;

    const trace_render = b.measure.begin("render");
    defer if (trace_render) b.measure.end("render");

    const refresh_hover_after_render = self.pending_hover or self.hover_position != null;
    const frame = self.root_frame orelse {
        _ = try self.resolveHoverAfterLayout(refresh_hover_after_render);
        self.needs_paint = false;
        self.visited_generation = visited_generation;
        return;
    };
    if (frame.current_node == null) {
        if (frame.styleNeeded()) frame.publishStyledDocument();
        _ = try self.resolveHoverAfterLayout(refresh_hover_after_render);
        self.needs_paint = false;
        self.visited_generation = visited_generation;
        return;
    }

    // Consume inherited iframe zoom from the preceding computed-style
    // generation before deciding which width-dependent media rules to parse.
    // A zoom change painted during this pass is detected by composition and
    // schedules the following protected generation.
    if (refreshInheritedFrameZoom(frame)) {
        self.media_environment_dirty = true;
        markFrameStyleDirty(frame);
        self.needs_paint = true;
    }

    // JavaScript structural mutations are complete by the time their
    // delayed render task runs. Refresh resources before style so newly
    // attached sheets participate in this frame and removed sheets no longer
    // do. Script tasks are queued behind this render and retain owned source.
    var resource_frames = std.ArrayList(*Frame).empty;
    defer resource_frames.deinit(self.allocator);
    try self.collectFramesPostOrder(frame, &resource_frames);
    const rebuild_media_rules = self.media_environment_dirty;
    if (rebuild_media_rules) self.media_environment_dirty = false;
    errdefer {
        if (rebuild_media_rules) self.media_environment_dirty = true;
    }
    for (resource_frames.items) |resource_frame| {
        try b.refreshFrameResources(resource_frame);
    }
    if (rebuild_media_rules) {
        for (resource_frames.items) |resource_frame| {
            try b.rebuildFrameStyleRules(resource_frame);
        }
    }

    var frames = std.ArrayList(*Frame).empty;
    defer frames.deinit(self.allocator);
    try self.collectFramesPostOrder(frame, &frames);
    for (frames.items) |child_frame| try child_frame.annotateVisited(b);

    b.layout_engine.accessibility = self.accessibility;

    // Frame.document protects the style/layout boundary. A dirty document is
    // republished only after its complete style and background-resource pass
    // succeeds; layout cannot read through this phase while it remains dirty.
    if (frameTreeNeedsStyle(frame)) {
        try self.refreshFocusState();
        const style_start = if (profiling) std.Io.Clock.awake.now(b.io).nanoseconds else 0;
        for (frames.items) |child_frame| {
            try child_frame.renderStyle(b);
        }
        if (profiling) {
            style_ns = @intCast(std.Io.Clock.awake.now(b.io).nanoseconds - style_start);
        }
    }

    // Geometry dirtiness comes from the retained layout dependency graph.
    // Paint remains independently forceable for colors, focus, and visited
    // state without manufacturing a layout invalidation.
    const force_paint = self.needs_paint;
    if (frameTreeNeedsLayout(frame) or force_paint) {
        self.needs_paint = false;
        errdefer self.needs_paint = true;
        const layout_start = if (profiling) std.Io.Clock.awake.now(b.io).nanoseconds else 0;
        frame.viewport_height = self.tab_height;
        for (frames.items) |child_frame| {
            if (child_frame.current_node == null) continue;
            if (child_frame.layoutNeeded() or force_paint) {
                try b.layoutTabNodes(child_frame, force_paint);
            }
        }
        // Layout publishes the document-space positions used for lazy-image
        // selection. Loading here deliberately schedules one follow-up layout:
        // decoded intrinsic dimensions may change line breaks and page height.
        for (frames.items) |child_frame| {
            _ = try b.loadLazyImagesNearViewport(child_frame);
        }
        if (profiling) {
            layout_ns = @intCast(std.Io.Clock.awake.now(b.io).nanoseconds - layout_start);
        }
        const clamped_scroll = self.clampScrollForFrame(frame, frame.scroll);
        if (clamped_scroll != frame.scroll) {
            self.scroll_changed_in_tab = true;
            frame.scroll = clamped_scroll;
        }
    }

    b.setNeedsCompositeRasterDraw();
    // Store the generation captured before annotation. A concurrent visit
    // leaves the tab conservatively stale for the next scheduled frame.
    self.visited_generation = visited_generation;

    // The hit test consumes only the clean retained generation produced (or
    // preserved) above. A changed DOM hover path dirties targeted style fields
    // and deliberately schedules a separate style/layout/paint generation.
    if (try self.resolveHoverAfterLayout(refresh_hover_after_render)) {
        self.needs_paint = true;
        b.setNeedsAnimationFrame(self);
        b.scheduleAnimationFrame();
    }

    if (profiling) {
        const total_ns: u64 = @intCast(std.Io.Clock.awake.now(b.io).nanoseconds - render_start);
        std.log.info(
            "profile: render total={}ms style={}ms layout={}ms",
            .{
                @divTrunc(total_ns, 1_000_000),
                @divTrunc(style_ns, 1_000_000),
                @divTrunc(layout_ns, 1_000_000),
            },
        );
    }
}

pub fn runAnimationFrame(self: *Tab, scroll: i32) void {
    self.runAnimationFrameForGeneration(scroll, null);
}

pub fn runAnimationFrameForGeneration(
    self: *Tab,
    scroll: i32,
    animation_generation: ?u64,
) void {
    const frame = self.root_frame orelse return;
    const activation_commit = self.activation_commit_requested.swap(false, .acq_rel);
    var frame_it = self.frames_by_id.valueIterator();
    while (frame_it.next()) |frame_ptr| {
        if (frame_ptr.*.js_render_context_initialized) {
            if (frame_ptr.*.js_context) |ctx| {
                ctx.runAnimationFrameHandlers(frame_ptr.*.window_id);
            }
        }
    }

    if (!self.scroll_changed_in_tab and !activation_commit) {
        frame.scroll = scroll;
    }

    const now_ns = std.Io.Clock.awake.now(self.browser.io).nanoseconds;
    const scroll_animations_running = self.advanceScrollAnimations(now_ns);

    // Clear previous frame's composited updates
    self.composited_updates.items.len = 0;

    // Advance CSS transition animations
    var animations_running = false;
    if (frame.current_node) |*root| {
        animations_running = self.advanceAnimations(root);
    }

    // If animations are running, schedule the next frame
    if (animations_running or scroll_animations_running) {
        self.browser.setNeedsAnimationFrame(self);
        self.browser.scheduleAnimationFrame();
    }

    // Root scrolling can otherwise remain a compositor-only update. Consult
    // retained image positions before the dirty gate so entering a preload
    // region turns this same frame into the required layout/paint pass.
    var lazy_frame_it = self.frames_by_id.valueIterator();
    while (lazy_frame_it.next()) |frame_ptr| {
        _ = self.browser.loadLazyImagesNearViewport(frame_ptr.*) catch |err| {
            std.log.warn("Lazy image load failed: {}", .{err});
            continue;
        };
    }

    // Only run full render if there are non-composited changes
    // Composited-only updates (like opacity) skip layout and paint
    const has_composited_updates = self.composited_updates.items.len > 0;
    const needs_full_render = self.animationFrameNeedsFullRender(self.browser);

    if (needs_full_render) {
        self.render(self.browser) catch |err| {
            std.log.warn("Animation frame render failed: {}", .{err});
        };
        // Style recomputation can instantiate a CSS keyframe animation after
        // the advance phase above. Arm its first follow-up frame here.
        if (!animations_running and frame.current_node != null and
            hasActiveAnimations(&frame.current_node.?))
        {
            self.browser.setNeedsAnimationFrame(self);
            self.browser.scheduleAnimationFrame();
        }
    }

    const commit_scroll: ?i32 = if (activation_commit or self.scroll_changed_in_tab)
        frame.scroll
    else
        null;

    // Only commit if we have something to send
    if (animationFrameHasCommit(
        needs_full_render,
        has_composited_updates,
        activation_commit,
        commit_scroll,
    )) {
        const composed_list = if (needs_full_render or activation_commit)
            self.composeDisplayList(frame) catch |err| blk: {
                std.log.warn("Failed to compose retained display list: {}", .{err});
                if (activation_commit) self.activation_commit_requested.store(true, .release);
                self.needs_paint = true;
                self.browser.setNeedsAnimationFrame(self);
                self.browser.scheduleAnimationFrame();
                break :blk null;
            }
        else
            null;
        const commit_data = browser_mod.CommitData{
            .url = frame.current_url orelse null,
            .certificate_error = frame.certificate_error,
            .display_list = composed_list,
            .scroll = commit_scroll,
            .height = frame.content_height,
            .zoom = self.accessibility.zoom,
            .prefers_dark = self.accessibility.prefers_dark,
            .composited_updates = self.composited_updates.items,
            .animation_generation = animation_generation,
        };
        self.browser.commit(self, commit_data);
    }
    self.scroll_changed_in_tab = false;
}

/// A root scroll is itself a visual commit even when layout, paint, and the
/// compositor command tree are unchanged.
pub fn animationFrameHasCommit(
    needs_full_render: bool,
    has_composited_updates: bool,
    activation_commit: bool,
    commit_scroll: ?i32,
) bool {
    return needs_full_render or has_composited_updates or activation_commit or commit_scroll != null;
}

fn advanceScrollAnimations(self: *Tab, now_ns: i96) bool {
    var any_running = false;
    var frame_it = self.frames_by_id.valueIterator();
    while (frame_it.next()) |frame_ptr| {
        const target_frame = frame_ptr.*;
        const animation = target_frame.scroll_animation orelse continue;
        const step = animation.sample(now_ns);
        const next_scroll = self.clampScrollForFrame(target_frame, step.scroll);
        if (next_scroll != target_frame.scroll) {
            target_frame.scroll = next_scroll;
            if (target_frame == self.root_frame) {
                self.scroll_changed_in_tab = true;
            } else {
                // Child-frame scroll is part of iframe composition rather
                // than Browser's root-scroll scalar.
                self.needs_paint = true;
            }
        }

        const target_scroll = self.clampScrollForFrame(
            target_frame,
            animation.target_scroll,
        );
        const target_was_clamped = target_scroll != animation.target_scroll;
        if (step.complete or (target_was_clamped and next_scroll == target_scroll)) {
            target_frame.scroll = target_scroll;
            target_frame.scroll_animation = null;
            if (target_frame == self.root_frame) {
                self.scroll_changed_in_tab = true;
            } else {
                self.needs_paint = true;
            }
        } else {
            any_running = true;
        }
    }
    return any_running;
}

fn hasActiveAnimations(node: *const parser.Node) bool {
    return tab_animation.hasActive(node);
}

fn markAnimationLayout(self: *Tab, elem: *parser.Element) void {
    if (elem.layout_ptr) |layout_ptr| {
        if (elem.layout_mark) |mark| {
            mark(layout_ptr);
            return;
        }
    }
    // A newly created animation can advance before its first layout has
    // attached an element-local owner.
    if (self.root_frame) |root_frame| markFrameLayoutDirty(root_frame);
}

fn publishAnimationComposited(context: *anyopaque, update: CompositedUpdate) void {
    const self: *Tab = @ptrCast(@alignCast(context));
    self.composited_updates.append(self.allocator, update) catch return;
    if (self.root_frame) |root_frame| applyRetainedCompositedUpdate(root_frame, update);
}

fn markAnimationLayoutFromSink(context: *anyopaque, element: *parser.Element) void {
    const self: *Tab = @ptrCast(@alignCast(context));
    self.markAnimationLayout(element);
}

fn requestAnimationPaint(context: *anyopaque) void {
    const self: *Tab = @ptrCast(@alignCast(context));
    self.needs_paint = true;
}

fn animationSink(self: *Tab) tab_animation.Sink {
    return .{
        .context = self,
        .publish_composited = publishAnimationComposited,
        .mark_layout = markAnimationLayoutFromSink,
        .request_paint = requestAnimationPaint,
    };
}

/// Advance transitions and named keyframe animations in the node tree.
fn advanceAnimations(self: *Tab, node: *parser.Node) bool {
    return tab_animation.advance(self.animationSink(), node);
}

fn createCleanPhaseTestDocument(
    allocator: std.mem.Allocator,
    node: *Node,
) !*Layout.DocumentLayout {
    const document = try allocator.create(Layout.DocumentLayout);
    document.* = .{
        .allocator = allocator,
        .node = node.*,
        .node_ptr = node,
        .zoom = ProtectedField(f32).init(1.0),
        .x = ProtectedField(i32).init(0),
        .y = ProtectedField(i32).init(0),
        .width = ProtectedField(i32).init(0),
        .height = ProtectedField(i32).init(0),
        .children = .empty,
    };
    document.zoom.set(1.0);
    document.x.set(0);
    document.y.set(0);
    document.width.set(0);
    document.height.set(0);
    return document;
}

fn initAnimationPhaseTest(
    tab: *Tab,
    frame: *Frame,
    allocator: std.mem.Allocator,
) !void {
    tab.allocator = allocator;
    tab.root_frame = frame;
    tab.needs_paint = false;
    tab.pending_hover = false;
    tab.composited_updates = .empty;
    tab.frames_by_id = std.AutoHashMap(u32, *Frame).init(allocator);
    tab.parent_window_ids = std.AutoHashMap(u32, u32).init(allocator);
    var frame_initialized = false;
    errdefer {
        if (frame_initialized) frame.deinit();
        tab.frames_by_id.deinit();
        tab.parent_window_ids.deinit();
        tab.composited_updates.deinit(allocator);
    }

    frame.* = Frame.init(allocator, tab, null, null);
    frame_initialized = true;
    frame.current_node = .{ .element = try parser.Element.init(allocator, "html", null) };
    frame.setDocumentLayout(try createCleanPhaseTestDocument(
        allocator,
        &frame.current_node.?,
    ));
}

fn deinitAnimationPhaseTest(tab: *Tab, frame: *Frame) void {
    frame.deinit();
    tab.frames_by_id.deinit();
    tab.parent_window_ids.deinit();
    tab.composited_updates.deinit(tab.allocator);
}

test "opacity and transform animations stay compositor-only" {
    const allocator = std.testing.allocator;
    var root = parser.Node{ .element = try parser.Element.init(allocator, "div", null) };
    defer root.deinit(allocator);
    try parser.style(allocator, &root, &.{});

    root.element.animations = std.StringHashMap(parser.Animation).init(allocator);
    try root.element.animations.?.put("opacity", .{ .numeric = parser.NumericAnimation.initWithEasing(
        0,
        1,
        2,
        .linear,
    ) });
    try root.element.animations.?.put("transform", .{ .transform = parser.TransformAnimation.initWithEasing(
        .{ .x = 0, .y = 0 },
        .{ .x = 20, .y = 30 },
        2,
        .linear,
    ) });

    var tab: Tab = undefined;
    var frame: Frame = undefined;
    try initAnimationPhaseTest(&tab, &frame, allocator);
    defer deinitAnimationPhaseTest(&tab, &frame);

    try std.testing.expect(tab.advanceAnimations(&root));
    try std.testing.expectEqual(@as(usize, 2), tab.composited_updates.items.len);
    try std.testing.expect(!frame.styleNeeded());
    try std.testing.expect(!frame.documentLayout().?.layoutNeeded());
    try std.testing.expect(!tab.needs_paint);
    try std.testing.expect(!tab.renderPhasesNeeded());
}

test "background color animation requests layout and paint" {
    const allocator = std.testing.allocator;
    var root = parser.Node{ .element = try parser.Element.init(allocator, "div", null) };
    defer root.deinit(allocator);
    try parser.style(allocator, &root, &.{});

    root.element.animations = std.StringHashMap(parser.Animation).init(allocator);
    try root.element.animations.?.put("background-color", .{ .color = parser.ColorAnimation.initWithEasing(
        .{ .r = 255, .g = 0, .b = 0, .a = 255 },
        .{ .r = 0, .g = 0, .b = 255, .a = 255 },
        2,
        .linear,
    ) });

    var tab: Tab = undefined;
    var frame: Frame = undefined;
    try initAnimationPhaseTest(&tab, &frame, allocator);
    defer deinitAnimationPhaseTest(&tab, &frame);

    try std.testing.expect(tab.advanceAnimations(&root));
    try std.testing.expect(!frame.styleNeeded());
    try std.testing.expect(frame.documentLayout().?.layoutNeeded());
    try std.testing.expect(tab.needs_paint);
    try std.testing.expect(tab.renderPhasesNeeded());
}

test "pixel dimension animation requests layout and produces px values" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<div style=\"width: 100px; height: 40px\"></div>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);
    try parser.style(allocator, &root, &.{});

    root.element.animations = std.StringHashMap(parser.Animation).init(allocator);
    try root.element.animations.?.put("width", .{ .pixel = parser.PixelAnimation.initWithEasing(100, 200, 2, .linear) });
    try root.element.animations.?.put("height", .{ .pixel = parser.PixelAnimation.initWithEasing(40, 80, 2, .linear) });

    var tab: Tab = undefined;
    var frame: Frame = undefined;
    try initAnimationPhaseTest(&tab, &frame, allocator);
    defer deinitAnimationPhaseTest(&tab, &frame);

    try std.testing.expect(tab.advanceAnimations(&root));
    try std.testing.expect(!frame.styleNeeded());
    try std.testing.expect(frame.documentLayout().?.layoutNeeded());
    try std.testing.expect(tab.renderPhasesNeeded());
    var width_buffer: [32]u8 = undefined;
    var height_buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("150.000px", try root.element.animations.?.get("width").?.pixel.formatValue(&width_buffer));
    try std.testing.expectEqualStrings("60.000px", try root.element.animations.?.get("height").?.pixel.formatValue(&height_buffer));
}

test "alternate keyframe cycles preserve endpoints and relayout dimensions" {
    const allocator = std.testing.allocator;
    var root = parser.Node{ .element = try parser.Element.init(allocator, "div", null) };
    defer root.deinit(allocator);
    try parser.style(allocator, &root, &.{});

    root.element.animations = std.StringHashMap(parser.Animation).init(allocator);
    try root.element.animations.?.put("opacity", .{ .numeric = parser.NumericAnimation.initWithEasing(
        0,
        1,
        2,
        .linear,
    ) });
    try root.element.animations.?.put("width", .{ .pixel = parser.PixelAnimation.initWithEasing(
        100,
        200,
        2,
        .linear,
    ) });
    root.element.css_animation = .{
        .signature = 1,
        .property_mask = parser.cssAnimationPropertyBit("opacity") |
            parser.cssAnimationPropertyBit("width"),
        .iterations = null,
        .direction = .alternate,
    };

    var tab: Tab = undefined;
    var frame: Frame = undefined;
    try initAnimationPhaseTest(&tab, &frame, allocator);
    defer deinitAnimationPhaseTest(&tab, &frame);

    try std.testing.expect(tab.advanceAnimations(&root));
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.5),
        root.element.animations.?.get("opacity").?.numeric.getValue(),
        0.000001,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 150),
        root.element.animations.?.get("width").?.pixel.getValue(),
        0.000001,
    );
    try std.testing.expect(frame.documentLayout().?.layoutNeeded());

    try std.testing.expect(tab.advanceAnimations(&root));
    try std.testing.expect(root.element.css_animation.?.restart_pending);
    try std.testing.expectApproxEqAbs(
        @as(f64, 1),
        root.element.animations.?.get("opacity").?.numeric.getValue(),
        0.000001,
    );

    try std.testing.expect(tab.advanceAnimations(&root));
    try std.testing.expectEqual(@as(u32, 1), root.element.css_animation.?.completed_iterations);
    try std.testing.expectApproxEqAbs(
        @as(f64, 1),
        root.element.animations.?.get("opacity").?.numeric.getValue(),
        0.000001,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 200),
        root.element.animations.?.get("width").?.pixel.getValue(),
        0.000001,
    );

    try std.testing.expect(tab.advanceAnimations(&root));
    try std.testing.expect(tab.advanceAnimations(&root));
    try std.testing.expectApproxEqAbs(
        @as(f64, 0),
        root.element.animations.?.get("opacity").?.numeric.getValue(),
        0.000001,
    );
}

test "finite keyframe animation restores its underlying property" {
    const allocator = std.testing.allocator;
    var root = parser.Node{ .element = try parser.Element.init(allocator, "div", null) };
    defer root.deinit(allocator);
    try parser.style(allocator, &root, &.{});

    root.element.animations = std.StringHashMap(parser.Animation).init(allocator);
    try root.element.animations.?.put("width", .{ .pixel = parser.PixelAnimation.initWithEasing(
        100,
        200,
        1,
        .linear,
    ) });
    root.element.css_animation = .{
        .signature = 2,
        .property_mask = parser.cssAnimationPropertyBit("width"),
        .iterations = 1,
        .direction = .normal,
    };

    var tab: Tab = undefined;
    var frame: Frame = undefined;
    try initAnimationPhaseTest(&tab, &frame, allocator);
    defer deinitAnimationPhaseTest(&tab, &frame);

    try std.testing.expect(tab.advanceAnimations(&root));
    try std.testing.expect(root.element.css_animation.?.restart_pending);
    try std.testing.expect(!tab.advanceAnimations(&root));
    try std.testing.expect(root.element.css_animation.?.finished);
    try std.testing.expect(root.element.animations.?.get("width") == null);
    try std.testing.expect(frame.documentLayout().?.layoutNeeded());
}

fn applyRetainedCompositedUpdate(frame: *Frame, update: CompositedUpdate) void {
    if (frame.display_list) |items| {
        switch (update.value) {
            .opacity => |opacity| {
                _ = DisplayItem.applyCompositedOpacity(items, update.node, opacity);
            },
            .transform => |transform| {
                _ = DisplayItem.applyCompositedTransform(
                    items,
                    update.node,
                    transform.x,
                    transform.y,
                );
            },
        }
    }
    for (frame.children.items) |child| applyRetainedCompositedUpdate(child, update);
}

// Handle click on tab content
pub fn click(self: *Tab, b: *Browser, x: i32, y: i32, button: ClickButton) !void {
    const zoom = self.accessibility.zoom;
    return self.clickDevice(
        b,
        DisplayItem.scaleLayoutPx(x, zoom),
        DisplayItem.scaleLayoutPx(y, zoom),
        button,
        zoom,
    );
}

pub fn clickDevice(
    self: *Tab,
    b: *Browser,
    device_x: i32,
    device_y: i32,
    button: ClickButton,
    zoom: f32,
) !void {
    const frame = self.root_frame orelse return;

    if (button == .primary) {
        // Record pointer modality before click/focus listeners run so a
        // synchronous JavaScript focus() observes the initiating input.
        self.focus_modality = .pointer;
        const focus_changed = self.blur();
        self.focused_frame = frame;
        if (focus_changed) self.setNeedsRender();
    }

    const handled = try frame.clickDevice(b, device_x, device_y, button, zoom);
    if (button == .primary and !handled and self.focused_frame != null) {
        self.setNeedsRender();
    }
}

test "frame hover state follows the innermost element and its ancestors" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(
        allocator,
        "<main><section><span>first</span></section><section><span>second</span></section></main>",
    );
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);

    var tab: Tab = undefined;
    tab.allocator = allocator;
    tab.root_frame = null;
    tab.frames_by_id = std.AutoHashMap(u32, *Frame).init(allocator);
    defer tab.frames_by_id.deinit();
    tab.parent_window_ids = std.AutoHashMap(u32, u32).init(allocator);
    defer tab.parent_window_ids.deinit();

    var frame = Frame.init(allocator, &tab, null, null);
    defer frame.deinit();
    tab.root_frame = &frame;
    frame.current_node = try html_parser.parse();
    parser.fixParentPointers(&frame.current_node.?, null);

    var css_parser = try CSSParser.init(allocator, "section:hover span { color: green; }", false);
    defer css_parser.deinit(allocator);
    const rules = try css_parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    try parser.style(allocator, &frame.current_node.?, rules);

    const main = &frame.current_node.?.element;
    const first_section_node = &main.children.items[0];
    const first_section = &first_section_node.element;
    const first_span_node = &first_section.children.items[0];
    const first_span = &first_span_node.element;
    const first_text = &first_span.children.items[0];
    const second_section = &main.children.items[1].element;
    const second_span_node = &second_section.children.items[0];
    const second_span = &second_span_node.element;

    // A descendant selector must recompute even though the span itself is not
    // hovered when the pointer is over section padding.
    try std.testing.expect(frame.updateHoveredNode(first_section_node));
    try parser.style(allocator, &frame.current_node.?, rules);
    try std.testing.expect(first_section.is_hovered);
    try std.testing.expect(!first_span.is_hovered);
    try std.testing.expectEqualStrings("green", first_span.style.?.getPtr("color").?.get().*);

    try std.testing.expect(frame.updateHoveredNode(first_text));
    try std.testing.expect(frame.hovered_node == first_span_node);
    try std.testing.expect(main.is_hovered);
    try std.testing.expect(first_section.is_hovered);
    try std.testing.expect(first_span.is_hovered);
    try std.testing.expect(!second_section.is_hovered);
    try std.testing.expect(!second_span.is_hovered);

    try std.testing.expect(frame.updateHoveredNode(second_span_node));
    try std.testing.expect(frame.hovered_node == second_span_node);
    try std.testing.expect(main.is_hovered);
    try std.testing.expect(!first_section.is_hovered);
    try std.testing.expect(!first_span.is_hovered);
    try std.testing.expect(second_section.is_hovered);
    try std.testing.expect(second_span.is_hovered);

    try std.testing.expect(frame.updateHoveredNode(null));
    try std.testing.expect(frame.hovered_node == null);
    try std.testing.expect(!main.is_hovered);
    try std.testing.expect(!second_section.is_hovered);
    try std.testing.expect(!second_span.is_hovered);
    try std.testing.expect(!frame.updateHoveredNode(null));
}

test "pending hover resolves a retained hit after the layout phase" {
    const allocator = std.testing.allocator;
    var html_parser = try parser.HTMLParser.init(allocator, "<div><span>hit</span></div>");
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);

    var tab: Tab = undefined;
    tab.allocator = allocator;
    tab.accessibility = .{ .zoom = 2.0, .dark_palette = .{} };
    tab.accessibility_root = null;
    tab.accessibility_hovered = null;
    tab.root_frame = null;
    tab.hover_position = .{ .device_x = 5, .viewport_device_y = 5 };
    tab.pending_hover = true;
    tab.frames_by_id = std.AutoHashMap(u32, *Frame).init(allocator);
    defer tab.frames_by_id.deinit();
    tab.parent_window_ids = std.AutoHashMap(u32, u32).init(allocator);
    defer tab.parent_window_ids.deinit();

    var frame = Frame.init(allocator, &tab, null, null);
    defer frame.deinit();
    tab.root_frame = &frame;
    frame.scroll = 10;
    frame.current_node = try html_parser.parse();
    parser.fixParentPointers(&frame.current_node.?, null);
    frame.publishStyledDocument();
    try std.testing.expect(!frame.styleNeeded());
    try std.testing.expect(frame.documentLayout() == null);

    const span_node = &frame.current_node.?.element.children.items[0];
    var layout_marker: u8 = 0;
    const items = try allocator.alloc(DisplayItem, 1);
    items[0] = .{ .rect = .{
        .x1 = 0,
        .y1 = 10,
        .x2 = 20,
        .y2 = 20,
        .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .source = .{ .layout = &layout_marker, .node = span_node },
    } };
    frame.display_list = items;

    try std.testing.expect(try tab.resolveHoverAfterLayout(false));
    try std.testing.expect(!tab.pending_hover);
    try std.testing.expect(frame.hovered_node == span_node);
    try std.testing.expect(span_node.element.is_hovered);
    try std.testing.expect(frame.current_node.?.element.is_hovered);
    try std.testing.expect(frame.styleNeeded());
    try std.testing.expect(frame.document.lastValue().* == null);
}

test "pending hover enters render without dirtying another phase" {
    var tab: Tab = undefined;
    tab.root_frame = null;
    tab.needs_paint = false;
    tab.pending_hover = false;
    try std.testing.expect(!tab.renderPhasesNeeded());

    tab.pending_hover = true;
    try std.testing.expect(tab.renderPhasesNeeded());
    try std.testing.expect(!tab.needs_paint);
}

pub const FormMethod = enum {
    get,
    post,
};

/// Parse the HTML form method. GET is the missing, empty, invalid, and
/// unsupported-value default; only an explicit ASCII-case-insensitive POST
/// selects a request body.
pub fn parseFormMethod(raw_method: ?[]const u8) FormMethod {
    const raw = raw_method orelse return .get;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return if (std.ascii.eqlIgnoreCase(trimmed, "post")) .post else .get;
}

/// A synchronous form-navigation plan. `action` and a non-null `payload`
/// borrow the caller's buffers; `owned_action` is present only for GET and is
/// released by `deinit`.
pub const FormSubmissionPlan = struct {
    action: []const u8,
    payload: ?[]const u8,
    owned_action: ?[]u8,

    pub fn deinit(self: *FormSubmissionPlan, allocator: std.mem.Allocator) void {
        if (self.owned_action) |action| allocator.free(action);
        self.* = undefined;
    }
};

fn buildGetFormAction(
    allocator: std.mem.Allocator,
    action: []const u8,
    encoded_data: []const u8,
) ![]u8 {
    // GET form data replaces the action's query. Keep a fragment after the
    // new query so relative, absolute, and empty actions all retain normal URL
    // resolution semantics.
    const fragment_index = std.mem.indexOfScalar(u8, action, '#') orelse action.len;
    const query_index = std.mem.indexOfScalar(u8, action[0..fragment_index], '?') orelse fragment_index;

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, action[0..query_index]);
    try result.append(allocator, '?');
    try result.appendSlice(allocator, encoded_data);
    if (fragment_index < action.len) {
        try result.appendSlice(allocator, action[fragment_index..]);
    }
    return result.toOwnedSlice(allocator);
}

pub fn planFormSubmission(
    allocator: std.mem.Allocator,
    method: FormMethod,
    action: []const u8,
    encoded_data: []const u8,
) !FormSubmissionPlan {
    return switch (method) {
        .get => blk: {
            const get_action = try buildGetFormAction(allocator, action, encoded_data);
            break :blk .{
                .action = get_action,
                .payload = null,
                .owned_action = get_action,
            };
        },
        .post => .{
            .action = action,
            .payload = encoded_data,
            .owned_action = null,
        },
    };
}

// Submit the form containing an activated button or text entry.
pub fn submitForm(self: *Tab, b: *Browser, frame: *Frame, control_node: *Node) !bool {
    // IMPORTANT: We cannot traverse parent pointers here because loadInTab
    // will free the tree, invalidating all pointers. Instead, we search
    // the entire tree from the root to find which form contains this control.

    std.log.info("submitForm called", .{});

    if (frame.current_node == null) {
        std.log.warn("No current_node", .{});
        return false;
    }

    // Get all nodes in the tree
    var node_list = std.ArrayList(*Node).empty;
    defer node_list.deinit(self.allocator);
    try parser.treeToList(self.allocator, &frame.current_node.?, &node_list);

    std.log.info("Found {} nodes in tree", .{node_list.items.len});

    // Find all form elements
    for (node_list.items) |node_ptr| {
        switch (node_ptr.*) {
            .element => |e| {
                if (std.mem.eql(u8, e.tag, "form")) {
                    std.log.info("Found form element", .{});
                    // Check if this form contains the activated control.
                    var form_nodes = std.ArrayList(*Node).empty;
                    defer form_nodes.deinit(self.allocator);
                    try parser.treeToList(self.allocator, node_ptr, &form_nodes);

                    std.log.info("Form has {} child nodes", .{form_nodes.items.len});

                    for (form_nodes.items) |form_child| {
                        if (form_child == control_node) {
                            std.log.info("Found activated control in form", .{});
                            const live_form_node = frame.dispatchEventForDefault(
                                "submit",
                                node_ptr,
                                node_ptr,
                            ) orelse {
                                std.log.info("Default submit prevented", .{});
                                return true;
                            };
                            const live_form = switch (live_form_node.*) {
                                .element => |*element| element,
                                .text => return true,
                            };

                            // A missing action submits back to the current
                            // document. Copy before scheduling navigation can
                            // retire the DOM backing the attribute.
                            const action = if (live_form.attributes) |attrs|
                                attrs.get("action") orelse ""
                            else
                                "";
                            const method = parseFormMethod(if (live_form.attributes) |attrs|
                                attrs.get("method")
                            else
                                null);
                            std.log.info("Form action: {s}", .{action});
                            const action_copy = try self.allocator.dupe(u8, action);
                            defer self.allocator.free(action_copy);

                            try self.submitFormData(b, frame, live_form_node, action_copy, method);
                            return true;
                        }
                    }
                }
            },
            .text => {},
        }
    }

    std.log.debug("No form found containing activated control", .{});
    return false;
}

/// Encode the form's named input controls. Unchecked checkboxes are not
/// successful controls; checked checkboxes use `on` when no value is present.
pub fn encodeFormData(allocator: std.mem.Allocator, form_node: *Node) ![]u8 {
    var node_list = std.ArrayList(*Node).empty;
    defer node_list.deinit(allocator);
    try parser.treeToList(allocator, form_node, &node_list);

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    var wrote_pair = false;

    for (node_list.items) |node_ptr| {
        switch (node_ptr.*) {
            .element => |*element| {
                if (!std.ascii.eqlIgnoreCase(element.tag, "input")) continue;
                const attributes = element.attributes orelse continue;
                const name = attributes.get("name") orelse continue;
                if (element.isCheckbox() and !element.isChecked()) continue;
                const value = if (element.isCheckbox())
                    attributes.get("value") orelse "on"
                else
                    attributes.get("value") orelse "";

                if (wrote_pair) try body.append(allocator, '&');
                try percentEncode(allocator, name, &body);
                try body.append(allocator, '=');
                try percentEncode(allocator, value, &body);
                wrote_pair = true;
            },
            .text => {},
        }
    }

    return body.toOwnedSlice(allocator);
}

// Collect form inputs and submit according to the form's GET/POST method.
fn submitFormData(
    self: *Tab,
    b: *Browser,
    frame: *Frame,
    form_node: *Node,
    action: []const u8,
    method: FormMethod,
) !void {
    const body_slice = try encodeFormData(self.allocator, form_node);
    var body_owned = true;
    defer if (body_owned) {
        self.allocator.free(body_slice);
    };

    // For file:// URLs, we can't actually submit forms, so just log it
    if (frame.current_url) |url_ptr| {
        if (std.mem.eql(u8, url_ptr.*.scheme, "file")) {
            std.log.info("Skipping form submission for file:// URL", .{});
            return;
        }
    }

    var submission = try planFormSubmission(self.allocator, method, action, body_slice);
    defer submission.deinit(self.allocator);

    std.log.info(
        "Form {s} submission to {s}: {s}",
        .{ @tagName(method), submission.action, body_slice },
    );

    // Resolve the action URL against the current page URL
    var form_url = try frame.current_url.?.*.resolveForNavigation(self.allocator, submission.action);

    // A non-null payload is the network layer's POST discriminator. GET data
    // lives only in the resolved URL and its encoded buffer stays local.
    const form_url_ptr = b.allocator.create(Url) catch |alloc_err| {
        std.log.err("Failed to allocate form URL: {any}", .{alloc_err});
        form_url.free(self.allocator);
        return;
    };
    form_url_ptr.* = form_url;
    var url_owned = true;
    defer if (url_owned) {
        form_url_ptr.*.free(b.allocator);
        b.allocator.destroy(form_url_ptr);
    };

    if (frame.parent != null) {
        b.scheduleFrameLoad(frame, form_url_ptr, submission.payload) catch |err| {
            std.log.err("Failed to submit iframe form: {any}", .{err});
            return;
        };
    } else {
        b.scheduleLoad(self, form_url_ptr, submission.payload) catch |err| {
            std.log.err("Failed to submit form: {any}", .{err});
            return;
        };
    }
    url_owned = false;
    if (submission.payload != null) body_owned = false;
}

// Cycle focus to the next input element (for Tab key)
test "hidden inputs are skipped by focus while password inputs remain editable" {
    const allocator = std.testing.allocator;
    var hidden = try parser.Element.init(allocator, "input type=HiDdEn tabindex=0", null);
    defer hidden.deinit(allocator);
    var password = try parser.Element.init(allocator, "input type=PASSWORD", null);
    defer password.deinit(allocator);

    try std.testing.expect(hidden.isHiddenInput());
    try std.testing.expect(!dom_focus.isSequentiallyFocusable(&hidden));
    try std.testing.expect(password.isPasswordInput());
    try std.testing.expect(dom_focus.isSequentiallyFocusable(&password));
    try std.testing.expect(isTextEntryInput(&password));
}

fn collectFocusableElements(self: *Tab, frame: *Frame, out: *std.ArrayList(*Node)) !void {
    const root_node = frame.current_node orelse return;

    var node_list = std.ArrayList(*Node).empty;
    defer node_list.deinit(self.allocator);

    var root_mut = root_node;
    try parser.treeToList(self.allocator, &root_mut, &node_list);

    for (node_list.items) |node_ptr| {
        switch (node_ptr.*) {
            .element => |e| {
                if (dom_focus.isSequentiallyFocusable(&e)) {
                    try out.append(self.allocator, node_ptr);
                }
            },
            else => {},
        }
    }
}

/// Sequential keyboard focus visits every element in one document before
/// entering that document's child frames. Keeping the frame walk separate
/// from the DOM walk makes empty frames skippable without flattening or
/// confusing nodes from distinct document trees.
fn collectFramesInFocusOrder(
    self: *Tab,
    frame: *Frame,
    out: *std.ArrayList(*Frame),
) !void {
    try out.append(self.allocator, frame);
    for (frame.children.items) |child| {
        try self.collectFramesInFocusOrder(child, out);
    }
}

fn focusBoundsForNode(frame: *const Frame, node: *Node) ?Bounds {
    for (frame.focus_bounds.items) |entry| {
        if (entry.node == node) return entry.bounds;
    }
    return null;
}

fn captureNodeHandleWithAccess(
    ctx: *js_module,
    window_id: u32,
    node: *Node,
    access: JsEventAccess,
) !u32 {
    return switch (access) {
        .acquire_lock => ctx.captureNodeHandle(window_id, node),
        .native_callback => ctx.captureNodeHandleFromNativeCallback(window_id, node),
    };
}

fn resolveAttachedNodeWithAccess(
    ctx: *js_module,
    window_id: u32,
    handle: u32,
    access: JsEventAccess,
) ?*Node {
    return switch (access) {
        .acquire_lock => ctx.resolveAttachedNode(window_id, handle),
        .native_callback => ctx.resolveAttachedNodeFromNativeCallback(window_id, handle),
    };
}

fn focusScrollTarget(self: *const Tab, frame: *const Frame, bounds: Bounds) i32 {
    const zoom = if (self.accessibility.zoom > 0) self.accessibility.zoom else 1.0;
    const viewport_device = if (frame.viewport_height > 0)
        frame.viewport_height
    else
        self.tab_height;
    const viewport_css_float = @as(f64, @floatFromInt(@max(viewport_device, 1))) /
        @as(f64, zoom);
    const viewport_css: i32 = @max(1, @as(i32, @intFromFloat(@ceil(viewport_css_float))));
    const top = bounds.y;
    const bottom = bounds.y +| bounds.height;
    const current_bottom = frame.scroll +| viewport_css;

    var requested = frame.scroll;
    if (bounds.height >= viewport_css) {
        if (top < frame.scroll or bottom > current_bottom) requested = top;
    } else if (top < frame.scroll) {
        requested = top;
    } else if (bottom > current_bottom) {
        requested = bottom -| viewport_css;
    }
    return self.clampScrollForFrame(frame, requested);
}

test "focus scrolling reveals an element using CSS coordinates at zoom" {
    var tab: Tab = undefined;
    tab.accessibility = .{ .zoom = 2.0, .dark_palette = .{} };
    tab.tab_height = 200;
    var frame: Frame = undefined;
    frame.viewport_height = 200;
    frame.content_height = 1000;
    frame.scroll = 0;

    try std.testing.expectEqual(@as(i32, 240), focusScrollTarget(
        &tab,
        &frame,
        .{ .x = 0, .y = 300, .width = 100, .height = 40 },
    ));

    frame.scroll = 300;
    try std.testing.expectEqual(@as(i32, 50), focusScrollTarget(
        &tab,
        &frame,
        .{ .x = 0, .y = 50, .width = 100, .height = 20 },
    ));
}

fn installFocusedElement(
    self: *Tab,
    b: *Browser,
    frame: *Frame,
    node: *Node,
    access: JsEventAccess,
) bool {
    const element = switch (node.*) {
        .element => |*value| value,
        .text => return false,
    };
    if (!dom_focus.isProgrammaticallyFocusable(element)) return false;
    if (frame.focus == node and self.focused_frame == frame) {
        b.requestContentFocus(self);
        return false;
    }

    element.is_focused = true;
    element.is_focus_visible = dom_focus.indicatorVisibleFor(element, self.focus_modality);
    parser.dirtyStyleForElement(element);
    frame.focus = node;
    self.focused_frame = frame;
    self.updateAccessibilityFocus(b);
    b.requestContentFocus(self);
    self.setNeedsRender();

    // DOM focus/blur do not bubble. State is installed before dispatch so a
    // listener observes the new focus and a structural mutation can retire it
    // through the normal synchronous mutation boundary.
    _ = frame.dispatchEventWithAccess("focus", node, false, access);
    return true;
}

/// Keyboard input promotes an already pointer-focused non-text control into
/// focus-visible state. This matters when Tab cycles back to the same sole
/// control and when Space/Return is the first keyboard action after a click.
fn promoteFocusedIndicatorForKeyboard(self: *Tab) bool {
    self.focus_modality = .keyboard;
    const frame = self.focused_frame orelse return false;
    const node = frame.focus orelse return false;
    const element = switch (node.*) {
        .element => |*value| value,
        .text => return false,
    };
    if (!element.is_focused or element.is_focus_visible) return false;
    if (!dom_focus.indicatorVisibleFor(element, .keyboard)) return false;

    element.is_focus_visible = true;
    parser.dirtyStyleForElement(element);
    return true;
}

fn noteKeyboardInteraction(self: *Tab) void {
    if (self.promoteFocusedIndicatorForKeyboard()) self.setNeedsRender();
}

test "keyboard interaction promotes an existing pointer focus" {
    const allocator = std.testing.allocator;
    var button = Node{ .element = try parser.Element.init(allocator, "button", null) };
    defer button.deinit(allocator);
    button.element.is_focused = true;
    button.element.is_focus_visible = false;

    var frame: Frame = undefined;
    frame.focus = &button;
    var tab: Tab = undefined;
    tab.focused_frame = &frame;
    tab.focus_modality = .pointer;

    try std.testing.expect(tab.promoteFocusedIndicatorForKeyboard());
    try std.testing.expectEqual(dom_focus.Modality.keyboard, tab.focus_modality);
    try std.testing.expect(button.element.is_focus_visible);
    try std.testing.expect(!tab.promoteFocusedIndicatorForKeyboard());
}

/// Move ordinary browser focus to a known attached element. Capturing a JS
/// handle before blur makes click/keyboard focus robust when a blur listener
/// relocates or removes the intended target.
pub fn focusElement(self: *Tab, b: *Browser, frame: *Frame, node: *Node) !bool {
    const element = switch (node.*) {
        .element => |*value| value,
        .text => return false,
    };
    if (!dom_focus.isProgrammaticallyFocusable(element)) return false;
    if (frame.focus == node and self.focused_frame == frame) {
        b.requestContentFocus(self);
        return false;
    }

    const handle = if (frame.js_context) |ctx|
        try ctx.captureNodeHandle(frame.window_id, node)
    else
        null;
    const changed = self.blur();
    if (changed) self.setNeedsRender();

    const live_node = if (handle) |stable_handle| blk: {
        const ctx = frame.js_context orelse return false;
        break :blk ctx.resolveAttachedNode(frame.window_id, stable_handle) orelse return false;
    } else node;
    return installFocusedElement(self, b, frame, live_node, .acquire_lock);
}

/// Synchronous HTMLElement.focus() implementation. JavaScript can dirty style
/// or layout and call focus in the same task, so render before consulting the
/// focus-bounds snapshot. Blur listeners can mutate again, requiring a second
/// generation check and layout synchronization before the final position read.
pub fn focusElementFromScript(
    self: *Tab,
    b: *Browser,
    window_id: u32,
    generation: u64,
    handle: u32,
) !bool {
    var frame = self.frameForWindowId(window_id) orelse return false;
    if (frame.document_generation != generation) return false;
    var ctx = frame.js_context orelse return false;
    var target = resolveAttachedNodeWithAccess(
        ctx,
        window_id,
        handle,
        .native_callback,
    ) orelse return false;
    const initial_element = switch (target.*) {
        .element => |*value| value,
        .text => return false,
    };
    if (!dom_focus.isProgrammaticallyFocusable(initial_element)) return false;

    try self.render(b);
    frame = self.frameForWindowId(window_id) orelse return false;
    if (frame.document_generation != generation) return false;
    ctx = frame.js_context orelse return false;
    target = resolveAttachedNodeWithAccess(
        ctx,
        window_id,
        handle,
        .native_callback,
    ) orelse return false;
    var bounds = focusBoundsForNode(frame, target) orelse return false;

    if (frame.focus != target or self.focused_frame != frame) {
        const blurred = self.blurWithAccess(.native_callback);
        if (blurred) self.setNeedsRender();

        // A blur listener may change style, structure, or even the document.
        // Re-render and recover both Frame and Node through stable identities.
        try self.render(b);
        frame = self.frameForWindowId(window_id) orelse return false;
        if (frame.document_generation != generation) return false;
        ctx = frame.js_context orelse return false;
        target = resolveAttachedNodeWithAccess(
            ctx,
            window_id,
            handle,
            .native_callback,
        ) orelse return false;
        const live_element = switch (target.*) {
            .element => |*value| value,
            .text => return false,
        };
        if (!dom_focus.isProgrammaticallyFocusable(live_element)) return false;
        bounds = focusBoundsForNode(frame, target) orelse return false;
    }

    const target_scroll = focusScrollTarget(self, frame, bounds);
    if (target_scroll != frame.scroll) {
        frame.scroll_animation = null;
        frame.scroll = target_scroll;
        self.scroll_changed_in_tab = true;
        self.setNeedsRender();
    }

    return installFocusedElement(self, b, frame, target, .native_callback);
}

pub fn cycleFocus(self: *Tab, b: *Browser, reverse: bool) !void {
    self.noteKeyboardInteraction();
    const root = self.root_frame orelse return;

    var frames = std.ArrayList(*Frame).empty;
    defer frames.deinit(self.allocator);
    try self.collectFramesInFocusOrder(root, &frames);

    var frame_index: usize = 0;
    if (self.focused_frame) |focused_frame| {
        for (frames.items, 0..) |frame, i| {
            if (frame == focused_frame) {
                frame_index = i;
                break;
            }
        }
    }

    const frame = frames.items[frame_index];
    var focusables = std.ArrayList(*Node).empty;
    defer focusables.deinit(self.allocator);
    try self.collectFocusableElements(frame, &focusables);

    var found_index: ?usize = null;
    if (frame.focus) |current_focus| {
        for (focusables.items, 0..) |elem, i| {
            if (elem == current_focus) {
                found_index = i;
                break;
            }
        }
    }

    if (found_index) |i| {
        if (reverse) {
            if (i > 0) {
                _ = try self.focusElement(b, frame, focusables.items[i - 1]);
                return;
            }
        } else if (i + 1 < focusables.items.len) {
            _ = try self.focusElement(b, frame, focusables.items[i + 1]);
            return;
        }
    } else if (focusables.items.len > 0) {
        const edge = if (reverse) focusables.items.len - 1 else 0;
        _ = try self.focusElement(b, frame, focusables.items[edge]);
        return;
    }

    // The current frame is exhausted (or empty). Visit the remaining frames
    // in the requested direction, wrapping only after the whole frame tree.
    // Including the current frame after a full revolution preserves cycling
    // when it is the only frame with focusable content.
    var candidate_frame_index = frame_index;
    var frames_examined: usize = 0;
    while (frames_examined < frames.items.len) : (frames_examined += 1) {
        candidate_frame_index = if (reverse)
            (if (candidate_frame_index == 0) frames.items.len - 1 else candidate_frame_index - 1)
        else
            (candidate_frame_index + 1) % frames.items.len;

        const candidate_frame = frames.items[candidate_frame_index];
        var candidates = std.ArrayList(*Node).empty;
        defer candidates.deinit(self.allocator);
        try self.collectFocusableElements(candidate_frame, &candidates);
        if (candidates.items.len == 0) continue;

        const edge = if (reverse) candidates.items.len - 1 else 0;
        _ = try self.focusElement(b, candidate_frame, candidates.items[edge]);
        return;
    }
}

pub fn activateFocusedElement(self: *Tab, b: *Browser) !void {
    self.noteKeyboardInteraction();
    const frame = self.focused_frame orelse self.root_frame orelse return;
    if (frame.focus == null) return;
    const node_ptr = frame.focus.?;

    switch (node_ptr.*) {
        .element => |*e| {
            if (std.mem.eql(u8, e.tag, "input")) {
                if (e.isCheckbox()) {
                    const live_node = frame.dispatchEventForDefault(
                        "click",
                        node_ptr,
                        node_ptr,
                    ) orelse return;
                    const live_element = switch (live_node.*) {
                        .element => |*element| element,
                        .text => return,
                    };
                    _ = try live_element.toggleChecked();
                    parser.dirtyStyleForElement(live_element);
                    self.setNeedsRender();
                    return;
                }
                if (e.attributes) |attrs| {
                    if (attrs.get("type")) |raw_type| {
                        if (std.mem.eql(u8, raw_type, "submit") or std.mem.eql(u8, raw_type, "button")) {
                            const live_node = frame.dispatchEventForDefault(
                                "click",
                                node_ptr,
                                node_ptr,
                            ) orelse return;
                            _ = try self.submitForm(b, frame, live_node);
                        }
                    }
                }
                return;
            }

            if (std.mem.eql(u8, e.tag, "button")) {
                const live_node = frame.dispatchEventForDefault(
                    "click",
                    node_ptr,
                    node_ptr,
                ) orelse return;
                _ = try self.submitForm(b, frame, live_node);
                return;
            }

            if (std.mem.eql(u8, e.tag, "a")) {
                const live_node = frame.dispatchEventForDefault(
                    "click",
                    node_ptr,
                    node_ptr,
                ) orelse return;
                const live_element = switch (live_node.*) {
                    .element => |*element| element,
                    .text => return,
                };
                if (live_element.attributes) |attrs| {
                    if (attrs.get("href")) |href| {
                        try frame.followLink(b, href, .primary);
                        return;
                    }
                }
                return;
            }

            _ = frame.dispatchEvent("click", node_ptr);
        },
        else => {},
    }
}

fn isTextEntryInput(element: *const parser.Element) bool {
    if (!std.ascii.eqlIgnoreCase(element.tag, "input")) return false;
    const input_type = element.inputType();

    // Unknown input types use HTML's text-state fallback. Exclude the known
    // non-text controls that should retain their ordinary activation behavior.
    const non_text_types = [_][]const u8{
        "button", "checkbox", "color", "file",   "hidden", "image",
        "radio",  "range",    "reset", "submit",
    };
    for (non_text_types) |non_text_type| {
        if (std.ascii.eqlIgnoreCase(input_type, non_text_type)) return false;
    }
    return true;
}

/// Handle Return for page content. Text entries submit their containing form;
/// buttons, links, and other focused elements keep the existing activation
/// behavior shared with accessibility and voice-command input.
pub fn enter(self: *Tab, b: *Browser) !bool {
    self.noteKeyboardInteraction();
    const frame = self.focused_frame orelse self.root_frame orelse return false;
    const focus_node = frame.focus orelse return false;

    switch (focus_node.*) {
        .element => |*element| {
            if (isTextEntryInput(element)) {
                const live_node = frame.dispatchEventForDefault(
                    "keydown",
                    focus_node,
                    focus_node,
                ) orelse return false;
                return self.submitForm(b, frame, live_node);
            }
            // Checkboxes use Space/default activation rather than Return.
            if (element.isCheckbox()) return false;
        },
        .text => {},
    }

    try self.activateFocusedElement(b);
    return false;
}

const PendingBlurEvent = struct {
    window_id: u32,
    generation: u64,
    handle: u32,
};

fn clearFrameFocus(
    frame: *Frame,
    allocator: std.mem.Allocator,
    events: *std.ArrayList(PendingBlurEvent),
    access: JsEventAccess,
) bool {
    var changed = false;
    frame.scroll_focus = null;
    if (frame.focus) |focus_node| {
        if (frame.js_context) |ctx| {
            if (captureNodeHandleWithAccess(
                ctx,
                frame.window_id,
                focus_node,
                access,
            )) |handle| {
                events.append(allocator, .{
                    .window_id = frame.window_id,
                    .generation = frame.document_generation,
                    .handle = handle,
                }) catch |err| {
                    std.log.warn("Failed to retain blur event target: {}", .{err});
                };
            } else |_| {}
        }
        switch (focus_node.*) {
            .element => |*e| {
                e.is_focused = false;
                e.is_focus_visible = false;
                parser.dirtyStyleForElement(e);
            },
            else => {},
        }
        frame.focus = null;
        changed = true;
    }
    for (frame.children.items) |child| {
        if (clearFrameFocus(child, allocator, events, access)) changed = true;
    }
    return changed;
}

/// Remove every DOM focus in this tab before another focus owner is selected.
/// Returns whether a focused element changed and therefore needs repainting.
pub fn blur(self: *Tab) bool {
    return self.blurWithAccess(.acquire_lock);
}

fn blurWithAccess(self: *Tab, access: JsEventAccess) bool {
    var events = std.ArrayList(PendingBlurEvent).empty;
    defer events.deinit(self.allocator);
    const changed = if (self.root_frame) |root|
        clearFrameFocus(root, self.allocator, &events, access)
    else
        false;

    // Clear the complete old focus generation before invoking JavaScript.
    // A blur listener may synchronously call focus(); that new state must not
    // be erased when this outer transition finishes walking child frames.
    self.focused_frame = null;
    self.accessibility_focused = null;

    for (events.items) |event| {
        const frame = self.frameForWindowId(event.window_id) orelse continue;
        if (event.generation != 0 and frame.document_generation != event.generation) continue;
        const ctx = frame.js_context orelse continue;
        const live_node = resolveAttachedNodeWithAccess(
            ctx,
            event.window_id,
            event.handle,
            access,
        ) orelse continue;
        _ = frame.dispatchEventWithAccess("blur", live_node, false, access);
    }
    return changed;
}

/// Try the clicked scroll box first, then each enclosing scroll box. Returning
/// false at a boundary lets the caller fall back to the frame/page scroller.
pub fn scrollElementChain(scroll_start: ?*Node, delta: i32) bool {
    var current = scroll_start;
    while (current) |node| {
        switch (node.*) {
            .element => |*element| {
                const parent = element.parent;
                if (element.scrollBy(delta)) {
                    parser.markPaintForElement(element);
                    return true;
                }
                current = parent;
            },
            .text => |text| current = text.parent,
        }
    }
    return false;
}

fn findBodyElement(node: *Node) ?*parser.Element {
    return switch (node.*) {
        .text => null,
        .element => |*element| blk: {
            // Zibra's permissive parser can retain an explicit authored
            // document below its implicit html/body wrapper. Prefer the
            // descendant body so an authored inline declaration wins over
            // that synthetic viewport container.
            for (element.children.items) |*child| {
                if (findBodyElement(child)) |body| break :blk body;
            }
            break :blk if (std.ascii.eqlIgnoreCase(element.tag, "body")) element else null;
        },
    };
}

/// The exercise deliberately uses the body element as the viewport's style
/// source. `scroll-behavior` is non-inherited, so descendants cannot enable it
/// accidentally.
pub fn documentScrollBehavior(root: *Node) scroll_model.Behavior {
    const body = findBodyElement(root) orelse return .auto;
    const styles = if (body.style) |*map| map else return .auto;
    const field = styles.getPtr("scroll-behavior") orelse return .auto;
    return scroll_model.parseBehavior(field.get().*);
}

fn frameScrollBehavior(frame: *Frame) scroll_model.Behavior {
    const root = if (frame.current_node) |*node| node else return .auto;
    return documentScrollBehavior(root);
}

/// Arrow-key scroll entry point. Element offsets are tab-worker-owned and need
/// only repaint; an exhausted element chain delegates to the existing frame
/// scroll model (including iframe and root interest-region behavior).
pub fn scrollFocused(self: *Tab, b: *Browser, delta: i32) void {
    if (!b.tabIsActive(self)) return;
    self.noteKeyboardInteraction();
    const frame = self.focused_frame orelse self.root_frame orelse return;
    if (scrollElementChain(frame.scroll_focus, delta)) {
        frame.scroll_animation = null;
        self.setNeedsPaint();
        return;
    }

    if (!self.accessibility.reduce_motion and frameScrollBehavior(frame) == .smooth) {
        const base_scroll = if (frame.scroll_animation) |animation|
            animation.target_scroll
        else
            frame.scroll;
        const target_scroll = self.clampScrollForFrame(frame, base_scroll +| delta);
        if (frame.scroll_animation) |animation| {
            if (animation.target_scroll == target_scroll) return;
        } else if (target_scroll == frame.scroll) {
            return;
        }

        frame.scroll_animation = scroll_model.ScrollAnimation.init(
            frame.scroll,
            target_scroll,
            std.Io.Clock.awake.now(b.io).nanoseconds,
        );
        b.setNeedsAnimationFrame(self);
        b.scheduleAnimationFrame();
        return;
    }

    self.scrollImmediate(b, delta);
}

/// Serialized immediate scrolling for `auto`, wheel, voice, and accessibility
/// input. Keeping cancellation on the tab worker prevents the optional clock
/// animation from being read or torn across threads.
pub fn scrollImmediate(self: *Tab, b: *Browser, delta: i32) void {
    if (!b.tabIsActive(self)) return;
    const frame = self.focused_frame orelse self.root_frame orelse return;
    frame.scroll_animation = null;
    b.handleScrollForTab(self, delta);
}

// Handle keypress in focused input
pub fn keypress(self: *Tab, b: *Browser, char: u8) !void {
    self.noteKeyboardInteraction();
    const frame = self.focused_frame orelse self.root_frame orelse return;
    if (frame.focus) |focus_node| {
        const live_focus_node = frame.dispatchEventForDefault(
            "keydown",
            focus_node,
            focus_node,
        ) orelse {
            std.log.info("Default keydown prevented", .{});
            return;
        };
        switch (live_focus_node.*) {
            .element => |*e| {
                if (std.mem.eql(u8, e.tag, "input")) {
                    if (!isTextEntryInput(e)) return;
                    if (e.attributes) |*attrs| {
                        const old_value = attrs.get("value") orelse "";
                        // Append the character
                        var new_value = try self.allocator.alloc(u8, old_value.len + 1);
                        @memcpy(new_value[0..old_value.len], old_value);
                        new_value[old_value.len] = char;
                        try attrs.put("value", new_value);
                        // Track this allocation so we can free it later
                        if (e.owned_strings == null) {
                            e.owned_strings = std.ArrayList([]const u8).empty;
                        }
                        try e.owned_strings.?.append(self.allocator, new_value);
                    }
                    parser.markPaintForElement(e);
                    self.setNeedsRender();
                } else if (e.attributes) |*attrs| {
                    if (attrs.get("contenteditable") != null) {
                        var node_list = std.ArrayList(*Node).empty;
                        defer node_list.deinit(self.allocator);
                        try parser.treeToList(self.allocator, live_focus_node, &node_list);

                        var last_text_node: ?*Node = null;
                        for (node_list.items) |node_ptr| {
                            if (node_ptr.* == .text) {
                                last_text_node = node_ptr;
                            }
                        }

                        const new_text = blk: {
                            if (last_text_node) |text_node| {
                                switch (text_node.*) {
                                    .text => |t| {
                                        const old_text = t.text;
                                        const buffer = try self.allocator.alloc(u8, old_text.len + 1);
                                        @memcpy(buffer[0..old_text.len], old_text);
                                        buffer[old_text.len] = char;
                                        break :blk buffer;
                                    },
                                    else => unreachable,
                                }
                            } else {
                                const buffer = try self.allocator.alloc(u8, 1);
                                buffer[0] = char;
                                break :blk buffer;
                            }
                        };
                        var new_text_owned = true;
                        errdefer if (new_text_owned) self.allocator.free(new_text);

                        if (e.owned_strings == null) {
                            e.owned_strings = std.ArrayList([]const u8).empty;
                        }
                        try e.owned_strings.?.append(self.allocator, new_text);
                        new_text_owned = false;

                        if (last_text_node) |text_node| {
                            switch (text_node.*) {
                                .text => |*t| t.text = new_text,
                                else => unreachable,
                            }
                            // Contenteditable text can change wrapping and
                            // therefore remains a layout invalidation.
                            if (e.layout_ptr) |layout_ptr| {
                                if (e.layout_mark) |mark_fn| mark_fn(layout_ptr);
                            }
                        } else {
                            const text_node = Node{ .text = .{
                                .text = new_text,
                                .parent = live_focus_node,
                            } };

                            // Appending can relocate every by-value child.
                            // Dirty and retire all current DOM-derived state
                            // before the first fallible capacity change.
                            e.markChildrenDirty();
                            parser.dirtyStyleForElement(e);
                            if (e.layout_ptr) |ptr| {
                                if (e.layout_mark) |mark_fn| mark_fn(ptr);
                            }
                            parser.clearStyleInvalidations(&frame.current_node.?);
                            self.prepareForDomMutation(b, frame, live_focus_node);
                            try e.children.ensureUnusedCapacity(self.allocator, 1);
                            e.children.appendAssumeCapacity(text_node);
                            parser.fixParentPointers(live_focus_node, e.parent);
                        }

                        self.setNeedsRender();
                    }
                }
            },
            else => {},
        }
    }
}

// Handle backspace in focused input
pub fn backspace(self: *Tab, b: *Browser) !void {
    self.noteKeyboardInteraction();
    _ = b;
    const frame = self.focused_frame orelse self.root_frame orelse return;
    if (frame.focus) |focus_node| {
        switch (focus_node.*) {
            .element => |*e| {
                if (std.mem.eql(u8, e.tag, "input")) {
                    if (!isTextEntryInput(e)) return;
                    if (e.attributes) |*attrs| {
                        const old_value = attrs.get("value") orelse "";
                        if (old_value.len > 0) {
                            // Remove the last character
                            const new_value = try self.allocator.alloc(u8, old_value.len - 1);
                            @memcpy(new_value, old_value[0 .. old_value.len - 1]);
                            try attrs.put("value", new_value);
                            // Track this allocation
                            if (e.owned_strings == null) {
                                e.owned_strings = std.ArrayList([]const u8).empty;
                            }
                            try e.owned_strings.?.append(self.allocator, new_value);
                            parser.markPaintForElement(e);
                        }
                        self.setNeedsRender();
                    }
                }
            },
            else => {},
        }
    }
}

pub fn buildAccessibilityTree(self: *Tab) !void {
    const previous_root = self.accessibility_root;
    const previous_reading_dom = if (self.accessibility_reading) |node|
        node.dom_node
    else
        null;
    const previous_highlight_dom = if (self.accessibility_highlight) |node|
        node.dom_node
    else
        null;
    self.accessibility_root = null;

    var previous_strings = self.accessibility_strings;
    self.accessibility_strings = .empty;
    defer {
        if (previous_root) |old_root| {
            old_root.deinit(self.allocator);
            self.allocator.destroy(old_root);
        }
        for (previous_strings.items) |value| {
            self.allocator.free(value);
        }
        previous_strings.deinit(self.allocator);
    }

    self.clearAccessibilityTree();

    const frame = self.root_frame orelse return;
    if (frame.current_node == null) return;

    var bounds_map = std.AutoHashMap(*Node, Bounds).init(self.allocator);
    defer bounds_map.deinit();

    var frames = std.ArrayList(*Frame).empty;
    defer frames.deinit(self.allocator);
    try self.collectFramesPostOrder(frame, &frames);
    for (frames.items) |target_frame| {
        const offset = self.frameOffsetToRoot(target_frame);
        for (target_frame.accessibility_bounds.items) |entry| {
            const adjusted = Bounds{
                .x = entry.bounds.x + offset.x,
                .y = entry.bounds.y + offset.y,
                .width = entry.bounds.width,
                .height = entry.bounds.height,
            };
            if (bounds_map.getPtr(entry.node)) |existing| {
                mergeBounds(existing, adjusted);
            } else {
                try bounds_map.put(entry.node, adjusted);
            }
        }
    }

    var root_children = std.ArrayList(*AccessibilityNode).empty;
    switch (frame.current_node.?) {
        .text => {},
        .element => |*root_element| {
            for (root_element.children.items) |*child| {
                try self.appendAccessibilityNodes(&root_children, child, &bounds_map);
            }
        },
    }

    const root_bounds = Bounds{
        .x = 0,
        .y = 0,
        .width = self.tab_width,
        .height = frame.content_height,
    };
    const root_name = try self.copyAccessibilityString("document");
    const root = try self.createAccessibilityNode("document", root_name, root_bounds, null, root_children);
    self.accessibility_root = root;
    self.accessibility_focused = self.findAccessibilityNodeForDom(self.accessibility_root, frame.focus);
    self.accessibility_reading = self.findAccessibilityNodeForDom(
        self.accessibility_root,
        previous_reading_dom,
    );
    self.accessibility_highlight = self.findAccessibilityNodeForDom(
        self.accessibility_root,
        previous_highlight_dom,
    );
    self.accessibility_hovered = null;

    if (previous_root) |old_root| {
        self.handleLiveRegionUpdates(old_root, root);
    }
    if (self.accessibility_focused != null and self.accessibility.screen_reader) {
        self.speakAccessibilityNode(self.accessibility_focused.?, "focus");
    }
}

fn createAccessibilityNode(
    self: *Tab,
    role: []const u8,
    name: []const u8,
    bounds: Bounds,
    dom_node: ?*Node,
    children: std.ArrayList(*AccessibilityNode),
) !*AccessibilityNode {
    const node = try self.allocator.create(AccessibilityNode);
    node.* = .{
        .role = role,
        .name = name,
        .bounds = bounds,
        .children = children,
        .dom_node = dom_node,
    };
    return node;
}

fn appendAccessibilityNodes(
    self: *Tab,
    out: *std.ArrayList(*AccessibilityNode),
    node_ptr: *Node,
    bounds_map: *std.AutoHashMap(*Node, Bounds),
) !void {
    switch (node_ptr.*) {
        .text => {},
        .element => |*e| {
            if (isAriaHidden(e)) return;
            if (e.isHiddenInput()) return;
            if (isPresentationalTag(e.tag)) {
                for (e.children.items) |*child| {
                    try self.appendAccessibilityNodes(out, child, bounds_map);
                }
                return;
            }

            var children = std.ArrayList(*AccessibilityNode).empty;
            if (std.mem.eql(u8, e.tag, "iframe")) {
                if (self.frameForElement(node_ptr)) |child_frame| {
                    if (child_frame.current_node) |*child_root| {
                        switch (child_root.*) {
                            .text => {},
                            .element => |*child_element| {
                                for (child_element.children.items) |*child| {
                                    try self.appendAccessibilityNodes(&children, child, bounds_map);
                                }
                            },
                        }
                    }
                }
            } else {
                for (e.children.items) |*child| {
                    try self.appendAccessibilityNodes(&children, child, bounds_map);
                }
            }

            const role = accessibilityRole(e);
            const name = try self.accessibilityName(node_ptr, e);
            const bounds = bounds_map.get(node_ptr) orelse Bounds{ .x = 0, .y = 0, .width = 0, .height = 0 };
            const node = try self.createAccessibilityNode(role, name, bounds, node_ptr, children);
            node.live = liveSettingFromAttributes(e);
            try out.append(self.allocator, node);
        },
    }
}

fn isPresentationalTag(tag: []const u8) bool {
    return std.mem.eql(u8, tag, "script") or
        std.mem.eql(u8, tag, "style") or
        std.mem.eql(u8, tag, "head") or
        std.mem.eql(u8, tag, "meta") or
        std.mem.eql(u8, tag, "link") or
        std.mem.eql(u8, tag, "title") or
        std.mem.eql(u8, tag, "br");
}

fn isAriaHidden(element: *const parser.Element) bool {
    if (element.attributes) |attrs| {
        if (attrs.get("aria-hidden")) |value| {
            return std.mem.eql(u8, std.mem.trim(u8, value, " \t\r\n"), "true");
        }
    }
    return false;
}

fn accessibilityRole(element: *const parser.Element) []const u8 {
    if (std.mem.eql(u8, element.tag, "a")) return "link";
    if (std.mem.eql(u8, element.tag, "button")) return "button";
    if (std.mem.eql(u8, element.tag, "input")) {
        if (element.isCheckbox()) return "checkbox";
        if (element.attributes) |attrs| {
            if (attrs.get("type")) |raw_type| {
                if (std.mem.eql(u8, raw_type, "submit") or std.mem.eql(u8, raw_type, "button")) {
                    return "button";
                }
            }
        }
        return "textbox";
    }
    if (std.mem.startsWith(u8, element.tag, "h") and element.tag.len == 2) return "heading";
    if (std.mem.eql(u8, element.tag, "p")) return "paragraph";
    if (std.mem.eql(u8, element.tag, "img")) return "img";
    if (std.mem.eql(u8, element.tag, "ul") or std.mem.eql(u8, element.tag, "ol")) return "list";
    if (std.mem.eql(u8, element.tag, "li")) return "listitem";
    if (std.mem.eql(u8, element.tag, "form")) return "form";
    if (std.mem.eql(u8, element.tag, "iframe")) return "iframe";
    return "generic";
}

fn frameForElement(self: *Tab, node: *Node) ?*Frame {
    const root = self.root_frame orelse return null;
    return root.findFrameByElement(node);
}

fn frameOffsetToRoot(self: *Tab, frame: *Frame) struct { x: i32, y: i32 } {
    _ = self;
    var x: i32 = 0;
    var y: i32 = 0;
    var current: *Frame = frame;
    while (current.parent) |parent| {
        if (current.frame_element) |elem| {
            for (parent.iframe_bounds.items) |entry| {
                if (entry.node == elem) {
                    x += entry.bounds.x;
                    y += entry.bounds.y - current.scroll;
                    break;
                }
            }
        }
        current = parent;
    }
    return .{ .x = x, .y = y };
}

fn accessibilityName(self: *Tab, node_ptr: *Node, element: *const parser.Element) ![]const u8 {
    if (element.attributes) |attrs| {
        if (attrs.get("aria-label")) |label| {
            return self.copyAccessibilityString(label);
        }
    }

    if (std.mem.eql(u8, element.tag, "input")) {
        if (element.attributes) |attrs| {
            if (!element.isPasswordInput()) {
                if (attrs.get("value")) |value| {
                    if (value.len > 0) return self.copyAccessibilityString(value);
                }
            }
            if (attrs.get("placeholder")) |placeholder| {
                if (placeholder.len > 0) return self.copyAccessibilityString(placeholder);
            }
        }
        if (element.isPasswordInput()) return self.copyAccessibilityString("password input");
        return self.copyAccessibilityString("input");
    }

    if (std.mem.eql(u8, element.tag, "img")) {
        if (element.attributes) |attrs| {
            if (attrs.get("alt")) |alt| {
                if (alt.len > 0) return self.copyAccessibilityString(alt);
            }
        }
        return self.copyAccessibilityString("image");
    }

    if (std.mem.eql(u8, element.tag, "a")) {
        const text = try self.collectText(node_ptr);
        if (text.len > 0) return text;
        if (element.attributes) |attrs| {
            if (attrs.get("href")) |href| {
                if (href.len > 0) return self.copyAccessibilityString(href);
            }
        }
    }

    const text = try self.collectText(node_ptr);
    if (text.len > 0) return text;
    return self.copyAccessibilityString("");
}

fn liveSettingFromAttributes(element: *const parser.Element) ?LiveSetting {
    if (element.attributes) |attrs| {
        if (attrs.get("aria-live")) |value| {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            if (std.mem.eql(u8, trimmed, "off")) return null;
            if (std.mem.eql(u8, trimmed, "assertive")) return .assertive;
            if (std.mem.eql(u8, trimmed, "polite")) return .polite;
        }
    }
    return null;
}

fn findLiveSettingInTree(node: *AccessibilityNode) ?LiveSetting {
    if (node.live) |setting| return setting;
    for (node.children.items) |child| {
        if (findLiveSettingInTree(child)) |setting| return setting;
    }
    return null;
}

fn collectText(self: *Tab, node_ptr: *Node) ![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(self.allocator);
    try self.collectTextImpl(node_ptr, &buffer);
    const trimmed = std.mem.trim(u8, buffer.items, " \t\r\n");
    return self.copyAccessibilityString(trimmed);
}

fn collectTextImpl(self: *Tab, node_ptr: *Node, buffer: *std.ArrayList(u8)) !void {
    switch (node_ptr.*) {
        .text => |t| {
            try buffer.appendSlice(self.allocator, t.text);
        },
        .element => |*e| {
            for (e.children.items) |*child| {
                try self.collectTextImpl(child, buffer);
            }
        },
    }
}

fn copyAccessibilityString(self: *Tab, value: []const u8) ![]const u8 {
    const duped = try self.allocator.alloc(u8, value.len);
    @memcpy(duped, value);
    try self.accessibility_strings.append(self.allocator, duped);
    return duped;
}

fn mergeBounds(existing: *Bounds, incoming: Bounds) void {
    const existing_right = existing.x + existing.width;
    const existing_bottom = existing.y + existing.height;
    const incoming_right = incoming.x + incoming.width;
    const incoming_bottom = incoming.y + incoming.height;
    if (incoming.x < existing.x) existing.x = incoming.x;
    if (incoming.y < existing.y) existing.y = incoming.y;
    const new_right = if (incoming_right > existing_right) incoming_right else existing_right;
    const new_bottom = if (incoming_bottom > existing_bottom) incoming_bottom else existing_bottom;
    existing.width = new_right - existing.x;
    existing.height = new_bottom - existing.y;
}

pub fn accessibilityHitTest(self: *Tab, x: i32, y: i32) ?*AccessibilityNode {
    const root = self.accessibility_root orelse return null;
    return self.hitTestAccessibilityNode(root, x, y);
}

pub fn updateAccessibilityFocus(self: *Tab, b: *Browser) void {
    _ = b;
    const frame = self.focused_frame orelse self.root_frame orelse return;
    self.accessibility_focused = self.findAccessibilityNodeForDom(self.accessibility_root, frame.focus);
    if (self.accessibility_focused != null and self.accessibility.screen_reader) {
        self.speakAccessibilityNode(self.accessibility_focused.?, "focus");
    }
}

pub fn updateAccessibilityHover(self: *Tab, node: ?*AccessibilityNode) void {
    if (self.accessibility_hovered == node) return;
    self.accessibility_hovered = node;
    if (node != null and self.accessibility.screen_reader) {
        self.speakAccessibilityNode(node.?, "hover");
    }
}

fn speakAccessibilityNode(self: *Tab, node: *AccessibilityNode, reason: []const u8) void {
    var value_text: []const u8 = "";
    if (node.dom_node) |dom| {
        switch (dom.*) {
            .element => |*e| {
                if (std.mem.eql(u8, e.tag, "input")) {
                    if (!e.isPasswordInput()) {
                        if (e.attributes) |attrs| {
                            if (attrs.get("value")) |val| {
                                value_text = val;
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }

    self.accessibility_speech.enqueue(
        reason,
        node.role,
        node.name,
        value_text,
    ) catch |err| {
        std.log.warn("Failed to queue accessibility speech: {}", .{err});
    };
}

pub fn clearAccessibilitySpeech(self: *Tab) void {
    self.accessibility_speech.clear();
}

fn findLiveSetting(node: *AccessibilityNode) ?LiveSetting {
    if (node.live) |setting| return setting;
    return null;
}

fn handleLiveRegionUpdates(self: *Tab, old_root: *AccessibilityNode, new_root: *AccessibilityNode) void {
    if (!self.accessibility.screen_reader) return;
    self.syncLiveRegionAnnounce(old_root, new_root);
    self.flushPoliteAnnouncements();
}

fn syncLiveRegionAnnounce(self: *Tab, old_node: *AccessibilityNode, new_node: *AccessibilityNode) void {
    const parent_setting = findLiveSetting(new_node);
    self.checkLiveRegionChange(old_node, new_node, parent_setting);
}

fn checkLiveRegionChange(self: *Tab, old_node: *AccessibilityNode, new_node: *AccessibilityNode, live_setting: ?LiveSetting) void {
    if (live_setting) |setting| {
        const old_text = old_node.name;
        const new_text = new_node.name;
        if (!std.mem.eql(u8, old_text, new_text) and new_text.len > 0) {
            if (setting == .assertive) {
                self.accessibility_polite_queue.clearRetainingCapacity();
                self.speakAccessibilityNode(new_node, "assertive");
            } else {
                _ = self.accessibility_polite_queue.append(self.allocator, new_node) catch {};
            }
        }
    }
}

fn syncLiveRegionAnnounceFromParent(
    self: *Tab,
    old_node: *AccessibilityNode,
    new_node: *AccessibilityNode,
    inherited_live: ?LiveSetting,
) void {
    const live_setting = new_node.live orelse inherited_live;
    self.checkLiveRegionChange(old_node, new_node, live_setting);

    const child_count = @min(old_node.children.items.len, new_node.children.items.len);
    var idx: usize = 0;
    while (idx < child_count) : (idx += 1) {
        self.syncLiveRegionAnnounceFromParent(
            old_node.children.items[idx],
            new_node.children.items[idx],
            live_setting,
        );
    }
}

fn flushPoliteAnnouncements(self: *Tab) void {
    for (self.accessibility_polite_queue.items) |node| {
        self.speakAccessibilityNode(node, "polite");
    }
    self.accessibility_polite_queue.clearRetainingCapacity();
}

/// Advance the screen-reader reading cursor by one accessibility-tree node.
/// The node remains highlighted until the next advance, so a repaint can show
/// the same element that was just spoken. Once the traversal reaches the end,
/// the next advance clears the reading highlight and the following advance
/// starts over at the document root.
pub fn advanceAccessibility(self: *Tab) void {
    if (!self.accessibility.screen_reader) return;
    const root = self.accessibility_root orelse return;

    const next = if (self.accessibility_reading) |current| blk: {
        break :blk nextAccessibilityNode(root, current);
    } else if (root.dom_node == null and root.children.items.len > 0) root.children.items[0] else root;

    if (next) |node| {
        self.accessibility_reading = node;
        self.accessibility_highlight = node;
        self.speakAccessibilityNode(node, "document");
    } else {
        self.accessibility_reading = null;
        self.accessibility_highlight = null;
    }
    self.setNeedsPaint();
}

/// Compatibility entry point for callers that used the old whole-document
/// reader. Reading is intentionally incremental now: one call advances one
/// node, allowing the corresponding highlight to be painted between calls.
pub fn readAccessibilityDocument(self: *Tab) void {
    self.advanceAccessibility();
}

fn nextAccessibilityNode(root: *AccessibilityNode, current: *AccessibilityNode) ?*AccessibilityNode {
    var seen = false;
    return nextAccessibilityNodeAfter(root, current, &seen);
}

fn nextAccessibilityNodeAfter(
    node: *AccessibilityNode,
    current: *AccessibilityNode,
    seen: *bool,
) ?*AccessibilityNode {
    if (seen.*) return node;
    if (node == current) {
        seen.* = true;
        if (node.children.items.len > 0) return node.children.items[0];
        return null;
    }
    for (node.children.items) |child| {
        if (nextAccessibilityNodeAfter(child, current, seen)) |next| return next;
    }
    return null;
}

test "accessibility reading traversal advances in preorder" {
    const allocator = std.testing.allocator;
    var root = AccessibilityNode{
        .role = "document",
        .name = "document",
        .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .children = std.ArrayList(*AccessibilityNode).empty,
        .dom_node = null,
    };
    var first = AccessibilityNode{
        .role = "heading",
        .name = "First",
        .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .children = std.ArrayList(*AccessibilityNode).empty,
        .dom_node = null,
    };
    var nested = AccessibilityNode{
        .role = "paragraph",
        .name = "Nested",
        .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .children = std.ArrayList(*AccessibilityNode).empty,
        .dom_node = null,
    };
    var last = AccessibilityNode{
        .role = "link",
        .name = "Last",
        .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .children = std.ArrayList(*AccessibilityNode).empty,
        .dom_node = null,
    };
    defer root.children.deinit(allocator);
    defer first.children.deinit(allocator);
    defer nested.children.deinit(allocator);
    defer last.children.deinit(allocator);

    try root.children.append(allocator, &first);
    try root.children.append(allocator, &last);
    try first.children.append(allocator, &nested);

    try std.testing.expectEqual(&first, nextAccessibilityNode(&root, &root));
    try std.testing.expectEqual(&nested, nextAccessibilityNode(&root, &first));
    try std.testing.expectEqual(&last, nextAccessibilityNode(&root, &nested));
    try std.testing.expect(nextAccessibilityNode(&root, &last) == null);
}

pub fn handleVoiceCommand(self: *Tab, b: *Browser, command: []const u8) void {
    if (self.accessibility_root == null) return;

    if (std.mem.eql(u8, command, "read page")) {
        self.advanceAccessibility();
        return;
    }
    if (std.mem.eql(u8, command, "focus next")) {
        self.cycleFocus(b, false) catch |err| {
            std.log.warn("Failed to focus next: {}", .{err});
        };
        return;
    }
    if (std.mem.eql(u8, command, "focus prev")) {
        self.cycleFocus(b, true) catch |err| {
            std.log.warn("Failed to focus previous: {}", .{err});
        };
        return;
    }
    if (std.mem.eql(u8, command, "scroll down")) {
        self.scrollImmediate(b, 100);
        return;
    }
    if (std.mem.eql(u8, command, "scroll up")) {
        self.scrollImmediate(b, -100);
        return;
    }

    if (std.mem.startsWith(u8, command, "click ")) {
        const query = std.mem.trim(u8, command["click ".len..], " \t\r\n");
        if (query.len == 0) return;
        self.commandClick(query);
        return;
    }

    std.log.info("voice command: unknown '{s}'", .{command});
}

fn commandClick(self: *Tab, query: []const u8) void {
    const root = self.accessibility_root orelse return;
    const frame = self.root_frame orelse return;
    if (self.findAccessibilityByName(root, query)) |node| {
        self.accessibility_highlight = node;
        if (node.dom_node) |dom| {
            self.noteKeyboardInteraction();
            _ = self.focusElement(self.browser, frame, dom) catch |err| {
                std.log.warn("Failed to focus voice-command target: {}", .{err});
                return;
            };
            self.activateFocusedElement(self.browser) catch |err| {
                std.log.warn("Failed to activate element: {}", .{err});
            };
        }
    } else {
        std.log.info("voice command: no match for '{s}'", .{query});
    }
}

fn findAccessibilityByName(self: *Tab, node: *AccessibilityNode, query: []const u8) ?*AccessibilityNode {
    if (node.name.len > 0 and std.mem.containsAtLeast(u8, node.name, 1, query)) {
        return node;
    }
    for (node.children.items) |child| {
        if (self.findAccessibilityByName(child, query)) |hit| {
            return hit;
        }
    }
    return null;
}

fn hitTestAccessibilityNode(self: *Tab, node: *AccessibilityNode, x: i32, y: i32) ?*AccessibilityNode {
    if (!boundsContains(node.bounds, x, y)) return null;
    for (node.children.items) |child| {
        if (self.hitTestAccessibilityNode(child, x, y)) |hit| {
            return hit;
        }
    }
    return node;
}

fn boundsContains(bounds: Bounds, x: i32, y: i32) bool {
    return x >= bounds.x and x < bounds.x + bounds.width and y >= bounds.y and y < bounds.y + bounds.height;
}

fn findAccessibilityNodeForDom(self: *Tab, root: ?*AccessibilityNode, dom_node: ?*Node) ?*AccessibilityNode {
    const root_node = root orelse return null;
    const target = dom_node orelse return null;
    if (root_node.dom_node == target) return root_node;
    for (root_node.children.items) |child| {
        if (findAccessibilityNodeForDom(self, child, dom_node)) |hit| {
            return hit;
        }
    }
    return null;
}

pub fn dumpAccessibilityTree(self: *Tab) void {
    const root = self.accessibility_root orelse return;
    dumpAccessibilityNode(root, 0);
}

fn dumpAccessibilityNode(node: *AccessibilityNode, indent: usize) void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        std.debug.print("  ", .{});
    }
    std.debug.print(
        "{s} \"{s}\" ({d},{d},{d},{d})\n",
        .{ node.role, node.name, node.bounds.x, node.bounds.y, node.bounds.width, node.bounds.height },
    );
    for (node.children.items) |child| {
        dumpAccessibilityNode(child, indent + 1);
    }
}

fn clearAccessibilityTree(self: *Tab) void {
    if (self.accessibility_root) |root| {
        root.deinit(self.allocator);
        self.allocator.destroy(root);
    }
    self.accessibility_root = null;
    self.accessibility_focused = null;
    self.accessibility_hovered = null;
    self.accessibility_polite_queue.clearRetainingCapacity();
    self.accessibility_highlight = null;
    self.accessibility_reading = null;
}

// Percent-encode a string for use in form data (application/x-www-form-urlencoded)
// Encodes special characters as %XX where XX is the hex code
fn percentEncode(allocator: std.mem.Allocator, input: []const u8, output: *std.ArrayList(u8)) !void {
    for (input) |byte| {
        // Unreserved characters (don't need encoding): A-Z a-z 0-9 - _ . ~
        if ((byte >= 'A' and byte <= 'Z') or
            (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            byte == '-' or byte == '_' or byte == '.' or byte == '~')
        {
            try output.append(allocator, byte);
        } else {
            // Encode as %XX
            const hex = "0123456789ABCDEF";
            try output.append(allocator, '%');
            try output.append(allocator, hex[byte >> 4]);
            try output.append(allocator, hex[byte & 0x0F]);
        }
    }
}
