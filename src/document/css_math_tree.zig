//! Bounded transient calculation trees emitted by the shared CSS math parser.
//! Simplification preserves relative units; serialized strings belong to callers.
const std = @import("std");
pub const max_nodes = 512;
pub const Index = u16;
pub const none = std.math.maxInt(Index);
pub const Unit = enum {
    number,
    percent,
    deg,
    em,
    px,
    rem,
    s,
    fn suffix(self: Unit) []const u8 {
        return switch (self) {
            .number => "",
            .percent => "%",
            else => @tagName(self),
        };
    }
    fn relative(self: Unit) bool {
        return self == .em or self == .rem;
    }
};
pub const Tag = enum { value, sum, product, negate, invert, min, max, clamp, abs, sign };
const Node = struct {
    tag: Tag,
    value: f64 = 0,
    unit: Unit = .number,
    first: Index = none,
    second: Index = none,
    next: Index = none,
};

pub const Tree = struct {
    nodes: [max_nodes]Node = undefined,
    count: Index = 0,

    fn add(self: *Tree, node: Node) ?Index {
        if (self.count == self.nodes.len) return null;
        const index = self.count;
        self.count += 1;
        self.nodes[index] = node;
        return index;
    }
    pub fn literal(self: *Tree, value: f64, unit: Unit) ?Index {
        return self.add(.{ .tag = .value, .value = value, .unit = unit });
    }
    pub fn unary(self: *Tree, tag: Tag, child: Index) ?Index {
        const node = self.nodes[child];
        if (node.tag == .value) {
            if (tag == .negate) return self.literal(-node.value, node.unit);
            if (tag == .invert and node.unit == .number) return self.literal(1 / node.value, .number);
        }
        return self.add(.{ .tag = tag, .first = child });
    }
    pub fn binary(self: *Tree, tag: Tag, first: Index, second: Index) ?Index {
        const a = self.nodes[first];
        const b = self.nodes[second];
        if (a.tag == .value and b.tag == .value) {
            if (tag == .sum and a.unit == b.unit) return self.literal(a.value + b.value, a.unit);
            if (tag == .product and (a.unit == .number or b.unit == .number)) return self.literal(a.value * b.value, if (a.unit == .number) b.unit else a.unit);
        }
        // Equal-unit division cancels the unit without assuming a font size.
        if (tag == .product and a.tag == .value and b.tag == .invert) {
            const denominator = self.nodes[b.first];
            if (denominator.tag == .value and denominator.unit == a.unit) return self.literal(a.value / denominator.value, .number);
        }
        return self.add(.{ .tag = tag, .first = first, .second = second });
    }
    pub fn function(self: *Tree, tag: Tag, arguments: []const Index) ?Index {
        const first = self.nodes[arguments[0]];
        var constant = first.tag == .value;
        for (arguments) |index| {
            const node = self.nodes[index];
            constant = constant and node.tag == .value and node.unit == first.unit;
        }
        if (constant and !(tag == .sign and first.unit.relative())) {
            var value = first.value;
            for (arguments[1..]) |index| {
                const next = self.nodes[index].value;
                value = if (std.math.isNan(value) or std.math.isNan(next)) std.math.nan(f64) else if (tag == .min) @min(value, next) else if (tag == .max) @max(value, next) else value;
            }
            if (tag == .clamp) {
                const middle = self.nodes[arguments[1]].value;
                const last = self.nodes[arguments[2]].value;
                value = if (std.math.isNan(value) or std.math.isNan(middle) or std.math.isNan(last)) std.math.nan(f64) else @max(value, @min(middle, last));
            } else if (tag == .abs) {
                value = @abs(value);
            } else if (tag == .sign) {
                value = if (value == 0 or std.math.isNan(value)) value else if (value < 0) -1 else 1;
            }
            return self.literal(value, if (tag == .sign) .number else first.unit);
        }
        for (arguments, 0..) |index, i| self.nodes[index].next = if (i + 1 == arguments.len) none else arguments[i + 1];
        return self.add(.{ .tag = tag, .first = arguments[0] });
    }

    /// Serialize a specified math function, retaining calc() around constants.
    pub fn serialize(self: *const Tree, allocator: std.mem.Allocator, root: Index) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        const tag = self.nodes[root].tag;
        const wrapped = tag == .value or tag == .sum or tag == .product or tag == .negate or tag == .invert;
        if (wrapped) try output.appendSlice(allocator, "calc(");
        try self.write(allocator, &output, root, true);
        if (wrapped) try output.append(allocator, ')');
        return output.toOwnedSlice(allocator);
    }

    fn number(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: f64, unit: Unit) !void {
        var buffer: [384]u8 = undefined;
        const text = if (std.math.isNan(value)) "NaN" else if (std.math.isInf(value)) (if (value < 0) "-infinity" else "infinity") else std.fmt.bufPrint(&buffer, "{d}", .{if (value == 0) @as(f64, 0) else value}) catch unreachable;
        try output.appendSlice(allocator, text);
        if (!std.math.isFinite(value) and unit != .number) try output.appendSlice(allocator, " * 1");
        try output.appendSlice(allocator, unit.suffix());
    }

    fn collect(self: *const Tree, index: Index, tag: Tag, items: *[max_nodes]Index, count: *usize) void {
        const node = self.nodes[index];
        if (node.tag == tag) {
            self.collect(node.first, tag, items, count);
            self.collect(node.second, tag, items, count);
        } else {
            items[count.*] = index;
            count.* += 1;
        }
    }

    fn write(self: *const Tree, allocator: std.mem.Allocator, output: *std.ArrayList(u8), index: Index, root: bool) std.mem.Allocator.Error!void {
        const node = self.nodes[index];
        switch (node.tag) {
            .value => try number(allocator, output, node.value, node.unit),
            .sum, .product => {
                if (!root) try output.append(allocator, '(');
                var items: [max_nodes]Index = undefined;
                var count: usize = 0;
                self.collect(index, node.tag, &items, &count);
                var values = [_]?f64{null} ** std.meta.tags(Unit).len;
                for (items[0..count]) |item| {
                    const leaf = self.nodes[item];
                    if (leaf.tag != .value) continue;
                    if (node.tag == .product and leaf.unit != .number) continue;
                    const slot = &values[@intFromEnum(leaf.unit)];
                    slot.* = if (slot.*) |value| (if (node.tag == .sum) value + leaf.value else value * leaf.value) else leaf.value;
                }
                var written = false;
                // Unit order is number, percentage, then alphabetic dimensions.
                for (std.meta.tags(Unit)) |unit| if (values[@intFromEnum(unit)]) |value| {
                    if (written) try output.appendSlice(allocator, if (node.tag == .product) " * " else if (value < 0) " - " else " + ");
                    try number(allocator, output, if (written and node.tag == .sum) @abs(value) else value, unit);
                    written = true;
                };
                // Sort dimensional product leaves before unresolved functions.
                for (0..2) |pass| for (items[0..count]) |item| {
                    const child = self.nodes[item];
                    const dimensional = child.tag == .value and child.unit != .number;
                    if (child.tag == .value and (node.tag == .sum or child.unit == .number)) continue;
                    if ((pass == 0) != dimensional) continue;
                    const inverse = node.tag == .product and child.tag == .invert;
                    const negative = node.tag == .sum and child.tag == .negate;
                    if (written) try output.appendSlice(allocator, if (inverse) " / " else if (negative) " - " else if (node.tag == .product) " * " else " + ");
                    if (!written and inverse) try output.appendSlice(allocator, "1 / ");
                    if (!written and negative) try output.appendSlice(allocator, "-1 * ");
                    try self.write(allocator, output, if (inverse or negative) child.first else item, false);
                    written = true;
                };
                if (!root) try output.append(allocator, ')');
            },
            .negate, .invert => {
                if (!root) try output.append(allocator, '(');
                try output.appendSlice(allocator, if (node.tag == .negate) "-1 * " else "1 / ");
                try self.write(allocator, output, node.first, false);
                if (!root) try output.append(allocator, ')');
            },
            .min, .max, .clamp, .abs, .sign => {
                try output.appendSlice(allocator, @tagName(node.tag));
                try output.append(allocator, '(');
                var child = node.first;
                while (child != none) : (child = self.nodes[child].next) {
                    if (child != node.first) try output.appendSlice(allocator, ", ");
                    try self.write(allocator, output, child, true);
                }
                try output.append(allocator, ')');
            },
        }
    }
};
