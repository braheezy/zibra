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
    viewport: ?[]const u8 = null,
};

const existing_cases = [_]Case{
    .{
        .name = "css-nested-sizing-layout",
        .mode = .layout,
        .fixture = "tests/pipeline/css-nested-sizing.html",
        .golden = "tests/golden/pipeline/css-nested-sizing.layout.txt",
    },
    .{
        .name = "css-nested-sizing-display-list",
        .mode = .display_list,
        .fixture = "tests/pipeline/css-nested-sizing.html",
        .golden = "tests/golden/pipeline/css-nested-sizing.display-list.txt",
    },
    .{
        .name = "css-shared-sizing-layout",
        .mode = .layout,
        .fixture = "tests/pipeline/css-shared-sizing.html",
        .golden = "tests/golden/pipeline/css-shared-sizing.layout.txt",
    },
    .{
        .name = "css-block-aspect-ratio-layout",
        .mode = .layout,
        .fixture = "tests/pipeline/css-block-aspect-ratio.html",
        .golden = "tests/golden/pipeline/css-block-aspect-ratio.layout.txt",
    },
    .{
        .name = "css-cascade-layers-narrow-display-list",
        .mode = .display_list,
        .fixture = "tests/pipeline/css-cascade-layers.html",
        .golden = "tests/golden/pipeline/css-cascade-layers-narrow.display-list.txt",
        .viewport = "400x400",
    },
    .{
        .name = "css-cascade-layers-wide-display-list",
        .mode = .display_list,
        .fixture = "tests/pipeline/css-cascade-layers.html",
        .golden = "tests/golden/pipeline/css-cascade-layers-wide.display-list.txt",
        .viewport = "800x600",
    },
    .{
        .name = "css-stylesheet-media-narrow-layout",
        .mode = .layout,
        .fixture = "tests/pipeline/css-stylesheet-media.html",
        .golden = "tests/golden/pipeline/css-stylesheet-media-narrow.layout.txt",
        .viewport = "400x400",
    },
    .{
        .name = "css-stylesheet-media-wide-layout",
        .mode = .layout,
        .fixture = "tests/pipeline/css-stylesheet-media.html",
        .golden = "tests/golden/pipeline/css-stylesheet-media-wide.layout.txt",
        .viewport = "800x600",
    },
    .{
        .name = "css-linear-gradients-display-list",
        .mode = .display_list,
        .fixture = "tests/pipeline/css-linear-gradients.html",
        .golden = "tests/golden/pipeline/css-linear-gradients.display-list.txt",
    },
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

/// Cascade and conditional media behavior at narrow and wide viewports.
const cascade_cases = [_]Case{
    .{
        .name = "css-cascade-narrow-style",
        .mode = .style,
        .fixture = "tests/pipeline/css-cascade.html",
        .golden = "tests/golden/pipeline/css-cascade-narrow.style.txt",
        .viewport = "320x300",
    },
    .{
        .name = "css-cascade-narrow-layout",
        .mode = .layout,
        .fixture = "tests/pipeline/css-cascade.html",
        .golden = "tests/golden/pipeline/css-cascade-narrow.layout.txt",
        .viewport = "320x300",
    },
    .{
        .name = "css-cascade-narrow-display-list",
        .mode = .display_list,
        .fixture = "tests/pipeline/css-cascade.html",
        .golden = "tests/golden/pipeline/css-cascade-narrow.display-list.txt",
        .viewport = "320x300",
    },
    .{
        .name = "css-cascade-wide-style",
        .mode = .style,
        .fixture = "tests/pipeline/css-cascade.html",
        .golden = "tests/golden/pipeline/css-cascade-wide.style.txt",
        .viewport = "800x600",
    },
    .{
        .name = "css-cascade-wide-layout",
        .mode = .layout,
        .fixture = "tests/pipeline/css-cascade.html",
        .golden = "tests/golden/pipeline/css-cascade-wide.layout.txt",
        .viewport = "800x600",
    },
    .{
        .name = "css-cascade-wide-display-list",
        .mode = .display_list,
        .fixture = "tests/pipeline/css-cascade.html",
        .golden = "tests/golden/pipeline/css-cascade-wide.display-list.txt",
        .viewport = "800x600",
    },
};

const recovery_cases = [_]Case{
    .{ .name = "css-recovery-style", .mode = .style, .fixture = "tests/manual/css-recovery.html", .golden = "tests/golden/pipeline/css-recovery.style.txt" },
    .{ .name = "css-recovery-layout", .mode = .layout, .fixture = "tests/manual/css-recovery.html", .golden = "tests/golden/pipeline/css-recovery.layout.txt" },
    .{ .name = "css-recovery-display-list", .mode = .display_list, .fixture = "tests/manual/css-recovery.html", .golden = "tests/golden/pipeline/css-recovery.display-list.txt" },
};

pub const cases = existing_cases ++ cascade_cases ++ recovery_cases;
