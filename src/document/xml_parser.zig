//! Bounded XML tree builder for detached DOMParser documents.
//!
//! This is deliberately separate from the HTML tree builder: XML has no tag
//! soup recovery, preserves qualified-name case, requires quoted attributes,
//! and reports malformed input through a parser-error document at the host
//! boundary. Nodes borrow the parser input; the WindowRealm owns that buffer.

const std = @import("std");
const dom = @import("dom.zig");

const Node = dom.Node;
const Element = dom.Element;

pub const Error = error{MalformedXml};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    body: []const u8,
    stack: std.ArrayList(Node),
    root: ?Node = null,

    pub fn init(allocator: std.mem.Allocator, body: []const u8) Parser {
        return .{ .allocator = allocator, .body = body, .stack = std.ArrayList(Node).empty };
    }

    pub fn deinit(self: *Parser) void {
        for (self.stack.items) |*node| node.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        if (self.root) |*node| node.deinit(self.allocator);
        self.root = null;
    }

    /// Parse one XML document. The returned Node is moved out of the parser;
    /// the caller must repair parent pointers after storing it stably.
    pub fn parse(self: *Parser) !Node {
        var pos: usize = if (std.mem.startsWith(u8, self.body, "\xef\xbb\xbf")) 3 else 0;
        var text_start = pos;
        while (pos < self.body.len) {
            if (self.body[pos] != '<') {
                pos += 1;
                continue;
            }
            try self.appendText(self.body[text_start..pos]);

            if (std.mem.startsWith(u8, self.body[pos..], "<!--")) {
                const end = std.mem.indexOfPos(u8, self.body, pos + 4, "-->") orelse return error.MalformedXml;
                pos = end + 3;
            } else if (std.mem.startsWith(u8, self.body[pos..], "<![CDATA[")) {
                const content_start = pos + "<![CDATA[".len;
                const end = std.mem.indexOfPos(u8, self.body, content_start, "]]>") orelse return error.MalformedXml;
                try self.appendText(self.body[content_start..end]);
                pos = end + 3;
            } else if (std.mem.startsWith(u8, self.body[pos..], "<?")) {
                const end = std.mem.indexOfPos(u8, self.body, pos + 2, "?>") orelse return error.MalformedXml;
                pos = end + 2;
            } else if (std.mem.startsWith(u8, self.body[pos..], "<!DOCTYPE")) {
                if (self.root != null or self.stack.items.len != 0) return error.MalformedXml;
                pos = try findDoctypeEnd(self.body, pos + "<!DOCTYPE".len);
            } else if (std.mem.startsWith(u8, self.body[pos..], "</")) {
                const end = try findTagEnd(self.body, pos + 2);
                try self.closeElement(self.body[pos + 2 .. end]);
                pos = end + 1;
            } else if (std.mem.startsWith(u8, self.body[pos..], "<!")) {
                return error.MalformedXml;
            } else {
                const end = try findTagEnd(self.body, pos + 1);
                try self.openElement(self.body[pos + 1 .. end]);
                pos = end + 1;
            }
            text_start = pos;
        }
        try self.appendText(self.body[text_start..]);
        if (self.stack.items.len != 0 or self.root == null) return error.MalformedXml;
        const result = self.root orelse return error.MalformedXml;
        self.root = null;
        return result;
    }

    fn appendText(self: *Parser, raw: []const u8) !void {
        if (raw.len == 0) return;
        if (self.stack.items.len == 0) {
            for (raw) |byte| if (!std.ascii.isWhitespace(byte)) return error.MalformedXml;
            return;
        }
        const decoded = try decodeXmlText(self.allocator, raw);
        var node = Node{ .text = .{ .text = decoded.bytes, .parent = null, .owned_text = decoded.owned } };
        errdefer node.deinit(self.allocator);
        try self.stack.items[self.stack.items.len - 1].appendChild(self.allocator, node);
        if (decoded.owned) {
            // Ownership moved into the child Node. The local union no longer
            // owns the bytes, despite retaining the copied discriminant.
            node.text.owned_text = false;
        }
    }

    fn openElement(self: *Parser, raw: []const u8) !void {
        var source = std.mem.trim(u8, raw, " \t\r\n");
        var self_closing = false;
        if (std.mem.endsWith(u8, source, "/")) {
            self_closing = true;
            source = std.mem.trim(u8, source[0 .. source.len - 1], " \t\r\n");
        }
        const name_end = xmlNameEnd(source, 0) orelse return error.MalformedXml;
        if (name_end == 0) return error.MalformedXml;
        const name = source[0..name_end];
        var element = try Element.initXml(self.allocator, name, null);
        var element_live = true;
        errdefer if (element_live) element.deinit(self.allocator);

        var names = std.StringHashMap(void).init(self.allocator);
        defer names.deinit();
        var pos = name_end;
        while (true) {
            while (pos < source.len and std.ascii.isWhitespace(source[pos])) : (pos += 1) {}
            if (pos == source.len) break;
            const attr_start = pos;
            const attr_end = xmlNameEnd(source, pos) orelse return error.MalformedXml;
            if (attr_end == attr_start) return error.MalformedXml;
            const attr_name = source[attr_start..attr_end];
            if (names.contains(attr_name)) return error.MalformedXml;
            try names.put(attr_name, {});
            pos = attr_end;
            while (pos < source.len and std.ascii.isWhitespace(source[pos])) : (pos += 1) {}
            if (pos >= source.len or source[pos] != '=') return error.MalformedXml;
            pos += 1;
            while (pos < source.len and std.ascii.isWhitespace(source[pos])) : (pos += 1) {}
            if (pos >= source.len or (source[pos] != '\'' and source[pos] != '"')) return error.MalformedXml;
            const quote = source[pos];
            pos += 1;
            const value_start = pos;
            while (pos < source.len and source[pos] != quote) : (pos += 1) {}
            if (pos >= source.len) return error.MalformedXml;
            const decoded = try decodeXmlText(self.allocator, source[value_start..pos]);
            defer if (decoded.owned) self.allocator.free(decoded.bytes);
            try element.putXmlAttribute(self.allocator, attr_name, decoded.bytes);
            pos += 1;
        }

        if (self.stack.items.len == 0 and self.root != null) return error.MalformedXml;
        var node = Node{ .element = element };
        var node_live = true;
        errdefer if (node_live) node.deinit(self.allocator);
        element_live = false;
        if (self_closing) {
            try self.appendCompleted(node);
        } else {
            try self.stack.append(self.allocator, node);
        }
        node_live = false;
    }

    fn closeElement(self: *Parser, raw: []const u8) !void {
        const name = std.mem.trim(u8, raw, " \t\r\n");
        const name_end = xmlNameEnd(name, 0) orelse return error.MalformedXml;
        if (name_end != name.len or self.stack.items.len == 0) return error.MalformedXml;
        var node = self.stack.pop() orelse return error.MalformedXml;
        var node_live = true;
        errdefer if (node_live) node.deinit(self.allocator);
        if (node.element.tag.len != name.len or !std.mem.eql(u8, node.element.tag, name)) return error.MalformedXml;
        try self.appendCompleted(node);
        node_live = false;
    }

    fn appendCompleted(self: *Parser, node: Node) !void {
        if (self.stack.items.len != 0) {
            try self.stack.items[self.stack.items.len - 1].appendChild(self.allocator, node);
        } else {
            if (self.root != null) return error.MalformedXml;
            self.root = node;
        }
    }
};

const Decoded = struct { bytes: []const u8, owned: bool };

fn decodeXmlText(allocator: std.mem.Allocator, raw: []const u8) !Decoded {
    const needs_copy = std.mem.indexOfScalar(u8, raw, '&') != null or std.mem.indexOfScalar(u8, raw, '\r') != null;
    if (!needs_copy) return .{ .bytes = raw, .owned = false };
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var pos: usize = 0;
    while (pos < raw.len) {
        if (raw[pos] == '\r') {
            try output.append(allocator, '\n');
            pos += 1;
            if (pos < raw.len and raw[pos] == '\n') pos += 1;
            continue;
        }
        if (raw[pos] != '&') {
            try output.append(allocator, raw[pos]);
            pos += 1;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, raw, pos + 1, ';') orelse return error.MalformedXml;
        const entity = raw[pos + 1 .. end];
        const codepoint: u21 = if (std.mem.eql(u8, entity, "amp")) '&' else if (std.mem.eql(u8, entity, "lt")) '<' else if (std.mem.eql(u8, entity, "gt")) '>' else if (std.mem.eql(u8, entity, "apos")) '\'' else if (std.mem.eql(u8, entity, "quot")) '"' else try parseNumericEntity(entity);
        var encoded: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(codepoint, &encoded);
        try output.appendSlice(allocator, encoded[0..length]);
        pos = end + 1;
    }
    return .{ .bytes = try output.toOwnedSlice(allocator), .owned = true };
}

fn parseNumericEntity(entity: []const u8) !u21 {
    if (entity.len < 2 or entity[0] != '#') return error.MalformedXml;
    const hex = entity.len > 2 and (entity[1] == 'x' or entity[1] == 'X');
    const digits = if (hex) entity[2..] else entity[1..];
    if (digits.len == 0) return error.MalformedXml;
    const radix: u32 = if (hex) 16 else 10;
    var value: u32 = 0;
    for (digits) |byte| {
        const digit: u32 = if (byte >= '0' and byte <= '9') byte - '0' else if (hex and byte >= 'a' and byte <= 'f') byte - 'a' + 10 else if (hex and byte >= 'A' and byte <= 'F') byte - 'A' + 10 else return error.MalformedXml;
        if (digit >= radix or value > (0x10ffff - digit) / radix) return error.MalformedXml;
        value = value * radix + digit;
    }
    if (value == 0 or value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) return error.MalformedXml;
    return @intCast(value);
}

fn xmlNameEnd(source: []const u8, start: usize) ?usize {
    if (start >= source.len or !isNameStart(source[start])) return null;
    var pos = start + 1;
    while (pos < source.len and isNameContinue(source[pos])) : (pos += 1) {}
    return pos;
}

fn isNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == ':';
}

fn isNameContinue(byte: u8) bool {
    return isNameStart(byte) or std.ascii.isDigit(byte) or byte == '-' or byte == '.';
}

fn findTagEnd(source: []const u8, start: usize) !usize {
    var quote: ?u8 = null;
    var pos = start;
    while (pos < source.len) : (pos += 1) {
        if (quote) |expected| {
            if (source[pos] == expected) quote = null;
        } else if (source[pos] == '\'' or source[pos] == '"') {
            quote = source[pos];
        } else if (source[pos] == '>') {
            return pos;
        }
    }
    return error.MalformedXml;
}

fn findDoctypeEnd(source: []const u8, start: usize) !usize {
    var subset_depth: usize = 0;
    var quote: ?u8 = null;
    var pos = start;
    while (pos < source.len) : (pos += 1) {
        if (quote) |expected| {
            if (source[pos] == expected) quote = null;
        } else if (source[pos] == '\'' or source[pos] == '"') {
            quote = source[pos];
        } else if (source[pos] == '[') {
            subset_depth += 1;
        } else if (source[pos] == ']' and subset_depth > 0) {
            subset_depth -= 1;
        } else if (source[pos] == '>' and subset_depth == 0) {
            return pos + 1;
        }
    }
    return error.MalformedXml;
}
