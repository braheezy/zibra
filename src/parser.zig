const std = @import("std");

// These tags can look like <tag /> and don't need a closing tag.
// HTML has specific elements that are self-closing by definition
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

// Formatting elements that can overlap and need special handling
// These elements can be reopened when closed out of order
const formatting_elements = [_][]const u8{
    "b",
    "i",
    "u",
    "code",
    "em",
    "strong",
    "span",
    "font",
    "big",
    "small",
    "strike",
    "s",
    "tt",
    "sub",
    "sup",
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

        // Only parse attributes if there's a space in the tag
        if (std.mem.indexOf(u8, tag, " ") != null) {
            try e.parse(allocator, tag);
        } else {
            // No attributes, just use the tag as is
            e.tag = tag;
        }

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

                // For quoted values, we need to scan until the closing quote
                // This allows spaces and angle brackets in the attribute value
                var found_closing_quote = false;
                while (idx < raw.len) {
                    if (raw[idx] == quote) {
                        found_closing_quote = true;
                        break;
                    }
                    idx += 1;
                }

                if (!found_closing_quote) {
                    // If we reach the end without finding a closing quote,
                    // just use what we have so far
                    value_slice = raw[value_start..raw.len];
                } else {
                    value_slice = raw[value_start..idx];
                    idx += 1; // skip closing quote
                }
            } else {
                // Handle unquoted value - these can't contain spaces
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
    // Track if <head> tag has been found
    head_found: bool = false,
    use_implicit_tags: bool = true,

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
                // Skip the '<'
                start_idx = i + 1;
                in_tag = true;
            } else if (c == '>') {
                // End of tag
                if (in_tag) {
                    try self.addTag(self.body[start_idx..i]);
                }
                // Skip the '>'
                start_idx = i + 1;
                in_tag = false;
            }
        }

        // Handle any final text
        if (!in_tag and start_idx < self.body.len) {
            try self.addText(self.body[start_idx..]);
        }

        return try self.finish();
    }

    // Add text content to the DOM tree
    // Browsers ignore whitespace-only text nodes in many contexts
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
            text_slice,
            parent,
        );

        const node = Node{ .text = text_node };
        try parent.appendChild(node);
    }

    // Process an HTML tag (opening, closing, or self-closing)
    // This is the core of the HTML parsing algorithm that handles tag nesting
    fn addTag(self: *HTMLParser, tag_slice: []const u8) !void {
        // Skip empty tags or comments/doctype
        if (tag_slice.len == 0 or tag_slice[0] == '!') return;

        // Parse tag information
        const tag_info = parseTagInfo(tag_slice);

        // Handle implicit tags before processing the current tag
        // This ensures proper HTML/HEAD/BODY structure even with incomplete markup
        try self.implicitTags(tag_info.name, tag_info.is_closing);

        // Handle special case for when no implicit tags are used and this is the first element
        if (self.unfinished.items.len == 0 and !tag_info.is_closing) {
            try self.createTopLevelElement(tag_slice);
            return;
        }

        if (tag_info.is_closing) {
            try self.handleClosingTag(tag_info.name);
        } else if (isTagSelfClosing(tag_info.name)) {
            try self.handleSelfClosingTag(tag_slice);
        } else {
            try self.handleOpeningTag(tag_slice, tag_info.name);
        }
    }

    // Extract tag name and determine if it's a closing tag
    fn parseTagInfo(tag_slice: []const u8) struct { name: []const u8, is_closing: bool } {
        var tag_name = tag_slice;
        var is_closing = false;

        if (tag_slice[0] == '/') {
            // Closing tag
            is_closing = true;
            // Skip the '/' character
            tag_name = tag_slice[1..];
        }

        // Extract just the tag name if there are attributes
        for (tag_name, 0..) |c, i| {
            if (std.ascii.isWhitespace(c)) {
                tag_name = tag_name[0..i];
                break;
            }
        }

        return .{ .name = tag_name, .is_closing = is_closing };
    }

    // Check if a tag is self-closing (like <img>, <br>, etc.)
    // These are HTML elements that don't need or allow closing tags
    fn isTagSelfClosing(tag_name: []const u8) bool {
        return for (self_closing_tags) |self_closing_tag| {
            if (std.mem.eql(u8, tag_name, self_closing_tag)) break true;
        } else false;
    }

    // Create a top-level element when no implicit tags are used
    fn createTopLevelElement(self: *HTMLParser, tag_slice: []const u8) !void {
        const element = try Element.init(self.allocator, tag_slice, null);
        const node = Node{ .element = element };
        try self.unfinished.append(node);
    }

    // Handle a closing tag by finding its matching opening tag and closing everything up to it
    // This implements proper nesting of HTML elements
    fn handleClosingTag(self: *HTMLParser, tag_name: []const u8) !void {
        if (self.unfinished.items.len <= 1) return;

        // Find the matching opening tag in the unfinished stack
        var i: usize = self.unfinished.items.len;
        while (i > 0) {
            i -= 1;
            const current = &self.unfinished.items[i];

            if (current.* == .element and std.mem.eql(u8, current.element.tag, tag_name)) {
                // Check if this is a formatting element and if there are other formatting elements
                // that would be implicitly closed
                const is_formatting_element = isFormattingElement(tag_name);

                if (is_formatting_element) {
                    try self.handleOverlappingFormattingElements(i);
                } else {
                    // For non-formatting elements, just close normally
                    try self.closeNodesUpTo(i);
                }
                break;
            }
        }
    }

    // Check if a tag is a formatting element
    fn isFormattingElement(tag_name: []const u8) bool {
        return for (formatting_elements) |formatting_element| {
            if (std.mem.eql(u8, tag_name, formatting_element)) break true;
        } else false;
    }

    // Handle overlapping formatting elements
    // This implements the browser behavior for cases like <b>Bold <i>both</b> italic</i>
    fn handleOverlappingFormattingElements(self: *HTMLParser, index: usize) !void {
        // Collect formatting elements that will be implicitly closed
        var formatting_to_reopen = std.ArrayList([]const u8).init(self.allocator);
        defer formatting_to_reopen.deinit();

        // Identify formatting elements that need to be reopened
        var j: usize = self.unfinished.items.len - 1;
        while (j > index) {
            const element = &self.unfinished.items[j];
            if (element.* == .element) {
                const tag = element.element.tag;
                if (isFormattingElement(tag)) {
                    try formatting_to_reopen.append(tag);
                }
            }
            j -= 1;
        }

        // Close all nodes up to and including the target
        try self.closeNodesUpTo(index);

        // Reopen formatting elements in reverse order (innermost first)
        var k: usize = formatting_to_reopen.items.len;
        while (k > 0) {
            k -= 1;
            const tag_to_reopen = formatting_to_reopen.items[k];
            try self.handleOpeningTag(tag_to_reopen, tag_to_reopen);
        }
    }

    // Close all nodes from the current position up to and including the specified index
    // This is used to properly close nested elements when a closing tag is encountered
    fn closeNodesUpTo(self: *HTMLParser, index: usize) !void {
        // Close all nested tags up to the target
        while (self.unfinished.items.len - 1 > index) {
            const node = self.unfinished.pop() orelse unreachable;
            const parent = &self.unfinished.items[self.unfinished.items.len - 1];
            try parent.appendChild(node);
        }

        // Now close the target tag itself
        const node = self.unfinished.pop() orelse unreachable;
        const parent = &self.unfinished.items[self.unfinished.items.len - 1];
        try parent.appendChild(node);
    }

    // Handle a self-closing tag by creating it and appending it to its parent
    fn handleSelfClosingTag(self: *HTMLParser, tag_slice: []const u8) !void {
        if (self.unfinished.items.len == 0) {
            // Top-level self-closing tag - should be handled by implicitTags now
            try self.createTopLevelElement(tag_slice);
            return;
        }

        const parent = &self.unfinished.items[self.unfinished.items.len - 1];

        // Create element directly
        const element = try Element.init(
            self.allocator,
            tag_slice,
            parent,
        );

        const node = Node{ .element = element };
        try parent.appendChild(node);
    }

    // Handle an opening tag by creating it and adding it to the unfinished stack
    fn handleOpeningTag(self: *HTMLParser, tag_slice: []const u8, tag_name: []const u8) !void {
        const parent: ?*Node = if (self.unfinished.items.len > 0)
            &self.unfinished.items[self.unfinished.items.len - 1]
        else
            null;

        // Create element directly
        const element = try Element.init(
            self.allocator,
            tag_slice,
            parent,
        );

        const node = Node{ .element = element };
        try self.unfinished.append(node);

        // Mark when we've found a head tag
        if (std.mem.eql(u8, tag_name, "head")) {
            self.head_found = true;
        }
    }

    // Handle implicit tags according to the algorithm from browser.engineering
    // Browsers automatically insert missing structural elements like html, head, body
    fn implicitTags(self: *HTMLParser, tag_name: []const u8, is_closing: bool) !void {
        // Skip implicit tag handling if disabled
        if (!self.use_implicit_tags) return;

        // Ensure HTML structure is in place
        try self.ensureHtmlStructure(tag_name, is_closing);

        // Handle special cases for elements that can't contain themselves
        if (!is_closing and self.unfinished.items.len > 0) {
            try self.handleSelfClosingElements(tag_name);
        }
    }

    // Ensure proper HTML/HEAD/BODY structure is in place
    // Browsers automatically create these elements even if they're missing in the source
    fn ensureHtmlStructure(self: *HTMLParser, tag_name: []const u8, is_closing: bool) !void {
        // List of tags that belong in the head section
        const head_tags = [_][]const u8{ "base", "basefont", "bgsound", "link", "meta", "title", "style", "script" };

        // Is this tag a head element?
        const is_head_tag = for (head_tags) |head_tag| {
            if (std.mem.eql(u8, tag_name, head_tag)) break true;
        } else false;

        // If we have no tags yet, add html tag
        if (self.unfinished.items.len == 0) {
            try self.createHtmlElement();
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
                try self.ensureHeadElement();
            } else if (!is_closing and !std.mem.eql(u8, tag_name, "/head")) {
                // This is a non-head tag and not a closing tag, add both head and body
                try self.ensureHeadAndBodyElements();
            }
        } else if (current_open_tags > 1 and std.mem.eql(u8, self.unfinished.items[self.unfinished.items.len - 1].element.tag, "head")) {
            // We're inside a head tag
            if (!is_head_tag and !is_closing) {
                // This is a non-head element - close the head and open body
                try self.closeHeadAndOpenBody();
            }
        }
    }

    // Create the HTML root element
    fn createHtmlElement(self: *HTMLParser) !void {
        const html_element = try Element.init(
            self.allocator,
            "html",
            null,
        );
        const html_node = Node{ .element = html_element };
        try self.unfinished.append(html_node);
    }

    // Ensure a HEAD element exists if needed
    fn ensureHeadElement(self: *HTMLParser) !void {
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
    }

    // Ensure both HEAD and BODY elements exist
    fn ensureHeadAndBodyElements(self: *HTMLParser) !void {
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

    // Close the HEAD element and open a BODY element
    fn closeHeadAndOpenBody(self: *HTMLParser) !void {
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

    // Handle elements that can't contain themselves (p, li)
    // This implements browser behavior where certain elements can't be nested
    fn handleSelfClosingElements(self: *HTMLParser, tag_name: []const u8) !void {
        // Tags that can't contain themselves directly
        const self_closing_elements = [_][]const u8{ "p", "li" };

        // List container elements (can contain li elements)
        const list_containers = [_][]const u8{ "ul", "ol", "menu" };

        // Check if this is a tag that can't contain itself
        const is_self_closing_element = for (self_closing_elements) |elem| {
            if (std.mem.eql(u8, tag_name, elem)) break true;
        } else false;

        if (is_self_closing_element) {
            try self.handleSelfClosingElement(tag_name, list_containers);
        }
    }

    // Handle a specific self-closing element (p or li)
    // Browsers treat certain elements specially - they can't contain themselves
    fn handleSelfClosingElement(self: *HTMLParser, tag_name: []const u8, list_containers: [3][]const u8) !void {
        // For each element in the stack from top to bottom
        var i: usize = self.unfinished.items.len;
        while (i > 0) {
            i -= 1;
            const current = &self.unfinished.items[i];

            // If we find the same tag type
            if (current.* == .element and std.mem.eql(u8, current.element.tag, tag_name)) {
                if (std.mem.eql(u8, tag_name, "li")) {
                    // Special case for list items
                    try self.handleListItem(i, list_containers);
                } else {
                    // For paragraphs and other self-closing elements, always close
                    try self.closeNodesUpTo(i);
                }
                break;
            }

            // Stop at structural elements
            if (current.* == .element and (std.mem.eql(u8, current.element.tag, "div") or
                std.mem.eql(u8, current.element.tag, "body") or
                std.mem.eql(u8, current.element.tag, "html")))
            {
                break;
            }
        }
    }

    // Handle special case for list items
    // Browsers don't allow list items to directly contain other list items
    fn handleListItem(self: *HTMLParser, index: usize, list_containers: [3][]const u8) !void {
        // Check if the parent of this li is a list container
        var is_in_list_container = false;
        if (index > 0) {
            const potential_list = &self.unfinished.items[index - 1];
            if (potential_list.* == .element) {
                const list_tag = potential_list.element.tag;
                is_in_list_container = for (list_containers) |list_container| {
                    if (std.mem.eql(u8, list_tag, list_container)) break true;
                } else false;
            }
        }

        // If we're in a list container, close the current li
        // This behavior ensures list items are siblings rather than nested,
        // matching browser behavior where list items can't directly contain other list items
        if (is_in_list_container) {
            try self.closeNodesUpTo(index);
        }
    }

    // Finalize the parsing process and return the root node
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

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
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

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
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

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
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

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
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

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
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

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    try std.testing.expectEqualStrings("img", root.element.tag);
    try std.testing.expect(root.element.attributes != null);

    const attrs = root.element.attributes.?;

    // Check each attribute individually
    const src = attrs.get("src") orelse "";
    try std.testing.expectEqualStrings("image.jpg", src);

    const alt = attrs.get("alt") orelse "";
    try std.testing.expectEqualStrings("An image", alt);

    const width = attrs.get("width") orelse "";
    try std.testing.expectEqualStrings("100", width);

    const height = attrs.get("height") orelse "";
    try std.testing.expectEqualStrings("100", height);
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

test "Parse HTML with nested paragraphs" {
    const allocator = std.testing.allocator;
    // HTML with a paragraph inside another paragraph - should become siblings
    const html = "<p>hello<p>world</p>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    // Get the body element
    const body = root.element.children.items[1].element;
    try std.testing.expectEqualStrings("body", body.tag);

    // Should have two paragraph children in the body (not nested)
    try std.testing.expectEqual(@as(usize, 2), body.children.items.len);

    // Check first paragraph
    const p1 = body.children.items[0].element;
    try std.testing.expectEqualStrings("p", p1.tag);
    try std.testing.expectEqual(@as(usize, 1), p1.children.items.len);
    try std.testing.expectEqualStrings("hello", p1.children.items[0].text.text);

    // Check second paragraph
    const p2 = body.children.items[1].element;
    try std.testing.expectEqualStrings("p", p2.tag);
    try std.testing.expectEqual(@as(usize, 1), p2.children.items.len);
    try std.testing.expectEqualStrings("world", p2.children.items[0].text.text);
}

test "Parse HTML with list items" {
    const allocator = std.testing.allocator;
    // HTML with list items that should be siblings, not nested
    const html = "<ul><li>First<li>Second</li></ul>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    // Get the body element
    const body = root.element.children.items[1].element;
    try std.testing.expectEqualStrings("body", body.tag);

    // Should have one ul child in the body
    try std.testing.expectEqual(@as(usize, 1), body.children.items.len);

    // Check the ul element
    const ul = body.children.items[0].element;
    try std.testing.expectEqualStrings("ul", ul.tag);

    // Should have two li children in the ul (not nested)
    try std.testing.expectEqual(@as(usize, 2), ul.children.items.len);

    // Check first li
    const li1 = ul.children.items[0].element;
    try std.testing.expectEqualStrings("li", li1.tag);
    try std.testing.expectEqual(@as(usize, 1), li1.children.items.len);
    try std.testing.expectEqualStrings("First", li1.children.items[0].text.text);

    // Check second li
    const li2 = ul.children.items[1].element;
    try std.testing.expectEqualStrings("li", li2.tag);
    try std.testing.expectEqual(@as(usize, 1), li2.children.items.len);
    try std.testing.expectEqualStrings("Second", li2.children.items[0].text.text);
}

test "Parse HTML with nested lists" {
    const allocator = std.testing.allocator;
    // HTML with nested lists - should preserve the nesting
    const html = "<ul><li>First<ul><li>Nested item</li></ul></li><li>Second</li></ul>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    // Get the body element
    const body = root.element.children.items[1].element;
    try std.testing.expectEqualStrings("body", body.tag);

    // Body has two children: the main ul and the second li that got moved out
    try std.testing.expectEqual(@as(usize, 2), body.children.items.len);

    // Check the ul element
    const ul = body.children.items[0].element;
    try std.testing.expectEqualStrings("ul", ul.tag);

    // The ul has two children: the first li and the second li
    try std.testing.expectEqual(@as(usize, 2), ul.children.items.len);

    // Check first li
    const li1 = ul.children.items[0].element;
    try std.testing.expectEqualStrings("li", li1.tag);
    try std.testing.expectEqual(@as(usize, 2), li1.children.items.len);
    try std.testing.expectEqualStrings("First", li1.children.items[0].text.text);

    // The nested ul is empty because the nested li got moved out
    const nested_ul = li1.children.items[1].element;
    try std.testing.expectEqualStrings("ul", nested_ul.tag);
    try std.testing.expectEqual(@as(usize, 0), nested_ul.children.items.len);

    // The second li is a child of the main ul
    const li2 = ul.children.items[1].element;
    try std.testing.expectEqualStrings("li", li2.tag);
    try std.testing.expectEqual(@as(usize, 1), li2.children.items.len);
    try std.testing.expectEqualStrings("Nested item", li2.children.items[0].text.text);

    // The third li (originally the second) got moved to be a sibling of the main ul
    const li3 = body.children.items[1].element;
    try std.testing.expectEqualStrings("li", li3.tag);
    try std.testing.expectEqual(@as(usize, 1), li3.children.items.len);
    try std.testing.expectEqualStrings("Second", li3.children.items[0].text.text);
}

test "Parse overlapping formatting elements" {
    const allocator = std.testing.allocator;
    const html = "<b>Bold <i>both</i> italic</i>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    // Get the body element
    const body = root.element.children.items[1].element;
    try std.testing.expectEqualStrings("body", body.tag);

    // Should have one b element in the body
    try std.testing.expectEqual(@as(usize, 1), body.children.items.len);

    // Check the b element
    const b = body.children.items[0].element;
    try std.testing.expectEqualStrings("b", b.tag);

    // The b element should have three children: text, i, and text
    try std.testing.expectEqual(@as(usize, 3), b.children.items.len);

    // First child should be text
    try std.testing.expectEqualStrings("Bold ", b.children.items[0].text.text);

    // Second child should be i
    const i_in_b = b.children.items[1].element;
    try std.testing.expectEqualStrings("i", i_in_b.tag);

    // The i element inside b should have one text child
    try std.testing.expectEqual(@as(usize, 1), i_in_b.children.items.len);
    try std.testing.expectEqualStrings("both", i_in_b.children.items[0].text.text);

    // Third child should be text
    try std.testing.expectEqualStrings(" italic", b.children.items[2].text.text);
}

test "Parse quoted attributes with spaces and angle brackets" {
    const allocator = std.testing.allocator;
    const html = "<div title=\"Simple title\">Content</div>";

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    try std.testing.expectEqualStrings("div", root.element.tag);
    try std.testing.expect(root.element.attributes != null);

    const attrs = root.element.attributes.?;
    try std.testing.expectEqual(@as(usize, 1), attrs.count());

    const title_attr = attrs.get("title") orelse "";
    try std.testing.expectEqualStrings("Simple title", title_attr);
}

test "Parse nested formatting elements" {
    const allocator = std.testing.allocator;
    const html = "<b>Bold <i>both bold and italic <u>and underlined</b> still italic and underlined</i> just underlined</u>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    // Get the body element
    const body = root.element.children.items[1].element;
    try std.testing.expectEqualStrings("body", body.tag);

    // Should have three elements in the body: b, i, and u
    try std.testing.expectEqual(@as(usize, 3), body.children.items.len);

    // Check the b element
    const b = body.children.items[0].element;
    try std.testing.expectEqualStrings("b", b.tag);

    // The b element should have two children: text and i
    try std.testing.expectEqual(@as(usize, 2), b.children.items.len);

    // First child should be text
    try std.testing.expectEqualStrings("Bold ", b.children.items[0].text.text);

    // Second child should be i
    const i_in_b = b.children.items[1].element;
    try std.testing.expectEqualStrings("i", i_in_b.tag);

    // The i element inside b should have two children: text and u
    try std.testing.expectEqual(@as(usize, 2), i_in_b.children.items.len);
    try std.testing.expectEqualStrings("both bold and italic ", i_in_b.children.items[0].text.text);

    // Check the u element inside i inside b
    const u_in_i_in_b = i_in_b.children.items[1].element;
    try std.testing.expectEqualStrings("u", u_in_i_in_b.tag);

    // Check the i element after b
    const i_after_b = body.children.items[1].element;
    try std.testing.expectEqualStrings("i", i_after_b.tag);

    // The i element should have one child: u
    try std.testing.expectEqual(@as(usize, 1), i_after_b.children.items.len);

    // Check the u element inside i after b
    const u_in_i_after_b = i_after_b.children.items[0].element;
    try std.testing.expectEqualStrings("u", u_in_i_after_b.tag);

    // The u element inside i after b should have one text child
    try std.testing.expectEqual(@as(usize, 1), u_in_i_after_b.children.items.len);
    try std.testing.expectEqualStrings(" still italic and underlined", u_in_i_after_b.children.items[0].text.text);

    // Check the u element after i
    const u_after_i = body.children.items[2].element;
    try std.testing.expectEqualStrings("u", u_after_i.tag);

    // The u element should have one text child
    try std.testing.expectEqual(@as(usize, 1), u_after_i.children.items.len);
    try std.testing.expectEqualStrings(" just underlined", u_after_i.children.items[0].text.text);
}
