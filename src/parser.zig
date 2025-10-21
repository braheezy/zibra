const std = @import("std");
pub const CSSParser = @import("cssParser.zig").CSSParser;

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

// Raw text elements where content should not be parsed as HTML
// Currently only script is supported, but could add style, textarea, etc.
const raw_text_elements = [_][]const u8{
    "script",
};

const Text = struct {
    text: []const u8,
    parent: ?*Node = null,
    children: ?std.ArrayList(Node) = null,
    is_focused: bool = false,

    pub fn init(text: []const u8, parent: ?*Node) !Text {
        return Text{
            .text = text,
            .parent = parent,
            .children = null,
            .is_focused = false,
        };
    }
};

pub const Element = struct {
    tag: []const u8,
    attributes: ?std.StringHashMap([]const u8) = null,
    style: ?std.StringHashMap([]const u8) = null,
    parent: ?*Node = null,
    children: std.ArrayList(Node),
    // Track strings we've allocated (like resolved percentage font sizes) so we can free them
    owned_strings: ?std.ArrayList([]const u8) = null,
    is_focused: bool = false,

    pub fn init(allocator: std.mem.Allocator, tag: []const u8, parent: ?*Node) !Element {
        var e = Element{
            .tag = tag,
            .parent = parent,
            .attributes = null,
            .style = null,
            .children = std.ArrayList(Node).empty,
            .owned_strings = null,
            .is_focused = false,
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

    pub fn deinit(self: *Element, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);

        if (self.attributes) |attributes| {
            var attrs = attributes;
            attrs.deinit();
        }

        if (self.style) |styles| {
            var s = styles;
            s.deinit();
        }

        // Free any strings we allocated (like resolved percentage font sizes)
        if (self.owned_strings) |owned| {
            for (owned.items) |str| {
                allocator.free(str);
            }
            var o = owned;
            o.deinit(allocator);
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

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => {},
            .element => |*e| e.deinit(allocator),
        }
    }

    pub fn appendChild(self: *Node, allocator: std.mem.Allocator, child: Node) !void {
        switch (self.*) {
            .text => unreachable,
            .element => |*e| {
                try e.children.append(allocator, child);
                // Note: Parent pointers are fixed after the tree is fully built
                // to avoid issues with ArrayList reallocation invalidating pointers
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
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(al);

        switch (self.*) {
            .text => |t| {
                try result.appendSlice(al, t.text);
            },
            .element => |e| {
                try result.append(al, '<');
                try result.appendSlice(al, e.tag);

                if (e.attributes) |attrs| {
                    var it = attrs.iterator();
                    while (it.next()) |entry| {
                        try result.append(al, ' ');
                        try result.appendSlice(al, entry.key_ptr.*);

                        // Only add ="value" if the attribute has a value
                        if (entry.value_ptr.*.len > 0) {
                            try result.appendSlice(al, "=\"");
                            try result.appendSlice(al, entry.value_ptr.*);
                            try result.append(al, '"');
                        }
                    }
                }

                try result.append(al, '>');
            },
        }

        return result.toOwnedSlice(al);
    }
};

// Public function to fix parent pointers after modifying the tree
pub fn fixParentPointers(node: *Node, parent: ?*Node) void {
    switch (node.*) {
        .element => |*e| {
            e.parent = parent;
            for (e.children.items) |*child| {
                fixParentPointers(child, node);
            }
        },
        .text => |*t| {
            t.parent = parent;
        },
    }
}

pub const HTMLParser = struct {
    body: []const u8,
    unfinished: std.ArrayList(Node) = undefined,
    allocator: std.mem.Allocator,
    // Track if <head> tag has been found
    head_found: bool = false,
    use_implicit_tags: bool = true,
    // Track if we're inside a script tag
    in_script_tag: bool = false,

    pub fn init(allocator: std.mem.Allocator, body: []const u8) !*HTMLParser {
        const parser = try allocator.create(HTMLParser);
        parser.* = HTMLParser{
            .body = body,
            .unfinished = std.ArrayList(Node).empty,
            .allocator = allocator,
            .head_found = false,
            .use_implicit_tags = true,
            .in_script_tag = false,
        };
        return parser;
    }

    pub fn deinit(self: *HTMLParser, allocator: std.mem.Allocator) void {
        self.unfinished.deinit(self.allocator);
        allocator.destroy(self);
    }

    pub fn parse(self: *HTMLParser) !Node {
        // Track ranges in the original body
        var pos: usize = 0;
        var start_idx: usize = 0;
        var in_tag = false;
        var script_content_start: ?usize = null;

        while (pos < self.body.len) {
            const c = self.body[pos];

            if (self.in_script_tag) {
                // Special handling for script tag content
                if (c == '<' and pos + 8 < self.body.len and
                    std.mem.eql(u8, self.body[pos + 1 .. pos + 9], "/script>"))
                {
                    // Found </script> closing tag

                    // Add all content up to this point as a script node
                    if (pos > start_idx and script_content_start != null) {
                        const script_content = self.body[script_content_start.?..pos];
                        try self.addText(script_content); // Add as text node to the script element
                    }

                    // Process the closing script tag
                    try self.addTag("/script");

                    // Skip past the closing tag
                    pos += 9;
                    start_idx = pos;
                    self.in_script_tag = false;
                    script_content_start = null;
                } else {
                    // Continue to next character if we're still in script tag
                    pos += 1;
                }
            } else if (c == '<') {
                // End of text, start of tag
                if (!in_tag and pos > start_idx) {
                    // Process text content using direct slice
                    try self.addText(self.body[start_idx..pos]);
                }
                // Skip the '<'
                start_idx = pos + 1;
                in_tag = true;
                pos += 1;
            } else if (c == '>') {
                // End of tag
                if (in_tag) {
                    const tag_slice = self.body[start_idx..pos];
                    try self.addTag(tag_slice);

                    // Check if we just entered a script tag
                    const tag_info = parseTagInfo(tag_slice);
                    if (!tag_info.is_closing and isRawTextElement(tag_info.name)) {
                        self.in_script_tag = true;
                        script_content_start = pos + 1; // Start capturing script content
                    }
                }
                // Skip the '>'
                start_idx = pos + 1;
                in_tag = false;
                pos += 1;
            } else {
                // Just a regular character
                pos += 1;
            }
        }

        // Handle any final text
        if (!in_tag and start_idx < self.body.len) {
            try self.addText(self.body[start_idx..]);
        }

        // Ensure we have a body element before finishing
        if (self.use_implicit_tags) {
            try self.ensureBodyElementBeforeFinish();
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
        // Don't pass parent pointer - let appendChild set it
        const text_node = try Text.init(
            text_slice,
            null,
        );

        const node = Node{ .text = text_node };
        try parent.appendChild(self.allocator, node);
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
        try self.unfinished.append(self.allocator, node);
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
        var formatting_to_reopen = std.ArrayList([]const u8).empty;
        defer formatting_to_reopen.deinit(self.allocator);

        // Identify formatting elements that need to be reopened
        var j: usize = self.unfinished.items.len - 1;
        while (j > index) {
            const element = &self.unfinished.items[j];
            if (element.* == .element) {
                const tag = element.element.tag;
                if (isFormattingElement(tag)) {
                    try formatting_to_reopen.append(self.allocator, tag);
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
            try parent.appendChild(self.allocator, node);
        }

        // Now close the target tag itself
        const node = self.unfinished.pop() orelse unreachable;
        const parent = &self.unfinished.items[self.unfinished.items.len - 1];
        try parent.appendChild(self.allocator, node);
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
        // Don't pass parent pointer - let appendChild set it
        const element = try Element.init(
            self.allocator,
            tag_slice,
            null,
        );

        const node = Node{ .element = element };
        try parent.appendChild(self.allocator, node);
    }

    // Handle an opening tag by creating it and adding it to the unfinished stack
    fn handleOpeningTag(self: *HTMLParser, tag_slice: []const u8, tag_name: []const u8) !void {
        // Create element directly
        // Don't pass parent pointer - it will be set when added to parent
        const element = try Element.init(
            self.allocator,
            tag_slice,
            null,
        );

        const node = Node{ .element = element };
        try self.unfinished.append(self.allocator, node);

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
        try self.unfinished.append(self.allocator, html_node);
    }

    // Ensure a HEAD element exists if needed
    fn ensureHeadElement(self: *HTMLParser) !void {
        if (!self.head_found) {
            const head_element = try Element.init(
                self.allocator,
                "head",
                null,
            );
            const head_node = Node{ .element = head_element };
            try self.unfinished.append(self.allocator, head_node);
            self.head_found = true;
        }
    }

    // Ensure a BODY element exists
    fn ensureBodyElement(self: *HTMLParser) !void {
        const body_element = try Element.init(
            self.allocator,
            "body",
            null,
        );
        const body_node = Node{ .element = body_element };
        try self.unfinished.append(self.allocator, body_node);
    }

    // Ensure both HEAD and BODY elements exist
    fn ensureHeadAndBodyElements(self: *HTMLParser) !void {
        // First add head if not already added
        if (!self.head_found) {
            const head_element = try Element.init(
                self.allocator,
                "head",
                null,
            );
            const head_node = Node{ .element = head_element };
            try self.unfinished.append(self.allocator, head_node);
            self.head_found = true;

            // Close the head immediately since we're about to see a body element
            const head_closed = self.unfinished.pop() orelse unreachable;
            try self.unfinished.items[0].appendChild(self.allocator, head_closed);
        }

        // Then add body
        try self.ensureBodyElement();
    }

    // Close the HEAD element and open a BODY element
    fn closeHeadAndOpenBody(self: *HTMLParser) !void {
        const head_closed = self.unfinished.pop() orelse unreachable;
        try self.unfinished.items[0].appendChild(self.allocator, head_closed);

        // Add body
        const body_element = try Element.init(
            self.allocator,
            "body",
            null,
        );
        const body_node = Node{ .element = body_element };
        try self.unfinished.append(self.allocator, body_node);
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
            try parent.appendChild(self.allocator, node);
        }

        // Return the root node
        var root = self.unfinished.pop() orelse unreachable;

        // Fix all parent pointers now that the tree is stable
        fixParentPointers(&root, null);

        return root;
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

    // Check if a tag is a raw text element (like script)
    fn isRawTextElement(tag_name: []const u8) bool {
        return for (raw_text_elements) |raw_text_element| {
            if (std.mem.eql(u8, tag_name, raw_text_element)) break true;
        } else false;
    }

    // Ensure a BODY element exists before finishing parsing
    fn ensureBodyElementBeforeFinish(self: *HTMLParser) !void {
        // If we have an HTML element and a HEAD element but no BODY element
        if (self.unfinished.items.len == 2 and
            std.mem.eql(u8, self.unfinished.items[0].element.tag, "html") and
            std.mem.eql(u8, self.unfinished.items[1].element.tag, "head"))
        {

            // Close the head
            const head_closed = self.unfinished.pop() orelse unreachable;
            try self.unfinished.items[0].appendChild(self.allocator, head_closed);

            // Add a body element
            try self.ensureBodyElement();
        }
    }
};

// Inherited CSS properties with their default values
const InheritedProperty = struct {
    name: []const u8,
    default_value: []const u8,
};

const INHERITED_PROPERTIES = [_]InheritedProperty{
    .{ .name = "font-size", .default_value = "16px" },
    .{ .name = "font-style", .default_value = "normal" },
    .{ .name = "font-weight", .default_value = "normal" },
    .{ .name = "color", .default_value = "black" },
};

// Helper to get a default parent style map with inherited defaults
fn getDefaultParentStyle(allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
    var parent_style = std.StringHashMap([]const u8).init(allocator);
    for (INHERITED_PROPERTIES) |prop| {
        try parent_style.put(prop.name, prop.default_value);
    }
    return parent_style;
}

// Parse inline styles from the style attribute and apply CSS rules to the node tree
// This function recurses through the HTML tree to process all elements
pub fn style(allocator: std.mem.Allocator, node: *Node, rules: []const CSSParser.CSSRule) !void {
    var default_parent = try getDefaultParentStyle(allocator);
    defer default_parent.deinit();
    const empty_ancestors = &[_]*Node{};
    try styleWithParent(allocator, node, rules, &default_parent, empty_ancestors);
}

fn styleWithParent(allocator: std.mem.Allocator, node: *Node, rules: []const CSSParser.CSSRule, parent_style: *const std.StringHashMap([]const u8), ancestor_chain: []const *Node) !void {
    switch (node.*) {
        .text => {
            // Text nodes don't have styles
            return;
        },
        .element => |*e| {
            // Initialize empty style map
            e.style = std.StringHashMap([]const u8).init(allocator);

            // First, inherit properties from parent
            for (INHERITED_PROPERTIES) |prop| {
                const value = parent_style.get(prop.name) orelse prop.default_value;
                try e.style.?.put(prop.name, value);
            }

            // Second, apply styles from CSS rules (can override inherited values)
            for (rules) |rule| {
                if (rule.selector.matches(node, ancestor_chain)) {
                    // This rule matches, copy all its properties
                    var it = rule.properties.iterator();
                    while (it.next()) |entry| {
                        try e.style.?.put(entry.key_ptr.*, entry.value_ptr.*);
                    }
                }
            }

            // Third, apply inline styles from the style attribute (overrides everything)
            if (e.attributes) |attrs| {
                if (attrs.get("style")) |style_attr| {
                    // The style_attr string is owned by the element's attributes map,
                    // so it will live as long as the element. We can parse it directly.
                    var css_parser = try CSSParser.init(allocator, style_attr);
                    defer css_parser.deinit(allocator);

                    var parsed_styles = try css_parser.body(allocator);
                    defer parsed_styles.deinit();

                    // Copy parsed styles to the element's style map (overriding everything else)
                    // Since style_attr lives in attributes, these slices are safe to store
                    var it = parsed_styles.iterator();
                    while (it.next()) |entry| {
                        try e.style.?.put(entry.key_ptr.*, entry.value_ptr.*);
                    }
                }
            }

            // Fourth, resolve percentage font sizes to absolute pixels
            if (e.style.?.get("font-size")) |font_size| {
                if (std.mem.endsWith(u8, font_size, "%")) {
                    // Get parent font size from inherited value
                    const parent_font_size = parent_style.get("font-size") orelse "16px";

                    // Parse the percentage (e.g., "150%" -> 150)
                    const pct_str = font_size[0 .. font_size.len - 1];
                    const node_pct = try std.fmt.parseFloat(f64, pct_str);

                    // Parse parent font size (e.g., "16px" -> 16)
                    const parent_px_str = parent_font_size[0 .. parent_font_size.len - 2];
                    const parent_px = try std.fmt.parseFloat(f64, parent_px_str);

                    // Calculate absolute size
                    const absolute_px = (node_pct / 100.0) * parent_px;

                    // Format back to string with "px"
                    const resolved_size = try std.fmt.allocPrint(allocator, "{d:.1}px", .{absolute_px});

                    // Track this allocated string so we can free it later
                    if (e.owned_strings == null) {
                        e.owned_strings = std.ArrayList([]const u8).empty;
                    }
                    try e.owned_strings.?.append(allocator, resolved_size);

                    try e.style.?.put("font-size", resolved_size);
                }
            }

            // Finally, recursively process all children with this element's computed style
            // Build new ancestor chain by appending current node
            var new_ancestors = try allocator.alloc(*Node, ancestor_chain.len + 1);
            defer allocator.free(new_ancestors);

            // Copy existing ancestors
            for (ancestor_chain, 0..) |ancestor, i| {
                new_ancestors[i] = ancestor;
            }
            // Add current node as the most recent ancestor
            new_ancestors[ancestor_chain.len] = node;

            for (e.children.items) |*child| {
                try styleWithParent(allocator, child, rules, &e.style.?, new_ancestors);
            }
        },
    }
}

/// Convert a tree structure into a flat list of nodes
/// Works on both HTML and layout trees
pub fn treeToList(allocator: std.mem.Allocator, node: *Node, list: *std.ArrayList(*Node)) !void {
    try list.append(allocator, node);

    switch (node.*) {
        .text => {},
        .element => |*e| {
            for (e.children.items) |*child| {
                try treeToList(allocator, child, list);
            }
        },
    }
}
