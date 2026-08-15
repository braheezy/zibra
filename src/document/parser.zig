//! DOM representation, tutorial HTML parser, and computed-style application.
//!
//! Parsed node strings borrow the parser input buffer. The caller must keep
//! that buffer alive until the complete `Node` tree has been deinitialized.
//! Child nodes are stored by value, so callers must repair parent pointers
//! after structural mutation and must not retain pointers across relocation.

const std = @import("std");
const zigimg = @import("zigimg");
const ProtectedField = @import("../core/protected_field.zig").ProtectedField;
const CSSParser = @import("css_parser.zig").CSSParser;

/// Animation state for a numeric CSS property transition
pub const NumericAnimation = struct {
    start_value: f64,
    end_value: f64,
    current_frame: u32,
    total_frames: u32,

    pub fn init(start: f64, end: f64, frames: u32) NumericAnimation {
        return .{
            .start_value = start,
            .end_value = end,
            .current_frame = 0,
            .total_frames = frames,
        };
    }

    /// Get the current interpolated value
    pub fn getValue(self: NumericAnimation) f64 {
        if (self.total_frames == 0) return self.end_value;
        const t: f64 = @as(f64, @floatFromInt(self.current_frame)) / @as(f64, @floatFromInt(self.total_frames));
        return self.start_value + (self.end_value - self.start_value) * t;
    }

    /// Advance the animation by one frame, returns true if animation is complete
    pub fn advance(self: *NumericAnimation) bool {
        if (self.current_frame < self.total_frames) {
            self.current_frame += 1;
        }
        return self.current_frame >= self.total_frames;
    }

    /// Check if animation is complete
    pub fn isComplete(self: NumericAnimation) bool {
        return self.current_frame >= self.total_frames;
    }
};

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

pub const StyleMap = std.StringHashMap(ProtectedField([]const u8));

const Text = struct {
    text: []const u8,
    parent: ?*Node = null,
    style: ?StyleMap = null,

    fn init(text: []const u8, parent: ?*Node) Text {
        return .{
            .text = text,
            .parent = parent,
            .style = null,
        };
    }
};

pub const Element = struct {
    tag: []const u8,
    attributes: ?std.StringHashMap([]const u8) = null,
    style: ?StyleMap = null,
    parent: ?*Node = null,
    children: std.ArrayList(Node),
    layout_ptr: ?*anyopaque = null,
    layout_mark: ?*const fn (*anyopaque) void = null,
    // Track strings we've allocated (like resolved percentage font sizes) so we can free them
    owned_strings: ?std.ArrayList([]const u8) = null,
    is_focused: bool = false,
    children_dirty: bool = true,
    // Animation state for CSS transitions, keyed by property name (e.g., "opacity")
    animations: ?std.StringHashMap(NumericAnimation) = null,
    image_data: ?ImageData = null,
    opacity_anim_value: [32]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, tag: []const u8, parent: ?*Node) !Element {
        var e = Element{
            .tag = tag,
            .parent = parent,
            .attributes = null,
            .style = null,
            .children = std.ArrayList(Node).empty,
            .owned_strings = null,
            .is_focused = false,
            .animations = null,
            .image_data = null,
        };
        errdefer e.deinit(allocator);

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

        if (self.style) |*styles| {
            deinitStyleMap(styles);
        }

        // Free any strings we allocated (like resolved percentage font sizes)
        if (self.owned_strings) |owned| {
            for (owned.items) |str| {
                allocator.free(str);
            }
            var o = owned;
            o.deinit(allocator);
        }

        if (self.image_data) |*image_data| {
            image_data.deinit(allocator);
        }

        // Free animations map
        if (self.animations) |animations| {
            var a = animations;
            a.deinit();
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

pub const ImageData = struct {
    encoded_bytes: ?[]const u8,
    image: zigimg.Image,

    pub fn deinit(self: *ImageData, allocator: std.mem.Allocator) void {
        self.image.deinit(allocator);
        if (self.encoded_bytes) |bytes| {
            allocator.free(bytes);
        }
    }
};

pub const Node = union(enum) {
    text: Text,
    element: Element,

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |*t| {
                if (t.style) |*styles| {
                    deinitStyleMap(styles);
                }
            },
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

    // Allocate a string from a node because attributes may need assembling.
    // caller must free the string
    fn asString(self: *const Node, al: std.mem.Allocator) ![]const u8 {
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
        for (self.unfinished.items) |*node| {
            node.deinit(self.allocator);
        }
        self.unfinished.deinit(self.allocator);
        allocator.destroy(self);
    }

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

    // Handle elements that can't contain themselves (p, li).
    fn handleSelfClosingElements(self: *HTMLParser, tag_name: []const u8) !void {
        // Tags that can't contain themselves directly
        const self_closing_elements = [_][]const u8{ "p", "li" };

        // Check if this is a tag that can't contain itself
        const is_self_closing_element = for (self_closing_elements) |elem| {
            if (std.mem.eql(u8, tag_name, elem)) break true;
        } else false;

        if (is_self_closing_element) {
            try self.handleSelfClosingElement(tag_name);
        }
    }

    // Handle a specific implied-closing element (p or li).
    fn handleSelfClosingElement(self: *HTMLParser, tag_name: []const u8) !void {
        // For each element in the stack from top to bottom
        var i: usize = self.unfinished.items.len;
        while (i > 0) {
            i -= 1;
            const current = &self.unfinished.items[i];

            // A nested list is valid content of an outer list item. When
            // opening an li inside it, do not close the outer item.
            if (std.mem.eql(u8, tag_name, "li") and
                current.* == .element and isListContainer(current.element.tag))
            {
                break;
            }

            // If we find the same tag type
            if (current.* == .element and std.mem.eql(u8, current.element.tag, tag_name)) {
                try self.closeNodesUpTo(i);
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

    fn isListContainer(tag_name: []const u8) bool {
        const list_containers = [_][]const u8{ "ul", "ol", "menu" };
        return for (list_containers) |list_container| {
            if (std.mem.eql(u8, tag_name, list_container)) break true;
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
        fixParentPointers(&root, null);

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
            if (std.mem.eql(u8, tag_name, raw_text_element)) break true;
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
    .{ .name = "font-family", .default_value = "sans-serif" },
    .{ .name = "font-size", .default_value = "16px" },
    .{ .name = "font-style", .default_value = "normal" },
    .{ .name = "font-weight", .default_value = "normal" },
    .{ .name = "color", .default_value = "black" },
    .{ .name = "color-scheme", .default_value = "light dark" },
};

const CSS_PROPERTIES = [_]struct { name: []const u8, default_value: []const u8 }{
    .{ .name = "font-family", .default_value = "inherit" },
    .{ .name = "font-size", .default_value = "inherit" },
    .{ .name = "font-weight", .default_value = "inherit" },
    .{ .name = "font-style", .default_value = "inherit" },
    .{ .name = "color", .default_value = "inherit" },
    .{ .name = "opacity", .default_value = "1.0" },
    .{ .name = "transition", .default_value = "" },
    .{ .name = "transform", .default_value = "none" },
    .{ .name = "mix-blend-mode", .default_value = "" },
    .{ .name = "border-radius", .default_value = "0px" },
    .{ .name = "overflow", .default_value = "visible" },
    .{ .name = "outline", .default_value = "none" },
    .{ .name = "background-color", .default_value = "transparent" },
    .{ .name = "image-rendering", .default_value = "auto" },
    .{ .name = "color-scheme", .default_value = "light dark" },
    .{ .name = "display", .default_value = "inline" },
    .{ .name = "width", .default_value = "auto" },
    .{ .name = "height", .default_value = "auto" },
};

fn isInheritedProperty(property: []const u8) bool {
    for (INHERITED_PROPERTIES) |prop| {
        if (std.mem.eql(u8, prop.name, property)) return true;
    }
    return false;
}

fn initStyleMap(allocator: std.mem.Allocator, obj_name: []const u8, parent_style: ?*StyleMap) !StyleMap {
    var map = StyleMap.init(allocator);
    errdefer deinitStyleMap(&map);
    for (CSS_PROPERTIES) |prop| {
        var field = ProtectedField([]const u8).initNamed(allocator, prop.default_value, obj_name, prop.name);
        field.dirty = true;
        map.put(prop.name, field) catch |err| {
            field.deinit();
            return err;
        };
    }
    for (CSS_PROPERTIES) |prop| {
        if (map.getPtr(prop.name)) |child_field| {
            if (parent_style != null and isInheritedProperty(prop.name)) {
                if (parent_style.?.getPtr(prop.name)) |parent_field| {
                    child_field.addDependency(parent_field);
                }
            }
            child_field.freezeDependencies();
        }
    }
    return map;
}

fn deinitStyleMap(map: *StyleMap) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit();
    }
    map.deinit();
}

fn styleNeedsUpdate(map: *StyleMap) bool {
    var it = map.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.dirty) return true;
    }
    return false;
}

pub fn dirtyStyleForElement(e: *Element) void {
    if (e.style) |*style_map| {
        var it = style_map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.mark();
        }
    }
}

fn cssDefaultFor(property: []const u8) []const u8 {
    for (CSS_PROPERTIES) |prop| {
        if (std.mem.eql(u8, prop.name, property)) {
            return prop.default_value;
        }
    }
    return "";
}

fn resolveFontFamilyKeyword(value: []const u8, inherited_value: []const u8) []const u8 {
    const keyword = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(keyword, "inherit") or
        std.ascii.eqlIgnoreCase(keyword, "unset"))
    {
        return inherited_value;
    }
    if (std.ascii.eqlIgnoreCase(keyword, "initial")) return "sans-serif";
    return value;
}

// Helper to get a default parent style map with inherited defaults
fn getDefaultParentStyle(allocator: std.mem.Allocator) !StyleMap {
    var parent_style = try initStyleMap(allocator, "Node", null);
    var it = parent_style.iterator();
    while (it.next()) |entry| {
        const default_value = cssDefaultFor(entry.key_ptr.*);
        entry.value_ptr.set(default_value);
    }
    for (INHERITED_PROPERTIES) |prop| {
        if (parent_style.getPtr(prop.name)) |field| {
            field.set(prop.default_value);
        }
    }
    return parent_style;
}

// Parse inline styles from the style attribute and apply CSS rules to the node tree
// This function recurses through the HTML tree to process all elements
pub fn style(allocator: std.mem.Allocator, node: *Node, rules: []const CSSParser.CSSRule) !void {
    var default_parent = try getDefaultParentStyle(allocator);
    defer deinitStyleMap(&default_parent);
    const empty_ancestors = &[_]*Node{};
    try styleWithParent(allocator, node, rules, &default_parent, empty_ancestors);
}

fn styleWithParent(allocator: std.mem.Allocator, node: *Node, rules: []const CSSParser.CSSRule, parent_style: *StyleMap, ancestor_chain: []const *Node) !void {
    switch (node.*) {
        .text => |*t| {
            if (t.style == null) {
                t.style = try initStyleMap(allocator, "TextNode", parent_style);
            }
            var style_map = &t.style.?;
            if (!styleNeedsUpdate(style_map)) return;

            var new_style = std.StringHashMap([]const u8).init(allocator);
            defer new_style.deinit();

            for (CSS_PROPERTIES) |prop| {
                try new_style.put(prop.name, prop.default_value);
            }

            for (INHERITED_PROPERTIES) |prop| {
                if (style_map.getPtr(prop.name)) |child_field| {
                    if (parent_style.getPtr(prop.name)) |parent_field| {
                        const parent_value = parent_field.read(child_field).*;
                        try new_style.put(prop.name, parent_value);
                    } else {
                        try new_style.put(prop.name, prop.default_value);
                    }
                }
            }

            for (CSS_PROPERTIES) |prop| {
                if (style_map.getPtr(prop.name)) |field| {
                    const value = new_style.get(prop.name) orelse prop.default_value;
                    field.set(value);
                }
            }
            return;
        },
        .element => |*e| {
            if (e.style == null) {
                e.style = try initStyleMap(allocator, "Element", parent_style);
            }
            var style_map = &e.style.?;
            const needs_style = styleNeedsUpdate(style_map);

            if (needs_style) {
                var new_style = std.StringHashMap([]const u8).init(allocator);
                defer new_style.deinit();

                for (CSS_PROPERTIES) |prop| {
                    try new_style.put(prop.name, prop.default_value);
                }

                // First, inherit properties from parent
                for (INHERITED_PROPERTIES) |prop| {
                    if (style_map.getPtr(prop.name)) |child_field| {
                        if (parent_style.getPtr(prop.name)) |parent_field| {
                            const parent_value = parent_field.read(child_field).*;
                            try new_style.put(prop.name, parent_value);
                        } else {
                            try new_style.put(prop.name, prop.default_value);
                        }
                    }
                }

                // Second, apply styles from CSS rules (can override inherited values)
                for (rules) |rule| {
                    if (rule.selector.matches(node, ancestor_chain)) {
                        var it = rule.properties.iterator();
                        while (it.next()) |entry| {
                            try new_style.put(entry.key_ptr.*, entry.value_ptr.*);
                        }
                    }
                }

                // Third, apply inline styles from the style attribute (overrides everything)
                if (e.attributes) |attrs| {
                    if (attrs.get("style")) |style_attr| {
                        var css_parser = try CSSParser.init(allocator, style_attr, false);
                        defer css_parser.deinit(allocator);

                        var parsed_styles = try css_parser.body(allocator);
                        defer parsed_styles.deinit();

                        var it = parsed_styles.iterator();
                        while (it.next()) |entry| {
                            try new_style.put(entry.key_ptr.*, entry.value_ptr.*);
                        }
                    }
                }

                // Resolve CSS-wide keywords before storing the computed
                // font-family value. Since font-family is inherited, `unset`
                // has the same effect as `inherit`.
                if (new_style.get("font-family")) |font_family| {
                    const child_field = style_map.getPtr("font-family").?;
                    const inherited_family = if (parent_style.getPtr("font-family")) |parent_field|
                        parent_field.read(child_field).*
                    else
                        "sans-serif";
                    try new_style.put(
                        "font-family",
                        resolveFontFamilyKeyword(font_family, inherited_family),
                    );
                }

                // Fourth, resolve percentage font sizes to absolute pixels
                if (new_style.get("font-size")) |font_size| {
                    if (std.mem.endsWith(u8, font_size, "%")) {
                        const child_field = style_map.getPtr("font-size").?;
                        const parent_font_size = if (parent_style.getPtr("font-size")) |parent_field|
                            parent_field.read(child_field).*
                        else
                            "16px";

                        const pct_str = font_size[0 .. font_size.len - 1];
                        const node_pct = try std.fmt.parseFloat(f64, pct_str);

                        const parent_px_str = parent_font_size[0 .. parent_font_size.len - 2];
                        const parent_px = try std.fmt.parseFloat(f64, parent_px_str);

                        const absolute_px = (node_pct / 100.0) * parent_px;
                        const resolved_size = try std.fmt.allocPrint(allocator, "{d:.1}px", .{absolute_px});
                        var resolved_size_owned = true;
                        defer if (resolved_size_owned) allocator.free(resolved_size);

                        if (e.owned_strings == null) {
                            e.owned_strings = std.ArrayList([]const u8).empty;
                        }
                        try e.owned_strings.?.append(allocator, resolved_size);
                        resolved_size_owned = false;

                        try new_style.put("font-size", resolved_size);
                    }
                }

                for (CSS_PROPERTIES) |prop| {
                    if (style_map.getPtr(prop.name)) |field| {
                        const value = new_style.get(prop.name) orelse prop.default_value;
                        field.set(value);
                    }
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
                try styleWithParent(allocator, child, rules, style_map, new_ancestors);
            }
        },
    }
}

/// Convert a DOM tree into a flat list of node pointers.
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

/// Write the DOM with its computed style values in a stable property order.
/// This is intentionally separate from `writePretty`: callers can inspect the
/// cascade without constructing layout, a renderer, or a JavaScript context.
pub fn writeStyledPretty(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    node: Node,
    indent: usize,
) !void {
    const spaces = try allocator.alloc(u8, indent);
    defer allocator.free(spaces);
    @memset(spaces, ' ');

    const node_str = try node.asString(allocator);
    defer allocator.free(node_str);
    try writer.print("{s}{s}", .{ spaces, node_str });

    const style_map: ?*const StyleMap = switch (node) {
        .text => |text| if (text.style) |*styles| styles else null,
        .element => |element| if (element.style) |*styles| styles else null,
    };
    if (style_map) |styles| {
        try writer.writeAll(" [");
        for (CSS_PROPERTIES, 0..) |prop, index| {
            if (index != 0) try writer.writeAll("; ");
            const value = if (styles.getPtr(prop.name)) |field|
                field.get().*
            else
                prop.default_value;
            try writer.print("{s}: {s}", .{ prop.name, value });
        }
        try writer.writeAll("]");
    }
    try writer.writeByte('\n');

    switch (node) {
        .text => {},
        .element => |element| {
            for (element.children.items) |child| {
                try writeStyledPretty(allocator, writer, child, indent + 2);
            }
        },
    }
}
