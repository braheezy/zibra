//! Pure event-routing and native-window registry regressions.

const std = @import("std");
const sdl2 = @import("sdl");
const app = @import("../browser/app.zig");

fn keyboardEvent(
    tag: enum { down, up },
    window_id: u32,
    keycode: sdl2.Keycode,
    is_repeat: bool,
    key_modifiers: sdl2.KeyModifierSet,
) sdl2.Event {
    const payload = sdl2.KeyboardEvent{
        .timestamp = 0,
        .window_id = window_id,
        .key_state = if (tag == .down) .pressed else .released,
        .is_repeat = is_repeat,
        .scancode = .unknown,
        .keycode = keycode,
        .modifiers = key_modifiers,
    };
    return if (tag == .down)
        .{ .key_down = payload }
    else
        .{ .key_up = payload };
}

fn modifiers(bits: []const sdl2.KeyModifierBit) sdl2.KeyModifierSet {
    var result = sdl2.KeyModifierSet.fromNative(0);
    for (bits) |bit| result.set(bit);
    return result;
}

fn nativeEvent(event_type: u32, window_id: u32) sdl2.Event {
    var raw = std.mem.zeroes(sdl2.c.SDL_Event);
    switch (event_type) {
        sdl2.c.SDL_WINDOWEVENT => {
            raw.window.type = event_type;
            raw.window.windowID = window_id;
            raw.window.event = sdl2.c.SDL_WINDOWEVENT_SHOWN;
        },
        sdl2.c.SDL_TEXTEDITING => {
            raw.edit.type = event_type;
            raw.edit.windowID = window_id;
        },
        sdl2.c.SDL_TEXTINPUT => {
            raw.text.type = event_type;
            raw.text.windowID = window_id;
        },
        sdl2.c.SDL_MOUSEMOTION => {
            raw.motion.type = event_type;
            raw.motion.windowID = window_id;
        },
        sdl2.c.SDL_MOUSEBUTTONDOWN, sdl2.c.SDL_MOUSEBUTTONUP => {
            raw.button.type = event_type;
            raw.button.windowID = window_id;
            raw.button.button = sdl2.c.SDL_BUTTON_LEFT;
            raw.button.state = if (event_type == sdl2.c.SDL_MOUSEBUTTONDOWN)
                sdl2.c.SDL_PRESSED
            else
                sdl2.c.SDL_RELEASED;
        },
        sdl2.c.SDL_MOUSEWHEEL => {
            raw.wheel.type = event_type;
            raw.wheel.windowID = window_id;
            raw.wheel.direction = sdl2.c.SDL_MOUSEWHEEL_NORMAL;
        },
        else => unreachable,
    }
    return sdl2.Event.from(raw);
}

fn windowEvent(window_id: u32, window_event: u8) sdl2.Event {
    var raw = std.mem.zeroes(sdl2.c.SDL_Event);
    raw.window.type = sdl2.c.SDL_WINDOWEVENT;
    raw.window.windowID = window_id;
    raw.window.event = window_event;
    return sdl2.Event.from(raw);
}

fn quitEvent() sdl2.Event {
    var raw = std.mem.zeroes(sdl2.c.SDL_Event);
    raw.quit.type = sdl2.c.SDL_QUIT;
    return sdl2.Event.from(raw);
}

test "event routing extracts key window and text targets" {
    const empty_modifiers = modifiers(&.{});
    try std.testing.expectEqual(
        @as(?u32, 11),
        app.eventWindowId(keyboardEvent(.down, 11, .n, false, empty_modifiers)),
    );
    try std.testing.expectEqual(
        @as(?u32, 12),
        app.eventWindowId(keyboardEvent(.up, 12, .n, false, empty_modifiers)),
    );
    try std.testing.expectEqual(@as(?u32, 21), app.eventWindowId(nativeEvent(sdl2.c.SDL_WINDOWEVENT, 21)));
    try std.testing.expectEqual(@as(?u32, 31), app.eventWindowId(nativeEvent(sdl2.c.SDL_TEXTEDITING, 31)));
    try std.testing.expectEqual(@as(?u32, 32), app.eventWindowId(nativeEvent(sdl2.c.SDL_TEXTINPUT, 32)));
}

test "event routing extracts every mouse target" {
    try std.testing.expectEqual(@as(?u32, 41), app.eventWindowId(nativeEvent(sdl2.c.SDL_MOUSEMOTION, 41)));
    try std.testing.expectEqual(@as(?u32, 42), app.eventWindowId(nativeEvent(sdl2.c.SDL_MOUSEBUTTONDOWN, 42)));
    try std.testing.expectEqual(@as(?u32, 43), app.eventWindowId(nativeEvent(sdl2.c.SDL_MOUSEBUTTONUP, 43)));
    try std.testing.expectEqual(@as(?u32, 44), app.eventWindowId(nativeEvent(sdl2.c.SDL_MOUSEWHEEL, 44)));

    try std.testing.expectEqual(@as(?u32, null), app.eventWindowId(.{ .unsupported = 0xffff }));
    try std.testing.expectEqual(@as(?u32, null), app.eventWindowId(nativeEvent(sdl2.c.SDL_MOUSEMOTION, 0)));
}

test "Ctrl+N accepts either control key and ignores ambient lock state" {
    try std.testing.expect(app.isNewWindowShortcut(keyboardEvent(
        .down,
        1,
        .n,
        false,
        modifiers(&.{.left_control}),
    )));
    try std.testing.expect(app.isNewWindowShortcut(keyboardEvent(
        .down,
        1,
        .n,
        false,
        modifiers(&.{ .right_control, .caps_lock, .num_lock }),
    )));
}

test "Ctrl+N filters repeat release key and competing modifiers" {
    const ctrl = modifiers(&.{.left_control});
    try std.testing.expect(!app.isNewWindowShortcut(keyboardEvent(.down, 1, .n, true, ctrl)));
    try std.testing.expect(!app.isNewWindowShortcut(keyboardEvent(.up, 1, .n, false, ctrl)));
    try std.testing.expect(!app.isNewWindowShortcut(keyboardEvent(.down, 1, .m, false, ctrl)));
    try std.testing.expect(!app.isNewWindowShortcut(keyboardEvent(.down, 1, .n, false, modifiers(&.{}))));
    try std.testing.expect(!app.isNewWindowShortcut(keyboardEvent(
        .down,
        1,
        .n,
        false,
        modifiers(&.{ .left_control, .left_shift }),
    )));
    try std.testing.expect(!app.isNewWindowShortcut(keyboardEvent(
        .down,
        1,
        .n,
        false,
        modifiers(&.{ .left_control, .left_alt }),
    )));
    try std.testing.expect(!app.isNewWindowShortcut(keyboardEvent(
        .down,
        1,
        .n,
        false,
        modifiers(&.{ .left_control, .left_gui }),
    )));
}

test "event routing preserves targets for new close dispatch and Escape" {
    const ctrl = modifiers(&.{.left_control});
    try std.testing.expectEqualDeep(
        app.EventRoute{ .new_window = 71 },
        app.routeEvent(keyboardEvent(.down, 71, .n, false, ctrl)),
    );
    try std.testing.expectEqualDeep(
        app.EventRoute{ .close_window = 72 },
        app.routeEvent(windowEvent(72, sdl2.c.SDL_WINDOWEVENT_CLOSE)),
    );
    try std.testing.expectEqualDeep(
        app.EventRoute{ .dispatch = 73 },
        app.routeEvent(nativeEvent(sdl2.c.SDL_TEXTINPUT, 73)),
    );
    try std.testing.expectEqualDeep(
        app.EventRoute{ .dispatch = 74 },
        app.routeEvent(keyboardEvent(.down, 74, .escape, false, modifiers(&.{}))),
    );
    try std.testing.expectEqual(app.EventRoute.global_quit, app.routeEvent(quitEvent()));
    try std.testing.expectEqual(
        app.EventRoute.ignore,
        app.routeEvent(.{ .unsupported = 0xffff }),
    );
}

test "generation tracker publishes each shared-session change once" {
    const Url = @import("../network/url.zig").Url;
    const BrowserSession = @import("../browser/session_state.zig").BrowserSession;

    var session = BrowserSession.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    var tracker = app.GenerationTracker.init(&session);
    try std.testing.expectEqualDeep(app.GenerationChanges{}, tracker.poll(&session));

    var visited = try Url.init(std.testing.allocator, "https://example.com/visited");
    defer visited.free(std.testing.allocator);
    _ = try session.markVisited(&visited);
    try std.testing.expectEqualDeep(
        app.GenerationChanges{ .visited = true },
        tracker.poll(&session),
    );
    try std.testing.expectEqualDeep(app.GenerationChanges{}, tracker.poll(&session));

    _ = try session.toggleBookmark(&visited);
    try std.testing.expectEqualDeep(
        app.GenerationChanges{ .bookmarks = true },
        tracker.poll(&session),
    );
    try std.testing.expectEqualDeep(app.GenerationChanges{}, tracker.poll(&session));
}

test "generation changes refresh every window without cross-window aliasing" {
    const TestWindow = struct {
        visited_refreshes: usize = 0,
        bookmark_refreshes: usize = 0,

        fn refreshVisited(self: *@This()) void {
            self.visited_refreshes += 1;
        }

        fn refreshBookmarks(self: *@This()) void {
            self.bookmark_refreshes += 1;
        }
    };
    const Registry = app.WindowRegistry(TestWindow);

    var first = TestWindow{};
    var second = TestWindow{};
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.put(1, &first);
    try registry.put(2, &second);

    app.applyGenerationChanges(
        TestWindow,
        &registry,
        .{ .visited = true, .bookmarks = true },
        TestWindow.refreshVisited,
        TestWindow.refreshBookmarks,
    );
    try std.testing.expectEqual(@as(usize, 1), first.visited_refreshes);
    try std.testing.expectEqual(@as(usize, 1), second.visited_refreshes);
    try std.testing.expectEqual(@as(usize, 1), first.bookmark_refreshes);
    try std.testing.expectEqual(@as(usize, 1), second.bookmark_refreshes);

    app.applyGenerationChanges(
        TestWindow,
        &registry,
        .{},
        TestWindow.refreshVisited,
        TestWindow.refreshBookmarks,
    );
    try std.testing.expectEqual(@as(usize, 1), first.visited_refreshes);
    try std.testing.expectEqual(@as(usize, 1), second.bookmark_refreshes);
}

test "window registry looks up and removes one of two stable entries" {
    const BrowserSession = @import("../browser/session_state.zig").BrowserSession;
    const TestWindow = struct {
        marker: u8,
        session: *BrowserSession,
    };
    const Registry = app.WindowRegistry(TestWindow);

    var session = BrowserSession.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
    var first = TestWindow{ .marker = 1, .session = &session };
    var second = TestWindow{ .marker = 2, .session = &session };
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.put(101, &first);
    try registry.put(202, &second);
    try std.testing.expectEqual(@as(usize, 2), registry.count());
    try std.testing.expect(registry.get(101) == &first);
    try std.testing.expect(registry.get(202) == &second);
    try std.testing.expect(registry.get(101).?.session == registry.get(202).?.session);
    try std.testing.expect(registry.get(303) == null);

    const removed = registry.remove(101).?;
    try std.testing.expectEqual(@as(u32, 101), removed.window_id);
    try std.testing.expect(removed.window == &first);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expect(registry.get(101) == null);
    try std.testing.expect(registry.get(202) == &second);
    try std.testing.expect(registry.get(202).?.session == &session);
    try std.testing.expect(registry.remove(101) == null);

    try std.testing.expectError(error.DuplicateWindowId, registry.put(202, &first));
    try std.testing.expectError(error.InvalidWindowId, registry.put(0, &first));
}

test "owned close destroys only its target and reports the last window" {
    const TestWindow = struct {
        deinit_count: *usize,

        fn deinit(self: *@This()) void {
            self.deinit_count.* += 1;
        }
    };
    const Registry = app.WindowRegistry(TestWindow);

    var deinit_count: usize = 0;
    const first = try std.testing.allocator.create(TestWindow);
    first.* = .{ .deinit_count = &deinit_count };
    const second = try std.testing.allocator.create(TestWindow);
    second.* = .{ .deinit_count = &deinit_count };
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.put(10, first);
    try registry.put(20, second);

    try std.testing.expectEqual(
        app.CloseResult.remaining,
        app.closeOwnedWindow(TestWindow, std.testing.allocator, &registry, 10, TestWindow.deinit),
    );
    try std.testing.expectEqual(@as(usize, 1), deinit_count);
    try std.testing.expect(registry.get(10) == null);
    try std.testing.expect(registry.get(20) == second);

    try std.testing.expectEqual(
        app.CloseResult.unknown,
        app.closeOwnedWindow(TestWindow, std.testing.allocator, &registry, 10, TestWindow.deinit),
    );
    try std.testing.expectEqual(@as(usize, 1), deinit_count);

    try std.testing.expectEqual(
        app.CloseResult.last,
        app.closeOwnedWindow(TestWindow, std.testing.allocator, &registry, 20, TestWindow.deinit),
    );
    try std.testing.expectEqual(@as(usize, 2), deinit_count);
    try std.testing.expectEqual(@as(usize, 0), registry.count());
}
