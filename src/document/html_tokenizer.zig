//! Incremental tokenization for an append-only HTML input stream.
//!
//! `Stream` borrows immutable source chunks supplied by its caller and emits
//! independently owned token bytes. That deliberate copy boundary makes the
//! lexical result independent of network chunking: a text run, tag, comment,
//! or raw-text script body can cross any number of chunks without changing the
//! token sequence. A future live tree builder can transfer each token's bytes
//! into its document-owned `html_source.Store` before storing a DOM borrow.

const std = @import("std");

/// The small token vocabulary needed by the existing HTML tree builder.
/// `start_tag` and `end_tag` bytes omit the surrounding angle brackets; an end
/// tag includes its leading slash (for example, `/div`).
pub const Kind = enum {
    text,
    start_tag,
    end_tag,
    comment,
    eof,
};

/// An owned lexical token. Call `deinit` exactly once for all non-EOF tokens
/// returned by `Stream.next`.
pub const Token = struct {
    kind: Kind,
    bytes: []u8 = &.{},

    pub fn deinit(self: *Token, allocator: std.mem.Allocator) void {
        if (self.bytes.len != 0) allocator.free(self.bytes);
        self.* = .{ .kind = .eof };
    }
};

const State = enum {
    data,
    tag,
    comment,
    raw_script,
};

const raw_script_end = "</script>";

/// Tokenizes an append-only sequence of stable source chunks.
///
/// Callers retain every chunk passed to `appendChunk` until this stream has
/// been deinitialized. `next` returns null when more source is required and
/// only returns EOF after `finish` declares that no later chunk can arrive.
/// The stream never borrows a token's bytes from its input, so a returned token
/// remains valid after the scanner advances.
pub const Stream = struct {
    allocator: std.mem.Allocator,
    chunks: std.ArrayList([]const u8) = .empty,
    chunk_index: usize = 0,
    chunk_offset: usize = 0,
    finished: bool = false,
    eof_emitted: bool = false,
    state: State = .data,
    tag_quote: ?u8 = null,
    raw_match_len: usize = 0,
    raw_match: [raw_script_end.len]u8 = undefined,
    text: std.ArrayList(u8) = .empty,
    tag: std.ArrayList(u8) = .empty,
    comment: std.ArrayList(u8) = .empty,
    queued: std.ArrayList(Token) = .empty,

    pub fn init(allocator: std.mem.Allocator) Stream {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Stream) void {
        self.text.deinit(self.allocator);
        self.tag.deinit(self.allocator);
        self.comment.deinit(self.allocator);
        for (self.queued.items) |*token| token.deinit(self.allocator);
        self.queued.deinit(self.allocator);
        self.chunks.deinit(self.allocator);
    }

    /// Append a stable, immutable chunk of source. Empty chunks are harmless.
    /// This rejects input after `finish`, because that would make EOF timing
    /// ambiguous to a parser suspended at a script boundary.
    pub fn appendChunk(self: *Stream, source: []const u8) !void {
        if (self.finished) return error.InputFinished;
        if (source.len == 0) return;
        try self.chunks.append(self.allocator, source);
    }

    /// Insert stable parser-produced input immediately before unread source.
    ///
    /// A live parser calls this after a parser-blocking script returns from
    /// `document.write`: the injected chunks must be tokenized before the
    /// original source following that script. It is valid after `finish`, as
    /// long as EOF has not been emitted, because `finish` only says the
    /// network/source producer has no more ordinary chunks. The caller keeps
    /// every supplied slice alive through this Stream's lifetime.
    pub fn insertBeforeUnread(self: *Stream, sources: []const []const u8) !void {
        if (self.eof_emitted) return error.InputFinished;

        var nonempty_count: usize = 0;
        for (sources) |source| {
            if (source.len != 0) nonempty_count += 1;
        }
        if (nonempty_count == 0) return;

        // `chunk_offset` may name a partly consumed input chunk. Replace its
        // stored slice with the unread suffix first, so a normal insertion at
        // `chunk_index` still puts written input before that suffix without
        // copying either immutable source chunk.
        if (self.chunk_index < self.chunks.items.len and self.chunk_offset != 0) {
            const current = self.chunks.items[self.chunk_index];
            if (self.chunk_offset < current.len) {
                self.chunks.items[self.chunk_index] = current[self.chunk_offset..];
            } else {
                self.chunk_index += 1;
            }
            self.chunk_offset = 0;
        }

        const insert_index = self.chunk_index;
        try self.chunks.ensureUnusedCapacity(self.allocator, nonempty_count);
        var next_index = insert_index;
        for (sources) |source| {
            if (source.len == 0) continue;
            self.chunks.insertAssumeCapacity(next_index, source);
            next_index += 1;
        }
    }

    /// Declare that no later chunk will be appended. Any unfinished lexical
    /// construct is resolved deterministically on the following `next` calls.
    pub fn finish(self: *Stream) void {
        self.finished = true;
    }

    /// Return the next completed token, null if more source is required, or a
    /// single EOF token after `finish` and every queued token have been read.
    pub fn next(self: *Stream) !?Token {
        while (true) {
            if (self.popQueued()) |token| return token;

            if (self.readByte()) |byte| {
                try self.consume(byte);
                continue;
            }

            if (!self.finished) return null;
            try self.finishInput();
            if (self.popQueued()) |token| return token;
            if (self.eof_emitted) return null;
            self.eof_emitted = true;
            return .{ .kind = .eof };
        }
    }

    fn popQueued(self: *Stream) ?Token {
        if (self.queued.items.len == 0) return null;
        return self.queued.orderedRemove(0);
    }

    fn readByte(self: *Stream) ?u8 {
        while (self.chunk_index < self.chunks.items.len) {
            const chunk = self.chunks.items[self.chunk_index];
            if (self.chunk_offset < chunk.len) {
                const byte = chunk[self.chunk_offset];
                self.chunk_offset += 1;
                return byte;
            }
            self.chunk_index += 1;
            self.chunk_offset = 0;
        }
        return null;
    }

    fn consume(self: *Stream, byte: u8) !void {
        switch (self.state) {
            .data => try self.consumeData(byte),
            .tag => try self.consumeTag(byte),
            .comment => try self.consumeComment(byte),
            .raw_script => try self.consumeRawScript(byte),
        }
    }

    fn consumeData(self: *Stream, byte: u8) !void {
        if (byte != '<') {
            try self.text.append(self.allocator, byte);
            return;
        }

        self.state = .tag;
        self.tag.clearRetainingCapacity();
        self.tag_quote = null;
    }

    fn consumeTag(self: *Stream, byte: u8) !void {
        if (self.tag_quote) |quote| {
            try self.tag.append(self.allocator, byte);
            if (byte == quote) self.tag_quote = null;
            return;
        }

        if (byte == '"' or byte == '\'') {
            self.tag_quote = byte;
            try self.tag.append(self.allocator, byte);
            return;
        }

        if (byte == '>') {
            try self.finishTag();
            return;
        }

        try self.tag.append(self.allocator, byte);
        if (std.mem.eql(u8, self.tag.items, "!--")) {
            self.tag.clearRetainingCapacity();
            self.state = .comment;
        }
    }

    fn consumeComment(self: *Stream, byte: u8) !void {
        try self.comment.append(self.allocator, byte);
        if (!std.mem.endsWith(u8, self.comment.items, "-->")) return;

        self.comment.items.len -= "-->".len;
        try self.queueText();
        try self.queueBuffer(.comment, &self.comment);
        self.state = .data;
    }

    fn consumeRawScript(self: *Stream, byte: u8) !void {
        if (std.ascii.toLower(byte) == raw_script_end[self.raw_match_len]) {
            self.raw_match[self.raw_match_len] = byte;
            self.raw_match_len += 1;
            if (self.raw_match_len != raw_script_end.len) return;

            self.raw_match_len = 0;
            try self.queueText();
            try self.queueCopy(.end_tag, "/script");
            self.state = .data;
            return;
        }

        if (self.raw_match_len != 0) {
            try self.text.appendSlice(self.allocator, self.raw_match[0..self.raw_match_len]);
            self.raw_match_len = 0;
        }

        if (std.ascii.toLower(byte) == raw_script_end[0]) {
            self.raw_match[0] = byte;
            self.raw_match_len = 1;
        } else {
            try self.text.append(self.allocator, byte);
        }
    }

    fn finishTag(self: *Stream) !void {
        const kind: Kind = if (isClosingTag(self.tag.items)) .end_tag else .start_tag;
        const begins_raw_script = kind == .start_tag and isScriptStartTag(self.tag.items);
        // Do not emit text before knowing that '<' starts a completed tag:
        // otherwise a chunk ending in an unfinished tag would create a
        // different text-node sequence from the same source in one chunk.
        try self.queueText();
        try self.queueBuffer(kind, &self.tag);
        self.tag_quote = null;
        self.state = if (begins_raw_script) .raw_script else .data;
    }

    fn finishInput(self: *Stream) !void {
        switch (self.state) {
            .data => try self.queueText(),
            .tag => {
                // A trailing '<... without a closing '>' is text in this
                // bounded tokenizer. Preserving it is more useful than losing
                // source and keeps chunk timing from changing the DOM text.
                try self.text.append(self.allocator, '<');
                try self.text.appendSlice(self.allocator, self.tag.items);
                self.tag.clearRetainingCapacity();
                self.state = .data;
                try self.queueText();
            },
            .comment => {
                // Unterminated comments consume the remainder of the input.
                self.comment.clearRetainingCapacity();
                self.state = .data;
            },
            .raw_script => {
                if (self.raw_match_len != 0) {
                    try self.text.appendSlice(self.allocator, self.raw_match[0..self.raw_match_len]);
                    self.raw_match_len = 0;
                }
                self.state = .data;
                try self.queueText();
            },
        }
    }

    fn queueText(self: *Stream) !void {
        if (self.text.items.len == 0) return;
        try self.queueBuffer(.text, &self.text);
    }

    fn queueCopy(self: *Stream, kind: Kind, bytes: []const u8) !void {
        const owned = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned);
        try self.queued.append(self.allocator, .{ .kind = kind, .bytes = owned });
    }

    fn queueBuffer(self: *Stream, kind: Kind, buffer: *std.ArrayList(u8)) !void {
        const owned = try buffer.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned);
        try self.queued.append(self.allocator, .{ .kind = kind, .bytes = owned });
    }
};

fn isClosingTag(tag: []const u8) bool {
    return tag.len > 0 and tag[0] == '/';
}

fn isScriptStartTag(tag: []const u8) bool {
    if (isClosingTag(tag)) return false;
    var end: usize = 0;
    while (end < tag.len and !std.ascii.isWhitespace(tag[end]) and tag[end] != '/') : (end += 1) {}
    if (!std.ascii.eqlIgnoreCase(tag[0..end], "script")) return false;

    var last = tag.len;
    while (last > 0 and std.ascii.isWhitespace(tag[last - 1])) : (last -= 1) {}
    return last == 0 or tag[last - 1] != '/';
}

fn expectToken(
    stream: *Stream,
    kind: Kind,
    bytes: []const u8,
) !void {
    var token = (try stream.next()) orelse return error.ExpectedToken;
    defer token.deinit(stream.allocator);
    try std.testing.expectEqual(kind, token.kind);
    try std.testing.expectEqualStrings(bytes, token.bytes);
}

test "chunked tokenizer preserves text, tags, and raw script input" {
    var stream = Stream.init(std.testing.allocator);
    defer stream.deinit();

    try stream.appendChunk("<div>hel");
    try stream.appendChunk("lo</d");
    try stream.appendChunk("iv><script>1 < 2</scr");
    try stream.appendChunk("IPT><p>x</p>");
    stream.finish();

    try expectToken(&stream, .start_tag, "div");
    try expectToken(&stream, .text, "hello");
    try expectToken(&stream, .end_tag, "/div");
    try expectToken(&stream, .start_tag, "script");
    try expectToken(&stream, .text, "1 < 2");
    try expectToken(&stream, .end_tag, "/script");
    try expectToken(&stream, .start_tag, "p");
    try expectToken(&stream, .text, "x");
    try expectToken(&stream, .end_tag, "/p");
    try expectToken(&stream, .eof, "");
    try std.testing.expect((try stream.next()) == null);
}

test "chunked tokenizer respects quoted tag delimiters and comments" {
    var stream = Stream.init(std.testing.allocator);
    defer stream.deinit();

    try stream.appendChunk("before<a title='>");
    try stream.appendChunk("'>ok</a><!-- co");
    try stream.appendChunk("mment > text -->after");
    stream.finish();

    try expectToken(&stream, .text, "before");
    try expectToken(&stream, .start_tag, "a title='>'");
    try expectToken(&stream, .text, "ok");
    try expectToken(&stream, .end_tag, "/a");
    try expectToken(&stream, .comment, " comment > text ");
    try expectToken(&stream, .text, "after");
    try expectToken(&stream, .eof, "");
}

test "chunked tokenizer waits for input and resolves unfinished input at EOF" {
    var stream = Stream.init(std.testing.allocator);
    defer stream.deinit();

    try stream.appendChunk("plain");
    try std.testing.expect((try stream.next()) == null);
    stream.finish();
    try expectToken(&stream, .text, "plain");
    try expectToken(&stream, .eof, "");

    var trailing = Stream.init(std.testing.allocator);
    defer trailing.deinit();
    try trailing.appendChunk("a<incomplete");
    trailing.finish();
    try expectToken(&trailing, .text, "a<incomplete");
    try expectToken(&trailing, .eof, "");
}

test "injected input precedes unread source even after network input finishes" {
    var stream = Stream.init(std.testing.allocator);
    defer stream.deinit();

    try stream.appendChunk("<script></script>after");
    stream.finish();
    try expectToken(&stream, .start_tag, "script");
    try expectToken(&stream, .end_tag, "/script");

    const writes = [_][]const u8{ "first", "second" };
    try stream.insertBeforeUnread(&writes);
    try expectToken(&stream, .text, "firstsecondafter");
    try expectToken(&stream, .eof, "");
}
