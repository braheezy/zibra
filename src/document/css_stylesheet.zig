//! Retained stylesheet source, compiled branches and provenance shared by Frame
//! and inspection. Media selection clones active rules without recompiling CSS.

const std = @import("std");
const parser = @import("css_parser.zig");
const referrer = @import("referrer.zig");
const media_query = @import("media_query.zig");
const tokenizer = @import("css_tokenizer.zig");
const layers = @import("css_layers.zig");

pub const MediaEnvironment = parser.MediaEnvironment;
pub const Options = struct {
    base_url: ?[]const u8 = null,
    origin: @FieldType(parser.CSSRule, "origin") = .author,
    referrer_policy: referrer.Policy = .default,
    media: ?[]const u8 = null,
};

pub const Sheet = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    metadata: Options,
    rules: []parser.CSSRule = &.{},
    keyframes: []parser.KeyframesRule = &.{},
    conditions: []parser.MediaCondition = &.{},
    layer_program: layers.Program,

    /// Copies source/provenance and compiles supported branches once. Condition
    /// queries and keyframe names borrow this immutable source. Failure frees
    /// every partial owner; construction publishes no document selection.
    pub fn init(allocator: std.mem.Allocator, text: []const u8, metadata: Options) !Sheet {
        var sheet = Sheet{ .allocator = allocator, .text = try allocator.dupe(u8, text), .layer_program = .init(allocator), .metadata = .{
            .origin = metadata.origin,
            .referrer_policy = metadata.referrer_policy,
        } };
        errdefer sheet.deinit();
        sheet.metadata.base_url = if (metadata.base_url) |base| try allocator.dupe(u8, base) else null;
        sheet.metadata.media = if (metadata.media) |query| try allocator.dupe(u8, query) else null;
        const compiler = try parser.init(allocator, sheet.text, false);
        defer compiler.deinit(allocator);
        var keyframes: std.ArrayList(parser.KeyframesRule) = .empty;
        defer {
            for (keyframes.items) |*rule| rule.deinit(allocator);
            keyframes.deinit(allocator);
        }
        var conditions: std.ArrayList(parser.MediaCondition) = .empty;
        defer conditions.deinit(allocator);
        sheet.rules = try compiler.parseRetained(allocator, &keyframes, &conditions, &sheet.layer_program);
        for (sheet.rules) |*rule| {
            rule.origin = metadata.origin;
            rule.referrer_policy = metadata.referrer_policy;
            rule.source_url = if (sheet.metadata.base_url) |base| try allocator.dupe(u8, base) else null;
        }
        sheet.keyframes = try keyframes.toOwnedSlice(allocator);
        for (sheet.keyframes) |*rule| rule.origin = metadata.origin;
        sheet.conditions = try conditions.toOwnedSlice(allocator);
        return sheet;
    }

    /// Requires every selection borrowing this source to have retired.
    pub fn deinit(self: *Sheet) void {
        for (self.rules) |*rule| rule.deinit(self.allocator);
        self.allocator.free(self.rules);
        for (self.keyframes) |*rule| rule.deinit(self.allocator);
        self.allocator.free(self.keyframes);
        self.allocator.free(self.conditions);
        self.layer_program.deinit();
        if (self.metadata.base_url) |base| self.allocator.free(base);
        if (self.metadata.media) |query| self.allocator.free(query);
        self.allocator.free(self.text);
        self.* = undefined;
    }

    /// Borrows this generation's source until deinit or replacement.
    pub fn source(self: Sheet) []const u8 {
        return self.text;
    }

    /// Metadata strings borrow this Sheet. A replacement must copy them before
    /// retiring the original owner.
    pub fn options(self: Sheet) Options {
        return self.metadata;
    }

    /// Select one standalone sheet, resolving its layers within this sheet.
    /// Document generations must use SelectionBuilder across every sheet.
    /// Selectors, declarations and provenance belong to the returned selection;
    /// keyframe names still borrow this Sheet. Failure publishes nothing.
    pub fn select(self: Sheet, allocator: std.mem.Allocator, media: MediaEnvironment) !Selection {
        return self.selectWithMedia(allocator, media, self.metadata.media);
    }

    /// Select one standalone sheet using an overriding media attribute.
    /// The query is borrowed only for this call; no source is changed.
    pub fn selectWithMedia(self: Sheet, allocator: std.mem.Allocator, media: MediaEnvironment, query: ?[]const u8) !Selection {
        var builder = SelectionBuilder.init(allocator);
        defer builder.deinit();
        try builder.append(self, media, query);
        return builder.finish();
    }
};

/// Stages active sheets in document order, with independent layer trees for
/// each origin. Append every sheet before finishing: later sheets can insert
/// children into earlier layers. Only keyframe names borrow source programs.
pub const SelectionBuilder = struct {
    allocator: std.mem.Allocator,
    rules: std.ArrayList(parser.CSSRule) = .empty,
    keyframes: std.ArrayList(parser.KeyframesRule) = .empty,
    registries: [@typeInfo(parser.cascade.Origin).@"enum".fields.len]layers.Registry,
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator) SelectionBuilder {
        var self = SelectionBuilder{ .allocator = allocator, .registries = undefined };
        for (&self.registries) |*registry| registry.* = .init(allocator);
        return self;
    }

    pub fn deinit(self: *SelectionBuilder) void {
        for (self.rules.items) |*rule| rule.deinit(self.allocator);
        self.rules.deinit(self.allocator);
        for (self.keyframes.items) |*rule| rule.deinit(self.allocator);
        self.keyframes.deinit(self.allocator);
        for (&self.registries) |*registry| registry.deinit();
        self.* = undefined;
    }

    /// Copies active executable rules and registers active layer declarations.
    /// Failure rolls back all three owners; the caller can retire a failed
    /// source immediately without leaving borrowed keyframe names behind.
    pub fn append(self: *SelectionBuilder, sheet: Sheet, media: MediaEnvironment, query: ?[]const u8) !void {
        std.debug.assert(!self.finished);
        if (!matchesMediaAttribute(query, media)) return;
        const active = try self.allocator.alloc(bool, sheet.conditions.len);
        defer self.allocator.free(active);
        for (sheet.conditions, 0..) |condition, i| {
            std.debug.assert(condition.parent == null or condition.parent.? < i);
            active[i] = (if (condition.parent) |parent| active[parent] else true) and media_query.matches(condition.query, media);
        }
        const registry = &self.registries[@intFromEnum(sheet.metadata.origin)];
        const layer_start = registry.nodes.items.len;
        const rule_start = self.rules.items.len;
        const keyframe_start = self.keyframes.items.len;
        errdefer {
            for (self.rules.items[rule_start..]) |*rule| rule.deinit(self.allocator);
            self.rules.shrinkRetainingCapacity(rule_start);
            for (self.keyframes.items[keyframe_start..]) |*rule| rule.deinit(self.allocator);
            self.keyframes.shrinkRetainingCapacity(keyframe_start);
            registry.truncate(layer_start);
        }
        const ids = try sheet.layer_program.register(self.allocator, registry, active);
        defer self.allocator.free(ids);
        for (sheet.rules) |rule| {
            if (rule.media_condition) |condition| if (!active[condition]) continue;
            var copy = try rule.clone(self.allocator);
            errdefer copy.deinit(self.allocator);
            copy.media_condition = null;
            switch (copy.layer) {
                .declaration => |index| copy.layer = .{ .registered = ids[index].? },
                else => {},
            }
            try self.rules.append(self.allocator, copy);
        }
        for (sheet.keyframes) |rule| {
            if (rule.media_condition) |condition| if (!active[condition]) continue;
            var copy = try rule.clone(self.allocator);
            errdefer copy.deinit(self.allocator);
            copy.media_condition = null;
            switch (copy.layer) {
                .declaration => |index| copy.layer = .{ .registered = ids[index].? },
                else => {},
            }
            try self.keyframes.append(self.allocator, copy);
        }
    }

    /// Finalize global ranks and transfer executable containers. Requires no
    /// further append/finish calls, including after failure; deinit the builder.
    /// The returned selection may outlive this builder, but not its sources.
    pub fn finish(self: *SelectionBuilder) !Selection {
        std.debug.assert(!self.finished);
        self.finished = true;
        var orders: [@typeInfo(parser.cascade.Origin).@"enum".fields.len][]usize = @splat(&.{});
        defer for (orders) |ranks| self.allocator.free(ranks);
        for (&self.registries, &orders) |registry, *ranks| ranks.* = try registry.orders(self.allocator);
        for (self.rules.items) |*rule| {
            switch (rule.layer) {
                .registered => |index| rule.layer = .{ .ordered = orders[@intFromEnum(rule.origin)][index] },
                else => {},
            }
        }
        for (self.keyframes.items) |*rule| {
            switch (rule.layer) {
                .registered => |index| rule.layer = .{ .ordered = orders[@intFromEnum(rule.origin)][index] },
                else => {},
            }
        }
        var selection = Selection{ .allocator = self.allocator, .rules = try self.rules.toOwnedSlice(self.allocator), .keyframes = &.{} };
        errdefer selection.deinit();
        selection.keyframes = try self.keyframes.toOwnedSlice(self.allocator);
        return selection;
    }
};

/// An absent or empty stylesheet media list applies to every medium. This is
/// distinct from the required condition in an authored @media rule.
pub fn matchesMediaAttribute(query: ?[]const u8, media: MediaEnvironment) bool {
    const text = query orelse return true;
    var tokens = tokenizer.Iterator{ .input = text };
    while (tokens.next()) |token| {
        if (!token.isTrivia()) return media_query.matches(text, media);
    }
    return true;
}

/// Move-only executable containers with owned selectors/declarations. Keyframe
/// names borrow the originating Sheet; retire the Selection before that Sheet.
pub const Selection = struct {
    allocator: std.mem.Allocator,
    rules: []parser.CSSRule,
    keyframes: []parser.KeyframesRule,

    /// Transfer both containers to lists using this selection's allocator.
    /// Reserve before moving either owner; failure leaves the selection intact.
    pub fn appendTo(self: *Selection, rules: *std.ArrayList(parser.CSSRule), keyframes: *std.ArrayList(parser.KeyframesRule)) !void {
        try rules.ensureUnusedCapacity(self.allocator, self.rules.len);
        try keyframes.ensureUnusedCapacity(self.allocator, self.keyframes.len);
        rules.appendSliceAssumeCapacity(self.rules);
        keyframes.appendSliceAssumeCapacity(self.keyframes);
        self.allocator.free(self.rules);
        self.allocator.free(self.keyframes);
        self.rules = &.{};
        self.keyframes = &.{};
    }

    pub fn deinit(self: *Selection) void {
        for (self.rules) |*rule| rule.deinit(self.allocator);
        self.allocator.free(self.rules);
        for (self.keyframes) |*rule| rule.deinit(self.allocator);
        self.allocator.free(self.keyframes);
        self.* = undefined;
    }
};
