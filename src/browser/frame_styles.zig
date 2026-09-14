//! Frame-owned attached stylesheet programs and transactional media selection.
//! Source ordinals belong to one attached DOM generation, not to CSSOM identity.
//! Structural mutations must rebuild sources before using these ordinals again.

const std = @import("std");
const parser = @import("../document/parser.zig");
const css = @import("../document/css_parser.zig");
const stylesheet = @import("../document/css_stylesheet.zig");

pub const Source = struct {
    sheet: stylesheet.Sheet,
    /// Index among all attached style/link elements, including unloaded links.
    source_index: usize,
    media_revision: u64,

    /// Copies the stylesheet; the owner Node is a synchronous borrow only.
    pub fn init(allocator: std.mem.Allocator, text: []const u8, options: stylesheet.Options, source_index: usize, owner: *const parser.Node) !Source {
        return .{
            .sheet = try stylesheet.Sheet.init(allocator, text, options),
            .source_index = source_index,
            .media_revision = mediaRevision(owner),
        };
    }

    /// Retire executable selections before their source program.
    pub fn deinit(self: *Source) void {
        self.sheet.deinit();
        self.* = undefined;
    }
};

pub fn mediaAttribute(owner: *const parser.Node) ?[]const u8 {
    return if (owner.element.attributes) |attrs| attrs.get("media") else null;
}

fn mediaRevision(owner: *const parser.Node) u64 {
    return if (owner.element.attributes) |attrs| attrs.media_revision else 0;
}

/// Returns an owned list of synchronous DOM borrows in stylesheet-source order.
pub fn collectOwners(allocator: std.mem.Allocator, root: *parser.Node) !std.ArrayList(*parser.Node) {
    var nodes: std.ArrayList(*parser.Node) = .empty;
    errdefer nodes.deinit(allocator);
    try parser.treeToList(allocator, root, &nodes);
    var count: usize = 0;
    for (nodes.items) |node| {
        if (node.* != .element) continue;
        const tag = node.element.tag;
        if (!std.mem.eql(u8, tag, "style") and !std.mem.eql(u8, tag, "link")) continue;
        nodes.items[count] = node;
        count += 1;
    }
    nodes.items.len = count;
    return nodes;
}

/// Requires the sources to describe this attached DOM generation. Attribute
/// changes require only selection; neither this check nor selection fetches CSS.
pub fn mediaChanged(allocator: std.mem.Allocator, root: *parser.Node, sources: []const Source) !bool {
    if (sources.len == 0) return false;
    var owners = try collectOwners(allocator, root);
    defer owners.deinit(allocator);
    for (sources) |source| {
        if (source.source_index >= owners.items.len) return error.StaleStylesheetSources;
        if (source.media_revision != mediaRevision(owners.items[source.source_index])) return true;
    }
    return false;
}

/// Staged executable generation. UA rules are borrowed; author rules and
/// keyframe containers are owned. Source revisions change only on publication.
pub const Pending = struct {
    allocator: std.mem.Allocator,
    rules: std.ArrayList(css.CSSRule) = .empty,
    keyframes: std.ArrayList(css.KeyframesRule) = .empty,
    revisions: []u64 = &.{},

    pub fn deinit(self: *Pending) void {
        for (self.rules.items) |*rule| if (rule.owned) rule.deinit(self.allocator);
        self.rules.deinit(self.allocator);
        for (self.keyframes.items) |*rule| rule.deinit(self.allocator);
        self.keyframes.deinit(self.allocator);
        self.allocator.free(self.revisions);
        self.* = undefined;
    }

    /// Call only when installing these rules, before any other DOM mutation.
    pub fn commitRevisions(self: Pending, sources: []Source) void {
        std.debug.assert(sources.len == self.revisions.len);
        for (sources, self.revisions) |*source, revision| source.media_revision = revision;
    }
};

/// Clone active rules in DOM order without changing sources or the installed
/// generation. The caller retires old rules, moves both pending containers,
/// commits revisions, and dirties computed style as one infallible publication.
pub fn select(allocator: std.mem.Allocator, root: *parser.Node, sources: []const Source, defaults: []const css.CSSRule, media: css.MediaEnvironment) !Pending {
    var pending = Pending{ .allocator = allocator };
    errdefer pending.deinit();
    try pending.rules.appendSlice(allocator, defaults);
    if (sources.len == 0) return pending;
    var owners = try collectOwners(allocator, root);
    defer owners.deinit(allocator);
    pending.revisions = try allocator.alloc(u64, sources.len);
    var builder = stylesheet.SelectionBuilder.init(allocator);
    defer builder.deinit();
    for (sources, 0..) |source, i| {
        if (source.source_index >= owners.items.len) return error.StaleStylesheetSources;
        const owner = owners.items[source.source_index];
        try builder.append(source.sheet, media, mediaAttribute(owner));
        pending.revisions[i] = mediaRevision(owner);
    }
    var selection = try builder.finish();
    defer selection.deinit();
    try selection.appendTo(&pending.rules, &pending.keyframes);
    return pending;
}

fn selectionAllocationTrial(allocator: std.mem.Allocator, root: *parser.Node, sources: []const Source) !void {
    const revision = sources[0].media_revision;
    defer std.debug.assert(sources[0].media_revision == revision);
    var pending = try select(allocator, root, sources, &.{}, .{ .viewport_width_css = 800 });
    defer pending.deinit();
    try std.testing.expectEqual(@as(usize, 2), pending.rules.items.len);
    try std.testing.expectEqual(@as(usize, 1), pending.keyframes.items.len);
    for (pending.rules.items) |rule| {
        try std.testing.expectEqualStrings("https://example.test/assets/site.css", rule.source_url.?);
        try std.testing.expectEqual(.no_referrer, rule.referrer_policy);
    }
}

test "attached stylesheet media selection preserves source revisions at every allocation failure" {
    const allocator = std.testing.allocator;
    const html = try parser.HTMLParser.init(allocator, "<link rel=icon><style media=print></style><p>target</p>");
    defer html.deinit(allocator);
    var root = try html.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);
    var owners = try collectOwners(allocator, &root);
    defer owners.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), owners.items.len);
    const owner = owners.items[1];
    var sources = [_]Source{try Source.init(allocator, "@layer base {p{color:red}@media(min-width:600px){p{color:green}@keyframes pulse{from,to{opacity:0.5}}}}", .{ .base_url = "https://example.test/assets/site.css", .referrer_policy = .no_referrer }, 1, owner)};
    defer sources[0].deinit();
    const program = sources[0].sheet.rules.ptr;
    var original = try select(allocator, &root, &sources, &.{}, .{});
    defer original.deinit();
    try std.testing.expectEqual(@as(usize, 0), original.rules.items.len);
    try std.testing.expect(!try mediaChanged(allocator, &root, &sources));
    try owner.element.attributes.?.put("media", "screen");
    try std.testing.expect(try mediaChanged(allocator, &root, &sources));
    try std.testing.checkAllAllocationFailures(allocator, selectionAllocationTrial, .{ &root, &sources });
    try std.testing.expect(try mediaChanged(allocator, &root, &sources));
    try std.testing.expectEqual(@as(usize, 0), original.rules.items.len);
    var pending = try select(allocator, &root, &sources, &.{}, .{ .viewport_width_css = 800 });
    defer pending.deinit();
    pending.commitRevisions(&sources);
    try std.testing.expect(!try mediaChanged(allocator, &root, &sources));
    try std.testing.expectEqual(program, sources[0].sheet.rules.ptr);
    try std.testing.expect(owner.element.attributes.?.orderedRemove("media"));
    try std.testing.expect(try mediaChanged(allocator, &root, &sources));
    var narrow = try select(allocator, &root, &sources, &.{}, .{ .viewport_width_css = 400 });
    defer narrow.deinit();
    try std.testing.expectEqual(@as(usize, 1), narrow.rules.items.len);
    try std.testing.expectEqual(@as(usize, 0), narrow.keyframes.items.len);
    try std.testing.expectEqual(@as(usize, 2), pending.rules.items.len);
}
