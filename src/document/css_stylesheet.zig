//! Inspection-owned stylesheet source and provenance. Native parsing produces
//! executable selections that borrow this source until their retirement.

const std = @import("std");
const parser = @import("css_parser.zig");
const referrer = @import("referrer.zig");

pub const MediaEnvironment = parser.MediaEnvironment;
pub const Options = struct {
    base_url: ?[]const u8 = null,
    origin: @FieldType(parser.CSSRule, "origin") = .author,
    referrer_policy: referrer.Policy = .default,
};

pub const Sheet = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    metadata: Options,

    /// Copies source and serialized provenance. Syntax is parsed by select;
    /// construction alone does not validate or publish executable rules.
    pub fn init(allocator: std.mem.Allocator, text: []const u8, metadata: Options) !Sheet {
        const owned = try allocator.dupe(u8, text);
        errdefer allocator.free(owned);
        var options_copy = metadata;
        options_copy.base_url = if (metadata.base_url) |base| try allocator.dupe(u8, base) else null;
        return .{ .allocator = allocator, .text = owned, .metadata = options_copy };
    }

    /// Requires every selection borrowing this source to have retired.
    pub fn deinit(self: *Sheet) void {
        if (self.metadata.base_url) |base| self.allocator.free(base);
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

    /// Reparses source for the supplied media environment. The result owns its
    /// rule/keyframe containers and provenance copies; declaration strings
    /// borrow this Sheet. Failure publishes nothing and releases partial owners.
    pub fn select(self: Sheet, allocator: std.mem.Allocator, media: MediaEnvironment) !Selection {
        const css = try parser.initWithMedia(allocator, self.text, media);
        defer css.deinit(allocator);
        var keyframes = std.ArrayList(parser.KeyframesRule).empty;
        errdefer {
            for (keyframes.items) |*rule| rule.deinit(allocator);
            keyframes.deinit(allocator);
        }
        const rules = try css.parseWithKeyframes(allocator, &keyframes);
        errdefer {
            for (rules) |*rule| rule.deinit(allocator);
            allocator.free(rules);
        }
        for (rules) |*rule| {
            rule.origin = self.metadata.origin;
            rule.referrer_policy = self.metadata.referrer_policy;
            rule.source_url = if (self.metadata.base_url) |base| try allocator.dupe(u8, base) else null;
        }
        return .{ .allocator = allocator, .rules = rules, .keyframes = try keyframes.toOwnedSlice(allocator) };
    }
};

/// Move-only executable containers. Their declaration strings borrow the
/// originating Sheet; retire the Selection before that Sheet.
pub const Selection = struct {
    allocator: std.mem.Allocator,
    rules: []parser.CSSRule,
    keyframes: []parser.KeyframesRule,

    pub fn deinit(self: *Selection) void {
        for (self.rules) |*rule| rule.deinit(self.allocator);
        self.allocator.free(self.rules);
        for (self.keyframes) |*rule| rule.deinit(self.allocator);
        self.allocator.free(self.keyframes);
        self.* = undefined;
    }
};
