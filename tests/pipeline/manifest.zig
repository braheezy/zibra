//! Portable inspection-pipeline fixtures and their exact text baselines.
//!
//! Layout and display-list cases intentionally contain no text, keeping their
//! geometry independent of platform font metrics.

pub const Mode = enum {
    style,
    layout,
    display_list,

    pub fn cliFlag(self: Mode) []const u8 {
        return switch (self) {
            .style => "--dump-style",
            .layout => "--dump-layout",
            .display_list => "--dump-display-list",
        };
    }
};

pub const Case = struct {
    name: []const u8,
    mode: Mode,
    fixture: []const u8,
    golden: []const u8,
};

pub const cases = [_]Case{
    .{
        .name = "box-model-style",
        .mode = .style,
        .fixture = "tests/pipeline/box-model.html",
        .golden = "tests/golden/pipeline/box-model.style.txt",
    },
    .{
        .name = "box-model-layout",
        .mode = .layout,
        .fixture = "tests/pipeline/box-model.html",
        .golden = "tests/golden/pipeline/box-model.layout.txt",
    },
    .{
        .name = "box-model-display-list",
        .mode = .display_list,
        .fixture = "tests/pipeline/box-model.html",
        .golden = "tests/golden/pipeline/box-model.display-list.txt",
    },
    .{
        .name = "css-zoom-style",
        .mode = .style,
        .fixture = "tests/pipeline/css-zoom.html",
        .golden = "tests/golden/pipeline/css-zoom.style.txt",
    },
    .{
        .name = "css-zoom-layout",
        .mode = .layout,
        .fixture = "tests/pipeline/css-zoom.html",
        .golden = "tests/golden/pipeline/css-zoom.layout.txt",
    },
    .{
        .name = "css-zoom-display-list",
        .mode = .display_list,
        .fixture = "tests/pipeline/css-zoom.html",
        .golden = "tests/golden/pipeline/css-zoom.display-list.txt",
    },
    .{
        .name = "table-format-layout",
        .mode = .layout,
        .fixture = "tests/pipeline/table-format.html",
        .golden = "tests/golden/pipeline/table-format.layout.txt",
    },
    .{
        .name = "table-format-display-list",
        .mode = .display_list,
        .fixture = "tests/pipeline/table-format.html",
        .golden = "tests/golden/pipeline/table-format.display-list.txt",
    },
};
