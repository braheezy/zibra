//! Stack-owned initial HTML loading driver.
//!
//! This module coordinates the document-side live parser without owning a
//! Frame, URL, network resource, JavaScript Realm, or render state. The
//! Browser stages those owners first, then supplies synchronous hooks to
//! publish the final-address root and execute each parser-blocking script.
//! No hook or queued task may retain the passed parser/root pointers.

const std = @import("std");
const parser = @import("../document/parser.zig");

const Node = parser.Node;
const LiveParser = parser.LiveParser;
const Pin = @import("../document/node_pins.zig").Pin;

/// Synchronous Browser-owned operations around one initial live parse.
pub const Hooks = struct {
    context: ?*anyopaque,
    /// Publish the caller-owned final root before any source token or script
    /// can observe it. This is where a Browser installs a document Realm and
    /// generation-bound callbacks.
    install_root: *const fn (context: ?*anyopaque, root: *Node) anyerror!void,
    /// Evaluate one complete parser-inserted classic script. The callback may
    /// call `live.write` synchronously, but must not retain `live`, `pin`, or a
    /// resolved Node after it returns.
    execute_script: *const fn (
        context: ?*anyopaque,
        live: *LiveParser,
        pin: Pin,
    ) anyerror!void,
};

/// Build the initial document through EOF. The source store must already have
/// its initial chunk, and `root` must be the Frame's final Node field. Network
/// input is complete for this first driver; future streaming callers can own a
/// LiveParser directly and use its `need_input` transition.
pub fn run(
    allocator: std.mem.Allocator,
    source: *parser.HtmlSourceStore,
    root: *Node,
    hooks: Hooks,
) !void {
    var live = try LiveParser.init(allocator, source, root);
    defer live.deinit();

    try drive(&live, root, hooks);
}

/// Like `run`, but initializes a caller-owned optional final-root slot. On an
/// error after publication this helper retires the partial DOM and resets the
/// slot, so navigation can fail without exposing a half-installed document.
pub fn runIntoSlot(
    allocator: std.mem.Allocator,
    source: *parser.HtmlSourceStore,
    root_slot: *?Node,
    hooks: Hooks,
) !void {
    var live = try LiveParser.initIntoSlot(allocator, source, root_slot);
    defer live.deinit();
    errdefer {
        root_slot.*.?.deinit(allocator);
        root_slot.* = null;
    }

    try drive(&live, &root_slot.*.?, hooks);
}

fn drive(live: *LiveParser, root: *Node, hooks: Hooks) !void {
    // A Realm-owned handle observer can be borrowed for the remainder of this
    // synchronous parse after its first script. Do not leave that borrowed
    // callback installed through a loader error or Frame/Realm retirement.
    defer live.setExternalRelocationObserver(null);
    try hooks.install_root(hooks.context, root);
    live.finishInput();

    while (true) {
        switch (try live.advance()) {
            .script => |pin| {
                try hooks.execute_script(hooks.context, live, pin);
                try live.resumeAfterScript();
            },
            .eof => return,
            .need_input => return error.UnexpectedInputBoundary,
        }
    }
}

test "document loader publishes root before ordered script boundaries" {
    const Probe = struct {
        allocator: std.mem.Allocator,
        installed: bool = false,
        scripts: std.ArrayList([]const u8) = .empty,

        fn install(context: ?*anyopaque, root: *Node) anyerror!void {
            const raw = context orelse return error.MissingProbe;
            const unaligned: *align(1) @This() = @ptrCast(raw);
            const self: *@This() = @alignCast(unaligned);
            self.installed = root.* == .element and std.ascii.eqlIgnoreCase(root.element.tag, "html");
        }

        fn execute(context: ?*anyopaque, live: *LiveParser, pin: Pin) anyerror!void {
            const raw = context orelse return error.MissingProbe;
            const unaligned: *align(1) @This() = @ptrCast(raw);
            const self: *@This() = @alignCast(unaligned);
            const script = live.resolve(pin) orelse return error.MissingScript;
            const text = switch (script.*) {
                .element => |element| if (element.children.items.len != 0) switch (element.children.items[0]) {
                    .text => |value| value.text,
                    .element => "",
                } else "",
                .text => "",
            };
            try self.scripts.append(self.allocator, text);
            if (std.mem.eql(u8, text, "first")) try live.write("<script>second</script>");
        }
    };

    var source = parser.HtmlSourceStore.init(std.testing.allocator);
    defer source.deinit();
    _ = try source.adopt(try std.testing.allocator.dupe(
        u8,
        "<body><script>first</script></body>",
    ));
    var root: Node = undefined;
    var probe = Probe{ .allocator = std.testing.allocator };
    defer probe.scripts.deinit(std.testing.allocator);
    try run(std.testing.allocator, &source, &root, .{
        .context = &probe,
        .install_root = Probe.install,
        .execute_script = Probe.execute,
    });
    defer root.deinit(std.testing.allocator);

    try std.testing.expect(probe.installed);
    try std.testing.expectEqual(@as(usize, 2), probe.scripts.items.len);
    try std.testing.expectEqualStrings("first", probe.scripts.items[0]);
    try std.testing.expectEqualStrings("second", probe.scripts.items[1]);
}
