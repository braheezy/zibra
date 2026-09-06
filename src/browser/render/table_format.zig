//! Scalar CSS-table formatting primitives for the bounded layout context.
//!
//! This module deliberately has no DOM, layout-object, or display-list
//! ownership. `layout.zig` owns the DOM-backed boxes and uses these helpers to
//! classify supported display roles and turn an already-normalized sequence of
//! rows and cells into column widths, row heights, and cell rectangles.
//!
//! The context currently supports separated, single-span cells. Captions,
//! columns, header/footer reordering, border collapse, border spacing, and vertical
//! alignment intentionally remain outside this owner until they have a
//! dedicated used-value contract. The inline-table display value also remains
//! unsupported until inline formatting can own an atomic table box.

const std = @import("std");

/// The CSS table roles understood by Zibra's bounded table formatter.
pub const Role = enum {
    ordinary,
    table,
    row_group,
    row,
    cell,
};

/// Classify one computed `display` value without allocating or retaining it.
pub fn roleForDisplay(raw_value: []const u8) Role {
    const value = std.mem.trim(u8, raw_value, " \t\r\n\x0c");
    if (std.ascii.eqlIgnoreCase(value, "table")) {
        return .table;
    }
    if (std.ascii.eqlIgnoreCase(value, "table-row")) return .row;
    if (std.ascii.eqlIgnoreCase(value, "table-row-group") or
        std.ascii.eqlIgnoreCase(value, "table-header-group") or
        std.ascii.eqlIgnoreCase(value, "table-footer-group")) return .row_group;
    if (std.ascii.eqlIgnoreCase(value, "table-cell")) return .cell;
    return .ordinary;
}

/// Table roles need retained block boxes even when their DOM children are
/// otherwise inline. This does not imply that an ordinary box is a cell.
pub fn establishesFormattingContext(role: Role) bool {
    return role != .ordinary;
}

/// One normalized logical row. `first_cell` and `cell_count` index a parallel
/// caller-owned `Cell` slice. The caller keeps the DOM/layout mapping.
pub const Row = struct {
    first_cell: usize,
    cell_count: usize,
};

/// Intrinsic metrics collected from one logical cell before grid placement.
/// Widths and heights are border-box sizes in layout coordinates.
pub const Cell = struct {
    min_width: ?i32 = null,
    preferred_width: i32 = 0,
    percentage: f64 = 0,
    constrained: bool = false,
    natural_height: i32 = 0,
};

const Track = struct { min: i32 = 0, max: i32 = 0, percentage: f64 = 0, constrained: bool = false };

fn trackFor(rows: []const Row, cells: []const Cell, column: usize) Track {
    var track = Track{};
    for (rows) |row| {
        if (column >= row.cell_count) continue;
        const cell = cells[row.first_cell + column];
        track.min = @max(track.min, @max(cell.min_width orelse cell.preferred_width, 0));
        track.max = @max(track.max, @max(cell.preferred_width, track.min));
        track.constrained = track.constrained or cell.constrained;
        if (std.math.isFinite(cell.percentage)) track.percentage = @max(track.percentage, @max(cell.percentage, 0));
    }
    track.max = @max(track.max, track.min);
    return track;
}

fn pixels(value: f64) i32 {
    return @intFromFloat(@min(@max(@ceil(value), 0), @as(f64, @floatFromInt(std.math.maxInt(i32)))));
}

/// Automatic single-span sizing. Intrinsic min-content is a hard floor;
/// preferred widths and percentages are constraints, never a viewport basis
/// recursively substituted into the table's own intrinsic measurements.
/// `requested` is the table's definite content width, when specified.
pub fn resolveWidths(rows: []const Row, cells: []const Cell, available: i32, requested: ?i32, columns: []i32) i32 {
    std.debug.assert(columns.len == columnCount(rows));
    var minimum: i32 = 0;
    var preferred: i32 = 0;
    var percentage_sum: f64 = 0;
    var nonpercentage_preferred: i32 = 0;
    for (columns, 0..) |*width, index| {
        const track = trackFor(rows, cells, index);
        width.* = track.min;
        minimum +|= track.min;
        preferred +|= track.max;
        percentage_sum += @min(track.percentage, 1);
        if (track.percentage == 0) nonpercentage_preferred +|= track.max;
    }
    var percentage_preferred = preferred;
    for (columns, 0..) |_, index| {
        const track = trackFor(rows, cells, index);
        if (track.percentage > 0) percentage_preferred = @max(percentage_preferred, pixels(@as(f64, @floatFromInt(track.max)) / track.percentage));
    }
    if (percentage_sum > 0 and percentage_sum < 1) {
        percentage_preferred = @max(percentage_preferred, pixels(@as(f64, @floatFromInt(nonpercentage_preferred)) / (1 - percentage_sum)));
    }
    const used = if (requested) |width| @max(width, minimum) else @max(minimum, @min(@max(available, 0), percentage_preferred));
    var remaining = used -| minimum;
    // Honor percentage columns before growing ordinary columns toward their
    // max-content widths. The minimum floors survive over-constrained tables.
    for (0..2) |stage| {
        var demand: i64 = 0;
        for (columns, 0..) |width, index| {
            const track = trackFor(rows, cells, index);
            const target = if (stage == 0)
                if (track.percentage > 0) pixels(@as(f64, @floatFromInt(used)) * track.percentage) else width
            else if (track.percentage == 0) track.max else width;
            demand += @max(target -| width, 0);
        }
        const budget = @min(@as(i64, remaining), demand);
        var allocated: i64 = 0;
        var cumulative: i64 = 0;
        for (columns, 0..) |*width, index| {
            const track = trackFor(rows, cells, index);
            const target = if (stage == 0)
                if (track.percentage > 0) pixels(@as(f64, @floatFromInt(used)) * track.percentage) else width.*
            else if (track.percentage == 0) track.max else width.*;
            cumulative += @max(target -| width.*, 0);
            const next = if (demand > 0) @divFloor(budget * cumulative, demand) else 0;
            width.* +|= @intCast(next - allocated);
            allocated = next;
        }
        remaining -= @intCast(allocated);
    }
    var recipients: i32 = 0;
    for (columns, 0..) |_, index| if (trackFor(rows, cells, index).percentage == 0) {
        if (!trackFor(rows, cells, index).constrained) recipients += 1;
    };
    const include_constrained = recipients == 0;
    if (include_constrained) for (columns, 0..) |_, index| {
        if (trackFor(rows, cells, index).percentage == 0) recipients += 1;
    };
    const all = recipients == 0;
    if (all) recipients = @intCast(columns.len);
    for (columns, 0..) |*width, index| {
        if (recipients == 0) break;
        if (!all and trackFor(rows, cells, index).percentage != 0) continue;
        if (!all and !include_constrained and trackFor(rows, cells, index).constrained) continue;
        const share = @divTrunc(remaining, recipients) + @as(i32, if (@mod(remaining, recipients) != 0) 1 else 0);
        width.* +|= share;
        remaining -= share;
        recipients -= 1;
    }
    return used;
}

/// One resolved table-cell border box in layout coordinates.
pub const CellRect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

/// Return the number of columns required by a normalized row sequence.
pub fn columnCount(rows: []const Row) usize {
    var result: usize = 0;
    for (rows) |row| result = @max(result, row.cell_count);
    return result;
}

/// Resolve a row's used height as the tallest cell in that row. The caller
/// applies the returned height to every cell in the row, which provides the
/// required table-cell stretch without reparenting DOM nodes.
pub fn resolveRowHeights(
    rows: []const Row,
    cells: []const Cell,
    row_heights: []i32,
) i32 {
    std.debug.assert(row_heights.len == rows.len);
    var total: i32 = 0;
    for (rows, row_heights) |row, *height| {
        std.debug.assert(row.first_cell <= cells.len);
        std.debug.assert(row.cell_count <= cells.len - row.first_cell);
        height.* = 0;
        for (cells[row.first_cell .. row.first_cell + row.cell_count]) |cell| {
            height.* = @max(height.*, @max(cell.natural_height, 0));
        }
        total +|= height.*;
    }
    return total;
}

/// Return a cell rectangle after the caller has resolved column and row
/// metrics. This is intentionally O(columns + rows); bounded tables are small
/// and the simple interface keeps the module allocation-free.
pub fn cellRect(
    table_x: i32,
    table_y: i32,
    rows: []const Row,
    columns: []const i32,
    row_heights: []const i32,
    row_index: usize,
    column_index: usize,
) CellRect {
    std.debug.assert(row_index < rows.len);
    std.debug.assert(column_index < rows[row_index].cell_count);
    std.debug.assert(row_heights.len == rows.len);
    std.debug.assert(column_index < columns.len);

    var x = table_x;
    for (columns[0..column_index]) |width| x +|= @max(width, 0);
    var y = table_y;
    for (row_heights[0..row_index]) |height| y +|= @max(height, 0);
    return .{
        .x = x,
        .y = y,
        .width = @max(columns[column_index], 0),
        .height = @max(row_heights[row_index], 0),
    };
}

test "automatic table widths account for content percentage constraints and available space" {
    const rows = [_]Row{.{ .first_cell = 0, .cell_count = 3 }};
    const cells = [_]Cell{
        .{ .min_width = 4, .preferred_width = 4, .percentage = 0.25 },
        .{ .min_width = 510, .preferred_width = 510 },
        .{ .min_width = 100, .preferred_width = 100, .percentage = 0.25 },
    };
    var columns: [3]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 1020), resolveWidths(&rows, &cells, 1600, null, &columns));
    try std.testing.expectEqualSlices(i32, &.{ 255, 510, 255 }, &columns);
    try std.testing.expectEqual(@as(i32, 800), resolveWidths(&rows, &cells, 800, null, &columns));
    try std.testing.expectEqual(@as(i32, 800), columns[0] + columns[1] + columns[2]);
    try std.testing.expect(columns[0] >= 4 and columns[1] >= 510 and columns[2] >= 100);
    try std.testing.expectEqual(@as(i32, 614), resolveWidths(&rows, &cells, 400, 0, &columns));
}

test "automatic table columns interpolate between min and max content" {
    const rows = [_]Row{.{ .first_cell = 0, .cell_count = 2 }};
    const cells = [_]Cell{ .{ .min_width = 20, .preferred_width = 100 }, .{ .min_width = 40, .preferred_width = 200 } };
    var columns: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 150), resolveWidths(&rows, &cells, 150, null, &columns));
    try std.testing.expectEqualSlices(i32, &.{ 50, 100 }, &columns);
    try std.testing.expectEqual(@as(i32, 300), resolveWidths(&rows, &cells, 600, null, &columns));
    try std.testing.expectEqual(@as(i32, 400), resolveWidths(&rows, &cells, 600, 400, &columns));
}

test "automatic table surplus prefers unconstrained columns" {
    const rows = [_]Row{.{ .first_cell = 0, .cell_count = 2 }};
    const cells = [_]Cell{
        .{ .min_width = 100, .preferred_width = 100, .constrained = true },
        .{ .min_width = 10, .preferred_width = 20 },
    };
    var columns: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 400), resolveWidths(&rows, &cells, 800, 400, &columns));
    try std.testing.expectEqualSlices(i32, &.{ 100, 300 }, &columns);
}

test "table roles classify supported display values" {
    try std.testing.expectEqual(Role.table, roleForDisplay(" table "));
    try std.testing.expectEqual(Role.ordinary, roleForDisplay("inline-table"));
    try std.testing.expectEqual(Role.row, roleForDisplay("table-row"));
    try std.testing.expectEqual(Role.cell, roleForDisplay("table-cell"));
    try std.testing.expectEqual(Role.ordinary, roleForDisplay("list-item"));
    try std.testing.expect(establishesFormattingContext(.cell));
    try std.testing.expect(!establishesFormattingContext(.ordinary));
}

test "table grid uses preferred tracks and stretches short cells" {
    const rows = [_]Row{
        .{ .first_cell = 0, .cell_count = 4 },
        .{ .first_cell = 4, .cell_count = 2 },
    };
    const cells = [_]Cell{
        .{ .preferred_width = 11, .natural_height = 13 },
        .{ .preferred_width = 17, .natural_height = 13 },
        .{ .preferred_width = 19, .natural_height = 5 },
        .{ .preferred_width = 23, .natural_height = 13 },
        .{ .preferred_width = 7, .natural_height = 9 },
        .{ .preferred_width = 31, .natural_height = 11 },
    };
    var columns: [4]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 84), resolveWidths(&rows, &cells, 0, 0, &columns));
    try std.testing.expectEqualSlices(i32, &.{ 11, 31, 19, 23 }, &columns);

    var heights: [2]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 24), resolveRowHeights(&rows, &cells, &heights));
    try std.testing.expectEqualSlices(i32, &.{ 13, 11 }, &heights);
    try std.testing.expectEqual(
        CellRect{ .x = 54, .y = 40, .width = 19, .height = 13 },
        cellRect(12, 40, &rows, &columns, &heights, 0, 2),
    );
    try std.testing.expectEqual(
        CellRect{ .x = 23, .y = 53, .width = 31, .height = 11 },
        cellRect(12, 40, &rows, &columns, &heights, 1, 1),
    );
}

test "authored table width shares extra space across columns" {
    const rows = [_]Row{.{ .first_cell = 0, .cell_count = 3 }};
    const cells = [_]Cell{
        .{ .preferred_width = 10 },
        .{ .preferred_width = 20 },
        .{ .preferred_width = 30 },
    };
    var columns: [3]i32 = undefined;
    try std.testing.expectEqual(@as(i32, 70), resolveWidths(&rows, &cells, 70, 70, &columns));
    try std.testing.expectEqualSlices(i32, &.{ 14, 23, 33 }, &columns);
}
