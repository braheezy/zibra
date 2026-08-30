//! Stateful HTML tokenizer/tree builder.
//!
//! The parser borrows its input buffer and constructs DOM values through a
//! small comptime type boundary, avoiding a dependency back on parser.zig's
//! style application and invalidation code.

const std = @import("std");
const html_serialization = @import("html_serialization.zig");

const formatting_elements = [_][]const u8{
    "b",     "i",      "u", "code", "em",  "strong", "span", "font", "big",
    "small", "strike", "s", "tt",   "sub", "sup",
};

const raw_text_elements = [_][]const u8{
    "script",
};

pub fn Parser(
    comptime Node: type,
    comptime Element: type,
    comptime Text: type,
    comptime fixParentPointersFn: anytype,
) type {
    return struct {
        const HTMLParser = @This();

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
            for (self.unfinished.items) |*node| {
                node.deinit(self.allocator);
            }
            self.unfinished.deinit(self.allocator);
            allocator.destroy(self);
        }

        /// Parse the source into an owning root Node returned by value.
        ///
        /// The parser can repair parent pointers only while its temporary root
        /// has a provisional address. After the caller stores this result at
        /// its final address, it must call `fixParentPointersFn(&root, null)`
        /// before any ancestry walk, style/invalidation, layout, or script
        /// handle publication.
        pub fn parse(self: *HTMLParser) !Node {
            // Track ranges in the original body
            var pos: usize = 0;
            var start_idx: usize = 0;
            var in_tag = false;
            var attribute_quote: ?u8 = null;
            var script_content_start: ?usize = null;

            while (pos < self.body.len) {
                const c = self.body[pos];

                if (self.in_script_tag) {
                    // Special handling for script tag content
                    if (c == '<' and pos + 8 < self.body.len and
                        std.ascii.eqlIgnoreCase(self.body[pos + 1 .. pos + 9], "/script>"))
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
                } else if (!in_tag and std.mem.startsWith(u8, self.body[pos..], "<!--")) {
                    // Comments are not tags: their contents may contain either
                    // angle bracket. Discard the whole comment before returning to
                    // normal text/tag scanning. HTML also treats <!--> as an
                    // abruptly closed empty comment.
                    if (pos > start_idx) {
                        try self.addText(self.body[start_idx..pos]);
                    }

                    const comment_start = pos + "<!--".len;
                    if (comment_start < self.body.len and self.body[comment_start] == '>') {
                        pos = comment_start + 1;
                    } else if (std.mem.indexOfPos(u8, self.body, comment_start, "-->")) |end| {
                        pos = end + "-->".len;
                    } else {
                        // An unterminated comment consumes the rest of the input.
                        pos = self.body.len;
                    }
                    start_idx = pos;
                } else if (c == '<' and !in_tag) {
                    // End of text, start of tag
                    if (pos > start_idx) {
                        // Process text content using direct slice
                        try self.addText(self.body[start_idx..pos]);
                    }
                    // Skip the '<'
                    start_idx = pos + 1;
                    in_tag = true;
                    attribute_quote = null;
                    pos += 1;
                } else if (in_tag and (c == '"' or c == '\'')) {
                    if (attribute_quote) |quote| {
                        if (c == quote) attribute_quote = null;
                    } else {
                        attribute_quote = c;
                    }
                    pos += 1;
                } else if (c == '>' and in_tag and attribute_quote == null) {
                    // End of tag
                    const tag_slice = self.body[start_idx..pos];
                    try self.addTag(tag_slice);

                    // Check if we just entered a script tag
                    const tag_info = parseTagInfo(tag_slice);
                    if (!tag_info.is_closing and isRawTextElement(tag_info.name)) {
                        self.in_script_tag = true;
                        script_content_start = pos + 1; // Start capturing script content
                    }
                    // Skip the '>'
                    start_idx = pos + 1;
                    in_tag = false;
                    attribute_quote = null;
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

        // Add text content to the DOM tree. Layout decides how CSS whitespace
        // collapses; DOM traversal must retain every nonempty text node.
        fn addText(self: *HTMLParser, text_slice: []const u8) !void {
            // Empty tokenization ranges do not represent DOM Text nodes.
            if (text_slice.len == 0) return;

            // If we don't have any elements in the stack yet, can't add text
            if (self.unfinished.items.len == 0) return;

            const parent = &self.unfinished.items[self.unfinished.items.len - 1];

            // Parent pointers are repaired after the tree reaches stable storage.
            const text_node = Text.init(
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

            // Explicit structural start tags supply the nodes that the implicit
            // algorithm would otherwise synthesize. Consume them here so normal
            // opening-tag handling cannot nest a second html/head/body element.
            if (self.use_implicit_tags and !tag_info.is_closing and
                try self.handleExplicitStructuralStart(tag_slice, tag_info.name)) return;

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

        fn hasOpenElement(self: *const HTMLParser, tag_name: []const u8) bool {
            for (self.unfinished.items) |node| switch (node) {
                .element => |element| if (std.ascii.eqlIgnoreCase(element.tag, tag_name)) return true,
                .text => {},
            };
            return false;
        }

        /// Return true when an explicit structural start tag was fully handled.
        fn handleExplicitStructuralStart(
            self: *HTMLParser,
            tag_slice: []const u8,
            tag_name: []const u8,
        ) !bool {
            const is_html = std.ascii.eqlIgnoreCase(tag_name, "html");
            const is_head = std.ascii.eqlIgnoreCase(tag_name, "head");
            const is_body = std.ascii.eqlIgnoreCase(tag_name, "body");
            if (!is_html and !is_head and !is_body) return false;

            if (is_html) {
                if (self.unfinished.items.len == 0) try self.createTopLevelElement(tag_slice);
                // Later html start tags are parse errors whose attributes would
                // merge onto the root in the full tree builder; never nest them.
                return true;
            }

            if (self.unfinished.items.len == 0) try self.createHtmlElement();
            if (is_head) {
                if (self.head_found or self.hasOpenElement("body")) return true;
                if (self.unfinished.items.len == 1) {
                    try self.handleOpeningTag(tag_slice, tag_name);
                }
                return true;
            }

            if (self.hasOpenElement("body")) return true;
            if (self.unfinished.items.len > 1 and
                self.unfinished.items[self.unfinished.items.len - 1] == .element and
                std.ascii.eqlIgnoreCase(
                    self.unfinished.items[self.unfinished.items.len - 1].element.tag,
                    "head",
                ))
            {
                const head_closed = self.unfinished.pop() orelse unreachable;
                try self.unfinished.items[0].appendChild(self.allocator, head_closed);
            }
            if (!self.head_found) {
                try self.ensureHeadElement();
                const head_closed = self.unfinished.pop() orelse unreachable;
                try self.unfinished.items[0].appendChild(self.allocator, head_closed);
            }
            if (self.unfinished.items.len == 1) try self.handleOpeningTag(tag_slice, tag_name);
            return true;
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
            return html_serialization.isVoidElementTag(tag_name);
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

                if (current.* == .element and std.ascii.eqlIgnoreCase(current.element.tag, tag_name)) {
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
                if (std.ascii.eqlIgnoreCase(tag_name, formatting_element)) break true;
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

            // Parent pointers are repaired after the tree reaches stable storage.
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
            // Parent pointers are repaired after the tree reaches stable storage.
            const element = try Element.init(
                self.allocator,
                tag_slice,
                null,
            );

            const node = Node{ .element = element };
            try self.unfinished.append(self.allocator, node);

            // Mark when we've found a head tag
            if (std.ascii.eqlIgnoreCase(tag_name, "head")) {
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
                if (closesOpenParagraph(tag_name)) try self.closeOpenParagraph();
                try self.handleSelfClosingElements(tag_name);
            }
        }

        fn closesOpenParagraph(tag_name: []const u8) bool {
            const paragraph_closing_starts = [_][]const u8{
                "address", "article",  "aside",      "blockquote", "details", "div",
                "dl",      "fieldset", "figcaption", "figure",     "footer",  "form",
                "h1",      "h2",       "h3",         "h4",         "h5",      "h6",
                "header",  "hgroup",   "hr",         "main",       "menu",    "nav",
                "ol",      "p",        "pre",        "search",     "section", "table",
                "ul",
            };
            return for (paragraph_closing_starts) |candidate| {
                if (std.ascii.eqlIgnoreCase(tag_name, candidate)) break true;
            } else false;
        }

        /// Flow-level block starts implicitly end a paragraph, including
        /// through still-open inline formatting descendants. Stop at the
        /// document or button scope boundary rather than reaching into an
        /// unrelated ancestor.
        fn closeOpenParagraph(self: *HTMLParser) !void {
            var i = self.unfinished.items.len;
            while (i > 0) {
                i -= 1;
                const current = &self.unfinished.items[i];
                if (current.* != .element) continue;
                if (std.ascii.eqlIgnoreCase(current.element.tag, "p")) {
                    try self.closeNodesUpTo(i);
                    return;
                }
                if (std.ascii.eqlIgnoreCase(current.element.tag, "button") or
                    std.ascii.eqlIgnoreCase(current.element.tag, "body") or
                    std.ascii.eqlIgnoreCase(current.element.tag, "html")) return;
            }
        }

        // Ensure proper HTML/HEAD/BODY structure is in place
        // Browsers automatically create these elements even if they're missing in the source
        fn ensureHtmlStructure(self: *HTMLParser, tag_name: []const u8, is_closing: bool) !void {
            // List of tags that belong in the head section
            const head_tags = [_][]const u8{ "base", "basefont", "bgsound", "link", "meta", "title", "style", "script" };

            // Is this tag a head element?
            const is_head_tag = for (head_tags) |head_tag| {
                if (std.ascii.eqlIgnoreCase(tag_name, head_tag)) break true;
            } else false;

            // If we have no tags yet, add html tag
            if (self.unfinished.items.len == 0) {
                try self.createHtmlElement();
            }

            // Check what's the current structure
            const current_open_tags = self.unfinished.items.len;
            const in_html_only = current_open_tags == 1 and
                std.ascii.eqlIgnoreCase(self.unfinished.items[0].element.tag, "html");

            // Add head tag if needed
            if (in_html_only) {
                // We're at the HTML level
                if (std.ascii.eqlIgnoreCase(tag_name, "head") or is_head_tag) {
                    // If this is a head tag or belongs in head, add the head element
                    try self.ensureHeadElement();
                } else if (!is_closing) {
                    // This is a non-head tag and not a closing tag, add both head and body
                    try self.ensureHeadAndBodyElements();
                }
            } else if (current_open_tags > 1 and std.ascii.eqlIgnoreCase(self.unfinished.items[self.unfinished.items.len - 1].element.tag, "head")) {
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

        // Handle elements that can't contain themselves. A second button start
        // tag implicitly closes the active button in real HTML parsing, making
        // the two controls siblings instead of nested interactive descendants.
        fn handleSelfClosingElements(self: *HTMLParser, tag_name: []const u8) !void {
            // Tags that can't contain themselves directly
            const self_closing_elements = [_][]const u8{ "p", "li", "button" };

            // Check if this is a tag that can't contain itself
            const is_self_closing_element = for (self_closing_elements) |elem| {
                if (std.ascii.eqlIgnoreCase(tag_name, elem)) break true;
            } else false;

            if (is_self_closing_element) {
                try self.handleSelfClosingElement(tag_name);
            }
        }

        // Handle a specific implied-closing element (p, li, or button).
        fn handleSelfClosingElement(self: *HTMLParser, tag_name: []const u8) !void {
            // For each element in the stack from top to bottom
            var i: usize = self.unfinished.items.len;
            while (i > 0) {
                i -= 1;
                const current = &self.unfinished.items[i];

                // A nested list is valid content of an outer list item. When
                // opening an li inside it, do not close the outer item.
                if (std.ascii.eqlIgnoreCase(tag_name, "li") and
                    current.* == .element and isListContainer(current.element.tag))
                {
                    break;
                }

                // If we find the same tag type
                if (current.* == .element and std.ascii.eqlIgnoreCase(current.element.tag, tag_name)) {
                    try self.closeNodesUpTo(i);
                    break;
                }

                // A button may contain arbitrary flow descendants in malformed
                // source, and a later button start still closes it through those
                // descendants. The simplified p/li recovery keeps its historical
                // div boundary.
                if (current.* == .element and ((!std.ascii.eqlIgnoreCase(tag_name, "button") and
                    std.ascii.eqlIgnoreCase(current.element.tag, "div")) or
                    std.ascii.eqlIgnoreCase(current.element.tag, "body") or
                    std.ascii.eqlIgnoreCase(current.element.tag, "html")))
                {
                    break;
                }
            }
        }

        fn isListContainer(tag_name: []const u8) bool {
            const list_containers = [_][]const u8{ "ul", "ol", "menu" };
            return for (list_containers) |list_container| {
                if (std.ascii.eqlIgnoreCase(tag_name, list_container)) break true;
            } else false;
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
            fixParentPointersFn(&root, null);

            return root;
        }

        /// Write a deterministic, indented DOM tree without invoking layout or
        /// rendering. The caller owns the output destination.
        pub fn writePretty(self: *HTMLParser, writer: *std.Io.Writer, node: Node, indent: usize) !void {
            // Create a temporary buffer filled with spaces
            const spaces = try self.allocator.alloc(u8, indent);
            defer self.allocator.free(spaces);

            // Fill with spaces
            @memset(spaces, ' ');

            // Get the string representation and properly free it after use
            const node_str = try node.asString(self.allocator);
            defer self.allocator.free(node_str);

            try writer.print("{s}{s}\n", .{ spaces, node_str });

            switch (node) {
                .text => {},
                .element => |e| {
                    for (e.children.items, 0..) |_, i| {
                        try self.writePretty(writer, e.children.items[i], indent + 2);
                    }
                },
            }
        }

        // Check if a tag is a raw text element (like script)
        fn isRawTextElement(tag_name: []const u8) bool {
            return for (raw_text_elements) |raw_text_element| {
                if (std.ascii.eqlIgnoreCase(tag_name, raw_text_element)) break true;
            } else false;
        }

        // Ensure a BODY element exists before finishing parsing
        fn ensureBodyElementBeforeFinish(self: *HTMLParser) !void {
            // An empty (or whitespace-only) response still represents an HTML
            // document. Build the same implicit structure that a non-head tag
            // would have caused during tokenization.
            if (self.unfinished.items.len == 0) {
                try self.createHtmlElement();
                try self.ensureHeadAndBodyElements();
                return;
            }

            // If we have an HTML element and a HEAD element but no BODY element
            if (self.unfinished.items.len == 2 and
                std.ascii.eqlIgnoreCase(self.unfinished.items[0].element.tag, "html") and
                std.ascii.eqlIgnoreCase(self.unfinished.items[1].element.tag, "head"))
            {

                // Close the head
                const head_closed = self.unfinished.pop() orelse unreachable;
                try self.unfinished.items[0].appendChild(self.allocator, head_closed);

                // Add a body element
                try self.ensureBodyElement();
            }
        }
    };
}
