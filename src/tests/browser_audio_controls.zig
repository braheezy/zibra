//! Native-control regression through real layout, display hits and the Tab
//! worker. PCM advances manually; a task-return barrier owns test callbacks.
const std = @import("std");
const browser = @import("../browser/root.zig");
const Tab = @import("../browser/tab.zig").Tab;
const tasks = @import("../runtime/task.zig");
const media = @import("../browser/media.zig").Integration(browser.Browser);
const controls = @import("../media/controls.zig");
const DisplayItem = browser.DisplayItem;
const Rect = @import("../browser/render/display_list.zig").Rect;

fn partRect(items: []const DisplayItem, part: controls.Part) ?Rect {
    for (items) |item| switch (item) {
        .cached_subtree => |cache| if (partRect(cache.list.items, part)) |rect| {
            return rect;
        },
        .blend => |blend| if (partRect(blend.children, part)) |rect| {
            return rect;
        },
        .transform => |transform| if (partRect(transform.children, part)) |rect| {
            return .{ .left = rect.left + transform.translate_x, .right = rect.right + transform.translate_x, .top = rect.top + transform.translate_y, .bottom = rect.bottom + transform.translate_y };
        },
        .rect => |rect| if (rect.source) |source| {
            if (source.audio_part == part) return .{ .left = rect.x1, .right = rect.x2, .top = rect.y1, .bottom = rect.y2 };
        },
        else => {},
    };
    return null;
}

fn clickPart(b: *browser.Browser, tab: *Tab, part: controls.Part, fraction: f64) !void {
    try tab.render(b);
    const rect = partRect(tab.root_frame.?.display_list.?, part) orelse return error.MissingAudioControl;
    const zoom = tab.accessibility.zoom;
    const left = DisplayItem.scaleLayoutPx(rect.left, zoom);
    const right = DisplayItem.scaleLayoutPx(rect.right, zoom);
    const x = left + @as(i32, @intFromFloat(@as(f64, @floatFromInt(right - left)) * fraction));
    try tab.clickDevice(b, x, DisplayItem.scaleLayoutPx(rect.top + @divTrunc(rect.height(), 2), zoom), .primary, zoom);
}

fn checkScript(tab: *Tab, script: []const u8) !void {
    const frame = tab.root_frame.?;
    const result = try frame.js_context.?.evaluate(frame.window_id, script);
    if (!result.toBoolean()) std.debug.print("audio control script failed: {s}\n", .{script});
    try std.testing.expect(result.toBoolean());
}

const Run = struct {
    browser: *browser.Browser,
    tab: *Tab,
    returned: std.Io.Semaphore = .{},
    failure: ?anyerror = null,
    fn run(raw: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.exercise() catch |err| {
            std.debug.print("audio control task failed: {s}\n", .{@errorName(err)});
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            self.failure = err;
        };
    }
    fn cleanup(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.returned.post(std.testing.io);
    }
    fn exercise(self: *@This()) !void {
        const b = self.browser;
        const tab = self.tab;
        const frame = tab.root_frame.?;
        try checkScript(tab, "var a=document.getElementById('a'); a.volume===1");
        const js = frame.js_context.?;
        var states = frame.audio_elements.iterator();
        const entry = states.next().?;
        const state = entry.value_ptr.*;
        const node = js.resolveAttachedNode(frame.window_id, entry.key_ptr.*).?;
        const samples = try b.session_state.audio.allocator.alloc(f32, 480000);
        @memset(samples, 0);
        state.accept(.{ .samples = samples, .sample_rate = 48000, .channels = 1 }) catch |err| {
            b.session_state.audio.allocator.free(samples);
            return err;
        };
        tab.setZoom(1.5);
        try checkScript(tab, "a.duration===10 && a.readyState===4");
        try clickPart(b, tab, .seek, 0.25);
        try checkScript(tab, "a.paused && a.seeking && a.currentTime>2.45 && a.currentTime<2.55 && leaked===0");
        const drag = tab.audio_drag.?;
        try std.testing.expect(try media.pointer(b, tab, drag.pointer_x + drag.width, true));
        try std.testing.expect(tab.audio_drag == null);
        try checkScript(tab, "a.currentTime===10 && a.paused");
        try clickPart(b, tab, .mute, 0.5);
        try std.testing.expect(try media.key(b, tab, .down));
        try checkScript(tab, "a.muted && a.volume===0.95");
        try clickPart(b, tab, .play, 0.5);
        try checkScript(tab, "!a.paused && a.currentTime===0");
        try tab.render(b);
        const layout = frame.documentLayout().?;
        var output: [9600]f32 = undefined;
        b.session_state.audio.mix(&output);
        try checkScript(tab, "a.played.length===1 && a.played.start(0)===0 && a.played.end(0)===0.1");
        try std.testing.expect(frame.documentLayout().? == layout);
        try std.testing.expect(!layout.layoutNeeded());
        try clickPart(b, tab, .play, 0.5);
        try checkScript(tab, "a.paused && leaked===0");
        try tab.cycleFocus(b, false);
        try std.testing.expectEqual(controls.Part.seek, node.element.audio_part);
        try tab.cycleFocus(b, false);
        try std.testing.expectEqual(controls.Part.mute, node.element.audio_part);
        try tab.cycleFocus(b, false);
        try std.testing.expectEqual(controls.Part.volume, node.element.audio_part);
        try tab.cycleFocus(b, false);
        try std.testing.expectEqualStrings("after", frame.focus.?.element.attributes.?.get("id").?);
        try tab.cycleFocus(b, true);
        try std.testing.expect(frame.focus == node);
        try std.testing.expectEqual(controls.Part.volume, node.element.audio_part);
        try std.testing.expect(try media.key(b, tab, .home));
        try checkScript(tab, "a.volume===0");
        try std.testing.expect(try media.key(b, tab, .end));
        try checkScript(tab, "a.volume===1");
        try clickPart(b, tab, .volume, 0.25);
        try std.testing.expect(tab.audio_drag != null);
        try checkScript(tab, "a.load(); true");
        try std.testing.expect(!try media.pointer(b, tab, 700, false));
        try std.testing.expect(tab.audio_drag == null);
        try checkScript(tab, "a.played.length===0 && leaked===0");
    }
};

test "audio native controls seek drag mute and keyboard actions share media state" {
    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp");
    const b = try browser.Browser.init(allocator, std.testing.io, &environ, false, true);
    defer {
        b.deinit();
        allocator.destroy(b);
    }
    b.session_state.audio.output = .manual;
    try b.newTab(try @import("../network/url.zig").Url.init(allocator, "data:text/html,<html><body><button>Before</button><div style='zoom:1.25;transform:translate(15px,10px)'><audio id='a' controls preload='none'></audio></div><button id='after'>After</button><script>var leaked=0;document.body.addEventListener('click',function(){leaked++});</script></body></html>"));
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 20 * std.time.ns_per_s;
    while (true) {
        _ = try b.tick();
        const tab = b.activeTab().?;
        b.lock.lock();
        const quiet = !b.needs_animation_frame and !b.animation_timer_active;
        b.lock.unlock();
        if (quiet and b.isIdle() and tab.isQuiescent()) break;
        if (std.Io.Clock.awake.now(std.testing.io).nanoseconds > deadline) return error.BrowserDidNotSettle;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    var run = Run{ .browser = b, .tab = b.activeTab().? };
    try run.tab.task_runner.schedule(tasks.Task.init(.user_input, "task:test_audio_controls", &run, Run.run, Run.cleanup));
    run.returned.waitUncancelable(std.testing.io);
    if (run.failure) |err| return err;
}
