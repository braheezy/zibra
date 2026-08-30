//! DOM node representation, resource ownership, and invalidation.
//!
//! Parsed names and text normally borrow the document source buffer. Decoded
//! attributes, image data, canvas backing, animation maps, and detached
//! resources are explicit Element owners. Child Nodes are stored by value, so
//! supported mutation must synchronously retire or rebind every raw pointer.

const std = @import("std");
const zigimg = @import("zigimg");
const ProtectedField = @import("../core/protected_field.zig").ProtectedField;
const css_length = @import("length.zig");
const canvas_module = @import("canvas.zig");
const animation_module = @import("animation.zig");
const html_serialization = @import("html_serialization.zig");
const style_application = @import("style_application.zig");
const pseudo = @import("pseudo.zig");

pub const CssColor = animation_module.CssColor;
pub const Canvas = canvas_module.Canvas;
pub const parseCssColor = animation_module.parseCssColor;
pub const EasingFunction = animation_module.EasingFunction;
pub const parseEasingFunction = animation_module.parseEasingFunction;
pub const Translation = animation_module.Translation;
pub const parseTranslate = animation_module.parseTranslate;
pub const CssLength = css_length.Length;
pub const CssLengthResolutionContext = css_length.ResolutionContext;
pub const parseCssLength = css_length.parse;
pub const resolveCssLength = css_length.resolve;
pub const parsePixelLength = css_length.parsePixel;
pub const pixelLengthToLayoutPixels = css_length.toLayoutPixels;
pub const NumericAnimation = animation_module.NumericAnimation;
pub const PixelAnimation = animation_module.PixelAnimation;
pub const ColorAnimation = animation_module.ColorAnimation;
pub const TransformAnimation = animation_module.TransformAnimation;
pub const Animation = animation_module.Animation;
pub const CssAnimationState = animation_module.CssAnimationState;
pub const cssAnimationPropertyBit = animation_module.cssAnimationPropertyBit;
pub const css_animation_properties = animation_module.css_animation_properties;
pub const StyleMap = std.StringHashMap(ProtectedField([]const u8));

fn parseCanvasDimension(raw: []const u8) ?i32 {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0 or text[0] == '-') return null;
    const value = std.fmt.parseInt(u32, text, 10) catch return null;
    if (value > std.math.maxInt(i32)) return null;
    return @intCast(value);
}

pub const CharacterReference = struct {
    codepoint: u21,
    len: usize,
};

/// Decode the semicolon-terminated character references supported by Zibra's
/// text and attribute pipelines. Unknown or malformed references remain
/// literal. Numeric references follow HTML's invalid-codepoint replacement
/// behavior and Windows-1252 compatibility mapping.
pub fn characterReferenceAt(text: []const u8, pos: usize) ?CharacterReference {
    if (pos >= text.len or text[pos] != '&') return null;
    const semicolon = std.mem.indexOfScalarPos(u8, text, pos + 1, ';') orelse return null;
    if (semicolon - pos > 64) return null;
    const name = text[pos + 1 .. semicolon];
    const codepoint: u21 = if (std.mem.eql(u8, name, "amp"))
        '&'
    else if (std.mem.eql(u8, name, "lt"))
        '<'
    else if (std.mem.eql(u8, name, "gt"))
        '>'
    else if (std.mem.eql(u8, name, "quot"))
        '"'
    else if (std.mem.eql(u8, name, "apos"))
        '\''
    else if (std.mem.eql(u8, name, "nbsp"))
        0x00a0
    else if (std.mem.eql(u8, name, "shy"))
        0x00ad
    else if (parseNumericCharacterReference(name)) |numeric|
        numeric
    else
        return null;
    return .{ .codepoint = codepoint, .len = semicolon - pos + 1 };
}

fn parseNumericCharacterReference(name: []const u8) ?u21 {
    if (name.len < 2 or name[0] != '#') return null;
    const hexadecimal = name.len >= 3 and (name[1] == 'x' or name[1] == 'X');
    const digits = if (hexadecimal) name[2..] else name[1..];
    if (digits.len == 0) return null;
    const radix: u32 = if (hexadecimal) 16 else 10;

    var value: u32 = 0;
    for (digits) |byte| {
        const digit: u32 = if (byte >= '0' and byte <= '9')
            byte - '0'
        else if (hexadecimal and byte >= 'a' and byte <= 'f')
            byte - 'a' + 10
        else if (hexadecimal and byte >= 'A' and byte <= 'F')
            byte - 'A' + 10
        else
            return null;
        if (value > (0x110000 - digit) / radix) {
            value = 0x110000;
        } else {
            value = value * radix + digit;
        }
    }

    if (value >= 0x80 and value <= 0x9f) {
        const windows_1252 = [_]u21{
            0x20ac, 0x0081, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021,
            0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008d, 0x017d, 0x008f,
            0x0090, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
            0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0x009d, 0x017e, 0x0178,
        };
        return windows_1252[@intCast(value - 0x80)];
    }
    if (value == 0 or value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) {
        return 0xfffd;
    }
    return @intCast(value);
}

fn decodeAttributeCharacterReferences(
    allocator: std.mem.Allocator,
    input: []const u8,
) !?[]u8 {
    if (std.mem.indexOfScalar(u8, input, '&') == null) return null;

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var changed = false;
    var cursor: usize = 0;
    while (cursor < input.len) {
        const amp = std.mem.indexOfScalarPos(u8, input, cursor, '&') orelse {
            try output.appendSlice(allocator, input[cursor..]);
            break;
        };
        try output.appendSlice(allocator, input[cursor..amp]);
        if (characterReferenceAt(input, amp)) |reference| {
            var encoded: [4]u8 = undefined;
            const encoded_len = try std.unicode.utf8Encode(reference.codepoint, &encoded);
            try output.appendSlice(allocator, encoded[0..encoded_len]);
            cursor = amp + reference.len;
            changed = true;
        } else {
            try output.append(allocator, '&');
            cursor = amp + 1;
        }
    }

    if (!changed) {
        output.deinit(allocator);
        return null;
    }
    const owned = try output.toOwnedSlice(allocator);
    return owned;
}

pub const Text = struct {
    text: []const u8,
    parent: ?*Node = null,
    style: ?StyleMap = null,
    /// Parser text borrows the document source; script-created text owns its
    /// duplicated bytes and releases them when its detached subtree dies.
    owned_text: bool = false,

    pub fn init(text: []const u8, parent: ?*Node) Text {
        return .{
            .text = text,
            .parent = parent,
            .style = null,
            .owned_text = false,
        };
    }

    pub fn deinit(self: *Text, allocator: std.mem.Allocator) void {
        if (self.style) |*styles| style_application.deinitStyleMap(StyleMap, styles, allocator);
        if (self.owned_text) allocator.free(self.text);
    }
};

pub const Element = struct {
    tag: []const u8,
    attributes: ?std.StringHashMap([]const u8) = null,
    style: ?StyleMap = null,
    parent: ?*Node = null,
    children: std.ArrayList(Node),
    /// Heap-stable generated boxes for CSS `::before` and `::after`. These
    /// private nodes participate in style and layout only; they are never
    /// stored in `children`, so DOM APIs, serialization, ID registration, and
    /// JavaScript `Node.children` continue to expose authored nodes alone.
    generated_before: ?*Node = null,
    generated_after: ?*Node = null,
    /// Non-null only on a private generated box. Its `parent` is always the
    /// authored host element, which lets selector matching and event-target
    /// normalization recover the public host without copying attributes.
    generated_kind: ?pseudo.Kind = null,
    layout_ptr: ?*anyopaque = null,
    layout_mark: ?*const fn (*anyopaque) void = null,
    /// Paint invalidation is intentionally separate from layout invalidation:
    /// controls, canvas pixels, colors, and other visual-only state can reuse
    /// geometry while refreshing the retained display-list cache.
    layout_paint_mark: ?*const fn (*anyopaque) void = null,
    // Block-mode layout owners can opt into matching already-laid-out direct
    // children across insertion-only child-array relocation. The compatibility
    // callback runs before storage can move; the rebind callback runs
    // immediately after parent pointers have been repaired. Both callbacks
    // borrow the opaque layout owner synchronously.
    layout_can_reuse_insert: ?*const fn (*anyopaque, usize) bool = null,
    layout_rebind_after_insert: ?*const fn (*anyopaque, *Node) bool = null,
    // Track strings we've allocated (like resolved relative font sizes) so we can free them
    owned_strings: ?std.ArrayList([]const u8) = null,
    is_focused: bool = false,
    // Snapshot of the user-agent focus-visible heuristic for this focus
    // generation. Native focus-ring paint and `:focus-visible` both consume
    // this bit so author styling cannot drift from the browser indicator.
    is_focus_visible: bool = false,
    // Dynamic selector state installed by the serialized Tab worker after a
    // retained-layout hit test. The pointed-to element and each of its DOM
    // ancestors carry this bit while the pointer is inside their subtree.
    is_hovered: bool = false,
    // Browser-session annotation used only while painting link descendants.
    // It owns no URL or session storage.
    is_visited: bool = false,
    // Persistent element-local scroll state. Layout refreshes the geometry,
    // while input changes only scroll_y and requests a repaint.
    scroll_container: bool = false,
    scroll_y: i32 = 0,
    scroll_client_height: i32 = 0,
    scroll_content_height: i32 = 0,
    // Classic script execution is terminal for this Element: true means the
    // script was claimed for evaluation, already evaluated, or was parsed as
    // an inert fragment (such as innerHTML). Reattachment never resets that
    // state, while an explicitly created Element starts eligible.
    script_started: bool = false,
    // Stable identity of the child browsing context currently attached to an
    // iframe element. Node values may move with their containing child array;
    // the Browser uses this scalar to rebind the Frame's raw frame_element
    // pointer after a supported structural JavaScript mutation. A detached
    // iframe may temporarily retain a stale value, which is validated against
    // the Tab registry before reattachment creates a fresh context.
    iframe_window_id: ?u32 = null,
    children_dirty: bool = true,
    // True only when every child mutation since the last successful layout
    // inserted a new child and the retained layout owner accepted matching the
    // existing children. Any other mutation must call markChildrenDirty,
    // which clears this bit.
    children_insertions_only: bool = false,
    // Summary bit for incremental style traversal. Individual computed
    // properties retain their own ProtectedField dirty bits; this records
    // whether any node strictly below this element may need style work.
    // Style-field owners are rebound whenever by-value DOM nodes move.
    has_dirty_style_descendants: bool = true,
    // Property interpolation state shared by transitions and the currently
    // selected named keyframe animation. CssAnimationState identifies which
    // entries belong to the latter so CSS animations override transitions.
    animations: ?std.StringHashMap(Animation) = null,
    css_animation: ?CssAnimationState = null,
    image_data: ?ImageData = null,
    // Installed only after computed style selects a supported url(...)
    // background. The source key records failed/blocked attempts too, so an
    // unchanged style does not refetch on every render.
    background_image: ?BackgroundImageData = null,
    // Heap-stable because z2d.Context borrows its embedded Surface. Element
    // values may relocate when DOM child arrays grow, but this pointee does
    // not move until the element is destroyed.
    canvas: ?*Canvas = null,
    opacity_anim_value: [32]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, tag: []const u8, parent: ?*Node) !Element {
        var e = Element{
            .tag = tag,
            .parent = parent,
            .attributes = null,
            .style = null,
            .children = std.ArrayList(Node).empty,
            .generated_before = null,
            .generated_after = null,
            .generated_kind = null,
            .owned_strings = null,
            .is_focused = false,
            .is_focus_visible = false,
            .is_hovered = false,
            .is_visited = false,
            .script_started = false,
            .animations = null,
            .css_animation = null,
            .image_data = null,
            .background_image = null,
            .canvas = null,
        };
        errdefer e.deinit(allocator);

        var has_whitespace = false;
        for (tag) |byte| {
            if (std.ascii.isWhitespace(byte)) {
                has_whitespace = true;
                break;
            }
        }
        if (has_whitespace) {
            try e.parse(allocator, tag);
        } else {
            e.tag = try e.normalizedHtmlName(allocator, tag);
        }

        return e;
    }

    /// HTML element and attribute names are ASCII case-insensitive. Borrow an
    /// already-normalized source slice, or retain one lowercase allocation in
    /// the element's existing owned-string list when uppercase bytes occur.
    fn normalizedHtmlName(self: *Element, allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
        var needs_normalization = false;
        for (value) |byte| {
            if (std.ascii.isUpper(byte)) {
                needs_normalization = true;
                break;
            }
        }
        if (!needs_normalization) return value;

        const normalized = try std.ascii.allocLowerString(allocator, value);
        errdefer allocator.free(normalized);
        if (self.owned_strings == null) self.owned_strings = std.ArrayList([]const u8).empty;
        try self.owned_strings.?.append(allocator, normalized);
        return normalized;
    }

    /// Invalidate the complete layout-child list. This is the conservative
    /// state for removals, replacements, unverified insertions, and
    /// non-structural changes that can alter child classification.
    pub fn markChildrenDirty(self: *Element) void {
        self.children_dirty = true;
        self.children_insertions_only = false;
    }

    /// Record a layout-verified insertion without overriding an earlier, more
    /// conservative invalidation that has not yet been consumed by layout.
    pub fn markChildInserted(self: *Element) void {
        if (!self.children_dirty) {
            self.children_dirty = true;
            self.children_insertions_only = true;
        }
    }

    pub fn clearChildrenDirty(self: *Element) void {
        self.children_dirty = false;
        self.children_insertions_only = false;
    }

    /// Ask the current layout owner whether its block children can be matched
    /// across an insertion at `insert_index`.
    pub fn canReuseLayoutForInsert(self: *Element, insert_index: usize) bool {
        const owner = self.layout_ptr orelse return false;
        const callback = self.layout_can_reuse_insert orelse return false;
        return callback(owner, insert_index);
    }

    /// Repair retained layout-to-DOM pointers after by-value children move.
    /// The caller must invoke this before another host callback or JavaScript
    /// statement can observe the new child storage.
    pub fn rebindLayoutAfterInsert(self: *Element, node: *Node) bool {
        const owner = self.layout_ptr orelse return false;
        const callback = self.layout_rebind_after_insert orelse return false;
        return callback(owner, node);
    }

    pub fn clearLayoutOwner(self: *Element) void {
        self.layout_ptr = null;
        self.layout_mark = null;
        self.layout_paint_mark = null;
        self.layout_can_reuse_insert = null;
        self.layout_rebind_after_insert = null;
    }

    pub fn deinit(self: *Element, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);

        // Generated boxes are host-owned but intentionally absent from the
        // public child array. Their retained layout owners are released before
        // DOM teardown, just like normal child layout owners.
        self.deinitGeneratedPseudo(allocator, .before);
        self.deinitGeneratedPseudo(allocator, .after);

        if (self.attributes) |attributes| {
            var attrs = attributes;
            attrs.deinit();
        }

        if (self.style) |*styles| {
            style_application.deinitStyleMap(StyleMap, styles, allocator);
        }

        // Free any strings we allocated (like resolved relative font sizes)
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

        if (self.background_image) |*background_image| {
            background_image.deinit(allocator);
        }

        if (self.canvas) |canvas| {
            canvas.destroy();
            self.canvas = null;
        }

        // Free animations map
        if (self.animations) |animations| {
            var a = animations;
            a.deinit();
        }
    }

    /// Return a host-owned private generated box, if it has been needed by a
    /// matching stylesheet rule. The returned node is heap-stable even when
    /// the host element moves in a resizable DOM child array.
    pub fn generatedPseudo(self: *const Element, kind: pseudo.Kind) ?*Node {
        return switch (kind) {
            .before => self.generated_before,
            .after => self.generated_after,
        };
    }

    /// Allocate the private node used to represent a CSS generated box. It
    /// never becomes an authored DOM child and therefore must be destroyed by
    /// `Element.deinit`, not by DOM mutation operations.
    pub fn ensureGeneratedPseudo(
        self: *Element,
        allocator: std.mem.Allocator,
        host: *Node,
        kind: pseudo.Kind,
    ) !*Node {
        if (self.generatedPseudo(kind)) |node| return node;

        const node = try allocator.create(Node);
        errdefer allocator.destroy(node);
        node.* = .{ .element = try Element.init(allocator, "zibra-generated-pseudo", host) };
        node.element.generated_kind = kind;
        switch (kind) {
            .before => self.generated_before = node,
            .after => self.generated_after = node,
        }
        return node;
    }

    fn deinitGeneratedPseudo(self: *Element, allocator: std.mem.Allocator, kind: pseudo.Kind) void {
        const node = self.generatedPseudo(kind) orelse return;
        node.deinit(allocator);
        allocator.destroy(node);
        switch (kind) {
            .before => self.generated_before = null,
            .after => self.generated_after = null,
        }
    }

    /// A generated box participates in layout only when CSS `content`
    /// computes to an actual generated value. This bounded implementation
    /// currently supports the empty quoted string used for generated shapes;
    /// `normal`, `none`, and text-bearing strings suppress the box until text
    /// generated content has an owned text-node representation.
    pub fn generatedPseudoActive(self: *const Element) bool {
        const style_map = self.style orelse return false;
        const display = if (style_map.get("display")) |field| field.get().* else "inline";
        const content = if (style_map.get("content")) |field| field.get().* else "normal";
        return generatedPseudoContentActive(self, display, content);
    }

    /// Return the previously published generated-content state without reading
    /// dirty fields. Style recomputation uses this to detect a content flip
    /// before it replaces the private box's computed values.
    pub fn generatedPseudoLastActive(self: *const Element) bool {
        const style_map = self.style orelse return false;
        const display = if (style_map.get("display")) |field| field.lastValue().* else "inline";
        const content = if (style_map.get("content")) |field| field.lastValue().* else "normal";
        return generatedPseudoContentActive(self, display, content);
    }

    fn generatedPseudoContentActive(
        self: *const Element,
        display: []const u8,
        content: []const u8,
    ) bool {
        if (self.generated_kind == null) return false;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, display, " \t\r\n"), "none")) {
            return false;
        }
        const value = std.mem.trim(u8, content, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(value, "normal") or std.ascii.eqlIgnoreCase(value, "none")) {
            return false;
        }
        return std.mem.eql(u8, value, "''") or std.mem.eql(u8, value, "\"\"");
    }

    /// Return the normalized input type. Unknown types are intentionally left
    /// intact so callers can apply HTML's text-state fallback where needed.
    pub fn inputType(self: *const Element) []const u8 {
        if (!std.ascii.eqlIgnoreCase(self.tag, "input")) return "";
        const attributes = self.attributes orelse return "text";
        const input_type = attributes.get("type") orelse return "text";
        return std.mem.trim(u8, input_type, " \t\r\n");
    }

    pub fn isInputType(self: *const Element, expected: []const u8) bool {
        if (!std.ascii.eqlIgnoreCase(self.tag, "input")) return false;
        return std.ascii.eqlIgnoreCase(self.inputType(), expected);
    }

    /// Return whether an HTML attribute contains `expected` as an
    /// ASCII-whitespace-separated, ASCII-case-insensitive token. Callers use
    /// this for token-list attributes such as `rel`; the returned slices
    /// continue to borrow the element's attribute storage.
    pub fn attributeHasToken(
        self: *const Element,
        attribute_name: []const u8,
        expected: []const u8,
    ) bool {
        const attributes = self.attributes orelse return false;
        const value = attributes.get(attribute_name) orelse return false;

        var start: usize = 0;
        while (start < value.len) {
            while (start < value.len and std.ascii.isWhitespace(value[start])) : (start += 1) {}
            if (start == value.len) break;

            var end = start;
            while (end < value.len and !std.ascii.isWhitespace(value[end])) : (end += 1) {}
            if (std.ascii.eqlIgnoreCase(value[start..end], expected)) return true;
            start = end;
        }
        return false;
    }

    /// Publish the latest layout overflow for an `overflow: scroll` box and
    /// preserve its offset across paint/layout passes, clamped to the new
    /// range. Disabling scrolling resets all element-local scroll state.
    pub fn setScrollGeometry(
        self: *Element,
        enabled: bool,
        client_height: i32,
        content_height: i32,
    ) void {
        if (!enabled) {
            self.scroll_container = false;
            self.scroll_y = 0;
            self.scroll_client_height = 0;
            self.scroll_content_height = 0;
            return;
        }

        self.scroll_container = true;
        self.scroll_client_height = @max(0, client_height);
        self.scroll_content_height = @max(0, content_height);
        self.scroll_y = @min(@max(0, self.scroll_y), self.maxScrollY());
    }

    pub fn maxScrollY(self: *const Element) i32 {
        if (!self.scroll_container or self.scroll_content_height <= self.scroll_client_height) return 0;
        return self.scroll_content_height - self.scroll_client_height;
    }

    /// Move within this element's current scroll range. Returns false at a
    /// boundary so keyboard input can bubble to an enclosing scroll box.
    pub fn scrollBy(self: *Element, delta: i32) bool {
        if (!self.scroll_container or delta == 0) return false;
        const maximum = self.maxScrollY();
        const candidate = @as(i64, self.scroll_y) + @as(i64, delta);
        const next: i32 = @intCast(std.math.clamp(candidate, 0, @as(i64, maximum)));
        if (next == self.scroll_y) return false;
        self.scroll_y = next;
        return true;
    }

    /// Checkbox state lives in the DOM attribute map so layout, activation,
    /// and form submission all observe the same source of truth.
    pub fn isCheckbox(self: *const Element) bool {
        return self.isInputType("checkbox");
    }

    pub fn isHiddenInput(self: *const Element) bool {
        return self.isInputType("hidden");
    }

    pub fn isPasswordInput(self: *const Element) bool {
        return self.isInputType("password");
    }

    pub fn isChecked(self: *const Element) bool {
        if (!self.isCheckbox()) return false;
        const attributes = self.attributes orelse return false;
        return attributes.get("checked") != null;
    }

    /// HTML canvas bitmap dimensions come from non-negative integer content
    /// attributes, independently of CSS/page zoom. Invalid values use the
    /// platform defaults.
    pub fn canvasDimensions(self: *const Element) struct { width: i32, height: i32 } {
        var width = canvas_module.default_width;
        var height = canvas_module.default_height;
        if (self.attributes) |attributes| {
            if (attributes.get("width")) |raw| {
                width = parseCanvasDimension(raw) orelse canvas_module.default_width;
            }
            if (attributes.get("height")) |raw| {
                height = parseCanvasDimension(raw) orelse canvas_module.default_height;
            }
        }
        return .{ .width = width, .height = height };
    }

    /// Toggle a checkbox's boolean `checked` attribute and return its new
    /// state. Attribute keys and values borrow either document storage or the
    /// static strings inserted here; the map never takes string ownership.
    pub fn toggleChecked(self: *Element) !bool {
        if (!self.isCheckbox()) return false;
        if (self.attributes) |*attributes| {
            if (attributes.remove("checked")) return false;
            try attributes.put("checked", "");
            return true;
        }
        unreachable;
    }

    fn parse(self: *Element, al: std.mem.Allocator, raw: []const u8) !void {
        var idx: usize = 0;
        // Skip any leading whitespace.
        while (idx < raw.len and std.ascii.isWhitespace(raw[idx])) : (idx += 1) {}

        // Parse the tag name: read until whitespace.
        const start_name = idx;
        while (idx < raw.len and !std.ascii.isWhitespace(raw[idx])) : (idx += 1) {}
        self.tag = try self.normalizedHtmlName(al, raw[start_name..idx]);

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
            const attr_name_slice = try self.normalizedHtmlName(al, raw[attr_start..idx]);

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

            var attribute_value = value_slice;
            if (try decodeAttributeCharacterReferences(al, value_slice)) |decoded| {
                if (self.owned_strings == null) {
                    self.owned_strings = std.ArrayList([]const u8).empty;
                }
                self.owned_strings.?.append(al, decoded) catch |err| {
                    al.free(decoded);
                    return err;
                };
                attribute_value = decoded;
            }

            try self.attributes.?.put(attr_name_slice, attribute_value);
        }
    }
};

pub const ImageData = struct {
    encoded_bytes: ?[]const u8,
    image: zigimg.Image,
    // A terminal decode/fetch failure owns synthetic fallback pixels just like
    // a decoded image. Keep the distinction so layout can apply HTML's alt
    // policy without retrying the failed request.
    is_broken: bool = false,

    pub fn deinit(self: *ImageData, allocator: std.mem.Allocator) void {
        self.image.deinit(allocator);
        if (self.encoded_bytes) |bytes| {
            allocator.free(bytes);
        }
    }
};

pub const BackgroundImageData = struct {
    source: []u8,
    data: ?ImageData = null,

    pub fn deinit(self: *BackgroundImageData, allocator: std.mem.Allocator) void {
        if (self.data) |*data| data.deinit(allocator);
        allocator.free(self.source);
    }
};

/// Serialize an element's current child tree as HTML source. The caller owns
/// the returned allocation.
pub fn serializeInnerHtml(allocator: std.mem.Allocator, node: *const Node) ![]u8 {
    return html_serialization.serializeInnerHtml(allocator, node);
}

/// Serialize an element and its current descendants as HTML source. The
/// caller owns the returned allocation.
pub fn serializeOuterHtml(allocator: std.mem.Allocator, node: *const Node) ![]u8 {
    return html_serialization.serializeOuterHtml(allocator, node);
}
pub const Node = union(enum) {
    text: Text,
    element: Element,

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |*t| {
                t.deinit(allocator);
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
                            try html_serialization.appendEscapedAttributeValue(al, &result, entry.value_ptr.*);
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

/// Return the private generated-box kind carried by `node`, if any.
pub fn generatedPseudoKind(node: *const Node) ?pseudo.Kind {
    return switch (node.*) {
        .element => |element| element.generated_kind,
        .text => null,
    };
}

/// Follow private generated-box nodes back to the authored element that owns
/// them. DOM events, focus, hover, accessibility, and JavaScript handles must
/// never expose implementation-only generated nodes.
pub fn publicEventTarget(node: *Node) *Node {
    var current = node;
    while (true) {
        switch (current.*) {
            .element => |element| {
                if (element.generated_kind == null) return current;
                current = element.parent orelse return current;
            },
            .text => |text| {
                const parent = text.parent orelse return current;
                if (generatedPseudoKind(parent) == null) return current;
                current = parent;
            },
        }
    }
}

/// Mark the nearest retained layout owner for `node` and its ancestors.
/// Generated-box activation changes the host's private layout child sequence,
/// so it needs geometry invalidation in addition to paint invalidation.
pub fn markLayoutForNode(node: *Node) void {
    var current: ?*Node = node;
    while (current) |candidate| {
        switch (candidate.*) {
            .text => |text| current = text.parent,
            .element => |*element| {
                if (element.layout_ptr) |owner| {
                    if (element.layout_mark) |mark_fn| {
                        mark_fn(owner);
                        return;
                    }
                }
                current = element.parent;
            },
        }
    }
}

// Public function to fix parent pointers after modifying the tree
pub fn fixParentPointers(node: *Node, parent: ?*Node) void {
    switch (node.*) {
        .element => |*e| {
            e.parent = parent;
            bindStyleOwner(node);
            for (e.children.items) |*child| {
                fixParentPointers(child, node);
            }
            if (e.generated_before) |generated| fixParentPointers(generated, node);
            if (e.generated_after) |generated| fixParentPointers(generated, node);
        },
        .text => |*t| {
            t.parent = parent;
            bindStyleOwner(node);
        },
    }
}

fn nodeParent(node: *const Node) ?*Node {
    return switch (node.*) {
        .text => |text| text.parent,
        .element => |element| element.parent,
    };
}

/// Publish a newly dirty computed-style field into the owning DOM tree's
/// summary bits. The field itself remains the source of truth for whether the
/// node needs recomputation; ancestors only summarize strict descendants.
fn markStyleOwnerOpaque(ptr: *anyopaque) void {
    const node: *Node = @ptrCast(@alignCast(ptr));
    var ancestor = nodeParent(node);
    while (ancestor) |parent| {
        switch (parent.*) {
            .text => break,
            .element => |*element| {
                element.has_dirty_style_descendants = true;
                ancestor = element.parent;
            },
        }
    }
}

/// DOM nodes live by value in resizable child arrays. Rebind every computed
/// field after a supported move so a later ProtectedField dependency
/// invalidation never calls through a stale Node address.
pub fn bindStyleOwner(node: *Node) void {
    const style_map = switch (node.*) {
        .text => |*text| if (text.style) |*map| map else return,
        .element => |*element| if (element.style) |*map| map else return,
    };
    var it = style_map.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.setOwner(node, markStyleOwnerOpaque);
    }
}

pub fn markStyleMapWithoutOwner(style_map: *StyleMap) void {
    var it = style_map.iterator();
    while (it.next()) |entry| entry.value_ptr.markNoOwner();
}

fn markAncestorStyleSummaries(node: ?*Node) void {
    var ancestor = node;
    while (ancestor) |parent| {
        switch (parent.*) {
            .text => break,
            .element => |*element| {
                element.has_dirty_style_descendants = true;
                ancestor = element.parent;
            },
        }
    }
}

pub fn styleTreeNeedsUpdate(node: *const Node) bool {
    return switch (node.*) {
        .text => |*text| text.style == null or
            style_application.styleNeedsUpdate(StyleMap, @constCast(&text.style.?)),
        .element => |*element| element.style == null or
            style_application.styleNeedsUpdate(StyleMap, @constCast(&element.style.?)) or
            element.has_dirty_style_descendants or
            generatedPseudoStyleNeedsUpdate(element.generated_before) or
            generatedPseudoStyleNeedsUpdate(element.generated_after),
    };
}

fn generatedPseudoStyleNeedsUpdate(node: ?*Node) bool {
    const pseudo_node = node orelse return false;
    return styleTreeNeedsUpdate(pseudo_node);
}

/// Mark the nearest retained layout object whose paint commands represent
/// this DOM node. Inline descendants often share an anonymous or containing
/// BlockLayout, so walking upward is required when the node itself has no
/// layout owner. The callback is a synchronous borrow installed by layout.
pub fn markPaintForNode(node: *Node) void {
    var current: ?*Node = node;
    while (current) |candidate| {
        switch (candidate.*) {
            .text => |text| current = text.parent,
            .element => |*element| {
                if (element.layout_ptr) |owner| {
                    if (element.layout_paint_mark) |mark_fn| {
                        mark_fn(owner);
                        return;
                    }
                }
                current = element.parent;
            },
        }
    }
}

pub fn markPaintForElement(element: *Element) void {
    if (element.layout_ptr) |owner| {
        if (element.layout_paint_mark) |mark_fn| {
            mark_fn(owner);
            return;
        }
    }
    if (element.parent) |parent| markPaintForNode(parent);
}

pub fn dirtyStyleForElement(e: *Element) void {
    if (e.style) |*style_map| markStyleMapWithoutOwner(style_map);
    if (e.generated_before) |generated| dirtyStyleSubtree(generated);
    if (e.generated_after) |generated| dirtyStyleSubtree(generated);
    markAncestorStyleSummaries(e.parent);

    // Relational selectors make an element's attributes/style relevant to
    // every ancestor. Conservatively dirty that chain; this remains O(depth)
    // and avoids rescanning or restyling unrelated subtrees.
    var ancestor = e.parent;
    while (ancestor) |node| {
        switch (node.*) {
            .text => break,
            .element => |*element| {
                if (element.style) |*style_map| markStyleMapWithoutOwner(style_map);
                ancestor = element.parent;
            },
        }
    }
}

/// Mark an entire retained subtree for recomputation after it is detached.
/// Unlike dirtyStyleForElement, this deliberately does not walk above the
/// subtree root, whose parent link has already been cleared.
pub fn dirtyStyleSubtree(node: *Node) void {
    switch (node.*) {
        .text => |*text| {
            if (text.style) |*style_map| markStyleMapWithoutOwner(style_map);
        },
        .element => |*element| {
            if (element.style) |*style_map| markStyleMapWithoutOwner(style_map);
            for (element.children.items) |*child| dirtyStyleSubtree(child);
            if (element.generated_before) |generated| dirtyStyleSubtree(generated);
            if (element.generated_after) |generated| dirtyStyleSubtree(generated);
            element.has_dirty_style_descendants = element.children.items.len != 0 or
                element.generated_before != null or element.generated_after != null;
        },
    }
}

/// Remove raw style/layout subscriber pointers before a structural DOM
/// mutation can destroy or relocate either endpoint. Supported mutation paths
/// force a complete style/layout pass afterward, which rebuilds live edges.
pub fn clearStyleInvalidations(node: *Node) void {
    switch (node.*) {
        .text => |*text| {
            if (text.style) |*style_map| {
                clearStyleMapInvalidations(style_map);
                markStyleMapWithoutOwner(style_map);
            }
        },
        .element => |*element| {
            if (element.style) |*style_map| {
                clearStyleMapInvalidations(style_map);
                markStyleMapWithoutOwner(style_map);
            }
            for (element.children.items) |*child| clearStyleInvalidations(child);
            if (element.generated_before) |generated| clearStyleInvalidations(generated);
            if (element.generated_after) |generated| clearStyleInvalidations(generated);
            // Clearing raw dependency edges requires a complete subtree style
            // pass to rebuild them, not merely a walk through clean nodes.
            element.has_dirty_style_descendants = element.children.items.len != 0 or
                element.generated_before != null or element.generated_after != null;
        },
    }
}

fn clearStyleMapInvalidations(style_map: *StyleMap) void {
    var it = style_map.iterator();
    while (it.next()) |entry| entry.value_ptr.clearInvalidations();
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

/// Return an owned copy of the direct text content of a `style` element.
///
/// HTML text nodes borrow the document source, while parsed CSS rules must stay
/// paired with a stylesheet buffer that can be rebuilt and retired as a unit.
/// Callers therefore own the returned allocation and should retain it for at
/// least as long as any rules parsed from it.
pub fn collectInlineStyleText(allocator: std.mem.Allocator, node: *const Node) !?[]u8 {
    const element = switch (node.*) {
        .element => |*value| value,
        .text => return null,
    };
    if (!std.mem.eql(u8, element.tag, "style")) return null;

    var text = std.ArrayList(u8).empty;
    errdefer text.deinit(allocator);
    for (element.children.items) |child| {
        switch (child) {
            .text => |value| try text.appendSlice(allocator, value.text),
            .element => {},
        }
    }
    if (text.items.len == 0) {
        text.deinit(allocator);
        return null;
    }
    return try text.toOwnedSlice(allocator);
}

fn findFirstTitleElement(node: *const Node) ?*const Element {
    return switch (node.*) {
        .text => null,
        .element => |*element| blk: {
            if (std.ascii.eqlIgnoreCase(element.tag, "title")) break :blk element;
            for (element.children.items) |*child| {
                if (findFirstTitleElement(child)) |title| break :blk title;
            }
            break :blk null;
        },
    };
}

fn appendNodeText(
    allocator: std.mem.Allocator,
    node: *const Node,
    output: *std.ArrayList(u8),
) !void {
    switch (node.*) {
        .text => |text| try output.appendSlice(allocator, text.text),
        .element => |element| {
            for (element.children.items) |*child| {
                try appendNodeText(allocator, child, output);
            }
        },
    }
}

/// Return an owned, sentinel-terminated copy of the first `title` element's
/// text content. The DOM continues to borrow the document source; this copy is
/// safe to retain independently for native window APIs.
pub fn collectDocumentTitle(
    allocator: std.mem.Allocator,
    root: *const Node,
) !?[:0]u8 {
    const title = findFirstTitleElement(root) orelse return null;
    var text = std.ArrayList(u8).empty;
    errdefer text.deinit(allocator);
    for (title.children.items) |*child| {
        try appendNodeText(allocator, child, &text);
    }
    return try text.toOwnedSliceSentinel(allocator, 0);
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
    // Keep formatting-only text in the live DOM while suppressing it in the
    // compact style inspection output. This avoids noisy blank entries caused
    // by indentation in the source fixture.
    switch (node) {
        .text => |text| {
            for (text.text) |byte| {
                if (!std.ascii.isWhitespace(byte)) break;
            } else return;
        },
        .element => {},
    }
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
        for (style_application.computed_properties, 0..) |prop, index| {
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

test "HTML token-list attributes are whitespace-separated and case-insensitive" {
    var link = try Element.init(
        std.testing.allocator,
        "link rel=\"appendix  StyleSheet\talternate\"",
        null,
    );
    defer link.deinit(std.testing.allocator);

    try std.testing.expect(link.attributeHasToken("rel", "stylesheet"));
    try std.testing.expect(link.attributeHasToken("rel", "APPENDIX"));
    try std.testing.expect(!link.attributeHasToken("rel", "style"));
    try std.testing.expect(!link.attributeHasToken("missing", "stylesheet"));
}
