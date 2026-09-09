//! Retained experimental stylesheet owner used by isolated inspection.
//! One source-owning Terence tree feeds Zibra selectors/property grammars once.
//! Media selection clones executable owners while borrowing this generation's
//! normalized values; selectors, cascade and DOM styling stay Zibra contracts.

const std = @import("std");
const frontend = @import("css_frontend.zig");
const bounds = @import("css_frontend_limits.zig");
const normalize = @import("css_normalize.zig");
const parser = @import("css_parser.zig");
const declarations = @import("css_declarations.zig");
const media_query = @import("media_query.zig");
const referrer = @import("referrer.zig");

pub const MediaEnvironment = media_query.Environment;
pub const Limits = frontend.Limits;
pub const Options = struct {
    limits: Limits = .{},
    /// Serialized final stylesheet URL. Copied on parse and independently
    /// cloned into executable CSSRule owners; no network.Url is shallow-copied.
    base_url: ?[]const u8 = null,
    origin: @FieldType(parser.CSSRule, "origin") = .author,
    referrer_policy: referrer.Policy = .default,
};

const Condition = struct {
    prelude: []const u8,
    parent: ?usize,
};

const Entry = struct {
    condition: ?usize,
    content: union(enum) {
        rule: parser.CSSRule,
        keyframes: parser.KeyframesRule,
    },

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        switch (self.content) {
            .rule => |*rule| rule.deinit(allocator),
            .keyframes => |*keyframes| keyframes.deinit(allocator),
        }
    }
};

const Storage = struct {
    budget: bounds.Budget,
    allocator: std.mem.Allocator,
    syntax: frontend.Syntax,
    options: Options,
    strings: std.ArrayList([]u8) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    conditions: std.ArrayList(Condition) = .empty,

    fn init(self: *Storage, source_text: []const u8) !void {
        self.allocator = self.budget.allocator();
        self.syntax = try frontend.Syntax.parse(self.allocator, source_text, .{
            .limits = self.options.limits,
            .base_url = self.options.base_url,
        });
        errdefer self.deinit();
        self.options.base_url = self.syntax.baseUrl();
        try self.appendRules(self.syntax.root(), null);
    }

    fn deinit(self: *Storage) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.conditions.deinit(self.allocator);
        freeStrings(self.allocator, &self.strings);
        self.syntax.deinit();
        std.debug.assert(self.budget.live == 0);
    }

    fn retain(self: *Storage, string: []u8) ![]const u8 {
        return retainString(self.allocator, &self.strings, string);
    }

    fn appendRules(self: *Storage, container: frontend.NodeId, condition: ?usize) anyerror!void {
        var children = self.syntax.children(container);
        while (children.next()) |child| {
            const node = self.syntax.node(child);
            switch (node.kind) {
                .qualified_rule => try self.appendQualified(child, condition),
                .at_rule => {
                    const parts = ruleParts(self.syntax, child) orelse continue;
                    const keyword = try normalize.identifier(self.allocator, self.syntax.slice(node.head)[1..]);
                    defer self.allocator.free(keyword);
                    if (std.ascii.eqlIgnoreCase(keyword, "media")) {
                        const prelude = try self.retain(try normalize.value(self.allocator, self.syntax, parts.prelude));
                        const index = self.conditions.items.len;
                        try self.conditions.append(self.allocator, .{ .prelude = prelude, .parent = condition });
                        try self.appendRules(parts.block, index);
                    } else if (std.ascii.eqlIgnoreCase(keyword, "keyframes")) {
                        try self.appendKeyframes(child, condition);
                    }
                    // Unknown at-rules and CSS nesting retain their syntax but
                    // never acquire media, layer, import or cascade semantics.
                },
                else => {},
            }
        }
    }

    fn appendQualified(self: *Storage, id: frontend.NodeId, condition: ?usize) !void {
        const parts = ruleParts(self.syntax, id) orelse return;
        const selectors = parser.parseSelectorList(self.allocator, self.syntax.slice(parts.prelude)) catch |err| switch (err) {
            error.InvalidSelector, error.InvalidWord, error.InvalidLiteral => return,
            // Invalid CSS discards its rule; admission and allocation failures
            // reject the generation so callers cannot publish a partial sheet.
            else => return err,
        };
        var transferred: usize = 0;
        defer {
            for (selectors[transferred..]) |*selector| selector.deinit(self.allocator);
            self.allocator.free(selectors);
        }
        var properties = try collectDeclarations(self.allocator, self.syntax, parts.block, &self.strings, false);
        defer properties.deinit();
        try self.entries.ensureUnusedCapacity(self.allocator, selectors.len);
        for (selectors) |selector| {
            var rule = parser.CSSRule{
                .selector = selector,
                .properties = try properties.clone(),
                .origin = self.options.origin,
                .referrer_policy = self.options.referrer_policy,
            };
            errdefer rule.properties.deinit();
            rule.source_url = if (self.syntax.baseUrl()) |url| try self.allocator.dupe(u8, url) else null;
            self.entries.appendAssumeCapacity(.{ .condition = condition, .content = .{ .rule = rule } });
            transferred += 1;
        }
    }

    fn appendKeyframes(self: *Storage, id: frontend.NodeId, condition: ?usize) !void {
        const parts = ruleParts(self.syntax, id) orelse return;
        var names = self.syntax.tokens(parts.prelude);
        var name_token: ?frontend.Token = null;
        while (names.next()) |token| {
            if (token.kind == .whitespace or token.kind == .comment) continue;
            if (token.kind != .identifier or name_token != null) return;
            name_token = token;
        }
        const token = name_token orelse return;
        const name = try self.retain(try normalize.identifier(self.allocator, self.syntax.slice(token.range)));
        for ([_][]const u8{ "none", "inherit", "initial", "unset", "revert", "revert-layer", "default" }) |reserved| {
            if (std.ascii.eqlIgnoreCase(name, reserved)) return;
        }
        var frames = std.ArrayList(parser.Keyframe).empty;
        errdefer {
            for (frames.items) |*frame| frame.deinit();
            frames.deinit(self.allocator);
        }
        var children = self.syntax.children(parts.block);
        while (children.next()) |child| {
            if (self.syntax.node(child).kind != .qualified_rule) continue;
            const frame_parts = ruleParts(self.syntax, child) orelse continue;
            const prelude = try normalize.value(self.allocator, self.syntax, frame_parts.prelude);
            defer self.allocator.free(prelude);
            var offsets = std.ArrayList(f64).empty;
            defer offsets.deinit(self.allocator);
            var raw_offsets = std.mem.splitScalar(u8, prelude, ',');
            var valid = true;
            while (raw_offsets.next()) |raw_offset| {
                const offset = keyframeOffset(raw_offset) orelse {
                    valid = false;
                    break;
                };
                try offsets.append(self.allocator, offset);
            }
            if (!valid or offsets.items.len == 0) continue;
            var properties = try collectDeclarations(self.allocator, self.syntax, frame_parts.block, &self.strings, true);
            defer properties.deinit();
            try frames.ensureUnusedCapacity(self.allocator, offsets.items.len);
            for (offsets.items) |offset| {
                frames.appendAssumeCapacity(.{ .offset = offset, .properties = try properties.clone() });
            }
        }
        if (frames.items.len == 0) {
            frames.deinit(self.allocator);
            return;
        }
        var keyframes = parser.KeyframesRule{ .name = name, .frames = try frames.toOwnedSlice(self.allocator) };
        errdefer keyframes.deinit(self.allocator);
        try self.entries.append(self.allocator, .{ .condition = condition, .content = .{ .keyframes = keyframes } });
    }

    fn matches(self: *const Storage, condition: ?usize, environment: MediaEnvironment) bool {
        var current = condition;
        while (current) |index| {
            const entry = self.conditions.items[index];
            if (!media_query.matches(entry.prelude, environment)) return false;
            current = entry.parent;
        }
        return true;
    }
};

/// Move-only retained source, syntax, semantic rules and normalized values.
/// Selectors, conditions and declarations are adapted once during parse; select
/// only evaluates conditions and clones owners. All Selections must retire
/// before this Sheet; computed Element strings use their existing intern owner.
pub const Sheet = struct {
    storage: *Storage,

    /// Stages a complete generation and owns copies of source/provenance.
    /// Invalid or unsupported rules are skipped; resource/OOM errors publish
    /// nothing. No browser, DOM, fetch or stylesheet invalidation occurs here.
    pub fn parse(allocator: std.mem.Allocator, source_text: []const u8, parse_options: Options) !Sheet {
        const storage = try allocator.create(Storage);
        errdefer allocator.destroy(storage);
        storage.* = .{
            .budget = .{ .parent = allocator, .limit = parse_options.limits.allocated_bytes },
            .allocator = undefined,
            .syntax = undefined,
            .options = parse_options,
        };
        storage.init(source_text) catch |err| {
            std.debug.assert(storage.budget.live == 0);
            if (err == error.OutOfMemory and storage.budget.exceeded) return error.MemoryLimitExceeded;
            return err;
        };
        return .{ .storage = storage };
    }

    pub fn deinit(self: *Sheet) void {
        const allocator = self.storage.budget.parent;
        self.storage.deinit();
        allocator.destroy(self.storage);
        self.* = undefined;
    }

    pub fn source(self: Sheet) []const u8 {
        return self.storage.syntax.source();
    }

    /// Returned base_url borrows this generation; a replacement parse copies it
    /// while the old Sheet is alive. Scalar origin and policy survive reselection.
    pub fn options(self: Sheet) Options {
        return self.storage.options;
    }

    pub fn stats(self: Sheet) frontend.Stats {
        return self.storage.syntax.stats();
    }

    pub fn diagnostics(self: Sheet) []const frontend.Diagnostic {
        return self.storage.syntax.diagnostics();
    }

    /// Owns the returned selector/map/URL/frame containers, whose declaration
    /// names and values borrow this Sheet. Multiple selections may coexist;
    /// none may outlive the Sheet. No syntax or selector parsing happens here.
    pub fn select(self: Sheet, allocator: std.mem.Allocator, environment: MediaEnvironment) !Selection {
        var rules = std.ArrayList(parser.CSSRule).empty;
        errdefer {
            for (rules.items) |*rule| rule.deinit(allocator);
            rules.deinit(allocator);
        }
        var keyframes = std.ArrayList(parser.KeyframesRule).empty;
        errdefer {
            for (keyframes.items) |*rule| rule.deinit(allocator);
            keyframes.deinit(allocator);
        }
        for (self.storage.entries.items) |entry| {
            if (!self.storage.matches(entry.condition, environment)) continue;
            switch (entry.content) {
                .rule => |rule| {
                    var copy = try cloneRule(allocator, rule);
                    errdefer copy.deinit(allocator);
                    try rules.append(allocator, copy);
                },
                .keyframes => |rule| {
                    var copy = try cloneKeyframes(allocator, rule);
                    errdefer copy.deinit(allocator);
                    try keyframes.append(allocator, copy);
                },
            }
        }
        const rule_slice = try rules.toOwnedSlice(allocator);
        errdefer {
            for (rule_slice) |*rule| rule.deinit(allocator);
            allocator.free(rule_slice);
        }
        return .{ .allocator = allocator, .rules = rule_slice, .keyframes = try keyframes.toOwnedSlice(allocator) };
    }
};

/// Move-only executable containers. Their strings borrow the originating Sheet;
/// retire the Selection before that Sheet. Ordinary CSSRule teardown is valid.
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

/// Move-only inline-style declaration owner. This uses the same syntax entry,
/// normalization and property grammar as Sheet. The map borrows this block's
/// source/strings and must retire with it; callers intern computed winners.
pub const DeclarationBlock = struct {
    budget: *bounds.Budget,
    allocator: std.mem.Allocator,
    syntax: frontend.Syntax,
    strings: std.ArrayList([]u8),
    properties: declarations.Map,

    pub fn parse(parent: std.mem.Allocator, source_text: []const u8, limits: Limits) !DeclarationBlock {
        const budget = try parent.create(bounds.Budget);
        errdefer parent.destroy(budget);
        budget.* = .{ .parent = parent, .limit = limits.allocated_bytes };
        return init(budget, source_text, limits) catch |err| {
            std.debug.assert(budget.live == 0);
            if (err == error.OutOfMemory and budget.exceeded) return error.MemoryLimitExceeded;
            return err;
        };
    }

    fn init(budget: *bounds.Budget, source_text: []const u8, limits: Limits) !DeclarationBlock {
        const allocator = budget.allocator();
        var syntax = try frontend.Syntax.parse(allocator, source_text, .{ .mode = .declarations, .limits = limits });
        errdefer syntax.deinit();
        var strings = std.ArrayList([]u8).empty;
        errdefer freeStrings(allocator, &strings);
        const properties = try collectDeclarations(allocator, syntax, syntax.root(), &strings, false);
        return .{
            .budget = budget,
            .allocator = allocator,
            .syntax = syntax,
            .properties = properties,
            .strings = strings,
        };
    }

    pub fn source(self: DeclarationBlock) []const u8 {
        return self.syntax.source();
    }

    pub fn deinit(self: *DeclarationBlock) void {
        self.properties.deinit();
        freeStrings(self.allocator, &self.strings);
        self.syntax.deinit();
        std.debug.assert(self.budget.live == 0);
        self.budget.parent.destroy(self.budget);
        self.* = undefined;
    }
};

fn retainString(allocator: std.mem.Allocator, strings: *std.ArrayList([]u8), string: []u8) ![]const u8 {
    errdefer allocator.free(string);
    try strings.append(allocator, string);
    return string;
}

fn freeStrings(allocator: std.mem.Allocator, strings: *std.ArrayList([]u8)) void {
    for (strings.items) |string| allocator.free(string);
    strings.deinit(allocator);
}

fn collectDeclarations(
    allocator: std.mem.Allocator,
    syntax: frontend.Syntax,
    container: frontend.NodeId,
    strings: *std.ArrayList([]u8),
    keyframe: bool,
) !declarations.Map {
    var properties = declarations.Map.init(allocator);
    errdefer properties.deinit();
    var lists = syntax.children(container);
    while (lists.next()) |list| {
        if (syntax.node(list).kind != .declaration_list) continue;
        var children = syntax.children(list);
        while (children.next()) |child| {
            const declaration = syntax.declaration(child) orelse continue;
            if (keyframe and declaration.important) continue;
            const name = try retainString(allocator, strings, try normalize.identifier(allocator, syntax.slice(declaration.name)));
            const value = try retainString(allocator, strings, try normalize.value(allocator, syntax, declaration.value));
            try declarations.putParsed(&properties, name, value, declaration.important);
        }
    }
    return properties;
}

const RuleParts = struct { prelude: frontend.Range, block: frontend.NodeId };

fn ruleParts(syntax: frontend.Syntax, id: frontend.NodeId) ?RuleParts {
    const node = syntax.node(id);
    var children = syntax.children(id);
    while (children.next()) |child| {
        if (syntax.node(child).kind != .block) continue;
        return .{ .prelude = .{
            .start = if (node.kind == .at_rule) node.head.end else node.range.start,
            .end = syntax.node(child).head.start,
        }, .block = child };
    }
    return null;
}

fn keyframeOffset(raw: []const u8) ?f64 {
    const token = std.mem.trim(u8, raw, " \t\r\n\x0c");
    if (std.ascii.eqlIgnoreCase(token, "from")) return 0;
    if (std.ascii.eqlIgnoreCase(token, "to")) return 1;
    if (!std.mem.endsWith(u8, token, "%")) return null;
    const percentage = std.fmt.parseFloat(f64, token[0 .. token.len - 1]) catch return null;
    if (!std.math.isFinite(percentage) or percentage < 0 or percentage > 100) return null;
    return percentage / 100;
}

fn cloneProperties(allocator: std.mem.Allocator, source: *const declarations.Map) !declarations.Map {
    var result = declarations.Map.init(allocator);
    errdefer result.deinit();
    try result.ensureUnusedCapacity(source.count());
    var entries = source.iterator();
    while (entries.next()) |entry| result.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
    return result;
}

fn cloneRule(allocator: std.mem.Allocator, source: parser.CSSRule) !parser.CSSRule {
    var selector = try source.selector.clone(allocator);
    errdefer selector.deinit(allocator);
    var properties = try cloneProperties(allocator, &source.properties);
    errdefer properties.deinit();
    return .{
        .selector = selector,
        .properties = properties,
        .source_url = if (source.source_url) |url| try allocator.dupe(u8, url) else null,
        .origin = source.origin,
        .referrer_policy = source.referrer_policy,
    };
}

fn cloneKeyframes(allocator: std.mem.Allocator, source: parser.KeyframesRule) !parser.KeyframesRule {
    const frames = try allocator.alloc(parser.Keyframe, source.frames.len);
    var initialized: usize = 0;
    errdefer {
        for (frames[0..initialized]) |*frame| frame.deinit();
        allocator.free(frames);
    }
    for (source.frames, frames) |frame, *copy| {
        copy.* = .{ .offset = frame.offset, .properties = try cloneProperties(allocator, &frame.properties) };
        initialized += 1;
    }
    return .{ .name = source.name, .frames = frames };
}

const test_allocator = std.testing.allocator;

fn expectValue(map: *const declarations.Map, name: []const u8, expected: []const u8) !void {
    const declaration = map.get(name) orelse return error.MissingDeclaration;
    try std.testing.expectEqualStrings(expected, declaration.value);
}

test "retained CSS adapts ordered declarations selectors recovery and token spelling" {
    var sheet = try Sheet.parse(test_allocator,
        \\p, #chosen { c\6f lor:r\65 d; color:unsupported; width:20p\78;
        \\  width:30/**/px; width:\31 0px; width:1\65 3px; margin:1px 2px!important;
        \\  margin-left:9px; --Color:g\72 een; --empty:;
        \\  background-color:r\67 b(0,128,0); @unknown { ignored:true; }
        \\  height:40px; & span { color:blue; } display:\62 lock; }
        \\p, :unknown { color:blue; } p, { color:blue; }
        \\@supports (display:block) { p { color:blue; } }
        \\#last { color:green
    , .{});
    defer sheet.deinit();
    var selection = try sheet.select(test_allocator, .{});
    defer selection.deinit();
    try std.testing.expectEqual(@as(usize, 3), selection.rules.len);
    const properties = &selection.rules[0].properties;
    try expectValue(properties, "color", "red");
    try expectValue(properties, "width", "20px");
    try expectValue(properties, "height", "40px");
    try expectValue(properties, "display", "block");
    try expectValue(properties, "background-color", "rgb(0,128,0)");
    try expectValue(properties, "margin-left", "2px");
    try std.testing.expect(properties.get("margin-left").?.important);
    try expectValue(properties, "--Color", "green");
    try expectValue(properties, "--empty", "");
    try std.testing.expect(selection.rules[0].cascadePriority() < selection.rules[1].cascadePriority());
    try expectValue(&selection.rules[2].properties, "color", "green");
    _ = selection.rules[0].properties.remove("color");
    try expectValue(&selection.rules[1].properties, "color", "red");
}

test "retained CSS media reselection preserves syntax selectors order and keyframes" {
    var sheet = try Sheet.parse(
        test_allocator,
        "p{color:red}" ++
            "@m\\65 dia (width>=600px){p{color:green}" ++
            "@media (height>500px){p{width:300px}" ++
            "@keyframes p\\75 lse{from{opacity:0.1;opacity:1!important}" ++
            "50%,75%{opacity:0.5}to{opacity:0.9}}}}" ++
            "@media not (1px < width > 2px){p{color:orange}}" ++
            "@media screen; p{height:40px}",
        .{},
    );
    defer sheet.deinit();
    const source = sheet.source();
    const stats = sheet.stats();
    var narrow = try sheet.select(test_allocator, .{ .viewport_width_css = 599, .viewport_height_css = 600 });
    defer narrow.deinit();
    var wide = try sheet.select(test_allocator, .{ .viewport_width_css = 600, .viewport_height_css = 600 });
    defer wide.deinit();
    var short = try sheet.select(test_allocator, .{ .viewport_width_css = 600, .viewport_height_css = 500 });
    defer short.deinit();
    try std.testing.expectEqual(@as(usize, 2), narrow.rules.len);
    try std.testing.expectEqual(@as(usize, 4), wide.rules.len);
    try std.testing.expectEqual(@as(usize, 3), short.rules.len);
    try std.testing.expectEqual(@as(usize, 0), narrow.keyframes.len);
    try std.testing.expectEqual(@as(usize, 1), wide.keyframes.len);
    try std.testing.expectEqual(@as(usize, 0), short.keyframes.len);
    try expectValue(&wide.rules[1].properties, "color", "green");
    try expectValue(&wide.rules[2].properties, "width", "300px");
    const pulse = &wide.keyframes[0];
    try std.testing.expectEqualStrings("pulse", pulse.name);
    try std.testing.expectEqual(@as(usize, 4), pulse.frames.len);
    try expectValue(&pulse.frameAt(0).?.properties, "opacity", "0.1");
    try expectValue(&pulse.frameAt(0.75).?.properties, "opacity", "0.5");
    try std.testing.expectEqual(source.ptr, sheet.source().ptr);
    try std.testing.expectEqualDeep(stats, sheet.stats());
    // Selections have independently owned maps and selectors, while values
    // deliberately share the immutable stylesheet generation.
    try std.testing.expectEqual(narrow.rules[0].properties.get("color").?.value.ptr, wide.rules[0].properties.get("color").?.value.ptr);
    _ = narrow.rules[0].properties.remove("color");
    try expectValue(&wide.rules[0].properties, "color", "red");
}

test "retained CSS source provenance moves independently of caller storage" {
    const input = try test_allocator.dupe(u8, "p{background-image:url(paint.png)}");
    const url = try test_allocator.dupe(u8, "https://example.test/assets/main.css");
    var original = Sheet.parse(test_allocator, input, .{ .base_url = url, .origin = .user_agent, .referrer_policy = .no_referrer }) catch |err| {
        test_allocator.free(input);
        test_allocator.free(url);
        return err;
    };
    @memset(input, 'x');
    @memset(url, 'x');
    test_allocator.free(input);
    test_allocator.free(url);
    var sheet = original;
    original = undefined;
    defer sheet.deinit();
    var first = try sheet.select(test_allocator, .{});
    defer first.deinit();
    var second = try sheet.select(test_allocator, .{});
    defer second.deinit();
    try std.testing.expectEqualStrings("p{background-image:url(paint.png)}", sheet.source());
    try std.testing.expectEqualStrings("https://example.test/assets/main.css", sheet.options().base_url.?);
    try std.testing.expectEqualStrings(sheet.options().base_url.?, first.rules[0].source_url.?);
    try std.testing.expect(first.rules[0].source_url.?.ptr != second.rules[0].source_url.?.ptr);
    try std.testing.expectEqual(.user_agent, first.rules[0].origin);
    try std.testing.expectEqual(.no_referrer, first.rules[0].referrer_policy);
}

test "Terence inline declarations use the same priority recovery and normalization" {
    var block = try DeclarationBlock.parse(test_allocator,
        \\--accent:g\72 een; color:var(--accent); margin:1px!important;
        \\margin-left:2px; @unknown x; width:12p\78; width:20/**/px;
        \\background-color:#\30 08800; color:unsupported;
    , .{});
    defer block.deinit();
    try expectValue(&block.properties, "color", "var(--accent)");
    try expectValue(&block.properties, "margin-left", "1px");
    try expectValue(&block.properties, "width", "12px");
    try expectValue(&block.properties, "background-color", "#008800");
    try expectValue(&block.properties, "--accent", "green");
}

fn allocationTrial(allocator: std.mem.Allocator) !void {
    var sheet = try Sheet.parse(
        allocator,
        "p, #x{c\\6flor:green!important; margin:1px 2px; --tone:red}" ++
            "@media(min-width:10px){p{color:var(--tone)}@keyframes pulse{from,to{opacity:0.5}}}",
        .{ .base_url = "https://example.test/style.css" },
    );
    defer sheet.deinit();
    var selection = try sheet.select(allocator, .{ .viewport_width_css = 20 });
    defer selection.deinit();
    try std.testing.expectEqual(@as(usize, 3), selection.rules.len);
    try std.testing.expectEqual(@as(usize, 1), selection.keyframes.len);
}

test "retained CSS allocation failures release syntax normalized values and cloned owners" {
    try std.testing.checkAllAllocationFailures(test_allocator, allocationTrial, .{});
}

fn declarationAllocationTrial(allocator: std.mem.Allocator) !void {
    var block = try DeclarationBlock.parse(allocator, "--x:g\\72 een; color:var(--x); width:30p\\78; @unknown x; margin:1px 2px!important", .{});
    defer block.deinit();
}

test "Terence inline declaration allocation failures release every source and map" {
    try std.testing.checkAllAllocationFailures(test_allocator, declarationAllocationTrial, .{});
}

test "retained CSS budget includes semantic selector expansion and URL clones" {
    const source = "p,p,p,p,p,p,p,p{color:green}";
    const base = "https://example.test/" ++ "a" ** 2048;
    const limits = Limits{ .allocated_bytes = 12 * 1024 };
    var syntax = try frontend.Syntax.parse(test_allocator, source, .{ .limits = limits, .base_url = base });
    defer syntax.deinit();
    try std.testing.expectError(error.MemoryLimitExceeded, Sheet.parse(test_allocator, source, .{ .limits = limits, .base_url = base }));
}

test "Terence declaration normalization recovers structural EOF and retains opaque payloads" {
    var math = try DeclarationBlock.parse(test_allocator, "width:calc(1px + 2px", .{});
    defer math.deinit();
    try expectValue(&math.properties, "width", "calc(1px + 2px)");
    var quoted = try DeclarationBlock.parse(test_allocator, "--text:\"r\\65 d; !important\"", .{});
    defer quoted.deinit();
    try expectValue(&quoted.properties, "--text", "\"r\\65 d; !important\"");
    // URL/string payloads still follow the existing property's raw-string
    // interface. Unlike structural function closure, their EOF normalization
    // awaits decoded string/URL values at that boundary.
    var url = try DeclarationBlock.parse(test_allocator, "--image:url(paint.png", .{});
    defer url.deinit();
    try expectValue(&url.properties, "--image", "url(paint.png");
    var string = try DeclarationBlock.parse(test_allocator, "--text:\"red", .{});
    defer string.deinit();
    try expectValue(&string.properties, "--text", "\"red");
}

test "Terence declaration edge trivia preserves escaped custom values" {
    var block = try DeclarationBlock.parse(test_allocator,
        \\--space:\ ; --digit:\31 ; color:green /* outer /* inner */;
    , .{});
    defer block.deinit();
    try expectValue(&block.properties, "--space", "\\ ");
    try expectValue(&block.properties, "--digit", "\\31 ");
    try expectValue(&block.properties, "color", "green");
}
