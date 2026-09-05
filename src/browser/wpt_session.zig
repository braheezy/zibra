//! One-test headless Web Platform Tests session ownership.
//!
//! A `Session` owns one standalone headless Browser and a heap-stable result
//! mailbox. The page's JavaScript report callback runs on the serialized Tab
//! worker, so it only copies its callback-scoped JSON into a pending candidate
//! with the thread-safe SMP allocator. The Session thread promotes that
//! candidate after the reporting Tab's serialized work returns and its queue
//! is empty, then later performs normal Browser teardown. This keeps worker
//! joins off the Tab worker and lets Tab shutdown interrupt long-running
//! JavaScript before any borrowed owner retires.

const std = @import("std");

const browser_module = @import("root.zig");
const Browser = browser_module.Browser;
const Tab = @import("tab.zig").Tab;
const js_module = @import("../script/js.zig");
const Url = @import("../network/url.zig").Url;
const Mutex = @import("../runtime/sync.zig").Mutex;

const result_allocator = std.heap.smp_allocator;
const poll_interval_ns: i96 = 2 * std.time.ns_per_ms;
const malformed_report_json =
    "{\"status\":\"ERROR\",\"harness\":{\"status\":\"ERROR\",\"code\":1,\"message\":\"Malformed WPT report callback payload\",\"stack\":null},\"tests\":[],\"message\":\"Malformed WPT report callback payload\"}";
const drive_error_json =
    "{\"status\":\"ERROR\",\"harness\":{\"status\":\"ERROR\",\"code\":1,\"message\":\"WPT browser drive failed\",\"stack\":null},\"tests\":[],\"message\":\"WPT browser drive failed\"}";

pub const Status = enum {
    pass,
    fail,
    error_result,
    timeout,

    pub fn jsonName(self: Status) []const u8 {
        return switch (self) {
            .pass => "PASS",
            .fail => "FAIL",
            .error_result => "ERROR",
            .timeout => "TIMEOUT",
        };
    }

    fn fromJsonName(value: []const u8) ?Status {
        if (std.mem.eql(u8, value, "PASS")) return .pass;
        if (std.mem.eql(u8, value, "FAIL")) return .fail;
        if (std.mem.eql(u8, value, "ERROR")) return .error_result;
        if (std.mem.eql(u8, value, "TIMEOUT")) return .timeout;
        return null;
    }
};

/// An independently owned terminal result. Its payload is the complete
/// harness report JSON, or an empty slice for a session-generated timeout.
pub const Result = struct {
    allocator: std.mem.Allocator,
    status: Status,
    payload: []u8,
    duration_ms: u64,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.payload);
        self.* = undefined;
    }
};

pub const Options = struct {
    timeout_ms: u64,
    rtl: bool = false,
};

const Candidate = struct {
    status: Status,
    payload: []u8,
};

const Terminal = struct {
    status: Status,
    payload: []u8,
    completed_ns: i96,
};

/// The mutex protects a two-stage result handoff. The first JavaScript report
/// owns `candidate`; only the Session thread may promote it to `terminal` once
/// the reporting task and its current serialized queue are idle. A deadline or
/// infrastructure failure may publish a terminal value first and retire the
/// pending candidate. `sealed` remains true after `takeResult` moves the value
/// to its caller, so no later callback can publish another result.
const Mailbox = struct {
    allocator: std.mem.Allocator,
    mutex: Mutex,
    candidate: ?Candidate = null,
    report_received: bool = false,
    terminal: ?Terminal = null,
    sealed: bool = false,

    fn init(io: std.Io, allocator: std.mem.Allocator) Mailbox {
        return .{
            .allocator = allocator,
            .mutex = .init(io),
        };
    }

    fn deinit(self: *Mailbox) void {
        self.mutex.lock();
        if (self.candidate) |candidate| self.allocator.free(candidate.payload);
        if (self.terminal) |terminal| self.allocator.free(terminal.payload);
        self.candidate = null;
        self.terminal = null;
        self.sealed = true;
        self.mutex.unlock();
    }

    /// Copy the first callback-scoped report without making it terminal. The
    /// reporting Tab task still owns JavaScript execution until it returns.
    fn copyCandidate(
        self: *Mailbox,
        status: Status,
        payload: []const u8,
    ) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.sealed or self.report_received) return false;

        const owned_payload = try self.allocator.dupe(u8, payload);
        self.candidate = .{
            .status = status,
            .payload = owned_payload,
        };
        self.report_received = true;
        return true;
    }

    fn hasCandidate(self: *Mailbox) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.candidate != null and !self.sealed;
    }

    /// Publish a non-page terminal result. This wins over and retires an
    /// undrained candidate, while an already promoted terminal remains first.
    fn publishTerminal(
        self: *Mailbox,
        status: Status,
        payload: []const u8,
        completed_ns: i96,
    ) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.publishTerminalLocked(status, payload, completed_ns);
    }

    /// Resolve one Session-thread observation. Deadline always precedes
    /// candidate promotion; before the deadline, a candidate becomes terminal
    /// only after the reporting Tab's serialized worker and current queue are
    /// idle. This is a task-return barrier, not a full Kiesel microtask drain.
    fn settle(
        self: *Mailbox,
        serialized_work_idle: bool,
        now_ns: i96,
        deadline_ns: i96,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.sealed) return;

        if (now_ns >= deadline_ns) {
            _ = try self.publishTerminalLocked(.timeout, "", deadline_ns);
            return;
        }
        if (!serialized_work_idle) return;

        const candidate = self.candidate orelse return;
        self.candidate = null;
        self.terminal = .{
            .status = candidate.status,
            .payload = candidate.payload,
            .completed_ns = now_ns,
        };
        self.sealed = true;
    }

    fn publishTerminalLocked(
        self: *Mailbox,
        status: Status,
        payload: []const u8,
        completed_ns: i96,
    ) !bool {
        if (self.sealed) return false;

        const owned_payload = try self.allocator.dupe(u8, payload);
        if (self.candidate) |candidate| self.allocator.free(candidate.payload);
        self.candidate = null;
        self.terminal = .{
            .status = status,
            .payload = owned_payload,
            .completed_ns = completed_ns,
        };
        self.sealed = true;
        return true;
    }

    fn takeResult(self: *Mailbox, started_ns: i96) ?Result {
        self.mutex.lock();
        defer self.mutex.unlock();
        const terminal = self.terminal orelse return null;
        self.terminal = null;

        const duration_ns = @max(terminal.completed_ns - started_ns, 0);
        return .{
            .allocator = self.allocator,
            .status = terminal.status,
            .payload = terminal.payload,
            .duration_ms = @intCast(@divFloor(duration_ns, std.time.ns_per_ms)),
        };
    }
};

/// Heap-stable owner of one standalone Browser and one result mailbox.
///
/// `init` consumes `url`, including on failure. The returned pointer must not
/// move: the top-level WindowRealm retains it as a callback context until
/// Browser teardown clears that Realm. Call `deinit` on the creating thread,
/// then destroy the Session allocation with the allocator passed to `init`.
pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    browser: ?*Browser,
    reporting_tab: ?*Tab,
    mailbox: Mailbox,
    owner_thread: std.Thread.Id,
    started_ns: i96,
    deadline_ns: i96,
    run_started: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        url: Url,
        options: Options,
    ) !*Session {
        var owned_url = url;
        var owns_url = true;
        defer if (owns_url) owned_url.free(allocator);

        if (options.timeout_ms == 0) return error.InvalidWptTimeout;

        const self = try allocator.create(Session);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .browser = null,
            .reporting_tab = null,
            .mailbox = Mailbox.init(io, result_allocator),
            .owner_thread = std.Thread.getCurrentId(),
            .started_ns = 0,
            .deadline_ns = 0,
        };
        errdefer {
            self.mailbox.deinit();
            allocator.destroy(self);
        }

        const browser = try Browser.init(allocator, io, environ, options.rtl, true);
        errdefer {
            browser.deinit();
            allocator.destroy(browser);
        }
        self.browser = browser;

        // Configuration precedes newTab so the top-level Realm receives the
        // callback immediately after setNodes and before its first parser
        // script can execute.
        browser.setTopLevelRealmObserver(installRealmBridge, @ptrCast(self));

        self.started_ns = std.Io.Clock.awake.now(io).nanoseconds;
        std.log.info("ZIBRA_WPT_DIAGNOSTIC {{\"kind\":\"session-started\"}}", .{});
        const timeout_ns: i96 = @as(i96, @intCast(options.timeout_ms)) * std.time.ns_per_ms;
        self.deadline_ns = self.started_ns + timeout_ns;

        // Browser.newTab consumes the URL even if tab creation or scheduling
        // fails, so ownership moves before entering the call.
        owns_url = false;
        try browser.newTab(owned_url);
        self.reporting_tab = browser.activeTab() orelse return error.MissingWptTab;
        return self;
    }

    /// Drive the ordinary headless Browser pipeline until the page publishes
    /// an explicit harness report or the monotonic per-test deadline wins.
    /// This is one-shot and must run on the thread that created the Session.
    pub fn run(self: *Session) !Result {
        self.assertOwnerThread();
        if (self.run_started) return error.WptSessionAlreadyRun;
        self.run_started = true;

        const browser = self.browser orelse return error.WptSessionDeinitialized;
        _ = self.reporting_tab orelse return error.MissingWptTab;
        while (true) {
            try self.settleCompletion();
            if (self.mailbox.takeResult(self.started_ns)) |result| return result;

            // tick starts serialized Tab work and consumes committed render
            // state without using load/render idleness as test completion.
            _ = browser.tick() catch |err| {
                std.log.err("WPT Browser.tick failed: {}", .{err});
                const now_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
                try self.publishTerminal(.error_result, drive_error_json, now_ns);
                continue;
            };
            try self.settleCompletion();
            if (self.mailbox.takeResult(self.started_ns)) |result| return result;

            var now_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
            if (now_ns >= self.deadline_ns) continue;
            const remaining_ns = self.deadline_ns - now_ns;
            const sleep_ns = @min(remaining_ns, poll_interval_ns);
            self.io.sleep(.fromNanoseconds(@intCast(sleep_ns)), .awake) catch |err| {
                std.log.err("WPT session sleep failed: {}", .{err});
                now_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
                try self.publishTerminal(.error_result, drive_error_json, now_ns);
            };
        }
    }

    /// Join and destroy all Browser-owned workers while the callback mailbox
    /// and its Session context are still alive. Safe after a returned result;
    /// any later duplicate report observes a sealed mailbox and is ignored.
    pub fn deinit(self: *Session) void {
        self.assertOwnerThread();
        if (self.browser) |browser| {
            browser.deinit();
            self.allocator.destroy(browser);
            self.browser = null;
            self.reporting_tab = null;
        }
        self.mailbox.deinit();
    }

    fn assertOwnerThread(self: *const Session) void {
        std.debug.assert(self.owner_thread == std.Thread.getCurrentId());
    }

    fn reportCallback(context: ?*anyopaque, report_json: []const u8) anyerror!void {
        const raw = context orelse return error.MissingWptSession;
        const unaligned: *align(1) Session = @ptrCast(raw);
        const self: *Session = @alignCast(unaligned);

        const inspection = inspectReport(report_json);
        const payload = if (inspection.retain_payload) report_json else malformed_report_json;
        _ = try self.mailbox.copyCandidate(inspection.status, payload);
    }

    fn installRealmBridge(
        context: ?*anyopaque,
        js_context: *js_module,
        window_id: u32,
    ) void {
        js_context.setWptReportCallback(window_id, reportCallback, context);
    }

    /// Promote a copied report only after the Tab worker has returned from the
    /// reporting callback and its current serialized queue is empty. This does
    /// not yet prove that Kiesel has drained every promise/microtask job.
    fn settleCompletion(self: *Session) !void {
        const tab = self.reporting_tab orelse return error.MissingWptTab;
        // Sample idleness only after observing a candidate. Otherwise a report
        // could arrive after an idle=true sample and be promoted from that
        // stale observation while its reporting task was still active.
        const serialized_work_idle = self.mailbox.hasCandidate() and
            tab.serializedWorkIdle();
        const now_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        try self.mailbox.settle(
            serialized_work_idle,
            now_ns,
            self.deadline_ns,
        );
    }

    /// Resolve a non-page failure at its producer timestamp. Once the session
    /// deadline has elapsed, timeout remains the semantic terminal result.
    fn publishTerminal(
        self: *Session,
        status: Status,
        payload: []const u8,
        completed_ns: i96,
    ) !void {
        const deadline_won = completed_ns >= self.deadline_ns;
        _ = try self.mailbox.publishTerminal(
            if (deadline_won) .timeout else status,
            if (deadline_won) "" else payload,
            if (deadline_won) self.deadline_ns else completed_ns,
        );
    }
};

const ReportInspection = struct {
    status: Status,
    retain_payload: bool,
};

fn inspectReport(report_json: []const u8) ReportInspection {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        result_allocator,
        report_json,
        .{},
    ) catch return .{ .status = .error_result, .retain_payload = false };
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |*object| object,
        else => return .{ .status = .error_result, .retain_payload = false },
    };
    const status_value = object.getPtr("status") orelse
        return .{ .status = .error_result, .retain_payload = false };
    const status_name = switch (status_value.*) {
        .string => |name| name,
        else => return .{ .status = .error_result, .retain_payload = false },
    };
    const status = Status.fromJsonName(status_name) orelse
        return .{ .status = .error_result, .retain_payload = false };

    const tests = object.getPtr("tests") orelse
        return .{ .status = .error_result, .retain_payload = false };
    switch (tests.*) {
        .array => {},
        else => return .{ .status = .error_result, .retain_payload = false },
    }
    const harness = object.getPtr("harness") orelse
        return .{ .status = .error_result, .retain_payload = false };
    switch (harness.*) {
        .object => {},
        else => return .{ .status = .error_result, .retain_payload = false },
    }

    if (object.getPtr("message")) |message| switch (message.*) {
        .string, .null => {},
        else => return .{ .status = .error_result, .retain_payload = false },
    };
    if (object.getPtr("console")) |console| switch (console.*) {
        .array => {},
        else => return .{ .status = .error_result, .retain_payload = false },
    };
    if (object.getPtr("exception")) |exception| switch (exception.*) {
        .object, .null => {},
        else => return .{ .status = .error_result, .retain_payload = false },
    };
    return .{
        .status = status,
        .retain_payload = true,
    };
}

test "WPT mailbox copies one candidate and promotes it only after serialized idle" {
    var mailbox = Mailbox.init(std.testing.io, std.testing.allocator);
    defer mailbox.deinit();

    var source = [_]u8{ '{', '"', 's', 't', 'a', 't', 'u', 's', '"', ':', '"', 'P', 'A', 'S', 'S', '"', '}' };
    try std.testing.expect(try mailbox.copyCandidate(.pass, &source));
    @memset(&source, 'x');
    try std.testing.expect(!(try mailbox.copyCandidate(.fail, "later")));
    try std.testing.expect(mailbox.takeResult(0) == null);

    try mailbox.settle(false, 10 * std.time.ns_per_ms, 20 * std.time.ns_per_ms);
    try std.testing.expect(mailbox.takeResult(0) == null);
    try mailbox.settle(true, 12 * std.time.ns_per_ms, 20 * std.time.ns_per_ms);

    var result = mailbox.takeResult(4 * std.time.ns_per_ms) orelse return error.MissingWptResult;
    defer result.deinit();
    try std.testing.expectEqual(Status.pass, result.status);
    try std.testing.expectEqualStrings("{\"status\":\"PASS\"}", result.payload);
    try std.testing.expectEqual(@as(u64, 8), result.duration_ms);
    try std.testing.expect(mailbox.takeResult(0) == null);
    try std.testing.expect(!(try mailbox.copyCandidate(.error_result, "duplicate")));
    try std.testing.expect(!(try mailbox.publishTerminal(.error_result, "duplicate", 13 * std.time.ns_per_ms)));
}

test "WPT mailbox resolves competing publishers exactly once" {
    const Context = struct {
        io: std.Io,
        mailbox: *Mailbox,
        ready: *std.Io.Semaphore,
        release: *std.Io.Semaphore,
        status: Status,
        payload: []const u8,
        accepted: *std.atomic.Value(usize),

        fn run(self: *@This()) void {
            self.ready.post(self.io);
            self.release.waitUncancelable(self.io);
            const published = self.mailbox.copyCandidate(
                self.status,
                self.payload,
            ) catch false;
            if (published) _ = self.accepted.fetchAdd(1, .monotonic);
        }
    };

    var mailbox = Mailbox.init(std.testing.io, result_allocator);
    defer mailbox.deinit();
    var ready: std.Io.Semaphore = .{};
    var release: std.Io.Semaphore = .{};
    var accepted = std.atomic.Value(usize).init(0);
    var first = Context{
        .io = std.testing.io,
        .mailbox = &mailbox,
        .ready = &ready,
        .release = &release,
        .status = .pass,
        .payload = "first",
        .accepted = &accepted,
    };
    var second = Context{
        .io = std.testing.io,
        .mailbox = &mailbox,
        .ready = &ready,
        .release = &release,
        .status = .timeout,
        .payload = "second",
        .accepted = &accepted,
    };

    const first_thread = try std.Thread.spawn(.{}, Context.run, .{&first});
    var first_joined = false;
    errdefer if (!first_joined) {
        release.post(std.testing.io);
        first_thread.join();
    };
    const second_thread = try std.Thread.spawn(.{}, Context.run, .{&second});
    ready.waitUncancelable(std.testing.io);
    ready.waitUncancelable(std.testing.io);
    release.post(std.testing.io);
    release.post(std.testing.io);
    first_thread.join();
    first_joined = true;
    second_thread.join();

    try std.testing.expectEqual(@as(usize, 1), accepted.load(.monotonic));
    try std.testing.expect(mailbox.takeResult(0) == null);
    try mailbox.settle(true, 9 * std.time.ns_per_ms, 20 * std.time.ns_per_ms);
    var result = mailbox.takeResult(0) orelse return error.MissingWptResult;
    defer result.deinit();
    const coherent_first = result.status == .pass and std.mem.eql(u8, result.payload, "first");
    const coherent_second = result.status == .timeout and std.mem.eql(u8, result.payload, "second");
    try std.testing.expect(coherent_first or coherent_second);
}

test "WPT deadline overrides an undrained report candidate" {
    var mailbox = Mailbox.init(std.testing.io, std.testing.allocator);
    defer mailbox.deinit();

    try std.testing.expect(try mailbox.copyCandidate(
        .pass,
        "{\"status\":\"PASS\",\"harness\":{},\"tests\":[]}",
    ));
    try mailbox.settle(false, 10 * std.time.ns_per_ms, 10 * std.time.ns_per_ms);
    var result = mailbox.takeResult(0) orelse return error.MissingWptResult;
    defer result.deinit();
    try std.testing.expectEqual(Status.timeout, result.status);
    try std.testing.expectEqualStrings("", result.payload);
    try std.testing.expectEqual(@as(u64, 10), result.duration_ms);
    try mailbox.settle(true, 11 * std.time.ns_per_ms, 10 * std.time.ns_per_ms);
    try std.testing.expect(mailbox.takeResult(0) == null);
}

test "WPT report status parsing fails closed" {
    const pass = inspectReport(
        "{\"status\":\"PASS\",\"harness\":{\"status\":\"OK\"},\"tests\":[]}",
    );
    try std.testing.expectEqual(Status.pass, pass.status);
    try std.testing.expect(pass.retain_payload);

    const fail = inspectReport(
        "{\"status\":\"FAIL\",\"harness\":{\"status\":\"OK\"},\"tests\":[{}]}",
    );
    try std.testing.expectEqual(Status.fail, fail.status);
    try std.testing.expect(fail.retain_payload);

    const invalid_tests = inspectReport(
        "{\"status\":\"PASS\",\"harness\":{},\"tests\":\"not an array\"}",
    );
    try std.testing.expectEqual(Status.error_result, invalid_tests.status);
    try std.testing.expect(!invalid_tests.retain_payload);

    const unknown = inspectReport("{\"status\":\"UNKNOWN\"}");
    try std.testing.expectEqual(Status.error_result, unknown.status);
    try std.testing.expect(!unknown.retain_payload);

    const malformed = inspectReport("not json");
    try std.testing.expectEqual(Status.error_result, malformed.status);
    try std.testing.expect(!malformed.retain_payload);
}
