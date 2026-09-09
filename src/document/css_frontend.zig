//! Experimental source-owning CSS syntax boundary. Terence types stay here;
//! selectors, property grammars, cascade, DOM and rendering remain Zibra owners.
//! The inspection adapter consumes this tree; native browsing stays on the
//! established parser until the frontend's production acceptance gates pass.

const std = @import("std");
const backend = @import("css_frontend_backend");
const bounds = @import("css_frontend_limits.zig");

pub const Limits = bounds.Limits;
pub const Mode = enum { stylesheet, declarations, component_values };
pub const Options = struct {
    mode: Mode = .stylesheet,
    limits: Limits = .{},
    /// Optional already-serialized resource provenance, copied on construction.
    /// This is not an owning network.Url and performs no URL resolution/fetch.
    base_url: ?[]const u8 = null,
};

/// An offset into one immutable source; never a decoded or serialized value.
pub const Range = struct { start: u32, end: u32 };
/// Synchronous, source-generation-bound borrow. Not a reusable CSSOM identity.
pub const NodeId = enum(u32) { _ };

pub const Kind = enum {
    root,
    at_rule,
    qualified_rule,
    block,
    declaration_list,
    declaration,
    invalid,
    token,
    brace,
    bracket,
    paren,
    function,
};

pub const Node = struct {
    kind: Kind,
    range: Range,
    /// Raw property name, at-keyword, function name/opening, or first token.
    head: Range,
};

pub const Declaration = struct {
    name: Range,
    value: Range,
    important: bool,
};

/// Stable adapter categories for source tokens. They carry no decoded value;
/// consumers must preserve token boundaries when normalizing spelling.
pub const TokenKind = enum {
    identifier,
    function,
    at_keyword,
    hash,
    dimension,
    number,
    percentage,
    string,
    url,
    whitespace,
    comment,
    open_brace,
    close_brace,
    open_bracket,
    close_bracket,
    open_paren,
    close_paren,
    comma,
    other,
};

pub const Token = struct {
    kind: TokenKind,
    range: Range,
};

pub const Diagnostic = struct {
    stage: enum { tokenizer, parser },
    range: Range,
    /// Static diagnostic spelling; no dependency-owned enum escapes the API.
    code: []const u8,
};

pub const Stats = struct {
    tokens: usize,
    nodes: usize,
    nesting: usize,
    recovery_work: usize,
    peak_allocated_bytes: usize,
};

const Storage = struct {
    budget: bounds.Budget,
    source: []u8,
    base_url: ?[]u8,
    tree: backend.Ast,
    diagnostics: []Diagnostic,
    inspection: bounds.Stats,
};

/// A move-only owner. All slices, node IDs and iterators borrow this generation
/// and retire before deinit/replacement. The heap holder keeps allocator context
/// stable even when this outer owner moves. No DOM/JS borrower is registered.
pub const Syntax = struct {
    storage: *Storage,

    /// Duplicates input/provenance and stages a complete tree. Failure releases
    /// every temporary allocation and publishes no owner. Generic syntax success
    /// says nothing about supported selectors, properties or at-rule semantics.
    pub fn parse(parent: std.mem.Allocator, input: []const u8, options: Options) !Syntax {
        const inspection = try bounds.inspect(input, options.limits, options.mode == .component_values);
        if (options.base_url) |url| {
            if (url.len > options.limits.source_bytes) return error.SourceLimitExceeded;
        }
        const storage = try parent.create(Storage);
        errdefer parent.destroy(storage);
        storage.budget = .{ .parent = parent, .limit = options.limits.allocated_bytes };
        return initStorage(storage, input, options, inspection) catch |err| {
            std.debug.assert(storage.budget.live == 0);
            if (err == error.OutOfMemory and storage.budget.exceeded) return error.MemoryLimitExceeded;
            return err;
        };
    }

    fn initStorage(storage: *Storage, input: []const u8, options: Options, inspection: bounds.Stats) !Syntax {
        const allocator = storage.budget.allocator();
        storage.source = try allocator.dupe(u8, input);
        errdefer allocator.free(storage.source);
        storage.base_url = if (options.base_url) |url| try allocator.dupe(u8, url) else null;
        errdefer if (storage.base_url) |url| allocator.free(url);
        storage.inspection = inspection;
        storage.tree = try switch (options.mode) {
            .stylesheet => backend.Ast.parseStylesheet(allocator, storage.source),
            .declarations => backend.Ast.parseBlockContents(allocator, storage.source),
            .component_values => backend.Ast.parseComponentValues(allocator, storage.source),
        };
        errdefer storage.tree.deinit(allocator);
        // Allocation is bounded throughout parsing, before these exact counts
        // exist. Preflight counts include trivia and EOF, before unicode-range
        // retokenization (which can only combine tokens).
        if (storage.tree.tokens.len > options.limits.tokens) return error.TokenLimitExceeded;
        if (storage.tree.nodes.len > options.limits.nodes) return error.NodeLimitExceeded;
        storage.diagnostics = try allocator.alloc(Diagnostic, inspection.lexical_errors + storage.tree.errors.len);
        var count: usize = 0;
        var tokenizer = backend.tokenizer.Tokenizer.init(storage.source);
        while (true) {
            const token = tokenizer.next();
            if (token.parse_error) |err| {
                storage.diagnostics[count] = .{
                    .stage = .tokenizer,
                    .range = .{ .start = @intCast(token.loc.start), .end = @intCast(token.loc.end) },
                    .code = @tagName(err),
                };
                count += 1;
            }
            if (token.tag == .eof) break;
        }
        for (storage.tree.errors) |err| {
            storage.diagnostics[count] = .{
                .stage = .parser,
                .range = tokenRange(storage.tree, err.token),
                .code = @tagName(err.tag),
            };
            count += 1;
        }
        std.debug.assert(count == storage.diagnostics.len);
        return .{ .storage = storage };
    }

    /// Requires all external borrowers to have retired. For future live style
    /// consumers, stage with parse, invalidate borrowers, then move/deinit owners
    /// explicitly at their publication boundary instead of using this helper.
    pub fn replace(self: *Syntax, input: []const u8, options: Options) !void {
        const replacement = try parse(self.storage.budget.parent, input, options);
        self.deinit();
        self.* = replacement;
    }

    pub fn deinit(self: *Syntax) void {
        const storage = self.storage;
        const parent = storage.budget.parent;
        const allocator = storage.budget.allocator();
        allocator.free(storage.diagnostics);
        storage.tree.deinit(allocator);
        if (storage.base_url) |url| allocator.free(url);
        allocator.free(storage.source);
        std.debug.assert(storage.budget.live == 0);
        parent.destroy(storage);
        self.* = undefined;
    }

    pub fn source(self: Syntax) []const u8 {
        return self.storage.source;
    }

    pub fn baseUrl(self: Syntax) ?[]const u8 {
        return self.storage.base_url;
    }

    pub fn slice(self: Syntax, range: Range) []const u8 {
        return self.source()[range.start..range.end];
    }

    pub fn root(self: Syntax) NodeId {
        return @enumFromInt(self.storage.tree.root);
    }

    pub fn node(self: Syntax, id: NodeId) Node {
        const tree = self.storage.tree;
        const index = @intFromEnum(id);
        const kind: Kind = switch (tree.nodes.items(.tag)[index]) {
            .root => .root,
            .at_rule => .at_rule,
            .qualified_rule => .qualified_rule,
            .block => .block,
            .declaration_list => .declaration_list,
            .declaration, .declaration_important => .declaration,
            .invalid => .invalid,
            .token => .token,
            .simple_block_brace => .brace,
            .simple_block_bracket => .bracket,
            .simple_block_paren => .paren,
            .function => .function,
            // These entry points never construct grammar-matched comma groups.
            .component_value_list, .component_value_list_invalid => unreachable,
        };
        return .{
            .kind = kind,
            .range = nodeRange(tree, index),
            .head = if (kind == .root) .{ .start = 0, .end = 0 } else tokenRange(tree, tree.nodes.items(.main_token)[index]),
        };
    }

    pub const Iterator = struct {
        indices: []const u32,
        pub fn next(self: *Iterator) ?NodeId {
            if (self.indices.len == 0) return null;
            const id = self.indices[0];
            self.indices = self.indices[1..];
            return @enumFromInt(id);
        }
    };

    pub fn children(self: Syntax, id: NodeId) Iterator {
        return .{ .indices = self.storage.tree.extraChildren(@intFromEnum(id)) };
    }

    pub const TokenIterator = struct {
        syntax: Syntax,
        index: u32,
        end: u32,

        pub fn next(self: *TokenIterator) ?Token {
            const tree = self.syntax.storage.tree;
            if (self.index >= tree.tokens.len or tree.tokenStart(self.index) >= self.end) return null;
            const index = self.index;
            self.index += 1;
            const kind: TokenKind = switch (tree.tokenTag(index)) {
                .ident => .identifier,
                .function => .function,
                .at_keyword => .at_keyword,
                .hash_id, .hash_unrestricted => .hash,
                .dimension => .dimension,
                .number => .number,
                .percentage => .percentage,
                .string => .string,
                .url => .url,
                .whitespace => .whitespace,
                .comment => .comment,
                .l_brace => .open_brace,
                .r_brace => .close_brace,
                .l_bracket => .open_bracket,
                .r_bracket => .close_bracket,
                .l_paren => .open_paren,
                .r_paren => .close_paren,
                .comma => .comma,
                else => .other,
            };
            return .{ .kind = kind, .range = tokenRange(tree, index) };
        }
    };

    /// Iterate existing tokens in a token-aligned source range, including
    /// comments and whitespace. This never invokes the tokenizer or parser.
    pub fn tokens(self: Syntax, range: Range) TokenIterator {
        const starts = self.storage.tree.tokens.items(.start);
        var low: usize = 0;
        var high = starts.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (starts[mid] < range.start) low = mid + 1 else high = mid;
        }
        return .{ .syntax = self, .index = @intCast(low), .end = range.end };
    }

    /// Returns syntax-valid declarations in authored spelling. Invalid recovery
    /// nodes and values containing bad strings/URLs or unmatched closers cannot
    /// enter the semantic adapter. Property validity remains a separate stage;
    /// declarations with unsupported values and duplicate fallbacks are retained.
    pub fn declaration(self: Syntax, id: NodeId) ?Declaration {
        const tree = self.storage.tree;
        const index = @intFromEnum(id);
        const tag = tree.nodes.items(.tag)[index];
        if (tag != .declaration and tag != .declaration_important) return null;
        if (!validValues(tree, index)) return null;
        const values = tree.extraChildren(index);
        const name_token = tree.nodes.items(.main_token)[index];
        // Empty custom-property values stay empty and retain their name/priority.
        const empty = tokenRange(tree, name_token).end;
        return .{
            .name = tokenRange(tree, name_token),
            .value = if (values.len == 0) .{ .start = empty, .end = empty } else .{
                .start = nodeRange(tree, values[0]).start,
                .end = nodeRange(tree, values[values.len - 1]).end,
            },
            .important = tag == .declaration_important,
        };
    }

    pub fn diagnostics(self: Syntax) []const Diagnostic {
        return self.storage.diagnostics;
    }

    pub fn stats(self: Syntax) Stats {
        return .{
            .tokens = self.storage.tree.tokens.len,
            .nodes = self.storage.tree.nodes.len,
            .nesting = self.storage.inspection.nesting,
            .recovery_work = self.storage.inspection.recovery_work,
            .peak_allocated_bytes = self.storage.budget.peak,
        };
    }
};

fn tokenRange(tree: backend.Ast, token: u32) Range {
    return .{ .start = tree.tokenStart(token), .end = tree.tokens.items(.end)[token] };
}

fn nodeRange(tree: backend.Ast, index: u32) Range {
    const range = tree.nodeRange(index);
    return .{ .start = tree.tokenStart(range.start), .end = tree.tokenStart(range.end) };
}

fn validValues(tree: backend.Ast, index: u32) bool {
    for (tree.extraChildren(index)) |child| {
        if (tree.nodes.items(.tag)[child] == .token) {
            switch (tree.tokenTag(tree.nodes.items(.main_token)[child])) {
                .bad_string, .bad_url, .r_brace, .r_bracket, .r_paren => return false,
                else => {},
            }
        } else if (!validValues(tree, child)) return false;
    }
    return true;
}
