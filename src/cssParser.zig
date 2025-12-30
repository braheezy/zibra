const std = @import("std");
const selector_mod = @import("selector.zig");
const Selector = selector_mod.Selector;
const TagSelector = selector_mod.TagSelector;
const DescendantSelector = selector_mod.DescendantSelector;

pub const CSSParser = @This();

string: []const u8,
pos: usize,

pub fn init(allocator: std.mem.Allocator, string: []const u8) !*CSSParser {
    const parser = try allocator.create(CSSParser);
    parser.* = CSSParser{
        .string = string,
        .pos = 0,
    };
    return parser;
}

pub fn deinit(self: *CSSParser, allocator: std.mem.Allocator) void {
    allocator.destroy(self);
}

pub fn whitespace(self: *CSSParser) void {
    while (self.pos < self.string.len and std.ascii.isWhitespace(self.string[self.pos])) {
        self.pos += 1;
    }
}

pub fn word(self: *CSSParser) ![]const u8 {
    const start = self.pos;
    while (self.pos < self.string.len) {
        const c = self.string[self.pos];
        if (std.ascii.isAlphanumeric(c) or c == '#' or c == '-' or c == '.' or c == '%') {
            self.pos += 1;
        } else {
            break;
        }
    }
    if (self.pos <= start) {
        return error.InvalidWord;
    }
    return self.string[start..self.pos];
}

pub fn literal(self: *CSSParser, lit: u8) !void {
    if (self.pos >= self.string.len or self.string[self.pos] != lit) {
        return error.InvalidLiteral;
    }
    self.pos += 1;
}

/// Read a CSS value until `;` or `}`, trimming trailing whitespace
pub fn value(self: *CSSParser) ![]const u8 {
    const start = self.pos;
    while (self.pos < self.string.len) {
        const c = self.string[self.pos];
        if (c == ';' or c == '}') {
            break;
        }
        self.pos += 1;
    }
    if (self.pos <= start) {
        return error.InvalidValue;
    }
    // Trim trailing whitespace
    var end = self.pos;
    while (end > start and std.ascii.isWhitespace(self.string[end - 1])) {
        end -= 1;
    }
    return self.string[start..end];
}

pub fn pair(self: *CSSParser) !struct { property: []const u8, value: []const u8 } {
    const property = try self.word();
    self.whitespace();
    try self.literal(':');
    self.whitespace();
    const val = try self.value();
    return .{ .property = property, .value = val };
}

pub fn body(self: *CSSParser, allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    // Stop at closing brace
    while (self.pos < self.string.len and self.string[self.pos] != '}') {
        // Try to parse a property-value pair, but catch any errors
        const result = self.pair() catch {
            // If parsing failed, skip to the next semicolon or closing brace
            const why = self.ignoreUntil(";}");
            if (why) |char| {
                if (char == ';') {
                    _ = self.literal(';') catch {};
                    self.whitespace();
                } else {
                    // Hit closing brace, stop parsing
                    break;
                }
            } else {
                // Reached end of string without finding a semicolon or brace
                break;
            }
            continue;
        };

        // Just store the slices directly - caller is responsible for memory management
        try map.put(result.property, result.value);
        self.whitespace();
        _ = self.literal(';') catch {};
        self.whitespace();
    }
    return map;
}

pub fn ignoreUntil(self: *CSSParser, chars: []const u8) ?u8 {
    while (self.pos < self.string.len) {
        const current_char = self.string[self.pos];
        for (chars) |c| {
            if (current_char == c) {
                return current_char;
            }
        }
        self.pos += 1;
    }
    return null;
}

/// Parse a CSS selector (tag selector or descendant selector)
/// Note: Using word() for tag names means .class and #id selectors
/// are mis-parsed as tag selectors, but this won't cause harm since
/// there are no elements with those tags
pub fn selector(self: *CSSParser, allocator: std.mem.Allocator) !Selector {
    // Start with a tag selector
    const first_tag = try self.word();

    // Convert to lowercase (casefold in Python)
    const lower_tag = try std.ascii.allocLowerString(allocator, first_tag);
    defer allocator.free(lower_tag);

    // Allocate permanent storage for the tag
    const tag_copy = try allocator.alloc(u8, lower_tag.len);
    @memcpy(tag_copy, lower_tag);

    var out = Selector{ .tag = TagSelector.init(tag_copy) };
    self.whitespace();

    // Continue parsing descendant selectors until we hit '{'
    while (self.pos < self.string.len and self.string[self.pos] != '{') {
        const tag = try self.word();

        // Convert to lowercase
        const lower_descendant = try std.ascii.allocLowerString(allocator, tag);
        defer allocator.free(lower_descendant);

        // Allocate permanent storage
        const descendant_tag_copy = try allocator.alloc(u8, lower_descendant.len);
        @memcpy(descendant_tag_copy, lower_descendant);

        const descendant = Selector{ .tag = TagSelector.init(descendant_tag_copy) };

        // Create a descendant selector: out is the ancestor, descendant is the child
        const desc_selector = try DescendantSelector.init(allocator, out, descendant);
        out = Selector{ .descendant = desc_selector };

        self.whitespace();
    }

    return out;
}

/// CSS Rule - a selector and its associated property-value pairs
pub const CSSRule = struct {
    selector: Selector,
    properties: std.StringHashMap([]const u8),

    pub fn deinit(self: *CSSRule, allocator: std.mem.Allocator) void {
        // Free the selector's allocated memory (pass pointer since deinit expects *Selector)
        Selector.deinit(&self.selector, allocator);

        // Free the properties hashmap structure (keys/values managed by arena)
        self.properties.deinit();
    }

    /// Get the cascade priority of this rule
    /// Used for sorting - more specific selectors override less specific ones
    pub fn cascadePriority(self: CSSRule) u32 {
        return self.selector.priority();
    }
};

/// Parse a full CSS file into a list of rules
pub fn parse(self: *CSSParser, allocator: std.mem.Allocator) ![]CSSRule {
    var rules = std.ArrayList(CSSRule).empty;
    errdefer {
        for (rules.items) |*rule| {
            var mutable_rule = rule;
            mutable_rule.deinit(allocator);
        }
        rules.deinit(allocator);
    }

    while (self.pos < self.string.len) {
        self.whitespace();

        // Try to parse a complete rule, but catch errors and skip the rule
        const rule_result = blk: {
            // Parse selector
            const sel = self.selector(allocator) catch {
                // If selector parsing failed, skip to closing brace
                const why = self.ignoreUntil("}");
                if (why) |char| {
                    if (char == '}') {
                        _ = self.literal('}') catch {};
                        self.whitespace();
                    }
                } else {
                    // Reached end of string
                    break;
                }
                continue;
            };

            // Expect '{'
            self.literal('{') catch {
                // Free the selector before skipping
                var sel_mut = sel;
                sel_mut.deinit(allocator);

                // Skip to closing brace
                const why = self.ignoreUntil("}");
                if (why) |char| {
                    if (char == '}') {
                        _ = self.literal('}') catch {};
                        self.whitespace();
                    }
                } else {
                    break;
                }
                continue;
            };
            self.whitespace();

            // Parse properties
            const properties = self.body(allocator) catch {
                // Free the selector before skipping
                var sel_mut = sel;
                sel_mut.deinit(allocator);

                // Skip to closing brace
                const why = self.ignoreUntil("}");
                if (why) |char| {
                    if (char == '}') {
                        _ = self.literal('}') catch {};
                        self.whitespace();
                    }
                } else {
                    break;
                }
                continue;
            };

            // Expect '}'
            self.literal('}') catch {
                // Free the selector and properties before skipping
                var sel_mut = sel;
                sel_mut.deinit(allocator);
                var props = properties;
                props.deinit();

                // Already at end or past it, just continue
                continue;
            };

            break :blk CSSRule{
                .selector = sel,
                .properties = properties,
            };
        };

        // Add rule if we successfully parsed one
        try rules.append(allocator, rule_result);
    }

    return rules.toOwnedSlice(allocator);
}
