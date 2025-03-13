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
    children: ?std.ArrayList(Node) = null,

    pub fn init(text: []const u8, parent: ?*Node) !Text {
        return Text{
            .text = text,
            .parent = parent,
            .children = null,
        };
    }
};

const Element = struct {
    tag: []const u8,
    attributes: ?std.StringHashMap([]const u8) = null,
    parent: ?*Node = null,
    children: std.ArrayList(Node),

    pub fn init(allocator: std.mem.Allocator, tag: []const u8, parent: ?*Node) !Element {
        var e = Element{
            .tag = tag,
            .parent = parent,
            .attributes = null,
            .children = std.ArrayList(Node).init(allocator),
        };
        try e.parse(allocator, tag);
        return e;
    }

    pub fn deinit(self: Element, allocator: std.mem.Allocator) void {
        for (self.children.items) |child| {
            child.deinit(allocator);
        }
        self.children.deinit();

        if (self.attributes) |attributes| {
            var attrs = attributes;
            attrs.deinit();
        }
    }

    fn parse(self: *Element, al: std.mem.Allocator, raw: []const u8) !void {
        var idx: usize = 0;
        // Skip any leading whitespace.
        while (idx < raw.len and std.ascii.isWhitespace(raw[idx])) : (idx += 1) {}

        // Parse the tag name: read until whitespace.
        const start_name = idx;
        while (idx < raw.len and !std.ascii.isWhitespace(raw[idx])) : (idx += 1) {}
        // Just store the tag name slice
        self.tag = raw[start_name..idx];

        // Early return if no attributes
        if (idx >= raw.len) return;

        // Initialize attributes hashmap
        self.attributes = std.StringHashMap([]const u8).init(al);

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
                try self.attributes.?.put(attr_name_slice, "");
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

            try self.attributes.?.put(attr_name_slice, value_slice);
        }
    }
};

pub const Node = union(enum) {
    text: Text,
    element: Element,

    pub fn deinit(self: Node, allocator: std.mem.Allocator) void {
        switch (self) {
            .text => {},
            .element => |*e| e.deinit(allocator),
        }
    }

    pub fn appendChild(self: *Node, child: Node) !void {
        switch (self.*) {
            .text => unreachable,
            .element => |*e| {
                try e.children.append(child);
            },
        }
    }

    pub fn children(self: *Node) ?*std.ArrayList(Node) {
        return switch (self.*) {
            .text => unreachable,
            .element => |e| &e.children,
        };
    }

    // allocate a string from node (because we may need to build up attribtues)
    // caller must free the string
    pub fn asString(self: *const Node, al: std.mem.Allocator) ![]const u8 {
        var result = std.ArrayList(u8).init(al);
        errdefer result.deinit();

        switch (self.*) {
            .text => |t| {
                try result.appendSlice(t.text);
            },
            .element => |e| {
                try result.append('<');
                try result.appendSlice(e.tag);

                if (e.attributes) |attrs| {
                    var it = attrs.iterator();
                    while (it.next()) |entry| {
                        try result.append(' ');
                        try result.appendSlice(entry.key_ptr.*);

                        // Only add ="value" if the attribute has a value
                        if (entry.value_ptr.*.len > 0) {
                            try result.appendSlice("=\"");
                            try result.appendSlice(entry.value_ptr.*);
                            try result.append('"');
                        }
                    }
                }

                try result.append('>');
            },
        }

        return result.toOwnedSlice();
    }
};

pub const HTMLParser = struct {
    body: []const u8,
    unfinished: std.ArrayList(Node) = undefined,
    allocator: std.mem.Allocator,
    head_found: bool = false, // Track if <head> tag has been found
    use_implicit_tags: bool = true, // Default to using implicit tags

    pub fn init(allocator: std.mem.Allocator, body: []const u8) !*HTMLParser {
        const parser = try allocator.create(HTMLParser);
        parser.* = HTMLParser{
            .body = body,
            .unfinished = std.ArrayList(Node).init(allocator),
            .allocator = allocator,
            .head_found = false,
            .use_implicit_tags = true,
        };
        return parser;
    }

    // Add a new init function for when we don't want implicit tags
    pub fn init_no_implicit(allocator: std.mem.Allocator, body: []const u8) !*HTMLParser {
        const parser = try allocator.create(HTMLParser);
        parser.* = HTMLParser{
            .body = body,
            .unfinished = std.ArrayList(Node).init(allocator),
            .allocator = allocator,
            .head_found = false,
            .use_implicit_tags = false,
        };
        return parser;
    }

    pub fn deinit(self: *HTMLParser, allocator: std.mem.Allocator) void {
        self.unfinished.deinit();
        allocator.destroy(self);
    }

    pub fn parse(self: *HTMLParser) !Node {
        // Track ranges in the original body
        var start_idx: usize = 0;
        var in_tag = false;

        for (self.body, 0..) |c, i| {
            if (c == '<') {
                // End of text, start of tag
                if (!in_tag and i > start_idx) {
                    // Process text content using direct slice
                    try self.addText(self.body[start_idx..i]);
                }
                start_idx = i + 1; // Skip the '<'
                in_tag = true;
            } else if (c == '>') {
                // End of tag
                if (in_tag) {
                    try self.addTag(self.body[start_idx..i]);
                }
                start_idx = i + 1; // Skip the '>'
                in_tag = false;
            }
        }

        // Handle any final text
        if (!in_tag and start_idx < self.body.len) {
            try self.addText(self.body[start_idx..]);
        }

        return try self.finish();
    }

    fn addText(self: *HTMLParser, text_slice: []const u8) !void {
        // Skip empty or whitespace-only text
        if (text_slice.len == 0) return;

        // Skip if the text is all whitespace
        var all_whitespace = true;
        for (text_slice) |c| {
            if (!std.ascii.isWhitespace(c)) {
                all_whitespace = false;
                break;
            }
        }
        if (all_whitespace) return;

        // If we don't have any elements in the stack yet, can't add text
        if (self.unfinished.items.len == 0) return;

        const parent = &self.unfinished.items[self.unfinished.items.len - 1];

        // Create text node and append directly
        const text_node = try Text.init(
            text_slice, // Direct reference to the text slice
            parent,
        );

        const node = Node{ .text = text_node };
        try parent.appendChild(node);
    }

    fn addTag(self: *HTMLParser, tag_slice: []const u8) !void {
        // Skip empty tags or comments/doctype
        if (tag_slice.len == 0 or tag_slice[0] == '!') return;

        // Extract tag name for matching
        var tag_name = tag_slice;
        var is_closing = false;

        if (tag_slice[0] == '/') {
            // Closing tag
            is_closing = true;
            tag_name = tag_slice[1..]; // Skip the '/' character
        }

        // Extract just the tag name if there are attributes
        for (tag_name, 0..) |c, i| {
            if (std.ascii.isWhitespace(c)) {
                tag_name = tag_name[0..i];
                break;
            }
        }

        // Handle implicit tags before processing the current tag
        try self.implicitTags(tag_name, is_closing);

        // Handle special case for when no implicit tags are used and this is the first element
        if (self.unfinished.items.len == 0 and !is_closing) {
            // Create the top-level element
            const element = try Element.init(self.allocator, tag_slice, null);
            const node = Node{ .element = element };
            try self.unfinished.append(node);
            return;
        }

        if (is_closing) {
            // Closing tag
            if (self.unfinished.items.len <= 1) return;

            // Find the matching opening tag in the unfinished stack
            var i: usize = self.unfinished.items.len;
            while (i > 0) {
                i -= 1;
                const current = &self.unfinished.items[i];

                if (current.* == .element and std.mem.eql(u8, current.element.tag, tag_name)) {
                    // Found matching tag, close all nested tags up to this one
                    while (self.unfinished.items.len - 1 > i) {
                        const node = self.unfinished.pop() orelse unreachable;
                        const parent = &self.unfinished.items[self.unfinished.items.len - 1];
                        try parent.appendChild(node);
                    }

                    // Now close the matching tag itself
                    const node = self.unfinished.pop() orelse unreachable;
                    const parent = &self.unfinished.items[self.unfinished.items.len - 1];
                    try parent.appendChild(node);
                    break;
                }
            }
        } else if (for (self_closing_tags) |self_closing_tag| {
            // Check if this is a self-closing tag (like <img>, <br>, etc.)
            if (std.mem.eql(u8, tag_name, self_closing_tag)) break true;
        } else false) {
            // Self-closing tag
            if (self.unfinished.items.len == 0) {
                // Top-level self-closing tag - should be handled by implicitTags now
                const element = try Element.init(
                    self.allocator,
                    tag_slice, // Direct reference to the tag slice
                    null, // No parent at the top level
                );
                const node = Node{ .element = element };
                try self.unfinished.append(node);
                return;
            }

            const parent = &self.unfinished.items[self.unfinished.items.len - 1];

            // Create element directly
            const element = try Element.init(
                self.allocator,
                tag_slice, // Direct reference to the tag slice
                parent,
            );

            const node = Node{ .element = element };
            try parent.appendChild(node);
        } else {
            // Opening tag
            const parent: ?*Node = if (self.unfinished.items.len > 0)
                &self.unfinished.items[self.unfinished.items.len - 1]
            else
                null;

            // Create element directly
            const element = try Element.init(
                self.allocator,
                tag_slice, // Direct reference to the tag slice
                parent,
            );

            const node = Node{ .element = element };
            try self.unfinished.append(node);

            // Mark when we've found a head tag
            if (std.mem.eql(u8, tag_name, "head")) {
                self.head_found = true;
            }
        }
    }

    // Handle implicit tags according to the algorithm from browser.engineering
    fn implicitTags(self: *HTMLParser, tag_name: []const u8, is_closing: bool) !void {
        // Skip implicit tag handling if disabled
        if (!self.use_implicit_tags) return;

        // List of tags that belong in the head section
        const head_tags = [_][]const u8{ "base", "basefont", "bgsound", "link", "meta", "title", "style", "script" };

        // Is this tag a head element?
        const is_head_tag = for (head_tags) |head_tag| {
            if (std.mem.eql(u8, tag_name, head_tag)) break true;
        } else false;

        // If we have no tags yet, add html tag
        if (self.unfinished.items.len == 0) {
            const html_element = try Element.init(
                self.allocator,
                "html",
                null,
            );
            const html_node = Node{ .element = html_element };
            try self.unfinished.append(html_node);
        }

        // Check what's the current structure
        const current_open_tags = self.unfinished.items.len;
        const in_html_only = current_open_tags == 1 and
            std.mem.eql(u8, self.unfinished.items[0].element.tag, "html");

        // Add head tag if needed
        if (in_html_only) {
            // We're at the HTML level
            if (std.mem.eql(u8, tag_name, "head") or is_head_tag) {
                // If this is a head tag or belongs in head, add the head element
                if (!self.head_found) {
                    const head_element = try Element.init(
                        self.allocator,
                        "head",
                        &self.unfinished.items[0],
                    );
                    const head_node = Node{ .element = head_element };
                    try self.unfinished.append(head_node);
                    self.head_found = true;
                }
            } else if (!is_closing and !std.mem.eql(u8, tag_name, "/head")) {
                // This is a non-head tag and not a closing tag, add both head and body

                // First add head if not already added
                if (!self.head_found) {
                    const head_element = try Element.init(
                        self.allocator,
                        "head",
                        &self.unfinished.items[0],
                    );
                    const head_node = Node{ .element = head_element };
                    try self.unfinished.append(head_node);
                    self.head_found = true;

                    // Close the head immediately since we're about to see a body element
                    const head_closed = self.unfinished.pop() orelse unreachable;
                    try self.unfinished.items[0].appendChild(head_closed);
                }

                // Then add body
                const body_element = try Element.init(
                    self.allocator,
                    "body",
                    &self.unfinished.items[0],
                );
                const body_node = Node{ .element = body_element };
                try self.unfinished.append(body_node);
            }
        } else if (current_open_tags > 1 and std.mem.eql(u8, self.unfinished.items[self.unfinished.items.len - 1].element.tag, "head")) {
            // We're inside a head tag
            if (!is_head_tag and !is_closing) {
                // This is a non-head element - close the head and open body
                const head_closed = self.unfinished.pop() orelse unreachable;
                try self.unfinished.items[0].appendChild(head_closed);

                // Add body
                const body_element = try Element.init(
                    self.allocator,
                    "body",
                    &self.unfinished.items[0],
                );
                const body_node = Node{ .element = body_element };
                try self.unfinished.append(body_node);
            }
        }

        // Handle unclosed non-void elements
        // When a new block element starts, it implicitly closes any open paragraph
        const block_elements = [_][]const u8{ "address", "article", "aside", "blockquote", "details", "dialog", "dd", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "table", "ul" };

        // Check if this is a block element opening tag
        const is_block_element = !is_closing and for (block_elements) |block_tag| {
            if (std.mem.eql(u8, tag_name, block_tag)) break true;
        } else false;

        // If this is a block element and we have an open paragraph, implicitly close it
        if (is_block_element and self.unfinished.items.len > 0) {
            // Walk up the stack looking for specific elements that this might close
            var i: usize = self.unfinished.items.len;
            while (i > 0) {
                i -= 1;
                const current = &self.unfinished.items[i];

                // Paragraphs are closed by other block elements
                if (current.* == .element and std.mem.eql(u8, current.element.tag, "p")) {
                    // If the new tag is another paragraph or a block element, close this p tag
                    if (std.mem.eql(u8, tag_name, "p") or is_block_element) {
                        // Close all nodes up to and including this paragraph
                        while (self.unfinished.items.len - 1 > i) {
                            const node = self.unfinished.pop() orelse unreachable;
                            const parent = &self.unfinished.items[self.unfinished.items.len - 1];
                            try parent.appendChild(node);
                        }

                        const p_node = self.unfinished.pop() orelse unreachable;
                        const parent = &self.unfinished.items[self.unfinished.items.len - 1];
                        try parent.appendChild(p_node);
                        break;
                    }
                }

                // If we reach a section type element like div, don't go further up
                if (current.* == .element and (std.mem.eql(u8, current.element.tag, "div") or
                    std.mem.eql(u8, current.element.tag, "body") or
                    std.mem.eql(u8, current.element.tag, "html")))
                {
                    break;
                }
            }
        }
    }

    fn finish(self: *HTMLParser) !Node {
        if (self.unfinished.items.len == 0) {
            return error.NoNodesCreated;
        }

        // If there are multiple top-level elements, ensure they are connected
        while (self.unfinished.items.len > 1) {
            const node = self.unfinished.pop() orelse unreachable;
            const parent = &self.unfinished.items[self.unfinished.items.len - 1];
            try parent.appendChild(node);
        }

        // Return the root node
        return self.unfinished.pop() orelse unreachable;
    }

    pub fn prettyPrint(self: *HTMLParser, node: Node, indent: usize) !void {
        // Create a temporary buffer filled with spaces
        const spaces = try self.allocator.alloc(u8, indent);
        defer self.allocator.free(spaces);

        // Fill with spaces
        @memset(spaces, ' ');

        // Get the string representation and properly free it after use
        const node_str = try node.asString(self.allocator);
        defer self.allocator.free(node_str);

        std.debug.print("{s}{s}\n", .{ spaces, node_str });

        switch (node) {
            .text => {},
            .element => |e| {
                for (e.children.items, 0..) |_, i| {
                    try self.prettyPrint(e.children.items[i], indent + 2);
                }
            },
        }
    }
};

// ===== TESTS =====

test "Parse basic HTML" {
    const allocator = std.testing.allocator;
    const html = "<html><body><p>Hello, world!</p></body></html>";

    var parser = try HTMLParser.init_no_implicit(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    try std.testing.expectEqualStrings("html", root.element.tag);
    try std.testing.expectEqual(@as(usize, 1), root.element.children.items.len);

    const body = root.element.children.items[0].element;
    try std.testing.expectEqualStrings("body", body.tag);
    try std.testing.expectEqual(@as(usize, 1), body.children.items.len);

    const p = body.children.items[0].element;
    try std.testing.expectEqualStrings("p", p.tag);
    try std.testing.expectEqual(@as(usize, 1), p.children.items.len);

    const text = p.children.items[0].text;
    try std.testing.expectEqualStrings("Hello, world!", text.text);
}

test "Parse quoted attributes" {
    const allocator = std.testing.allocator;
    const html = "<div class=\"container\" id=\"main\"><span>Text</span></div>";

    var parser = try HTMLParser.init_no_implicit(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    try std.testing.expectEqualStrings("div", root.element.tag);
    try std.testing.expect(root.element.attributes != null);

    const attrs = root.element.attributes.?;
    try std.testing.expectEqual(@as(usize, 2), attrs.count());

    try std.testing.expectEqualStrings("container", attrs.get("class").?);
    try std.testing.expectEqualStrings("main", attrs.get("id").?);
}

test "Parse boolean attributes" {
    const allocator = std.testing.allocator;
    const html = "<input disabled required><label>Check me</label>";

    var parser = try HTMLParser.init_no_implicit(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);
    try std.testing.expectEqualStrings("input", root.element.tag);
    try std.testing.expect(root.element.attributes != null);

    const attrs = root.element.attributes.?;
    try std.testing.expectEqual(@as(usize, 2), attrs.count());

    try std.testing.expectEqualStrings("", attrs.get("disabled").?);
    try std.testing.expectEqualStrings("", attrs.get("required").?);
}

test "Parse unquoted attributes" {
    const allocator = std.testing.allocator;
    const html = "<input type=text value=hello><button>Submit</button>";

    var parser = try HTMLParser.init_no_implicit(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);
    try std.testing.expectEqualStrings("input", root.element.tag);
    try std.testing.expect(root.element.attributes != null);

    const attrs = root.element.attributes.?;
    try std.testing.expectEqual(@as(usize, 2), attrs.count());

    try std.testing.expectEqualStrings("text", attrs.get("type").?);
    try std.testing.expectEqualStrings("hello", attrs.get("value").?);
}

test "Parse mixed attribute types" {
    const allocator = std.testing.allocator;
    const html = "<form action=\"/submit\" method=post novalidate><input></form>";

    var parser = try HTMLParser.init_no_implicit(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);
    try std.testing.expectEqualStrings("form", root.element.tag);
    try std.testing.expect(root.element.attributes != null);

    const attrs = root.element.attributes.?;
    try std.testing.expectEqual(@as(usize, 3), attrs.count());

    try std.testing.expectEqualStrings("/submit", attrs.get("action").?);
    try std.testing.expectEqualStrings("post", attrs.get("method").?);
    try std.testing.expectEqualStrings("", attrs.get("novalidate").?);
}

test "Parse self-closing tags with attributes" {
    const allocator = std.testing.allocator;
    const html = "<img src=\"image.jpg\" alt=\"An image\" width=100 height=100>";

    var parser = try HTMLParser.init_no_implicit(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    try std.testing.expectEqualStrings("img", root.element.tag);
    try std.testing.expect(root.element.attributes != null);

    const attrs = root.element.attributes.?;
    try std.testing.expectEqual(@as(usize, 4), attrs.count());

    try std.testing.expectEqualStrings("image.jpg", attrs.get("src").?);
    try std.testing.expectEqualStrings("An image", attrs.get("alt").?);
    try std.testing.expectEqualStrings("100", attrs.get("width").?);
    try std.testing.expectEqualStrings("100", attrs.get("height").?);
}

test "Parse HTML with implicit tags" {
    const allocator = std.testing.allocator;
    // HTML without html, head, or body tags
    const html = "<p>Hello, world!</p>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    // Verify implicit html tag was added
    try std.testing.expectEqualStrings("html", root.element.tag);
    try std.testing.expectEqual(@as(usize, 2), root.element.children.items.len);

    // First child should be head
    const head = root.element.children.items[0].element;
    try std.testing.expectEqualStrings("head", head.tag);

    // Second child should be body
    const body = root.element.children.items[1].element;
    try std.testing.expectEqualStrings("body", body.tag);
    try std.testing.expectEqual(@as(usize, 1), body.children.items.len);

    // Body should contain the paragraph
    const p = body.children.items[0].element;
    try std.testing.expectEqualStrings("p", p.tag);
    try std.testing.expectEqual(@as(usize, 1), p.children.items.len);

    // Paragraph should contain the text
    const text = p.children.items[0].text;
    try std.testing.expectEqualStrings("Hello, world!", text.text);
}

test "Parse HTML with head elements but no explicit head tag" {
    const allocator = std.testing.allocator;
    // HTML with a title but no explicit head or body tags
    const html = "<title>Test Page</title><p>Content</p>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    // Verify implicit html tag was added
    try std.testing.expectEqualStrings("html", root.element.tag);
    try std.testing.expectEqual(@as(usize, 2), root.element.children.items.len);

    // First child should be head containing title
    const head = root.element.children.items[0].element;
    try std.testing.expectEqualStrings("head", head.tag);
    try std.testing.expectEqual(@as(usize, 1), head.children.items.len);

    // Head should contain the title
    const title = head.children.items[0].element;
    try std.testing.expectEqualStrings("title", title.tag);

    // Second child should be body
    const body = root.element.children.items[1].element;
    try std.testing.expectEqualStrings("body", body.tag);
    try std.testing.expectEqual(@as(usize, 1), body.children.items.len);

    // Body should contain the paragraph
    const p = body.children.items[0].element;
    try std.testing.expectEqualStrings("p", p.tag);
    try std.testing.expectEqual(@as(usize, 1), p.children.items.len);
}

test "Parse HTML with unclosed paragraph tags" {
    const allocator = std.testing.allocator;
    // HTML with an unclosed paragraph tag
    const html = "<p>First paragraph<p>Second paragraph</p>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    // Verify implicit html tag was added
    try std.testing.expectEqualStrings("html", root.element.tag);
    try std.testing.expectEqual(@as(usize, 2), root.element.children.items.len);

    // First child should be head (which might be empty)
    const head = root.element.children.items[0].element;
    try std.testing.expectEqualStrings("head", head.tag);

    // Second child should be body
    const body = root.element.children.items[1].element;
    try std.testing.expectEqualStrings("body", body.tag);

    // Should have two paragraph children in the body
    try std.testing.expectEqual(@as(usize, 2), body.children.items.len);

    // Check first paragraph (implicitly closed)
    const p1 = body.children.items[0].element;
    try std.testing.expectEqualStrings("p", p1.tag);
    try std.testing.expectEqual(@as(usize, 1), p1.children.items.len);
    try std.testing.expectEqualStrings("First paragraph", p1.children.items[0].text.text);

    // Check second paragraph
    const p2 = body.children.items[1].element;
    try std.testing.expectEqualStrings("p", p2.tag);
    try std.testing.expectEqual(@as(usize, 1), p2.children.items.len);
    try std.testing.expectEqualStrings("Second paragraph", p2.children.items[0].text.text);
}
