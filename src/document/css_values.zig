//! CSS value validation and serialization shared by declaration frontends.
//! Returned strings belong to the caller. Tokens retain source identity; custom
//! values and pending substitutions preserve spelling instead of folding data.
const std = @import("std");
pub const tokenizer = @import("css_tokenizer.zig");
const Kind = tokenizer.Kind;
const Token = tokenizer.Token;
pub const max_depth = 64;
pub const max_bytes = 1024 * 1024;

/// Normalize implemented primitive families after shorthand expansion. The
/// result borrows input/static storage or belongs to allocator. Named colors
/// retain their keyword; modern colors retain their color space, without changing
/// custom-property data or case-sensitive identifiers.
pub fn primitive(allocator: std.mem.Allocator, property: []const u8, input: []const u8) ![]const u8 {
    const grid_placement = @import("css_grid_placement.zig");
    if (grid_placement.isLineProperty(property)) return grid_placement.canonicalLine(allocator, input);
    if (std.mem.eql(u8, property, "grid-auto-flow")) {
        if (grid_placement.parseFlow(input)) |flow| return grid_placement.canonicalFlow(flow);
    }
    if (std.mem.startsWith(u8, property, "animation-") and !std.mem.eql(u8, property, "animation-name")) {
        return std.ascii.allocLowerString(allocator, input);
    }
    if (std.mem.eql(u8, property, "aspect-ratio")) {
        if (@import("css_aspect_ratio.zig").parse(input)) |ratio| return ratio.serialize(allocator);
    }
    if (std.mem.startsWith(u8, property, "align-") or std.mem.startsWith(u8, property, "justify-")) {
        if (@import("css_alignment.zig").parse(input)) |alignment| {
            if (alignment.keyword == .baseline) return "baseline";
        }
    }
    for (@import("css_properties.zig").computed) |entry| {
        if (!std.mem.eql(u8, entry.name, property)) continue;
        switch (entry.serialization) {
            .image => if (try @import("css_gradient.zig").serialize(allocator, input, .{}, .retained)) |gradient| return gradient,
            .tokens => {},
            .length => if (std.mem.eql(u8, input, "0")) {
                return "0px";
            },
            .position => {
                const position = @import("css_position.zig").parse(input) orelse return input;
                return position.serialize(allocator);
            },
            .color => {
                if (input.len == 0 or (input[0] != '#' and std.mem.indexOfScalar(u8, input, '(') == null)) return input;
                return try @import("color.zig").normalizeSpecified(allocator, input) orelse input;
            },
        }
        break;
    }
    return input;
}

pub const Options = struct {
    preserve: bool = false,
    fold_identifiers: bool = true,
};

/// Reject bad tokens, unmatched closers and excessive component nesting.
/// Open components at EOF are valid and repaired during serialization.
pub fn valid(input: []const u8) bool {
    if (input.len > max_bytes) return false;
    var stack: [max_depth]Kind = undefined;
    var variable: [max_depth]bool = undefined;
    var depth: usize = 0;
    var iterator = tokenizer.Iterator{ .input = input };
    while (iterator.next()) |token| {
        if (token.kind == .bad_string or token.kind == .bad_url) return false;
        if (depth > 0 and variable[depth - 1] and (token.kind == .semicolon or (token.kind == .delim and token.delim == '!'))) return false;
        const is_variable = token.kind == .function and tokenizer.identifierEquals(token.encodedValue(input), "var");
        if (is_variable) {
            var arguments = iterator;
            var name = arguments.next() orelse return false;
            while (name.isTrivia()) name = arguments.next() orelse return false;
            if (name.kind != .ident) return false;
            var decoded = tokenizer.Decoder{ .input = name.encodedValue(input) };
            if (decoded.next() != '-' or decoded.next() != '-' or decoded.next() == null) return false;
            var next = arguments.next();
            while (next != null and next.?.isTrivia()) next = arguments.next();
            if (next) |arg| if (arg.kind != .comma and arg.kind != .close_paren) {
                return false;
            };
        }
        if (token.closer()) |closer| {
            if (depth == stack.len) return false;
            stack[depth] = closer;
            variable[depth] = is_variable;
            depth += 1;
        } else if (token.isClose()) {
            if (depth == 0 or stack[depth - 1] != token.kind) return false;
            depth -= 1;
        }
    }
    return true;
}

/// CSS Syntax serialization table. A comment separates adjacent tokens without
/// inventing whitespace (which can change calc() and other property grammars).
pub fn needsSeparator(left: Token, right: Token) bool {
    const name = right.kind == .ident or right.kind == .function or right.kind == .url or right.kind == .bad_url;
    const numeric = right.kind == .number or right.kind == .percentage or right.kind == .dimension;
    const minus = right.kind == .delim and right.delim == '-';
    if (left.kind == .ident) return name or numeric or minus or right.kind == .cdc or right.kind == .open_paren;
    if (left.kind == .at_keyword or left.kind == .hash or left.kind == .dimension) return name or numeric or minus or right.kind == .cdc;
    if (left.kind == .number) return name or numeric or right.kind == .cdc or (right.kind == .delim and right.delim == '%');
    if (left.kind != .delim) return false;
    return switch (left.delim) {
        '#' => name or numeric or minus or right.kind == .cdc,
        '-' => name or numeric or minus or right.kind == .cdc,
        '@' => name or minus or right.kind == .cdc,
        '.', '+' => numeric,
        '/' => right.kind == .delim and right.delim == '*',
        else => false,
    };
}

/// Owned normalized component sequence, or null for invalid lexical input.
/// Standard values decode escapes and normalize numbers, units, strings and
/// separators. Preserve mode changes only preprocessing and EOF repairs.
pub fn normalize(allocator: std.mem.Allocator, input: []const u8, options: Options) !?[]u8 {
    if (!valid(input)) return null;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var stack: [max_depth]u8 = undefined;
    var depth: usize = 0;
    var previous: ?Token = null;
    var space = false;
    var iterator = tokenizer.Iterator{ .input = input };
    while (iterator.next()) |token| {
        if (token.closer() != null) {
            stack[depth] = switch (token.kind) {
                .open_curly => '}',
                .open_square => ']',
                else => ')',
            };
            depth += 1;
        } else if (token.isClose()) depth -= 1;
        if (options.preserve) {
            try preserveToken(allocator, &output, input, token);
            if (output.items.len > max_bytes) {
                output.deinit(allocator);
                return null;
            }
            continue;
        }
        if (token.kind == .whitespace) {
            space = true;
            continue;
        }
        if (token.kind == .comment) continue;
        if (previous) |left| {
            const interior = left.closer() != null or token.isClose() or token.kind == .comma;
            if (!interior and (space or left.kind == .comma)) {
                try output.append(allocator, ' ');
            } else if (needsSeparator(left, token)) try output.appendSlice(allocator, "/**/");
        }
        try serializeToken(allocator, &output, input, token, options);
        previous = token;
        space = false;
        if (output.items.len > max_bytes) {
            output.deinit(allocator);
            return null;
        }
    }
    while (depth > 0) {
        depth -= 1;
        try output.append(allocator, stack[depth]);
    }
    return try output.toOwnedSlice(allocator);
}

fn preserveToken(allocator: std.mem.Allocator, output: *std.ArrayList(u8), input: []const u8, token: Token) !void {
    var end = token.end;
    const escape_eof = end == input.len and end > token.start and input[end - 1] == '\\' and
        (token.kind == .ident or token.kind == .dimension or token.kind == .hash or token.kind == .at_keyword or token.kind == .url or token.kind == .string);
    // Only an unpaired final backslash escapes EOF. A literal escaped backslash
    // is retained; counting the final run distinguishes those two token values.
    var backslashes: usize = 0;
    if (escape_eof) {
        var i = end;
        while (i > token.start and input[i - 1] == '\\') : (i -= 1) backslashes += 1;
    }
    const repair_escape = escape_eof and backslashes % 2 == 1;
    if (repair_escape) end -= 1;
    var cursor = token.start;
    while (cursor < end) {
        const p = tokenizer.point(input[0..end], cursor).?;
        try tokenizer.appendPoint(allocator, output, p.value);
        cursor = p.end;
    }
    if (repair_escape and token.kind != .string) try tokenizer.appendPoint(allocator, output, 0xfffd);
    if (!token.closed) switch (token.kind) {
        .string => try output.append(allocator, input[token.start]),
        .url => try output.append(allocator, ')'),
        .comment => try output.appendSlice(allocator, "*/"),
        else => {},
    };
}

fn serializeToken(allocator: std.mem.Allocator, output: *std.ArrayList(u8), input: []const u8, token: Token, options: Options) !void {
    switch (token.kind) {
        .ident, .function, .at_keyword, .hash => {
            if (token.kind == .at_keyword) try output.append(allocator, '@');
            if (token.kind == .hash) try output.append(allocator, '#');
            try serializeName(allocator, output, token.encodedValue(input), .{
                .fold = if (token.kind == .function) true else options.fold_identifiers,
                .unrestricted = token.kind == .hash and token.hash_type == .unrestricted,
            });
            if (token.kind == .function) try output.append(allocator, '(');
        },
        .string => try serializeString(allocator, output, token.encodedValue(input), true),
        .url => {
            try output.appendSlice(allocator, "url(");
            try serializeString(allocator, output, token.encodedValue(input), false);
            try output.append(allocator, ')');
        },
        .number, .percentage, .dimension => {
            try serializeNumber(allocator, output, input[token.start..token.number_end]);
            if (token.kind == .percentage) try output.append(allocator, '%');
            if (token.kind == .dimension) try serializeName(allocator, output, token.encodedValue(input), .{ .fold = true, .dimension = true });
        },
        .delim => {
            try tokenizer.appendPoint(allocator, output, token.delim);
            if (token.delim == '\\') try output.append(allocator, '\n');
        },
        else => try output.appendSlice(allocator, token.raw(input)),
    }
}

const NameOptions = struct { fold: bool = false, unrestricted: bool = false, dimension: bool = false };

/// Serialize an encoded CSS name while preserving its token identity. CSSOM
/// literal names use serializeIdentifier instead of passing through decoding.
fn serializeName(allocator: std.mem.Allocator, output: *std.ArrayList(u8), raw: []const u8, options: NameOptions) !void {
    var decoder = tokenizer.Decoder{ .input = raw };
    var prefix = decoder;
    const custom_name = prefix.next() == '-' and prefix.next() == '-';
    var index: usize = 0;
    var first: u21 = 0;
    while (decoder.next()) |decoded| : (index += 1) {
        const scalar: u21 = if (options.fold and !custom_name and decoded <= 127) std.ascii.toLower(@intCast(decoded)) else decoded;
        if (index == 0) first = scalar;
        var lookahead = decoder;
        const next = lookahead.next();
        const number_start = !options.unrestricted and ((index == 0 or (index == 1 and first == '-')) and scalar >= '0' and scalar <= '9');
        // A dimension unit starting with e followed by digits/sign-digits could
        // turn into the number's exponent after escapes are decoded.
        const exponent = options.dimension and index == 0 and scalar == 'e' and next != null and
            ((next.? >= '0' and next.? <= '9') or next.? == '-' or next.? == '+');
        if (scalar <= 31 or scalar == 127 or number_start or exponent) {
            var buffer: [16]u8 = undefined;
            try output.appendSlice(allocator, (std.fmt.bufPrint(&buffer, "\\{x} ", .{scalar}) catch unreachable));
        } else if ((scalar >= 'a' and scalar <= 'z') or (scalar >= 'A' and scalar <= 'Z') or
            (scalar >= '0' and scalar <= '9') or scalar >= 128 or scalar == '_' or (scalar == '-' and !(index == 0 and next == null and !options.unrestricted)))
        {
            try tokenizer.appendPoint(allocator, output, scalar);
        } else {
            try output.append(allocator, '\\');
            try tokenizer.appendPoint(allocator, output, scalar);
        }
    }
}

pub fn serializeIdentifier(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Escape literal backslashes before using the same identifier serializer.
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(allocator);
    for (input) |c| {
        if (c == '\\') try encoded.append(allocator, '\\');
        try encoded.append(allocator, c);
    }
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try serializeName(allocator, &output, encoded.items, .{});
    return output.toOwnedSlice(allocator);
}

fn serializeString(allocator: std.mem.Allocator, output: *std.ArrayList(u8), raw: []const u8, string: bool) !void {
    try output.append(allocator, '"');
    // URL escapes consume EOF as U+FFFD; a quoted string drops escaped EOF.
    var decoder = tokenizer.Decoder{ .input = raw, .string = string };
    while (decoder.next()) |scalar| {
        if (scalar <= 31 or scalar == 127) {
            var buffer: [16]u8 = undefined;
            try output.appendSlice(allocator, (std.fmt.bufPrint(&buffer, "\\{x} ", .{scalar}) catch unreachable));
        } else {
            if (scalar == '"' or scalar == '\\') try output.append(allocator, '\\');
            try tokenizer.appendPoint(allocator, output, scalar);
        }
    }
    try output.append(allocator, '"');
}

/// Decimal normalization without a float round-trip: arbitrary integer digits
/// retain their precision. Exponent expansion is bounded by max_bytes.
fn serializeNumber(allocator: std.mem.Allocator, output: *std.ArrayList(u8), raw: []const u8) !void {
    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(allocator);
    var start: usize = 0;
    const negative = raw[0] == '-';
    if (raw[0] == '+' or raw[0] == '-') start += 1;
    const exponent_start = std.mem.indexOfAnyPos(u8, raw, start, "eE") orelse raw.len;
    var decimal: i64 = 0;
    var dot = false;
    for (raw[start..exponent_start]) |c| {
        if (c == '.') {
            dot = true;
            continue;
        }
        try digits.append(allocator, c);
        if (!dot) decimal += 1;
    }
    const exponent = if (exponent_start < raw.len) std.fmt.parseInt(i64, raw[exponent_start + 1 ..], 10) catch {
        try output.appendSlice(allocator, raw);
        return;
    } else 0;
    if (exponent > 4096 or exponent < -4096 or raw.len > 4096) {
        // Keep extreme numeric source finite in storage; the property family
        // decides representability. Never truncate or accidentally make zero.
        try output.appendSlice(allocator, raw[if (raw[0] == '+') @as(usize, 1) else 0..]);
        return;
    }
    decimal += exponent;
    var leading: usize = 0;
    while (leading < digits.items.len and digits.items[leading] == '0') : (leading += 1) {}
    if (leading == digits.items.len) {
        try output.append(allocator, '0');
        return;
    }
    decimal -= @intCast(leading);
    var end = digits.items.len;
    while (end > leading and digits.items[end - 1] == '0') end -= 1;
    const significant = digits.items[leading..end];
    if (negative) try output.append(allocator, '-');
    if (decimal <= 0) {
        try output.appendSlice(allocator, "0.");
        try output.appendNTimes(allocator, '0', @intCast(-decimal));
        try output.appendSlice(allocator, significant);
    } else if (decimal >= significant.len) {
        try output.appendSlice(allocator, significant);
        try output.appendNTimes(allocator, '0', @as(usize, @intCast(decimal)) - significant.len);
    } else {
        const pos: usize = @intCast(decimal);
        try output.appendSlice(allocator, significant[0..pos]);
        try output.append(allocator, '.');
        try output.appendSlice(allocator, significant[pos..]);
    }
}

test "CSS values normalize escapes numbers strings URLs and component EOF" {
    const cases = [_][2][]const u8{
        .{ " +001.2500P\\58 ", "1.25px" },
        .{ "-0.00EM", "0em" },
        .{ "1e2px", "100px" },
        .{ "\\67 reen", "green" },
        .{ "RGB( 001, .50, 3 )", "rgb(1, 0.5, 3)" },
        .{ "url( A\\20 B.png", "url(\"A B.png\")" },
        .{ "url(foo\\", "url(\"foo�\")" },
        .{ "'A\\\r\nB", "\"AB\"" },
        .{ "f([{}]", "f([{}])" },
        .{ "1/**/px", "1/**/px" },
        .{ "1\\65 2", "1\\65 2" },
        .{ "1.000000000000001px", "1.000000000000001px" },
        .{ "1/**/-->", "1/**/-->" },
        .{ "#/**/-->", "#/**/-->" },
        .{ "@/**/-->", "@/**/-->" },
        .{ "-/**/-->", "-/**/-->" },
    };
    for (cases) |case| {
        const value = (try normalize(std.testing.allocator, case[0], .{})).?;
        defer std.testing.allocator.free(value);
        try std.testing.expectEqualStrings(case[1], value);
    }
    for ([_][]const u8{ "url(a b)", "'a\nb", "f(])", "f(" ** 65, "var(--x, red!important)", "var(--x, ;)" }) |input| try std.testing.expect(!valid(input));
}

test "CSS values preserve custom spelling but repair EOF and preprocess scalars" {
    const cases = [_][2][]const u8{
        .{ "A/**/ +01.00PX  url(A.png)", "A/**/ +01.00PX  url(A.png)" },
        .{ "foo\\", "foo�" },
        .{ "'foo\\", "'foo'" },
        .{ "url(foo\\", "url(foo�)" },
        .{ "f([", "f([])" },
        .{ "a\r\nb\x00", "a\nb�" },
    };
    for (cases) |case| {
        const result = (try normalize(std.testing.allocator, case[0], .{ .preserve = true })).?;
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings(case[1], result);
    }
}
