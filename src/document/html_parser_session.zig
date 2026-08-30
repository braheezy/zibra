//! One document source and one current HTML parser invocation.
//!
//! This compatibility session owns the existing one-shot parser while borrowing
//! a document-owned source store. It gives navigation code a stable seam for a
//! future resumable parser without changing today's tree-construction behavior.

const std = @import("std");
const html_source = @import("html_source.zig");

/// Bind a one-shot parser to one document-owned HTML source store.
///
/// The session owns the parser allocated by `Parser.init`, while `source` is a
/// borrow. Callers must keep the source store alive through both `deinit` and
/// the lifetime of the parsed DOM, whose text and attribute slices borrow it.
pub fn Session(comptime Parser: type, comptime Node: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        source: *const html_source.Store,
        parser: ?*Parser,
        consumed: bool = false,

        /// Create a session over the initial document chunk.
        ///
        /// The caller retains `source`; a source store without an initial chunk
        /// cannot begin parsing.
        pub fn init(allocator: std.mem.Allocator, source: *const html_source.Store) !Self {
            const initial = source.initial() orelse return error.MissingInitialSource;
            return .{
                .allocator = allocator,
                .source = source,
                .parser = try Parser.init(allocator, initial),
            };
        }

        /// Release the owned parser. This does not release `source` or any DOM
        /// root returned from `parseToEnd`.
        pub fn deinit(self: *Self) void {
            if (self.parser) |parser| {
                parser.deinit(self.allocator);
                self.parser = null;
            }
        }

        /// Parse the initial source to completion using the current parser.
        ///
        /// This is deliberately single-use: a later resumable implementation
        /// will replace this boundary with parser advancement and pause events,
        /// but callers must not accidentally replay a partially consumed source.
        pub fn parseToEnd(self: *Self) !Node {
            if (self.parser == null) return error.ParserDeinitialized;
            if (self.consumed) return error.ParserAlreadyConsumed;

            self.consumed = true;
            return self.parser.?.parse();
        }
    };
}
