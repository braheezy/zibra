//! Scalar CSS-table formatting primitives for the bounded layout context.
//!
//! This module deliberately has no DOM, layout-object, or display-list
//! ownership. `layout.zig` owns the DOM-backed boxes and uses these helpers to
//! classify supported display roles and turn an already-normalized sequence of
//! rows and cells into column widths, row heights, and cell rectangles.
//!
//! The context currently supports separated, single-span cells. Captions,
//! columns, row groups, border collapse, border spacing, and vertical
//! alignment intentionally remain outside this owner until they have a
//! dedicated used-value contract. The inline-table display value also remains
//! unsupported until inline formatting can own an atomic table box.

const std = @import("std");

/// The CSS table roles understood by Zibra's bounded table formatter.
pub const Role = enum {
    ordinary,
    table,
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
    preferred_width: i32 = 0,
    natural_height: i32 = 0,
};

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

/// Resolve single-span column widths. `columns` must have exactly
/// `columnCount(rows)` slots. An authored table width expands columns evenly;
/// an undersized authored width cannot shrink a column below its preferred
/// width.
pub fn resolveColumnWidths(
    rows: []const Row,
    cells: []const Cell,
    requested_width: i32,
    columns: []i32,
) i32 {
    std.debug.assert(columns.len == columnCount(rows));
    @memset(columns, 0);

    for (rows) |row| {
        std.debug.assert(row.first_cell <= cells.len);
        std.debug.assert(row.cell_count <= cells.len - row.first_cell);
        for (0..row.cell_count) |column| {
            const preferred = @max(cells[row.first_cell + column].preferred_width, 0);
            columns[column] = @max(columns[column], preferred);
        }
    }

    var intrinsic_width: i32 = 0;
    for (columns) |width| intrinsic_width +|= width;
    const used_width = @max(intrinsic_width, @max(requested_width, 0));
    const extra = used_width -| intrinsic_width;
    if (columns.len == 0 or extra == 0) return used_width;

    const divisor: i32 = @intCast(columns.len);
    const share = @divFloor(extra, divisor);
    var remainder: usize = @intCast(@mod(extra, divisor));
    for (columns) |*width| {
        width.* +|= share;
        if (remainder > 0) {
            width.* +|= 1;
            remainder -= 1;
        }
    }
    return used_width;
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
    try std.testing.expectEqual(@as(i32, 84), resolveColumnWidths(&rows, &cells, 0, &columns));
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
    try std.testing.expectEqual(@as(i32, 70), resolveColumnWidths(&rows, &cells, 70, &columns));
    try std.testing.expectEqualSlices(i32, &.{ 14, 23, 33 }, &columns);
}
