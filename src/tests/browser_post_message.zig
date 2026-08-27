//! Cross-document messaging origin-policy and host-boundary regressions.

const std = @import("std");
const script_tasks = @import("../browser/script_tasks.zig");
const Js = @import("../script/js.zig");
const Url = @import("../network/url.zig").Url;

const PostMessageTargetOrigin = script_tasks.PostMessageTargetOrigin;

test "postMessage target origins compare canonical scheme host and effective port" {
    const allocator = std.testing.allocator;

    var source = try Url.init(allocator, "https://parent.example/start");
    defer source.free(allocator);
    var same_origin_target = try Url.init(allocator, "https://child.example/page");
    defer same_origin_target.free(allocator);
    var different_scheme = try Url.init(allocator, "http://child.example/page");
    defer different_scheme.free(allocator);
    var different_port = try Url.init(allocator, "https://child.example:8443/page");
    defer different_port.free(allocator);

    var wildcard = try PostMessageTargetOrigin.parse(allocator, "*", &source);
    defer wildcard.deinit(allocator);
    try std.testing.expect(wildcard.allows(&different_scheme));
    try std.testing.expect(wildcard.allows(null));

    // The path/query/fragment are intentionally present. Only the parsed URL
    // origin participates, and an explicit default port is canonicalized.
    var exact = try PostMessageTargetOrigin.parse(
        allocator,
        "https://CHILD.example:443/ignored?q=1#fragment",
        &source,
    );
    defer exact.deinit(allocator);
    try std.testing.expect(exact.allows(&same_origin_target));
    try std.testing.expect(!exact.allows(&different_scheme));
    try std.testing.expect(!exact.allows(&different_port));
    try std.testing.expect(!exact.allows(null));
}

test "postMessage slash target uses the sending document origin" {
    const allocator = std.testing.allocator;

    var source = try Url.init(allocator, "http://parent.example:8080/start");
    defer source.free(allocator);
    var same_origin_target = try Url.init(allocator, "http://PARENT.example:8080/child");
    defer same_origin_target.free(allocator);
    var other_target = try Url.init(allocator, "http://parent.example:8081/child");
    defer other_target.free(allocator);

    var same_source = try PostMessageTargetOrigin.parse(allocator, "/", &source);
    defer same_source.deinit(allocator);
    try std.testing.expect(same_source.allows(&same_origin_target));
    try std.testing.expect(!same_source.allows(&other_target));

    try std.testing.expectError(
        error.InvalidTargetOrigin,
        PostMessageTargetOrigin.parse(allocator, "/", null),
    );
    try std.testing.expectError(
        error.InvalidTargetOrigin,
        PostMessageTargetOrigin.parse(allocator, "relative/path", &source),
    );
    try std.testing.expectError(
        error.InvalidTargetOrigin,
        PostMessageTargetOrigin.parse(allocator, " * ", &source),
    );
}

const PostMessageCapture = struct {
    calls: usize = 0,
    source_window_id: u32 = 0,
    target_window_id: u32 = 0,
    target_origin: [128]u8 = undefined,
    target_origin_len: usize = 0,
    message: [128]u8 = undefined,
    message_len: usize = 0,
    reject_origin: bool = false,

    fn callback(
        context: ?*anyopaque,
        source_window_id: u32,
        target_window_id: u32,
        target_origin: []const u8,
        message: []const u8,
    ) anyerror!void {
        const raw = context orelse return error.MissingCapture;
        const unaligned: *align(1) PostMessageCapture = @ptrCast(raw);
        const self: *PostMessageCapture = @alignCast(unaligned);
        if (self.reject_origin) return error.InvalidTargetOrigin;

        self.calls += 1;
        self.source_window_id = source_window_id;
        self.target_window_id = target_window_id;
        self.target_origin_len = @min(target_origin.len, self.target_origin.len);
        @memcpy(self.target_origin[0..self.target_origin_len], target_origin[0..self.target_origin_len]);
        self.message_len = @min(message.len, self.message.len);
        @memcpy(self.message[0..self.message_len], message[0..self.message_len]);
    }
};

test "postMessage JavaScript binding forwards explicit and same-origin default targets" {
    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);

    var capture = PostMessageCapture{};
    js.setPostMessageCallback(7, PostMessageCapture.callback, &capture);

    _ = try js.evaluate(
        7,
        "window.postMessage('hello', 9, 'https://child.example/path');",
    );
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(u32, 7), capture.source_window_id);
    try std.testing.expectEqual(@as(u32, 9), capture.target_window_id);
    try std.testing.expectEqualStrings(
        "https://child.example/path",
        capture.target_origin[0..capture.target_origin_len],
    );
    try std.testing.expectEqualStrings("hello", capture.message[0..capture.message_len]);

    _ = try js.evaluate(7, "window.postMessage('default', 11);");
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expectEqualStrings("/", capture.target_origin[0..capture.target_origin_len]);

    // A cross-origin parent has no WindowContext in this Js realm. It must
    // still be represented by the restricted postMessage-only proxy.
    js.setParentWindow(7, 41);
    _ = try js.evaluate(7, "window.parent.postMessage('to parent', '*');");
    try std.testing.expectEqual(@as(usize, 3), capture.calls);
    try std.testing.expectEqual(@as(u32, 41), capture.target_window_id);
    try std.testing.expectEqualStrings("*", capture.target_origin[0..capture.target_origin_len]);
    try std.testing.expectEqualStrings("to parent", capture.message[0..capture.message_len]);

    capture.reject_origin = true;
    const caught = try js.evaluate(
        7,
        "var targetSyntaxError = false;" ++
            "try { window.postMessage('bad', 9, 'not-an-origin'); }" ++
            "catch (error) { targetSyntaxError = error.name === 'SyntaxError'; }" ++
            "targetSyntaxError;",
    );
    try std.testing.expect(caught.toBoolean());
}

test "dispatched message strings outlive callback-owned buffers" {
    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    var js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);

    _ = try js.evaluate(
        0,
        "var savedMessageData = ''; var savedMessageOrigin = ''; var savedSource = -1;" ++
            "window.addEventListener('message', function(event) {" ++
            " savedMessageData = event.data; savedMessageOrigin = event.origin;" ++
            " savedSource = event.source.__id; });",
    );

    const message = try allocator.dupe(u8, "persistent message");
    const origin = try allocator.dupe(u8, "https://source.example");
    try js.dispatchPostMessage(0, message, origin, 23);
    allocator.free(message);
    allocator.free(origin);

    // Encourage the testing allocator to reuse the released temporary spans.
    const overwrite = try allocator.alloc(u8, 64);
    defer allocator.free(overwrite);
    @memset(overwrite, 'x');

    const retained = try js.evaluate(
        0,
        "savedMessageData === 'persistent message' &&" ++
            " savedMessageOrigin === 'https://source.example' && savedSource === 23;",
    );
    try std.testing.expect(retained.toBoolean());
}
