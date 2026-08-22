//! Process-level owner and SDL event router for native browser windows.
//!
//! `BrowserApp` keeps every `Browser` at a stable heap address while the
//! generic registry moves only borrowed pointers as the native-window set
//! grows and shrinks.

const std = @import("std");
const sdl2 = @import("sdl");
const Browser = @import("root.zig").Browser;
const BrowserSession = @import("session_state.zig").BrowserSession;
const MeasureTime = @import("../runtime/measure_time.zig").MeasureTime;
const Url = @import("../network/url.zig").Url;

/// Return the native window targeted by an SDL event, or null for process-wide
/// events and SDL's sentinel window id zero.
pub fn eventWindowId(event: sdl2.Event) ?u32 {
    const window_id = switch (event) {
        .window => |window_event| window_event.window_id,
        .key_down, .key_up => |key_event| key_event.window_id,
        .text_editing => |text_event| text_event.windowID,
        .text_input => |text_event| text_event.windowID,
        .mouse_motion => |motion_event| motion_event.window_id,
        .mouse_button_down, .mouse_button_up => |button_event| button_event.window_id,
        .mouse_wheel => |wheel_event| wheel_event.window_id,
        .finger_down, .finger_up, .finger_motion => |finger_event| finger_event.windowID,
        .drop_file, .drop_text, .drop_begin, .drop_complete => |drop_event| drop_event.windowID,
        .user => |user_event| user_event.window_id,
        else => return null,
    };
    return if (window_id == 0) null else window_id;
}

/// Recognize the process-level shortcut for creating one native window.
///
/// Key-repeat events are ignored so holding the chord creates only one window.
/// Shift, Alt/Option, GUI/Command, and AltGr's mode modifier are reserved for
/// distinct shortcuts. Ambient lock modifiers do not suppress Ctrl+N.
pub fn isNewWindowShortcut(event: sdl2.Event) bool {
    const key_event = switch (event) {
        .key_down => |value| value,
        else => return false,
    };
    if (key_event.is_repeat or key_event.keycode != .n) return false;

    const modifiers = key_event.modifiers;
    const has_control = modifiers.get(.left_control) or modifiers.get(.right_control);
    const has_reserved_modifier = modifiers.get(.left_shift) or
        modifiers.get(.right_shift) or
        modifiers.get(.left_alt) or
        modifiers.get(.right_alt) or
        modifiers.get(.left_gui) or
        modifiers.get(.right_gui) or
        modifiers.get(.mode);
    return has_control and !has_reserved_modifier;
}

pub const EventRoute = union(enum) {
    global_quit,
    new_window: u32,
    close_window: u32,
    dispatch: u32,
    ignore,
};

/// Classify an SDL event before consulting the live window registry. SDL quit
/// is process-wide; every window-targeted action (including Escape) retains
/// its native id so BrowserApp can ignore events queued for a destroyed
/// window. A live Browser still interprets Escape as a global quit request.
pub fn routeEvent(event: sdl2.Event) EventRoute {
    switch (event) {
        .quit => return .global_quit,
        else => {},
    }

    const window_id = eventWindowId(event) orelse return .ignore;
    if (isNewWindowShortcut(event)) return .{ .new_window = window_id };
    switch (event) {
        .window => |window_event| switch (window_event.type) {
            .close => return .{ .close_window = window_id },
            else => {},
        },
        else => {},
    }
    return .{ .dispatch = window_id };
}

pub const GenerationChanges = struct {
    visited: bool = false,
    bookmarks: bool = false,
};

/// App-main-thread cursor over lock-free session generation publication.
pub const GenerationTracker = struct {
    visited: u64,
    bookmarks: u64,

    pub fn init(session: *const BrowserSession) GenerationTracker {
        return .{
            .visited = session.currentVisitedGeneration(),
            .bookmarks = session.currentBookmarkGeneration(),
        };
    }

    pub fn poll(self: *GenerationTracker, session: *const BrowserSession) GenerationChanges {
        const visited = session.currentVisitedGeneration();
        const bookmarks = session.currentBookmarkGeneration();
        const changes = GenerationChanges{
            .visited = visited != self.visited,
            .bookmarks = bookmarks != self.bookmarks,
        };
        self.visited = visited;
        self.bookmarks = bookmarks;
        return changes;
    }
};

/// Fan one generation publication out to every live window. The caller polls
/// BrowserSession before entering this helper, so neither callback runs with a
/// session lock held.
pub fn applyGenerationChanges(
    comptime Window: type,
    registry: *const WindowRegistry(Window),
    changes: GenerationChanges,
    visited_fn: *const fn (*Window) void,
    bookmarks_fn: *const fn (*Window) void,
) void {
    if (!changes.visited and !changes.bookmarks) return;
    for (registry.entries.items) |entry| {
        if (changes.visited) visited_fn(entry.window);
        if (changes.bookmarks) bookmarks_fn(entry.window);
    }
}

/// One registry record. The pointed-to window is borrowed and must remain at a
/// stable address until its entry is removed.
pub fn WindowEntry(comptime Window: type) type {
    return struct {
        window_id: u32,
        window: *Window,
    };
}

/// A small, non-owning registry for the window set in `BrowserApp`. Removing
/// or deinitializing the registry never destroys the pointed-to windows; the
/// app owner remains responsible for their shutdown.
pub fn WindowRegistry(comptime Window: type) type {
    return struct {
        const Self = @This();
        pub const Entry = WindowEntry(Window);

        allocator: std.mem.Allocator,
        entries: std.ArrayList(Entry) = .empty,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.entries.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn put(self: *Self, window_id: u32, window: *Window) !void {
            if (window_id == 0) return error.InvalidWindowId;
            if (self.get(window_id) != null) return error.DuplicateWindowId;
            try self.entries.append(self.allocator, .{
                .window_id = window_id,
                .window = window,
            });
        }

        pub fn get(self: *const Self, window_id: u32) ?*Window {
            for (self.entries.items) |entry| {
                if (entry.window_id == window_id) return entry.window;
            }
            return null;
        }

        pub fn remove(self: *Self, window_id: u32) ?Entry {
            for (self.entries.items, 0..) |entry, index| {
                if (entry.window_id == window_id) return self.entries.orderedRemove(index);
            }
            return null;
        }

        pub fn count(self: *const Self) usize {
            return self.entries.items.len;
        }
    };
}

pub const CloseResult = enum {
    unknown,
    remaining,
    last,
};

/// Remove one registry entry before running its destructor, then free exactly
/// that heap-stable window. Removing first ensures reentrant/stale events can
/// no longer resolve an object whose native handle is being destroyed.
pub fn closeOwnedWindow(
    comptime Window: type,
    allocator: std.mem.Allocator,
    registry: *WindowRegistry(Window),
    window_id: u32,
    deinit_fn: *const fn (*Window) void,
) CloseResult {
    const entry = registry.remove(window_id) orelse return .unknown;
    deinit_fn(entry.window);
    allocator.destroy(entry.window);
    return if (registry.count() == 0) .last else .remaining;
}

fn deinitBrowser(browser: *Browser) void {
    browser.deinit();
}

fn requestBrowserVisitedRefresh(browser: *Browser) void {
    browser.requestVisitedGenerationRefresh();
}

fn requestBrowserBookmarkRefresh(browser: *Browser) void {
    browser.requestBookmarkGenerationRefresh();
}

/// Process owner for native-window Browser instances and shared services.
/// Browser pointers are heap-stable; registry growth moves only borrowed
/// pointers. SDL polling and text input remain exclusively on this owner.
pub const BrowserApp = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    rtl_flag: bool,
    session_state: *BrowserSession,
    measure: *MeasureTime,
    windows: WindowRegistry(Browser),
    generations: GenerationTracker,
    quit_requested: bool = false,
    owns_sdl: bool = true,
    owns_text_input: bool = true,
    owns_ttf_guard: bool = true,
    owns_session: bool = true,
    owns_measure: bool = true,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        rtl_flag: bool,
    ) !*BrowserApp {
        try sdl2.init(.{ .video = true });
        errdefer sdl2.quit();

        // FontManager pairs one SDL_ttf reference per window. This App-owned
        // guard keeps TTF initialized while any window may be closing, and is
        // released only after every per-window FontManager has been destroyed.
        try sdl2.ttf.init();
        errdefer sdl2.ttf.quit();

        sdl2.startTextInput();
        errdefer sdl2.stopTextInput();

        const session = try allocator.create(BrowserSession);
        errdefer allocator.destroy(session);
        session.* = BrowserSession.init(allocator, io);
        errdefer session.deinit();

        const measure = try allocator.create(MeasureTime);
        errdefer allocator.destroy(measure);
        measure.* = try MeasureTime.init(allocator, io, environ);
        errdefer measure.finish();

        const app = try allocator.create(BrowserApp);
        errdefer allocator.destroy(app);
        app.* = .{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .rtl_flag = rtl_flag,
            .session_state = session,
            .measure = measure,
            .windows = WindowRegistry(Browser).init(allocator),
            .generations = GenerationTracker.init(session),
        };
        return app;
    }

    pub fn deinit(self: *BrowserApp) void {
        while (self.windows.entries.items.len > 0) {
            const window_id = self.windows.entries.items[0].window_id;
            _ = self.closeWindow(window_id);
        }
        self.windows.deinit();

        if (self.owns_session) {
            self.session_state.deinit();
            self.allocator.destroy(self.session_state);
            self.owns_session = false;
        }
        if (self.owns_measure) {
            self.measure.finish();
            self.allocator.destroy(self.measure);
            self.owns_measure = false;
        }
        if (self.owns_text_input) {
            sdl2.stopTextInput();
            self.owns_text_input = false;
        }
        if (self.owns_ttf_guard) {
            sdl2.ttf.quit();
            self.owns_ttf_guard = false;
        }
        if (self.owns_sdl) {
            sdl2.quit();
            self.owns_sdl = false;
        }
    }

    /// Consume `url`, including on every failure after entry.
    pub fn newWindow(self: *BrowserApp, url: Url) !u32 {
        var owned_url = url;
        var url_owned = true;
        defer if (url_owned) owned_url.free(self.allocator);

        const browser = try Browser.initAppWindow(
            self.allocator,
            self.io,
            self.environ,
            self.rtl_flag,
            self.session_state,
            self.measure,
        );
        var browser_owned = true;
        defer if (browser_owned) {
            browser.deinit();
            self.allocator.destroy(browser);
        };

        // Browser.newTab consumes its Url on entry, including failure.
        url_owned = false;
        try browser.newTab(owned_url);

        const window_id = try browser.windowId();
        try self.windows.put(window_id, browser);
        browser_owned = false;
        browser.scheduleAnimationFrame();
        return window_id;
    }

    pub fn newBlankWindow(self: *BrowserApp) !u32 {
        const blank = try Url.blank(self.allocator);
        return self.newWindow(blank);
    }

    /// Close exactly one addressed native window. Unknown ids are harmless;
    /// removing the last live window requests process-loop termination.
    pub fn closeWindow(self: *BrowserApp, window_id: u32) bool {
        return switch (closeOwnedWindow(
            Browser,
            self.allocator,
            &self.windows,
            window_id,
            deinitBrowser,
        )) {
            .unknown => false,
            .remaining => true,
            .last => blk: {
                self.quit_requested = true;
                break :blk true;
            },
        };
    }

    pub fn browserForWindowId(self: *const BrowserApp, window_id: u32) ?*Browser {
        return self.windows.get(window_id);
    }

    pub fn windowCount(self: *const BrowserApp) usize {
        return self.windows.count();
    }

    /// Poll generations without any Browser lock held, then touch each window
    /// independently. This deliberately avoids Session-lock/Browser-lock
    /// nesting in either direction.
    pub fn broadcastSessionChanges(self: *BrowserApp) GenerationChanges {
        const changes = self.generations.poll(self.session_state);
        if (!changes.visited and !changes.bookmarks) return changes;

        applyGenerationChanges(
            Browser,
            &self.windows,
            changes,
            requestBrowserVisitedRefresh,
            requestBrowserBookmarkRefresh,
        );
        return changes;
    }

    pub fn dispatchEvent(self: *BrowserApp, event: sdl2.Event) !void {
        switch (routeEvent(event)) {
            .global_quit => self.quit_requested = true,
            .new_window => |source_window_id| {
                // A queued key event from a closed window must not create a
                // replacement window.
                if (self.windows.get(source_window_id) == null) return;
                _ = self.newBlankWindow() catch |err| {
                    // Creating an additional window is a user gesture. Keep
                    // existing windows alive when that request cannot be
                    // satisfied (for example after an allocation failure).
                    std.log.err("Unable to create browser window: {}", .{err});
                    return;
                };
            },
            .close_window => |window_id| _ = self.closeWindow(window_id),
            .dispatch => |window_id| {
                const browser = self.windows.get(window_id) orelse return;
                if (try browser.handleEvent(event)) self.quit_requested = true;
            },
            .ignore => {},
        }
    }

    pub fn run(self: *BrowserApp) !void {
        if (self.windows.count() == 0) return error.BrowserAppRequiresWindow;

        while (!self.quit_requested and self.windows.count() > 0) {
            var handled_event = false;
            if (sdl2.waitEventTimeout(17)) |event| {
                handled_event = true;
                try self.dispatchEvent(event);
                while (!self.quit_requested) {
                    const extra_event = sdl2.pollEvent() orelse break;
                    handled_event = true;
                    try self.dispatchEvent(extra_event);
                }
            }

            if (self.quit_requested or self.windows.count() == 0) break;
            _ = self.broadcastSessionChanges();

            var all_idle = true;
            for (self.windows.entries.items) |entry| {
                if (!try entry.window.tick()) all_idle = false;
            }

            if (!handled_event and all_idle) {
                try self.io.sleep(.fromNanoseconds(2_000_000), .awake);
            }
        }
    }
};
