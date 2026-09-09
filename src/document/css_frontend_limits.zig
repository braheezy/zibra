//! Admission and allocation bounds for the experimental Terence frontend.
//! Syntax and retained semantic owners share these gates; production CSS does
//! not use them yet.

const std = @import("std");
const backend = @import("css_frontend_backend");

pub const Limits = struct {
    source_bytes: usize = 1024 * 1024,
    tokens: usize = 32 * 1024,
    nodes: usize = 128 * 1024,
    nesting: usize = 64,
    allocated_bytes: usize = 16 * 1024 * 1024,
    /// Conservative admission charge, not a count of executed instructions.
    /// The pinned parser can rescan suffixes during declaration/rule recovery.
    /// Until it has native fuel, reserve 4*T*(B+T) for its two parsing passes.
    recovery_work: usize = 64 * 1024 * 1024,
};

pub const Stats = struct {
    tokens: usize = 0,
    nesting: usize = 0,
    lexical_errors: usize = 0,
    recovery_work: usize = 0,
};

/// Allocation-free tokenization runs before the recursive parser or source
/// duplication. Limits may be tightened, but the fixed nesting ceiling cannot
/// be raised. Mismatched closing tokens do not pop a different opening token.
pub fn inspect(source: []const u8, limits: Limits, component_values: bool) !Stats {
    if (source.len > limits.source_bytes or source.len >= std.math.maxInt(u32))
        return error.SourceLimitExceeded;
    var stack: [64]backend.tokenizer.Token.Tag = undefined;
    var depth: usize = 0;
    var stats: Stats = .{};
    var tokenizer = backend.tokenizer.Tokenizer.init(source);
    while (true) {
        const before = tokenizer.index;
        const token = tokenizer.next();
        stats.tokens += 1;
        if (stats.tokens > limits.tokens) return error.TokenLimitExceeded;
        if (token.parse_error != null) stats.lexical_errors += 1;
        const closing: ?backend.tokenizer.Token.Tag = switch (token.tag) {
            .function, .l_paren => .r_paren,
            .l_bracket => .r_bracket,
            .l_brace => .r_brace,
            else => null,
        };
        if (closing) |tag| {
            if (depth >= @min(stack.len, limits.nesting)) return error.NestingLimitExceeded;
            stack[depth] = tag;
            depth += 1;
            stats.nesting = @max(stats.nesting, depth);
        } else if (depth != 0 and token.tag == stack[depth - 1]) {
            depth -= 1;
        }
        if (token.tag == .eof) break;
        // A dependency update must never turn preflight into a non-progress loop.
        if (tokenizer.index <= before) return error.FrontendDidNotProgress;
    }
    const bytes_and_tokens = std.math.add(usize, source.len, stats.tokens) catch
        return error.RecoveryLimitExceeded;
    // Component-value parsing has no declaration/rule backtracking.
    const multiplier = if (component_values) 4 else std.math.mul(usize, 4, stats.tokens) catch
        return error.RecoveryLimitExceeded;
    stats.recovery_work = std.math.mul(usize, multiplier, bytes_and_tokens) catch
        return error.RecoveryLimitExceeded;
    if (stats.recovery_work > limits.recovery_work) return error.RecoveryLimitExceeded;
    return stats;
}

/// Heap-stable in the frontend's Storage. Caps live bytes, including source,
/// metadata, AST temporaries and retained diagnostics. The fixed Storage header
/// itself is allocated by the parent. Failed growth is recoverable by realloc.
pub const Budget = struct {
    parent: std.mem.Allocator,
    limit: usize,
    live: usize = 0,
    peak: usize = 0,
    exceeded: bool = false,

    pub fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn permits(self: *Budget, old_len: usize, new_len: usize) bool {
        if (new_len > old_len and new_len - old_len > self.limit - self.live) {
            self.exceeded = true;
            return false;
        }
        return true;
    }

    fn account(self: *Budget, old_len: usize, new_len: usize) void {
        self.live = self.live - old_len + new_len;
        self.peak = @max(self.peak, self.live);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (!self.permits(0, len)) return null;
        const result = self.parent.rawAlloc(len, alignment, ra) orelse return null;
        self.account(0, len);
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (!self.permits(memory.len, len)) return false;
        if (!self.parent.rawResize(memory, alignment, len, ra)) return false;
        self.account(memory.len, len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (!self.permits(memory.len, len)) return null;
        const result = self.parent.rawRemap(memory, alignment, len, ra) orelse return null;
        self.account(memory.len, len);
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ra);
        self.account(memory.len, 0);
    }
};
