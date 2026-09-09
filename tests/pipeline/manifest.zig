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
    css_parser: ?[]const u8 = null,
    viewport: ?[]const u8 = null,
};

const existing_cases = [_]Case{
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
    .{
        .name = "html-table-sizing-layout",
        .mode = .layout,
        .fixture = "tests/pipeline/html-table-sizing.html",
        .golden = "tests/golden/pipeline/html-table-sizing.layout.txt",
    },
    .{
        .name = "float-paint-phases-layout",
        .mode = .layout,
        .fixture = "tests/pipeline/float-paint-phases.html",
        .golden = "tests/golden/pipeline/float-paint-phases.layout.txt",
    },
    .{
        .name = "float-paint-phases-display-list",
        .mode = .display_list,
        .fixture = "tests/pipeline/float-paint-phases.html",
        .golden = "tests/golden/pipeline/float-paint-phases.display-list.txt",
    },
    .{
        .name = "paint-order-phases-display-list",
        .mode = .display_list,
        .fixture = "tests/pipeline/paint-order-phases.html",
        .golden = "tests/golden/pipeline/paint-order-phases.display-list.txt",
    },
    .{
        .name = "margin-collapse-layout",
        .mode = .layout,
        .fixture = "tests/pipeline/margin-collapse.html",
        .golden = "tests/golden/pipeline/margin-collapse.layout.txt",
    },
    .{
        .name = "margin-collapse-display-list",
        .mode = .display_list,
        .fixture = "tests/pipeline/margin-collapse.html",
        .golden = "tests/golden/pipeline/margin-collapse.display-list.txt",
    },
    .{
        .name = "generated-pseudo-display-list",
        .mode = .display_list,
        .fixture = "tests/pipeline/generated-pseudo.html",
        .golden = "tests/golden/pipeline/generated-pseudo.display-list.txt",
    },
};

/// The same goldens cover both frontends. A difference remains a regression
/// until it has been diagnosed and justified against the fixture's semantics.
fn withTerence(comptime source: []const Case) [source.len]Case {
    var result: [source.len]Case = undefined;
    inline for (source, 0..) |case, index| {
        result[index] = case;
        result[index].name = "terence-" ++ case.name;
        result[index].css_parser = "terence";
    }
    return result;
}

const parity_cases = [_]Case{
    .{
        .name = "css-terence-parity-narrow-style",
        .mode = .style,
        .fixture = "tests/pipeline/css-terence-parity.html",
        .golden = "tests/golden/pipeline/css-terence-parity-narrow.style.txt",
        .css_parser = "legacy",
        .viewport = "320x300",
    },
    .{
        .name = "css-terence-parity-narrow-layout",
        .mode = .layout,
        .fixture = "tests/pipeline/css-terence-parity.html",
        .golden = "tests/golden/pipeline/css-terence-parity-narrow.layout.txt",
        .css_parser = "legacy",
        .viewport = "320x300",
    },
    .{
        .name = "css-terence-parity-narrow-display-list",
        .mode = .display_list,
        .fixture = "tests/pipeline/css-terence-parity.html",
        .golden = "tests/golden/pipeline/css-terence-parity-narrow.display-list.txt",
        .css_parser = "legacy",
        .viewport = "320x300",
    },
    .{
        .name = "css-terence-parity-wide-style",
        .mode = .style,
        .fixture = "tests/pipeline/css-terence-parity.html",
        .golden = "tests/golden/pipeline/css-terence-parity-wide.style.txt",
        .css_parser = "legacy",
        .viewport = "800x600",
    },
    .{
        .name = "css-terence-parity-wide-layout",
        .mode = .layout,
        .fixture = "tests/pipeline/css-terence-parity.html",
        .golden = "tests/golden/pipeline/css-terence-parity-wide.layout.txt",
        .css_parser = "legacy",
        .viewport = "800x600",
    },
    .{
        .name = "css-terence-parity-wide-display-list",
        .mode = .display_list,
        .fixture = "tests/pipeline/css-terence-parity.html",
        .golden = "tests/golden/pipeline/css-terence-parity-wide.display-list.txt",
        .css_parser = "legacy",
        .viewport = "800x600",
    },
};

const recovery_cases = [_]Case{
    .{
        .name = "css-terence-recovery-style",
        .mode = .style,
        .fixture = "tests/pipeline/css-terence-recovery.html",
        .golden = "tests/golden/pipeline/css-terence-recovery.style.txt",
        .css_parser = "terence",
        .viewport = "800x600",
    },
    .{
        .name = "css-terence-recovery-layout",
        .mode = .layout,
        .fixture = "tests/pipeline/css-terence-recovery.html",
        .golden = "tests/golden/pipeline/css-terence-recovery.layout.txt",
        .css_parser = "terence",
        .viewport = "800x600",
    },
    .{
        .name = "css-terence-recovery-display-list",
        .mode = .display_list,
        .fixture = "tests/pipeline/css-terence-recovery.html",
        .golden = "tests/golden/pipeline/css-terence-recovery.display-list.txt",
        .css_parser = "terence",
        .viewport = "800x600",
    },
};

pub const cases = existing_cases ++ withTerence(&existing_cases) ++
    parity_cases ++ withTerence(&parity_cases) ++ recovery_cases;
