//! Browser-session resource and navigation loading.
//!
//! `Loader` is embedded in one heap-stable `Browser` but depends only on the
//! shared `BrowserSession`, allocator, and I/O. Network task contexts borrow
//! the Loader synchronously: callers wait on their completion semaphore before
//! returning, while linked-resource transport workers are joined before their
//! source-ordered `Batch` is consumed or destroyed.

const std = @import("std");

const navigation = @import("navigation.zig");
const BrowserSession = @import("session_state.zig").BrowserSession;
const url_module = @import("../network/url.zig");
const task_module = @import("../runtime/task.zig");
const thread_batch = @import("../runtime/thread_batch.zig");
const Node = @import("../document/parser.zig").Node;

const Task = task_module.Task;
const Url = url_module.Url;

pub const NavigationDocument = navigation.NavigationDocument;

pub const Kind = enum {
    script,
    stylesheet,
};

/// One resolved classic script or stylesheet request. The DOM node is only a
/// source-order identity used after `Batch.runAndJoin` has joined every worker.
pub const Fetch = struct {
    loader: *Loader,
    node: *Node,
    kind: Kind,
    resource_url: Url,
    referrer_url: Url,
    referrer_policy: url_module.ReferrerPolicy,
    response: ?url_module.HttpResponse = null,
    fetch_error: ?anyerror = null,

    fn runOpaque(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.response = self.loader.fetchBodyDirect(
            self.resource_url,
            self.referrer_url,
            null,
            self.referrer_policy,
        ) catch |err| {
            self.fetch_error = err;
            return;
        };
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.response) |response| {
            const body_owned = !std.mem.eql(u8, self.resource_url.scheme, "data") and
                !std.mem.eql(u8, self.resource_url.scheme, "about");
            if (body_owned) allocator.free(response.body);
            if (response.csp_header) |header| allocator.free(header);
            if (response.access_control_allow_origin) |header| allocator.free(header);
        }
        self.resource_url.free(allocator);
        self.referrer_url.free(allocator);
        self.* = undefined;
    }
};

/// An independently owned, source-ordered resource generation. Each Fetch
/// owns its URL/referrer and eventual response until `deinit`.
pub const Batch = struct {
    allocator: std.mem.Allocator,
    fetches: std.ArrayList(Fetch) = .empty,
    jobs: std.ArrayList(thread_batch.Job) = .empty,

    pub fn deinit(self: *@This()) void {
        for (self.fetches.items) |*fetch| fetch.deinit(self.allocator);
        self.fetches.deinit(self.allocator);
        self.jobs.deinit(self.allocator);
    }

    fn runAndJoin(self: *@This()) !void {
        try self.jobs.ensureTotalCapacity(self.allocator, self.fetches.items.len);
        for (self.fetches.items) |*fetch| {
            self.jobs.appendAssumeCapacity(.{
                .context = fetch,
                .run_fn = Fetch.runOpaque,
            });
        }
        thread_batch.runAndJoin(self.jobs.items);
    }

    pub fn find(self: *@This(), node: *Node, kind: Kind) ?*Fetch {
        for (self.fetches.items) |*fetch| {
            if (fetch.node == node and fetch.kind == kind) return fetch;
        }
        return null;
    }
};

const FetchMode = enum {
    ordinary,
    cors,
    navigation,
};

/// One synchronous bridge through the session networking runner. All request
/// fields borrow the waiting caller; response/final URL ownership moves back
/// to that caller only after cleanup posts `completed`.
const FetchContext = struct {
    loader: *Loader,
    mode: FetchMode,
    url: Url,
    referrer: ?Url,
    payload: ?[]const u8,
    request_origin: ?[]const u8,
    referrer_policy: url_module.ReferrerPolicy,
    response: ?url_module.HttpResponse = null,
    final_url: ?Url = null,
    fetch_error: ?anyerror = error.NetworkTaskCancelled,
    completed: std.Io.Semaphore = .{},

    fn runOpaque(raw: *anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.response = switch (self.mode) {
            .ordinary => self.loader.fetchBodyDirect(
                self.url,
                self.referrer,
                self.payload,
                self.referrer_policy,
            ),
            .cors => self.loader.fetchBodyWithOriginDirect(
                self.url,
                self.referrer,
                self.payload,
                self.request_origin.?,
                self.referrer_policy,
            ),
            .navigation => self.loader.fetchBodyForNavigationDirect(
                self.url,
                self.referrer,
                self.payload,
                &self.final_url,
                self.referrer_policy,
            ),
        } catch |err| {
            self.fetch_error = err;
            return;
        };
        self.fetch_error = null;
    }

    fn cleanupOpaque(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        // The waiter may release this stack context immediately after the post.
        self.completed.post(self.loader.io);
    }
};

const BatchContext = struct {
    loader: *Loader,
    batch: *Batch,
    run_error: ?anyerror = error.NetworkTaskCancelled,
    completed: std.Io.Semaphore = .{},

    fn runOpaque(raw: *anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.batch.runAndJoin() catch |err| {
            self.run_error = err;
            return;
        };
        self.run_error = null;
    }

    fn cleanupOpaque(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.completed.post(self.loader.io);
    }
};

pub const Loader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *BrowserSession,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        session: *BrowserSession,
    ) Loader {
        return .{ .allocator = allocator, .io = io, .session = session };
    }

    pub fn fetchBody(
        self: *Loader,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
    ) !url_module.HttpResponse {
        return self.fetchBodyWithReferrerPolicy(url, referrer, payload, .default);
    }

    pub fn fetchBodyWithReferrerPolicy(
        self: *Loader,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        referrer_policy: url_module.ReferrerPolicy,
    ) !url_module.HttpResponse {
        return self.runNetworkFetch(
            .ordinary,
            .normal,
            "task:network_fetch",
            url,
            referrer,
            payload,
            null,
            null,
            referrer_policy,
        );
    }

    pub fn fetchBodyForXhr(
        self: *Loader,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        request_origin: ?[]const u8,
        referrer_policy: url_module.ReferrerPolicy,
    ) !url_module.HttpResponse {
        return self.runNetworkFetch(
            if (request_origin != null) .cors else .ordinary,
            .javascript,
            "task:network_xhr",
            url,
            referrer,
            payload,
            request_origin,
            null,
            referrer_policy,
        );
    }

    fn fetchBodyDirect(
        self: *Loader,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        referrer_policy: url_module.ReferrerPolicy,
    ) !url_module.HttpResponse {
        return url_module.Url.fetchBodyWithReferrerPolicySynchronized(
            self.allocator,
            self.io,
            &self.session.http_client,
            &self.session.cookie_jar,
            &self.session.http_cache,
            &self.session.network_lock,
            url,
            referrer,
            payload,
            referrer_policy,
        );
    }

    fn fetchBodyWithOriginDirect(
        self: *Loader,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        request_origin: []const u8,
        referrer_policy: url_module.ReferrerPolicy,
    ) !url_module.HttpResponse {
        return url_module.Url.fetchBodyWithOriginAndReferrerPolicySynchronized(
            self.allocator,
            self.io,
            &self.session.http_client,
            &self.session.cookie_jar,
            &self.session.http_cache,
            &self.session.network_lock,
            url,
            referrer,
            payload,
            request_origin,
            referrer_policy,
        );
    }

    fn fetchBodyForNavigation(
        self: *Loader,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        final_url: *?Url,
        referrer_policy: url_module.ReferrerPolicy,
    ) !url_module.HttpResponse {
        final_url.* = null;
        return self.runNetworkFetch(
            .navigation,
            .normal,
            "task:network_navigation",
            url,
            referrer,
            payload,
            null,
            final_url,
            referrer_policy,
        );
    }

    fn fetchBodyForNavigationDirect(
        self: *Loader,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        final_url: *?Url,
        referrer_policy: url_module.ReferrerPolicy,
    ) !url_module.HttpResponse {
        return url_module.Url.fetchBodyWithFinalUrlAndReferrerPolicySynchronized(
            self.allocator,
            self.io,
            &self.session.http_client,
            &self.session.cookie_jar,
            &self.session.http_cache,
            &self.session.network_lock,
            url,
            referrer,
            payload,
            final_url,
            referrer_policy,
        );
    }

    fn runNetworkFetch(
        self: *Loader,
        mode: FetchMode,
        priority: Task.Priority,
        trace_name: []const u8,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        request_origin: ?[]const u8,
        final_url_output: ?*?Url,
        referrer_policy: url_module.ReferrerPolicy,
    ) !url_module.HttpResponse {
        var context = FetchContext{
            .loader = self,
            .mode = mode,
            .url = url,
            .referrer = referrer,
            .payload = payload,
            .request_origin = request_origin,
            .referrer_policy = referrer_policy,
        };
        try self.session.scheduleNetworkTask(Task.init(
            priority,
            trace_name,
            &context,
            FetchContext.runOpaque,
            FetchContext.cleanupOpaque,
        ));
        context.completed.waitUncancelable(self.io);

        if (context.fetch_error) |err| {
            if (context.final_url) |resolved| resolved.free(self.allocator);
            return err;
        }
        if (final_url_output) |output| {
            output.* = context.final_url;
            context.final_url = null;
        } else if (context.final_url) |resolved| {
            resolved.free(self.allocator);
        }
        return context.response orelse error.NetworkTaskMissingResponse;
    }

    /// Fetch or generate a navigation response with explicit body ownership.
    /// A non-null `final_url` receives the independently owned redirect target.
    pub fn fetchNavigationDocument(
        self: *Loader,
        url: Url,
        referrer: ?Url,
        payload: ?[]const u8,
        final_url: ?*?Url,
        referrer_policy: url_module.ReferrerPolicy,
    ) !NavigationDocument {
        if (final_url) |output| output.* = null;

        if (url.isAboutBookmarks()) {
            const body = try self.session.bookmarksPageHtml(self.allocator);
            return .{
                .response = .{ .body = body },
                .owned_body = body,
            };
        }

        const response = if (final_url) |output|
            self.fetchBodyForNavigation(url, referrer, payload, output, referrer_policy) catch |err| {
                if (!url_module.Url.isCertificateError(err)) return err;
                const body = try navigation.certificateWarningHtml(self.allocator, &url, err);
                return .{
                    .response = .{ .body = body },
                    .owned_body = body,
                    .certificate_error = true,
                };
            }
        else
            self.fetchBodyWithReferrerPolicy(url, referrer, payload, referrer_policy) catch |err| {
                if (!url_module.Url.isCertificateError(err)) return err;
                const body = try navigation.certificateWarningHtml(self.allocator, &url, err);
                return .{
                    .response = .{ .body = body },
                    .owned_body = body,
                    .certificate_error = true,
                };
            };
        const body_is_owned = !std.mem.eql(u8, url.scheme, "about") and
            !std.mem.eql(u8, url.scheme, "data");
        return .{
            .response = response,
            .owned_body = if (body_is_owned) response.body else null,
        };
    }

    /// Run one complete linked-resource generation on the session networking
    /// runner. Transport workers are joined before this synchronous call ends.
    pub fn runBatch(self: *Loader, batch: *Batch) !void {
        var context = BatchContext{ .loader = self, .batch = batch };
        try self.session.scheduleNetworkTask(Task.init(
            .normal,
            "task:network_resource_batch",
            &context,
            BatchContext.runOpaque,
            BatchContext.cleanupOpaque,
        ));
        context.completed.waitUncancelable(self.io);
        if (context.run_error) |err| return err;
    }
};

test "resource batch owns URLs and finds slots by node and kind" {
    const allocator = std.testing.allocator;
    var batch = Batch{ .allocator = allocator };
    defer batch.deinit();

    var loader: Loader = undefined;
    var script_node: Node = undefined;
    var other_node: Node = undefined;
    var resource_url = try Url.init(allocator, "data:text/javascript,ok");
    var resource_url_owned = true;
    errdefer if (resource_url_owned) resource_url.free(allocator);
    var referrer_url = try Url.init(allocator, "https://example.test/page");
    var referrer_url_owned = true;
    errdefer if (referrer_url_owned) referrer_url.free(allocator);

    try batch.fetches.append(allocator, .{
        .loader = &loader,
        .node = &script_node,
        .kind = .script,
        .resource_url = resource_url,
        .referrer_url = referrer_url,
        .referrer_policy = .default,
    });
    resource_url_owned = false;
    referrer_url_owned = false;

    try std.testing.expect(batch.find(&script_node, .script) != null);
    try std.testing.expect(batch.find(&script_node, .stylesheet) == null);
    try std.testing.expect(batch.find(&other_node, .script) == null);
}
