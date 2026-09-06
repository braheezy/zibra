//! Bounded SVG number/path grammar translated into borrowed z2d contexts.
//! No source slices or drawing state survive the synchronous append call.

const std = @import("std");
const z2d = @import("z2d");

pub const Numbers = struct {
    source: []const u8,
    pos: usize = 0,

    pub fn whitespace(self: *Numbers) void {
        while (self.pos < self.source.len and std.ascii.isWhitespace(self.source[self.pos])) : (self.pos += 1) {}
    }

    pub fn done(self: *Numbers) bool {
        self.whitespace();
        return self.pos == self.source.len;
    }

    fn separator(self: *Numbers) void {
        self.whitespace();
        if (self.pos < self.source.len and self.source[self.pos] == ',') self.pos += 1;
        self.whitespace();
    }

    /// Read one finite, bounded SVG number, including compact signs/exponents.
    pub fn number(self: *Numbers) !f64 {
        self.separator();
        const start = self.pos;
        if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) self.pos += 1;
        var digits: usize = 0;
        while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) : (self.pos += 1) digits += 1;
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            self.pos += 1;
            while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) : (self.pos += 1) digits += 1;
        }
        if (digits == 0) return error.InvalidSvgNumber;
        if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) self.pos += 1;
            const exponent = self.pos;
            while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) : (self.pos += 1) {}
            if (exponent == self.pos) return error.InvalidSvgNumber;
        }
        const value = std.fmt.parseFloat(f64, self.source[start..self.pos]) catch return error.InvalidSvgNumber;
        if (!std.math.isFinite(value) or @abs(value) > 1e6) return error.InvalidSvgNumber;
        return value;
    }

    fn flag(self: *Numbers) !bool {
        self.separator();
        if (self.pos == self.source.len) return error.InvalidSvgPath;
        const c = self.source[self.pos];
        if (c != '0' and c != '1') return error.InvalidSvgPath;
        self.pos += 1;
        return c == '1';
    }
};

const Point = struct {
    x: f64 = 0,
    y: f64 = 0,

    fn read(numbers: *Numbers, origin: Point) !Point {
        const result = Point{ .x = origin.x + try numbers.number(), .y = origin.y + try numbers.number() };
        if (@abs(result.x) > 1e6 or @abs(result.y) > 1e6) return error.InvalidSvgPath;
        return result;
    }

    fn reflected(self: Point, around: Point) Point {
        return .{ .x = 2 * around.x - self.x, .y = 2 * around.y - self.y };
    }
};

/// Append an SVG path. Fill mode closes each open subpath independently;
/// stroke mode preserves authored open ends and caps. The context owns nodes.
pub fn append(context: *z2d.Context, source: []const u8, fill: bool) !void {
    var numbers = Numbers{ .source = source };
    var current = Point{};
    var start = Point{};
    var control = Point{};
    var previous: u8 = 0;
    var command: u8 = 0;
    var open = false;
    var count: usize = 0;
    while (!numbers.done()) {
        count += 1;
        if (count > 32768) return error.SvgTooComplex;
        if (std.ascii.isAlphabetic(source[numbers.pos])) {
            command = source[numbers.pos];
            numbers.pos += 1;
        } else if (command == 0) return error.InvalidSvgPath;
        const op = std.ascii.toUpper(command);
        if (previous == 0 and op != 'M') return error.InvalidSvgPath;
        const origin = if (std.ascii.isLower(command)) current else Point{};
        switch (op) {
            'M' => {
                if (fill and open) try context.closePath();
                current = try Point.read(&numbers, origin);
                try context.moveTo(current.x, current.y);
                start = current;
                open = true;
                command = if (command == 'm') 'l' else 'L';
            },
            'L', 'H', 'V' => {
                current = switch (op) {
                    'H' => .{ .x = origin.x + try numbers.number(), .y = current.y },
                    'V' => .{ .x = current.x, .y = origin.y + try numbers.number() },
                    else => try Point.read(&numbers, origin),
                };
                try context.lineTo(current.x, current.y);
                open = true;
            },
            'C', 'S' => {
                const first = if (op == 'C') try Point.read(&numbers, origin) else if (previous == 'C' or previous == 'S') control.reflected(current) else current;
                control = try Point.read(&numbers, origin);
                current = try Point.read(&numbers, origin);
                try context.curveTo(first.x, first.y, control.x, control.y, current.x, current.y);
                open = true;
            },
            'Q', 'T' => {
                control = if (op == 'Q') try Point.read(&numbers, origin) else if (previous == 'Q' or previous == 'T') control.reflected(current) else current;
                const end = try Point.read(&numbers, origin);
                try context.curveTo(
                    current.x + (control.x - current.x) * 2 / 3,
                    current.y + (control.y - current.y) * 2 / 3,
                    end.x + (control.x - end.x) * 2 / 3,
                    end.y + (control.y - end.y) * 2 / 3,
                    end.x,
                    end.y,
                );
                current = end;
                open = true;
            },
            'A' => {
                const rx = try numbers.number();
                const ry = try numbers.number();
                const rotation = try numbers.number();
                const large = try numbers.flag();
                const sweep = try numbers.flag();
                const end = try Point.read(&numbers, origin);
                try arc(context, current, end, rx, ry, rotation, large, sweep);
                current = end;
                open = true;
            },
            'Z' => {
                try context.closePath();
                current = start;
                open = false;
                command = 0;
            },
            else => return error.InvalidSvgPath,
        }
        if (@abs(current.x) > 1e6 or @abs(current.y) > 1e6) return error.InvalidSvgPath;
        previous = op;
    }
    if (fill and open) try context.closePath();
}

// SVG endpoint-to-center conversion, then cubic segments of at most 90°.
fn arc(context: *z2d.Context, start: Point, end: Point, radius_x: f64, radius_y: f64, rotation: f64, large: bool, sweep: bool) !void {
    if (start.x == end.x and start.y == end.y) return;
    var rx = @abs(radius_x);
    var ry = @abs(radius_y);
    if (rx < 1e-10 or ry < 1e-10) return context.lineTo(end.x, end.y);
    const phi = rotation * std.math.pi / 180;
    const cos = @cos(phi);
    const sin = @sin(phi);
    const dx = (start.x - end.x) / 2;
    const dy = (start.y - end.y) / 2;
    if (@abs(dx) < 1e-10 and @abs(dy) < 1e-10) return context.lineTo(end.x, end.y);
    const xp = cos * dx + sin * dy;
    const yp = -sin * dx + cos * dy;
    const scale = xp * xp / (rx * rx) + yp * yp / (ry * ry);
    if (scale > 1) {
        rx *= @sqrt(scale);
        ry *= @sqrt(scale);
    }
    const denominator = rx * rx * yp * yp + ry * ry * xp * xp;
    const numerator = @max(0, rx * rx * ry * ry - denominator);
    const factor = (if (large == sweep) @as(f64, -1) else 1) * @sqrt(numerator / denominator);
    const cxp = factor * rx * yp / ry;
    const cyp = -factor * ry * xp / rx;
    const center = Point{
        .x = cos * cxp - sin * cyp + (start.x + end.x) / 2,
        .y = sin * cxp + cos * cyp + (start.y + end.y) / 2,
    };
    const ux = (xp - cxp) / rx;
    const uy = (yp - cyp) / ry;
    const vx = (-xp - cxp) / rx;
    const vy = (-yp - cyp) / ry;
    var angle = std.math.atan2(uy, ux);
    var delta = std.math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
    if (sweep and delta < 0) delta += 2 * std.math.pi;
    if (!sweep and delta > 0) delta -= 2 * std.math.pi;
    const segments: usize = @intFromFloat(@max(1, @ceil(@abs(delta) / (std.math.pi / 2.0))));
    const step = delta / @as(f64, @floatFromInt(segments));
    for (0..segments) |_| {
        const next = angle + step;
        const k = 4.0 / 3.0 * @tan(step / 4);
        const p1 = ellipsePoint(center, rx, ry, cos, sin, @cos(angle) - k * @sin(angle), @sin(angle) + k * @cos(angle));
        const p2 = ellipsePoint(center, rx, ry, cos, sin, @cos(next) + k * @sin(next), @sin(next) - k * @cos(next));
        const p3 = ellipsePoint(center, rx, ry, cos, sin, @cos(next), @sin(next));
        try context.curveTo(p1.x, p1.y, p2.x, p2.y, p3.x, p3.y);
        angle = next;
    }
}

fn ellipsePoint(center: Point, rx: f64, ry: f64, cos: f64, sin: f64, x: f64, y: f64) Point {
    return .{ .x = center.x + cos * rx * x - sin * ry * y, .y = center.y + sin * rx * x + cos * ry * y };
}
