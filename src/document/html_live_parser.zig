//! Resumable HTML tree construction for parser-blocking scripts.
//!
//! `LiveParser` is deliberately separate from the compatibility one-shot
//! `HTMLParser`: it publishes its root directly in final caller-owned storage,
//! stores only opaque `node_pins.Pin` values for open elements, and consumes
//! the chunk-aware tokenizer one token at a time. This lets a loader expose a
//! partial DOM to a classic script, copy `document.write` input into the
//! document source store, then resume before the unread network source.
//!
//! The tree-recovery policy is intentionally bounded to Zibra's established
//! html/head/body, void-element, paragraph/list/button cases. It is a stable
//! execution seam, not a claim of full HTML5 tree-builder conformance.

const std = @import("std");
const dom = @import("dom.zig");
const html_serialization = @import("html_serialization.zig");
const html_source = @import("html_source.zig");
const html_tokenizer = @import("html_tokenizer.zig");
const node_pins = @import("node_pins.zig");
const RelocationObserver = @import("../core/relocatable_identity.zig").RelocationObserver;

const Node = dom.Node;
const Element = dom.Element;
const Text = dom.Text;

/// One externally visible parser transition.
pub const Advance = union(enum) {
    /// More network/source chunks are necessary before a complete lexical
    /// token can be consumed.
    need_input,
    /// A complete parser-inserted classic script is attached to the partial
    /// DOM. Resolve this pin only through the same live parser, evaluate the
    /// script synchronously, submit any writes, then call `resumeAfterScript`.
    script: node_pins.Pin,
    /// The tokenizer and implicit document structure reached EOF.
    eof,
};

const DirectPin = struct {
    old_ptr: *Node,
    index: usize,
    relocation: ?node_pins.Relocation = null,
    external_relocation: ?RelocationObserver.Token = null,
};

/// One live document tree builder.
///
/// The caller owns `root` and must keep it in its final Frame field for this
/// parser's entire lifetime. `source` owns all source-backed DOM strings and
/// must outlive the root. `deinit` retires parser pins and lexical scratch but
/// deliberately does not destroy either caller-owned object.
pub const LiveParser = struct {
    allocator: std.mem.Allocator,
    source: *html_source.Store,
    root: *Node,
    tokens: html_tokenizer.Stream,
    pins: node_pins.Store,
    open: std.ArrayList(node_pins.Pin) = .empty,
    pending_write_chunks: std.ArrayList(usize) = .empty,
    // JavaScript wrappers name Nodes through a separate identity registry.
    // Once the parser has exposed a script, normal parsing can still grow a
    // child array and relocate values that script retained. The browser
    // installs this Realm-owned observer for the remainder of the synchronous
    // parse so parser writes repair both identity domains together.
    external_relocation_observer: ?RelocationObserver = null,
    head_found: bool = false,
    body_found: bool = false,
    saw_explicit_html: bool = false,
    paused_at_script: bool = false,
    reached_eof: bool = false,

    /// Initialize a parser over the first stable source chunk. The root is
    /// initialized immediately as an implicit html element in its final
    /// address, so scripts can safely observe `document.documentElement` at
    /// the first script boundary. An early explicit `<html ...>` replaces
    /// that otherwise-empty element in place to preserve its attributes.
    pub fn init(
        allocator: std.mem.Allocator,
        source: *html_source.Store,
        root: *Node,
    ) !LiveParser {
        const initial = source.initial() orelse return error.MissingInitialSource;
        root.* = .{ .element = try Element.init(allocator, "html", null) };
        errdefer root.deinit(allocator);
        return initWithInitializedRoot(allocator, source, initial, root);
    }

    /// Initialize directly into an optional final-owner slot such as
    /// `Frame.current_node`. This is the safe publication path for Browser
    /// navigation: the root becomes present before the install hook can create
    /// a Realm, without a temporary heap root or an invalid optional payload.
    pub fn initIntoSlot(
        allocator: std.mem.Allocator,
        source: *html_source.Store,
        root_slot: *?Node,
    ) !LiveParser {
        const initial = source.initial() orelse return error.MissingInitialSource;
        root_slot.* = .{ .element = try Element.init(allocator, "html", null) };
        errdefer {
            root_slot.*.?.deinit(allocator);
            root_slot.* = null;
        }
        return initWithInitializedRoot(allocator, source, initial, &root_slot.*.?);
    }

    fn initWithInitializedRoot(
        allocator: std.mem.Allocator,
        source: *html_source.Store,
        initial: []const u8,
        root: *Node,
    ) !LiveParser {
        var tokens = html_tokenizer.Stream.init(allocator);
        errdefer tokens.deinit();
        try tokens.appendChunk(initial);

        var pins = node_pins.Store.init(allocator);
        errdefer pins.deinit();
        const root_pin = try pins.pin(root);

        var open = std.ArrayList(node_pins.Pin).empty;
        errdefer open.deinit(allocator);
        try open.append(allocator, root_pin);

        return .{
            .allocator = allocator,
            .source = source,
            .root = root,
            .tokens = tokens,
            .pins = pins,
            .open = open,
        };
    }

    /// Retire parser-only state before the caller retires the DOM/source.
    pub fn deinit(self: *LiveParser) void {
        self.pins.retireAll();
        self.pins.deinit();
        self.tokens.deinit();
        self.open.deinit(self.allocator);
        self.pending_write_chunks.deinit(self.allocator);
    }

    /// Supply another already-owned source chunk before `finishInput`.
    pub fn appendSourceChunk(self: *LiveParser, source_index: usize) !void {
        if (self.reached_eof) return error.ParserFinished;
        try self.tokens.appendChunk(self.source.get(source_index));
    }

    /// Mark ordinary network/source input complete. Parser-written chunks may
    /// still be inserted before EOF while paused at a script boundary.
    pub fn finishInput(self: *LiveParser) void {
        self.tokens.finish();
    }

    /// Resolve a parser-local script pin for the current synchronous parser
    /// callback. A null result means a script mutation retired its open-node
    /// identity, so the caller must abandon or reload the parser transaction.
    pub fn resolve(self: *const LiveParser, pin: node_pins.Pin) ?*Node {
        return self.pins.resolve(pin);
    }

    /// Return the parser's synchronous relocation participant for one direct
    /// parser-blocking JavaScript evaluation. The caller must clear it from
    /// JavaScript before this parser yields or deinitializes.
    pub fn relocationObserver(self: *LiveParser) RelocationObserver {
        return self.pins.relocationObserver();
    }

    /// Install a Realm-owned observer that follows JavaScript node wrappers
    /// while subsequent parser tokens relocate child storage. The observer
    /// borrows only a heap-stable Realm identity map; callers must clear it
    /// before retiring that Realm or this parser.
    pub fn setExternalRelocationObserver(
        self: *LiveParser,
        observer: ?RelocationObserver,
    ) void {
        self.external_relocation_observer = observer;
    }

    /// Copy `document.write` source into the document-owned store. Calls are
    /// accepted only while the parser is paused at its script boundary, and
    /// their order is preserved when `resumeAfterScript` injects them ahead of
    /// unread original input.
    pub fn write(self: *LiveParser, source: []const u8) !void {
        if (!self.paused_at_script) return error.ParserNotPausedAtScript;
        try self.pending_write_chunks.ensureUnusedCapacity(self.allocator, 1);
        const chunk_index = try self.source.appendCopy(source);
        self.pending_write_chunks.appendAssumeCapacity(chunk_index);
    }

    /// Resume after the caller has synchronously evaluated the last script.
    /// All writes made by that script become the immediate next tokenizer
    /// input, in call order, before any original source that follows it.
    pub fn resumeAfterScript(self: *LiveParser) !void {
        if (!self.paused_at_script) return error.ParserNotPausedAtScript;

        var write_chunks = std.ArrayList([]const u8).empty;
        defer write_chunks.deinit(self.allocator);
        try write_chunks.ensureTotalCapacity(self.allocator, self.pending_write_chunks.items.len);
        for (self.pending_write_chunks.items) |index| {
            write_chunks.appendAssumeCapacity(self.source.get(index));
        }
        try self.tokens.insertBeforeUnread(write_chunks.items);
        self.pending_write_chunks.clearRetainingCapacity();
        self.paused_at_script = false;
    }

    /// Consume source until a parser-blocking script, EOF, or input boundary.
    /// Calling this while a script is paused is an error because that would
    /// skip the caller's chance to install a `document.write` sink.
    pub fn advance(self: *LiveParser) !Advance {
        if (self.reached_eof) return .eof;
        if (self.paused_at_script) return error.ParserScriptStillPending;

        while (true) {
            var token = (try self.tokens.next()) orelse return .need_input;
            defer token.deinit(self.allocator);

            switch (token.kind) {
                .text => {
                    const text = try self.adoptTokenBytes(&token);
                    try self.addText(text);
                },
                .start_tag, .end_tag => {
                    const tag = try self.adoptTokenBytes(&token);
                    if (try self.addTag(tag)) |script_pin| {
                        self.paused_at_script = true;
                        return .{ .script = script_pin };
                    }
                },
                .comment => {},
                .eof => {
                    try self.finishTree();
                    self.reached_eof = true;
                    return .eof;
                },
            }
        }
    }

    /// Move a tokenizer-owned token allocation into the append-only source
    /// store. DOM text and Element attribute slices then remain valid after
    /// tokenizer scratch advances or the parser pauses for script execution.
    fn adoptTokenBytes(self: *LiveParser, token: *html_tokenizer.Token) ![]const u8 {
        if (token.bytes.len == 0) return "";
        const index = try self.source.adopt(token.bytes);
        token.bytes = token.bytes[0..0];
        return self.source.get(index);
    }

    fn current(self: *const LiveParser) !*Node {
        const pin = self.open.getLastOrNull() orelse return error.NoOpenElement;
        return self.pins.resolve(pin) orelse error.OpenElementRetired;
    }

    fn nodeParent(node: *Node) ?*Node {
        return switch (node.*) {
            .text => |text| text.parent,
            .element => |element| element.parent,
        };
    }

    fn tagInfo(tag: []const u8) struct {
        name: []const u8,
        is_closing: bool,
        self_closing: bool,
    } {
        const trimmed = std.mem.trim(u8, tag, " \t\r\n");
        if (trimmed.len == 0) return .{ .name = "", .is_closing = false, .self_closing = false };
        const is_closing = trimmed[0] == '/';
        const text = if (is_closing) trimmed[1..] else trimmed;
        var end: usize = 0;
        while (end < text.len and !std.ascii.isWhitespace(text[end]) and text[end] != '/') : (end += 1) {}
        var last = text.len;
        while (last > 0 and std.ascii.isWhitespace(text[last - 1])) : (last -= 1) {}
        return .{
            .name = text[0..end],
            .is_closing = is_closing,
            .self_closing = !is_closing and last > 0 and text[last - 1] == '/',
        };
    }

    fn tagEquals(tag: []const u8, expected: []const u8) bool {
        return std.ascii.eqlIgnoreCase(tag, expected);
    }

    fn isHeadTag(tag: []const u8) bool {
        const tags = [_][]const u8{ "base", "basefont", "bgsound", "link", "meta", "title", "style", "script" };
        return for (tags) |candidate| {
            if (tagEquals(tag, candidate)) break true;
        } else false;
    }

    fn isBlockStart(tag: []const u8) bool {
        const tags = [_][]const u8{
            "address",    "article", "aside",  "blockquote", "details", "div",   "dl",   "fieldset",
            "figcaption", "figure",  "footer", "form",       "h1",      "h2",    "h3",   "h4",
            "h5",         "h6",      "header", "hgroup",     "hr",      "main",  "menu", "nav",
            "ol",         "p",       "pre",    "search",     "section", "table", "ul",
        };
        return for (tags) |candidate| {
            if (tagEquals(tag, candidate)) break true;
        } else false;
    }

    fn findOpen(self: *const LiveParser, tag: []const u8) !?usize {
        var index = self.open.items.len;
        while (index > 0) {
            index -= 1;
            const node = self.pins.resolve(self.open.items[index]) orelse return error.OpenElementRetired;
            if (node.* == .element and tagEquals(node.element.tag, tag)) return index;
        }
        return null;
    }

    fn popThrough(self: *LiveParser, index: usize) node_pins.Pin {
        const closed = self.open.items[index];
        self.open.items.len = index;
        return closed;
    }

    fn closeOpen(self: *LiveParser, tag: []const u8) !?node_pins.Pin {
        const index = (try self.findOpen(tag)) orelse return null;
        // The root stays installed even for a malformed closing html tag.
        if (index == 0) return null;
        return self.popThrough(index);
    }

    fn snapshotDirectPins(self: *LiveParser, parent: *Node) !std.ArrayList(DirectPin) {
        var bindings = std.ArrayList(DirectPin).empty;
        errdefer bindings.deinit(self.allocator);
        const children = switch (parent.*) {
            .text => return bindings,
            .element => |element| element.children.items,
        };
        for (children, 0..) |*child, index| {
            if (self.pins.pinFor(child) == null and self.external_relocation_observer == null) continue;
            try bindings.append(self.allocator, .{ .old_ptr = child, .index = index });
        }
        return bindings;
    }

    /// Move an already-owned Node value into an Element child array and repair
    /// every parser pin naming a direct child that array may relocate. `node`
    /// is a synchronous temporary; if `incoming_pin` is present, it is
    /// rebound from that temporary address to the installed child address.
    fn appendOwnedNode(
        self: *LiveParser,
        parent: *Node,
        node: *Node,
        incoming_pin: ?node_pins.Pin,
    ) !*Node {
        var bindings = try self.snapshotDirectPins(parent);
        defer bindings.deinit(self.allocator);
        const parent_parent = nodeParent(parent);
        const element = switch (parent.*) {
            .element => |*value| value,
            .text => return error.TextCannotHaveChildren,
        };

        // Capacity growth may invalidate every old child pointer. The map
        // lookup below never dereferences those old addresses, and no foreign
        // callback runs between growth and synchronous rebind.
        try element.children.ensureUnusedCapacity(self.allocator, 1);
        for (bindings.items) |*binding| {
            binding.relocation = self.pins.unpublishForRelocation(binding.old_ptr);
            binding.external_relocation = if (self.external_relocation_observer) |observer|
                observer.unpublishItem(@ptrCast(binding.old_ptr))
            else
                null;
        }
        const incoming_relocation = if (incoming_pin) |pin| blk: {
            const relocation = self.pins.unpublishForRelocation(node) orelse return error.MissingIncomingPin;
            std.debug.assert(relocation.pin == pin);
            break :blk relocation;
        } else null;

        element.children.appendAssumeCapacity(node.*);
        for (bindings.items) |binding| {
            if (binding.relocation) |relocation| {
                self.pins.rebindAfterRelocation(&element.children.items[binding.index], relocation);
            }
            if (binding.external_relocation) |token| {
                const observer = self.external_relocation_observer orelse unreachable;
                observer.rebindItem(@ptrCast(&element.children.items[binding.index]), token);
            }
        }
        const installed = &element.children.items[element.children.items.len - 1];
        if (incoming_relocation) |relocation| {
            self.pins.rebindAfterRelocation(installed, relocation);
        }
        dom.fixParentPointers(parent, parent_parent);
        return installed;
    }

    fn appendElement(
        self: *LiveParser,
        parent: *Node,
        tag: []const u8,
        keep_open: bool,
    ) !?node_pins.Pin {
        var node = Node{ .element = try Element.init(self.allocator, tag, null) };
        var node_owned = true;
        errdefer if (node_owned) node.deinit(self.allocator);

        if (!keep_open) {
            _ = try self.appendOwnedNode(parent, &node, null);
            node_owned = false;
            return null;
        }

        // Every allocation must precede the by-value child insertion, so an
        // OOM leaves the current partial tree and all pins coherent.
        try self.open.ensureUnusedCapacity(self.allocator, 1);
        const pin = try self.pins.pin(&node);
        errdefer if (node_owned) self.pins.retireNode(&node);
        _ = try self.appendOwnedNode(parent, &node, pin);
        node_owned = false;
        self.open.appendAssumeCapacity(pin);
        return pin;
    }

    fn addText(self: *LiveParser, text: []const u8) !void {
        if (text.len == 0) return;
        // Whitespace before the first structural/head token belongs to the
        // document prologue, not an implicit body. In particular, the common
        // `<!doctype html>\n<title>…</title>\n<body onload=…>` form must
        // leave the authored body start tag free to establish its attributes.
        // Treating this run as body content would create an attribute-less
        // implicit body and later ignore the real body start tag.
        if (!self.body_found and !self.head_found and
            std.mem.trim(u8, text, " \t\r\n\x0c").len == 0)
        {
            return;
        }
        if (!self.body_found and !self.head_found) try self.ensureBody();
        const parent = try self.current();
        var node = Node{ .text = Text.init(text, null) };
        var node_owned = true;
        errdefer if (node_owned) node.deinit(self.allocator);
        _ = try self.appendOwnedNode(parent, &node, null);
        node_owned = false;
    }

    fn ensureHead(self: *LiveParser) !void {
        if (self.head_found or self.body_found) return;
        _ = try self.appendElement(self.root, "head", true);
        self.head_found = true;
    }

    fn ensureBody(self: *LiveParser) !void {
        if (self.body_found) return;
        if (!self.head_found) {
            _ = try self.appendElement(self.root, "head", true);
            self.head_found = true;
        }
        if (try self.findOpen("head")) |index| _ = self.popThrough(index);
        _ = try self.appendElement(self.root, "body", true);
        self.body_found = true;
    }

    fn startHead(self: *LiveParser, tag: []const u8) !void {
        if (self.head_found or self.body_found) return;
        _ = try self.appendElement(self.root, tag, true);
        self.head_found = true;
    }

    fn startBody(self: *LiveParser, tag: []const u8) !void {
        if (self.body_found) return;
        if (!self.head_found) {
            _ = try self.appendElement(self.root, "head", true);
            self.head_found = true;
        }
        if (try self.findOpen("head")) |index| _ = self.popThrough(index);
        _ = try self.appendElement(self.root, tag, true);
        self.body_found = true;
    }

    fn closeParagraphForBlockStart(self: *LiveParser) !void {
        const index = (try self.findOpen("p")) orelse return;
        const body_index = (try self.findOpen("body")) orelse return;
        if (index > body_index) _ = self.popThrough(index);
    }

    fn closeSameOpen(self: *LiveParser, tag: []const u8) !void {
        const index = (try self.findOpen(tag)) orelse return;
        const body_index = (try self.findOpen("body")) orelse return;
        if (index > body_index) _ = self.popThrough(index);
    }

    /// HTML tables have an implicit `tbody` insertion mode: a `tr` directly
    /// under `table` is reparented below a generated section.  Acid3 and
    /// ordinary DOM code observe that section as a real element, so it must be
    /// inserted into the live tree (rather than merely exposed as a collection
    /// compatibility shim).
    fn ensureImplicitTableBody(self: *LiveParser, tag: []const u8) !void {
        if (!tagEquals(tag, "tr")) return;
        const parent = try self.current();
        const is_table = switch (parent.*) {
            .element => |element| tagEquals(element.tag, "table"),
            .text => false,
        };
        if (is_table) _ = try self.appendElement(parent, "tbody", true);
    }

    fn replaceImplicitRoot(self: *LiveParser, tag: []const u8) !void {
        if (self.saw_explicit_html or self.head_found or self.body_found) return;
        const root_element = switch (self.root.*) {
            .element => |*element| element,
            .text => unreachable,
        };
        if (root_element.children.items.len != 0) return;

        var replacement = try Element.init(self.allocator, tag, null);
        errdefer replacement.deinit(self.allocator);
        self.root.deinit(self.allocator);
        self.root.* = .{ .element = replacement };
        self.saw_explicit_html = true;
        dom.fixParentPointers(self.root, null);
    }

    fn addTag(self: *LiveParser, tag: []const u8) !?node_pins.Pin {
        const info = tagInfo(tag);
        if (info.name.len == 0 or tag[0] == '!') return null;

        if (info.is_closing) {
            const closed = try self.closeOpen(info.name);
            if (tagEquals(info.name, "script")) return closed;
            return null;
        }

        if (tagEquals(info.name, "html")) {
            try self.replaceImplicitRoot(tag);
            return null;
        }
        if (tagEquals(info.name, "head")) {
            try self.startHead(tag);
            return null;
        }
        if (tagEquals(info.name, "body")) {
            try self.startBody(tag);
            return null;
        }

        if (!self.body_found) {
            if (isHeadTag(info.name)) {
                try self.ensureHead();
            } else {
                try self.ensureBody();
            }
        }

        if (isBlockStart(info.name)) try self.closeParagraphForBlockStart();
        if (tagEquals(info.name, "li") or tagEquals(info.name, "button")) {
            try self.closeSameOpen(info.name);
        }

        try self.ensureImplicitTableBody(info.name);

        const parent = try self.current();
        const void_tag = html_serialization.isVoidElementTag(info.name) or info.self_closing;
        // A start tag only extends the partial DOM. Parser blocking happens
        // after the matching script end tag has attached its raw-text child,
        // not when `<script>` first becomes the current open element.
        _ = try self.appendElement(parent, tag, !void_tag);
        return null;
    }

    fn finishTree(self: *LiveParser) !void {
        if (!self.head_found) {
            _ = try self.appendElement(self.root, "head", false);
            self.head_found = true;
        }
        if (!self.body_found) {
            // A still-open head is already attached to root; closing the parser
            // stack is enough before appending the implicit body sibling.
            self.open.items.len = 1;
            _ = try self.appendElement(self.root, "body", false);
            self.body_found = true;
        }
        dom.fixParentPointers(self.root, null);
        self.open.clearRetainingCapacity();
    }
};

fn childElementByTag(node: *Node, tag: []const u8) ?*Node {
    return switch (node.*) {
        .text => null,
        .element => |*element| for (element.children.items) |*child| {
            if (child.* == .element and std.ascii.eqlIgnoreCase(child.element.tag, tag)) return child;
        } else null,
    };
}

fn textOf(node: *Node) []const u8 {
    return switch (node.*) {
        .text => |text| text.text,
        .element => "",
    };
}

test "live parser exposes a partial script DOM and inserts writes before unread source" {
    var source = html_source.Store.init(std.testing.allocator);
    defer source.deinit();
    const initial = try std.testing.allocator.dupe(
        u8,
        "<body>before<script>first</script>after</body>",
    );
    _ = try source.adopt(initial);

    var root: Node = undefined;
    var parser = try LiveParser.init(std.testing.allocator, &source, &root);
    defer parser.deinit();
    defer root.deinit(std.testing.allocator);
    parser.finishInput();

    const first = try parser.advance();
    const script_pin = switch (first) {
        .script => |pin| pin,
        else => return error.ExpectedScriptBoundary,
    };
    const body = childElementByTag(&root, "body").?;
    const script = parser.resolve(script_pin).?;
    try std.testing.expectEqualStrings("script", script.element.tag);
    try std.testing.expectEqualStrings("first", textOf(&script.element.children.items[0]));
    try std.testing.expectEqual(@as(usize, 2), body.element.children.items.len);
    script.element.script_started = true;

    try parser.write("<b>written</b>");
    try parser.resumeAfterScript();
    try std.testing.expectEqual(Advance{ .eof = {} }, try parser.advance());

    try std.testing.expectEqual(@as(usize, 4), body.element.children.items.len);
    try std.testing.expectEqualStrings("before", textOf(&body.element.children.items[0]));
    try std.testing.expectEqualStrings("script", body.element.children.items[1].element.tag);
    try std.testing.expect(body.element.children.items[1].element.script_started);
    try std.testing.expectEqualStrings("b", body.element.children.items[2].element.tag);
    try std.testing.expectEqualStrings("written", textOf(&body.element.children.items[2].element.children.items[0]));
    try std.testing.expectEqualStrings("after", textOf(&body.element.children.items[3]));
}

test "live parser preserves multiple writes and can pause again in injected source" {
    var source = html_source.Store.init(std.testing.allocator);
    defer source.deinit();
    const initial = try std.testing.allocator.dupe(
        u8,
        "<body><script>first</script><p>tail</p></body>",
    );
    _ = try source.adopt(initial);

    var root: Node = undefined;
    var parser = try LiveParser.init(std.testing.allocator, &source, &root);
    defer parser.deinit();
    defer root.deinit(std.testing.allocator);
    parser.finishInput();

    _ = switch (try parser.advance()) {
        .script => |pin| pin,
        else => return error.ExpectedFirstScript,
    };
    try parser.write("<i>one</i>");
    try parser.write("<script>second</script>");
    try parser.resumeAfterScript();

    const second_pin = switch (try parser.advance()) {
        .script => |pin| pin,
        else => return error.ExpectedSecondScript,
    };
    const second_script = parser.resolve(second_pin).?;
    try std.testing.expectEqualStrings("second", textOf(&second_script.element.children.items[0]));
    try parser.resumeAfterScript();
    try std.testing.expectEqual(Advance{ .eof = {} }, try parser.advance());

    const body = childElementByTag(&root, "body").?;
    try std.testing.expectEqual(@as(usize, 4), body.element.children.items.len);
    try std.testing.expectEqualStrings("script", body.element.children.items[0].element.tag);
    try std.testing.expectEqualStrings("i", body.element.children.items[1].element.tag);
    try std.testing.expectEqualStrings("script", body.element.children.items[2].element.tag);
    try std.testing.expectEqualStrings("p", body.element.children.items[3].element.tag);
}

test "live parser keeps style text containing angle brackets intact" {
    var source = html_source.Store.init(std.testing.allocator);
    defer source.deinit();
    _ = try source.adopt(try std.testing.allocator.dupe(
        u8,
        "<head><style>.x::before { content: '<'; }</styLE></head>" ++
            "<body><p>visible</p></body>",
    ));

    var root: Node = undefined;
    var parser = try LiveParser.init(std.testing.allocator, &source, &root);
    defer parser.deinit();
    defer root.deinit(std.testing.allocator);
    parser.finishInput();
    try std.testing.expectEqual(Advance{ .eof = {} }, try parser.advance());

    const head = childElementByTag(&root, "head").?;
    try std.testing.expectEqual(@as(usize, 1), head.element.children.items.len);
    const style = &head.element.children.items[0];
    try std.testing.expectEqualStrings("style", style.element.tag);
    try std.testing.expectEqual(@as(usize, 1), style.element.children.items.len);
    try std.testing.expectEqualStrings(
        ".x::before { content: '<'; }",
        textOf(&style.element.children.items[0]),
    );
    const body = childElementByTag(&root, "body").?;
    try std.testing.expectEqualStrings("p", body.element.children.items[0].element.tag);
}

test "live parser keeps authored body attributes after a whitespace prologue" {
    var source = html_source.Store.init(std.testing.allocator);
    defer source.deinit();
    _ = try source.adopt(try std.testing.allocator.dupe(
        u8,
        "<!doctype html>\n<title>prologue</title>\n<body onload=ready>content</body>",
    ));

    var root: Node = undefined;
    var parser = try LiveParser.init(std.testing.allocator, &source, &root);
    defer parser.deinit();
    defer root.deinit(std.testing.allocator);
    parser.finishInput();
    try std.testing.expectEqual(Advance{ .eof = {} }, try parser.advance());

    const head = childElementByTag(&root, "head").?;
    const body = childElementByTag(&root, "body").?;
    try std.testing.expectEqualStrings("title", head.element.children.items[0].element.tag);
    try std.testing.expectEqualStrings("ready", body.element.attributes.?.get("onload").?);
    try std.testing.expectEqualStrings("content", textOf(&body.element.children.items[0]));
}

test "live parser repairs an external node identity while parsing after a script" {
    var source = html_source.Store.init(std.testing.allocator);
    defer source.deinit();
    _ = try source.adopt(try std.testing.allocator.dupe(
        u8,
        "<body><span>keep</span><script>pause</script></body>",
    ));

    var root: Node = undefined;
    var parser = try LiveParser.init(std.testing.allocator, &source, &root);
    defer parser.deinit();
    defer root.deinit(std.testing.allocator);
    parser.finishInput();

    _ = switch (try parser.advance()) {
        .script => |pin| pin,
        else => return error.ExpectedScriptBoundary,
    };
    const body = childElementByTag(&root, "body").?;
    const original_span = childElementByTag(body, "span").?;

    var external_pins = node_pins.Store.init(std.testing.allocator);
    defer external_pins.deinit();
    const span_pin = try external_pins.pin(original_span);
    parser.setExternalRelocationObserver(external_pins.relocationObserver());

    // The initial body child list already has the span and script. Enough
    // following children force one or more backing-array relocations after a
    // script has had an opportunity to retain the span identity.
    try parser.write(
        "<i>0</i><i>1</i><i>2</i><i>3</i><i>4</i><i>5</i><i>6</i><i>7</i>" ++
            "<i>8</i><i>9</i><i>10</i><i>11</i><i>12</i><i>13</i><i>14</i><i>15</i>",
    );
    try parser.resumeAfterScript();
    try std.testing.expectEqual(Advance{ .eof = {} }, try parser.advance());

    const installed_span = childElementByTag(childElementByTag(&root, "body").?, "span").?;
    try std.testing.expectEqual(installed_span, external_pins.resolve(span_pin).?);
}
