const std = @import("std");

const self_closing_tags = [_][]const u8{
    "area",
    "base",
    "br",
    "col",
    "embed",
    "hr",
    "img",
    "input",
    "link",
    "meta",
    "param",
    "source",
    "track",
    "wbr",
};

const Text = struct {
    text: []const u8,
    parent: ?*Node = null,
    children: ?std.ArrayList(*Node) = null,

    pub fn init(allocator: std.mem.Allocator, text: []const u8, parent: *Node) !*Text {
        const t = try allocator.create(Text);
        t.* = Text{
            .text = text,
            .parent = parent,
            .children = std.ArrayList(*Node).init(allocator),
        };
        return t;
    }

    pub fn deinit(self: *Text, allocator: std.mem.Allocator) void {
        if (self.children) |children| {
            for (children.items) |child| {
                child.deinit(allocator);
            }
            children.deinit();
        }
        allocator.free(self.text);
        allocator.destroy(self);
    }
};

const Element = struct {
    tag: []const u8,
    attributes: ?std.StringHashMap([]const u8) = null,
    parent: ?*Node = null,
    children: ?std.ArrayList(*Node) = null,

    pub fn init(allocator: std.mem.Allocator, tag: []const u8, parent: ?*Node) !*Element {
        var e = try allocator.create(Element);
        e.parent = parent;
        e.attributes = null;
        e.children = std.ArrayList(*Node).init(allocator);
        try e.parse(allocator, tag);
        return e;
    }

    pub fn deinit(self: *Element, allocator: std.mem.Allocator) void {
        if (self.children) |children| {
            // Free all child nodes first
            for (children.items) |child| {
                child.deinit(allocator);
            }
            // Then free the ArrayList itself
            children.deinit();
        }

        if (self.attributes) |attributes| {
            var it = attributes.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            self.attributes.?.deinit();
        }

        allocator.free(self.tag);
        allocator.destroy(self);
    }

    fn parse(self: *Element, al: std.mem.Allocator, raw: []const u8) !void {
        var idx: usize = 0;
        // Skip any leading whitespace.
        while (idx < raw.len and std.ascii.isWhitespace(raw[idx])) : (idx += 1) {}

        // Parse the tag name: read until whitespace.
        const start_name = idx;
        while (idx < raw.len and !std.ascii.isWhitespace(raw[idx])) : (idx += 1) {}
        const tag_name_slice = raw[start_name..idx];
        const tag_name = try al.dupe(u8, tag_name_slice);
        self.tag = tag_name;

        // Parse attributes (if any)
        while (idx < raw.len) {
            // Skip whitespace.
            while (idx < raw.len and std.ascii.isWhitespace(raw[idx])) : (idx += 1) {}
            if (idx >= raw.len) break;

            // Capture attribute name.
            const attr_start = idx;
            while (idx < raw.len and raw[idx] != '=' and !std.ascii.isWhitespace(raw[idx])) : (idx += 1) {}
            const attr_name_slice = raw[attr_start..idx];

            // Skip whitespace until '='.
            while (idx < raw.len and std.ascii.isWhitespace(raw[idx])) : (idx += 1) {}

            // Handle boolean attributes (no value)
            if (idx >= raw.len or raw[idx] != '=') {
                // This is a boolean attribute
                if (self.attributes == null) {
                    self.attributes = std.StringHashMap([]const u8).init(al);
                }
                const key_dup = try al.dupe(u8, attr_name_slice);
                const empty_value = try al.dupe(u8, "");
                try self.attributes.?.put(key_dup, empty_value);
                continue;
            }

            idx += 1; // skip '='

            // Skip whitespace.
            while (idx < raw.len and std.ascii.isWhitespace(raw[idx])) : (idx += 1) {}
            if (idx >= raw.len) break;

            // Handle value - either quoted or unquoted
            var value_slice: []const u8 = undefined;

            const quote = raw[idx];
            if (quote == '"' or quote == '\'') {
                // Handle quoted value
                idx += 1; // skip opening quote
                const value_start = idx;

                while (idx < raw.len and raw[idx] != quote) : (idx += 1) {}
                if (idx >= raw.len) {
                    std.log.info("Invalid attribute format: {s}", .{raw});
                    return error.InvalidAttributeFormat;
                }

                value_slice = raw[value_start..idx];
                idx += 1; // skip closing quote
            } else {
                // Handle unquoted value
                const value_start = idx;
                while (idx < raw.len and !std.ascii.isWhitespace(raw[idx])) : (idx += 1) {}
                value_slice = raw[value_start..idx];
            }

            if (self.attributes == null) {
                self.attributes = std.StringHashMap([]const u8).init(al);
            }

            // Duplicate keys and values so the Element assumes ownership
            const key_dup = try al.dupe(u8, attr_name_slice);
            const value_dup = try al.dupe(u8, value_slice);
            try self.attributes.?.put(key_dup, value_dup);
        }
    }
};

pub const Node = union(enum) {
    text: *Text,
    element: *Element,

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |t| t.deinit(allocator),
            .element => |e| e.deinit(allocator),
        }
    }

    pub fn appendChild(self: Node, child: *Node) !void {
        switch (self) {
            .text => |t| {
                if (t.children) |_| {
                    try t.children.?.append(child);
                }
            },
            .element => |e| {
                if (e.children) |_| {
                    try e.children.?.append(child);
                }
            },
        }
    }

    pub fn children(self: *Node) ?std.ArrayList(*Node) {
        switch (self.*) {
            .text => |t| return t.children,
            .element => |e| return e.children,
        }
    }

    pub fn asString(self: *Node, al: std.mem.Allocator) ![]const u8 {
        return switch (self.*) {
            .text => |t| t.text,
            .element => |e| {
                // Setup attributes.
                if (e.attributes) |attrs| {
                    var attr_strings = try al.alloc([]const u8, attrs.count());
                    var it = attrs.iterator();
                    var i: usize = 0;
                    while (it.next()) |entry| {
                        attr_strings[i] = try std.fmt.allocPrint(
                            al,
                            "{s}=\"{s}\"",
                            .{ entry.key_ptr.*, entry.value_ptr.* },
                        );
                        i += 1;
                    }
                    var full_attr_string = std.ArrayList(u8).init(al);
                    defer full_attr_string.deinit();
                    for (attr_strings) |attr| {
                        try full_attr_string.appendSlice(attr);
                        try full_attr_string.append(' ');
                    }
                    _ = full_attr_string.pop();
                    return try std.fmt.allocPrint(al, "<{s} {s}>", .{ e.tag, full_attr_string.items });
                } else {
                    return try std.fmt.allocPrint(al, "<{s}>", .{e.tag});
                }
            },
        };
    }
};

pub const HTMLParser = struct {
    body: []const u8,
    unfinished: std.ArrayList(*Node) = undefined,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, body: []const u8) !*HTMLParser {
        const parser = try allocator.create(HTMLParser);
        parser.* = HTMLParser{
            .body = body,
            .unfinished = std.ArrayList(*Node).init(allocator),
            .allocator = allocator,
        };
        return parser;
    }

    pub fn deinit(self: *HTMLParser, allocator: std.mem.Allocator) void {
        // Root contains all allocated nodes, so this would free the entire tree
        if (self.unfinished.items.len > 0) {
            var root = self.unfinished.items[0];
            root.deinit(allocator);
        } else {
            // Free any other unfinished nodes
            for (self.unfinished.items) |node| {
                node.deinit(allocator);
            }
        }
        self.unfinished.deinit();
        allocator.destroy(self);
    }

    pub fn parse(self: *HTMLParser) !*Node {
        var text: std.ArrayList(u8) = std.ArrayList(u8).init(self.allocator);
        defer {
            text.clearAndFree();
            text.deinit();
        }
        var in_tag: bool = false;

        for (self.body) |c| {
            if (c == '<') {
                in_tag = true;
                if (text.items.len > 0) try self.addText(&text);
                text.clearRetainingCapacity();
            } else if (c == '>') {
                in_tag = false;
                try self.addTag(&text);
                text.clearRetainingCapacity();
            } else {
                try text.append(c);
            }
        }

        if (!in_tag and text.items.len > 0) {
            try self.addText(&text);
        }

        return self.finish();
    }

    fn addText(self: *HTMLParser, text: *std.ArrayList(u8)) !void {
        if (text.items.len == 0 or std.ascii.isWhitespace(text.items[0])) return;
        var parent = self.unfinished.getLast();
        const new_node = try self.allocator.create(Node);
        new_node.* = .{ .text = try Text.init(
            self.allocator,
            try text.toOwnedSlice(),
            parent,
        ) };
        try parent.appendChild(new_node);
    }

    fn addTag(self: *HTMLParser, tag: *std.ArrayList(u8)) !void {
        // skip comments and DOCTYPE
        if (tag.items.len == 0 or tag.items[0] == '!') return;

        if (tag.items[0] == '/') {
            // close tag
            if (self.unfinished.items.len == 1) return;
            const node = self.unfinished.pop() orelse return;
            var parent = self.unfinished.getLast();
            try parent.appendChild(node);
        } else if (for (self_closing_tags) |self_closing_tag| {
            if (std.mem.eql(u8, tag.items, self_closing_tag)) break true;
        } else false) {
            const parent = self.unfinished.getLast();
            const new_node = try self.allocator.create(Node);
            new_node.* = .{ .element = try Element.init(
                self.allocator,
                try tag.toOwnedSlice(),
                parent,
            ) };
            try parent.appendChild(new_node);
        } else {
            // open tag
            const parent = self.unfinished.getLastOrNull();
            const new_node = try self.allocator.create(Node);
            new_node.* = .{ .element = try Element.init(
                self.allocator,
                try tag.toOwnedSlice(),
                parent,
            ) };
            try self.unfinished.append(new_node);
        }
    }

    fn finish(self: *HTMLParser) !*Node {
        while (self.unfinished.items.len > 1) {
            const node = self.unfinished.pop() orelse unreachable;
            var parent = self.unfinished.getLast();
            try parent.appendChild(node);
        }
        return self.unfinished.pop() orelse unreachable;
    }

    pub fn prettyPrint(self: *HTMLParser, node: *Node, indent: usize) !void {
        // Create a temporary buffer filled with spaces
        const spaces = try self.allocator.alloc(u8, indent);
        defer self.allocator.free(spaces);

        // Fill with spaces
        @memset(spaces, ' ');

        std.debug.print("{s}{s}\n", .{ spaces, try node.asString(self.allocator) });

        if (node.children()) |children| {
            for (children.items) |child| {
                try self.prettyPrint(child, indent + 2);
            }
        }
    }
};

// ===== TESTS =====

test "Parse basic HTML" {
    const allocator = std.testing.allocator;
    const html = "<html><body><p>Hello, world!</p></body></html>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    try std.testing.expectEqualStrings("html", root.element.tag);
    try std.testing.expectEqual(@as(usize, 1), root.element.children.?.items.len);

    const body = root.element.children.?.items[0].element;
    try std.testing.expectEqualStrings("body", body.tag);
    try std.testing.expectEqual(@as(usize, 1), body.children.?.items.len);

    const p = body.children.?.items[0].element;
    try std.testing.expectEqualStrings("p", p.tag);
    try std.testing.expectEqual(@as(usize, 1), p.children.?.items.len);

    const text = p.children.?.items[0].text;
    try std.testing.expectEqualStrings("Hello, world!", text.text);
}

// test "Parse quoted attributes" {
//     const allocator = std.testing.allocator;
//     const html = "<div class=\"container\" id=\"main\"><span>Text</span></div>";

//     var parser = try HTMLParser.init(allocator, html);
//     defer parser.deinit(allocator);

//     const root = try parser.parse();

//     try std.testing.expectEqualStrings("div", root.element.tag);
//     try std.testing.expect(root.element.attributes != null);

//     const attrs = root.element.attributes.?;
//     try std.testing.expectEqual(@as(usize, 2), attrs.count());

//     try std.testing.expectEqualStrings("container", attrs.get("class").?);
//     try std.testing.expectEqualStrings("main", attrs.get("id").?);
// }

// test "Parse boolean attributes" {
//     const allocator = std.testing.allocator;
//     const html = "<input disabled required><label>Check me</label>";

//     var parser = try HTMLParser.init(allocator, html);
//     defer parser.deinit(allocator);

//     const root = try parser.parse();

//     try std.testing.expectEqualStrings("input", root.element.tag);
//     try std.testing.expect(root.element.attributes != null);

//     const attrs = root.element.attributes.?;
//     try std.testing.expectEqual(@as(usize, 2), attrs.count());

//     try std.testing.expectEqualStrings("", attrs.get("disabled").?);
//     try std.testing.expectEqualStrings("", attrs.get("required").?);
// }

// test "Parse unquoted attributes" {
//     const allocator = std.testing.allocator;
//     const html = "<input type=text value=hello><button>Submit</button>";

//     var parser = try HTMLParser.init(allocator, html);
//     defer parser.deinit(allocator);

//     const root = try parser.parse();

//     try std.testing.expectEqualStrings("input", root.element.tag);
//     try std.testing.expect(root.element.attributes != null);

//     const attrs = root.element.attributes.?;
//     try std.testing.expectEqual(@as(usize, 2), attrs.count());

//     try std.testing.expectEqualStrings("text", attrs.get("type").?);
//     try std.testing.expectEqualStrings("hello", attrs.get("value").?);
// }

// test "Parse mixed attribute types" {
//     const allocator = std.testing.allocator;
//     const html = "<form action=\"/submit\" method=post novalidate><input></form>";

//     var parser = try HTMLParser.init(allocator, html);
//     defer parser.deinit(allocator);

//     const root = try parser.parse();

//     try std.testing.expectEqualStrings("form", root.element.tag);
//     try std.testing.expect(root.element.attributes != null);

//     const attrs = root.element.attributes.?;
//     try std.testing.expectEqual(@as(usize, 3), attrs.count());

//     try std.testing.expectEqualStrings("/submit", attrs.get("action").?);
//     try std.testing.expectEqualStrings("post", attrs.get("method").?);
//     try std.testing.expectEqualStrings("", attrs.get("novalidate").?);
// }

// test "Parse self-closing tags with attributes" {
//     const allocator = std.testing.allocator;
//     const html = "<img src=\"image.jpg\" alt=\"An image\" width=100 height=100>";

//     var parser = try HTMLParser.init(allocator, html);
//     defer parser.deinit(allocator);

//     const root = try parser.parse();

//     try std.testing.expectEqualStrings("img", root.element.tag);
//     try std.testing.expect(root.element.attributes != null);

//     const attrs = root.element.attributes.?;
//     try std.testing.expectEqual(@as(usize, 4), attrs.count());

//     try std.testing.expectEqualStrings("image.jpg", attrs.get("src").?);
//     try std.testing.expectEqualStrings("An image", attrs.get("alt").?);
//     try std.testing.expectEqualStrings("100", attrs.get("width").?);
//     try std.testing.expectEqualStrings("100", attrs.get("height").?);
// }
