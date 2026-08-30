//! Build, run, unit-test, WPT, and windowless screenshot steps for Zibra.

const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl");
const pipeline_manifest = @import("tests/pipeline/manifest.zig");

const UnitTestSuite = struct {
    step_name: []const u8,
    description: []const u8,
    root_source_file: []const u8,
    dependencies: Dependencies,
    comprehensive: bool = false,

    const Dependencies = enum {
        document,
        network,
        script,
        full,
    };
};

const unit_test_suites = [_]UnitTestSuite{
    .{
        .step_name = "test",
        .description = "Run the comprehensive unit-test suite",
        .root_source_file = "src/test_root.zig",
        .dependencies = .full,
        .comprehensive = true,
    },
    .{
        .step_name = "test-document",
        .description = "Run focused document, HTML, and CSS unit tests",
        .root_source_file = "src/test_document.zig",
        .dependencies = .document,
    },
    .{
        .step_name = "test-render",
        .description = "Run focused layout, paint, and compositing unit tests",
        .root_source_file = "src/test_render.zig",
        .dependencies = .full,
    },
    .{
        .step_name = "test-network",
        .description = "Run focused URL, HTTP, cookie, and cache unit tests",
        .root_source_file = "src/test_network.zig",
        .dependencies = .network,
    },
    .{
        .step_name = "test-script",
        .description = "Run focused JavaScript host and DOM API unit tests",
        .root_source_file = "src/test_script.zig",
        .dependencies = .script,
    },
    .{
        .step_name = "test-browser",
        .description = "Run focused browser, tab, input, and worker unit tests",
        .root_source_file = "src/test_browser.zig",
        .dependencies = .full,
    },
};

const DumpDomInput = union(enum) {
    argument: []const u8,
    file: []const u8,
};

const DumpDomFixture = struct {
    input: DumpDomInput,
    golden: []const u8,
    output_basename: []const u8,
};

const dump_dom_fixtures = [_]DumpDomFixture{
    .{
        .input = .{ .file = "tests/manual/dump-dom.html" },
        .golden = "tests/golden/dump-dom.txt",
        .output_basename = "dump-dom.txt",
    },
    .{
        .input = .{ .argument = "about:blank" },
        .golden = "tests/golden/about-blank-dom.txt",
        .output_basename = "about-blank-dom.txt",
    },
    .{
        .input = .{ .argument = "http://[" },
        .golden = "tests/golden/about-blank-dom.txt",
        .output_basename = "malformed-url-dom.txt",
    },
    .{
        .input = .{ .argument = "mailto:test@example.com" },
        .golden = "tests/golden/about-blank-dom.txt",
        .output_basename = "unsupported-scheme-dom.txt",
    },
};

const ScreenshotFixture = struct {
    input_prefix: []const u8 = "file://",
    fixture: []const u8,
    golden: []const u8,
    output_basename: []const u8,
};

const screenshot_fixtures = [_]ScreenshotFixture{
    .{
        .fixture = "tests/manual/native-screenshot.html",
        .golden = "tests/golden/native-screenshot.macos.png",
        .output_basename = "native-screenshot.png",
    },
    .{
        .input_prefix = "view-source:file://",
        .fixture = "tests/manual/view-source.html",
        .golden = "tests/golden/view-source.macos.png",
        .output_basename = "view-source-screenshot.png",
    },
    .{
        .fixture = "tests/manual/scrollbar.html",
        .golden = "tests/golden/scrollbar.macos.png",
        .output_basename = "scrollbar-screenshot.png",
    },
    .{
        .fixture = "tests/manual/emoji.html",
        .golden = "tests/golden/emoji.macos.png",
        .output_basename = "emoji-screenshot.png",
    },
    .{
        .fixture = "tests/manual/alternate-text-direction.html",
        .golden = "tests/golden/alternate-text-direction.macos.png",
        .output_basename = "alternate-text-direction-screenshot.png",
    },
    .{
        .fixture = "tests/manual/centered-title.html",
        .golden = "tests/golden/centered-title.macos.png",
        .output_basename = "centered-title-screenshot.png",
    },
    .{
        .fixture = "tests/manual/superscript.html",
        .golden = "tests/golden/superscript.macos.png",
        .output_basename = "superscript-screenshot.png",
    },
    .{
        .fixture = "tests/manual/soft-hyphens.html",
        .golden = "tests/golden/soft-hyphens.macos.png",
        .output_basename = "soft-hyphens-screenshot.png",
    },
    .{
        .fixture = "tests/manual/small-caps.html",
        .golden = "tests/golden/small-caps.macos.png",
        .output_basename = "small-caps-screenshot.png",
    },
    .{
        .fixture = "tests/manual/preformatted.html",
        .golden = "tests/golden/preformatted.macos.png",
        .output_basename = "preformatted-screenshot.png",
    },
};

const WptFixture = struct {
    fixture: []const u8,
    status: []const u8,
    timeout_ms: u64,
    output_basename: []const u8,
};

const wpt_fixtures = [_]WptFixture{
    .{
        .fixture = "tests/wpt/fixtures/harness-pass.html",
        .status = "PASS",
        .timeout_ms = 10_000,
        .output_basename = "wpt-harness-pass.jsonl",
    },
    .{
        .fixture = "tests/wpt/fixtures/harness-promise-microtask-pass.html",
        .status = "PASS",
        .timeout_ms = 10_000,
        .output_basename = "wpt-harness-promise-microtask-pass.jsonl",
    },
    .{
        .fixture = "tests/wpt/fixtures/harness-timeout.html",
        .status = "TIMEOUT",
        .timeout_ms = 20,
        .output_basename = "wpt-harness-timeout.jsonl",
    },
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const io = b.graph.io;
    // Zig 0.16's default backend can crash while compiling Zibra on Linux.
    // Prefer the LLVM backend there until the compiler issue is resolved.
    const use_llvm = builtin.os.tag == .linux or builtin.os.tag == .macos;

    const sdk = sdl.init(b, .{});
    const sdl_mod = sdk.getWrapperModule();

    const source_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    source_module.addImport("sdl", sdl_mod);

    const exe = b.addExecutable(.{
        .name = "zibra",
        .root_module = source_module,
        .use_llvm = use_llvm,
    });

    // SDL2_ttf uses SDL2, but does not make SDL2's symbols available to this
    // executable on every linker/platform. Link both libraries explicitly.
    sdk.link(io, exe, .static, sdl.Library.SDL2);
    sdk.link(io, exe, .static, sdl.Library.SDL2_ttf);
    b.installArtifact(exe);

    const zg = b.dependency("zg", .{});
    source_module.addImport("grapheme", zg.module("Graphemes"));
    source_module.addImport("emoji", zg.module("Emoji"));
    source_module.addImport("code_point", zg.module("code_point"));

    const ada_dep = b.dependency("adazig", .{
        .target = target,
        .optimize = optimize,
    });
    source_module.addImport("ada", ada_dep.module("ada"));

    const z2d_dep = b.dependency("z2d", .{});
    source_module.addImport("z2d", z2d_dep.module("z2d"));

    const kiesel_dep = b.dependency("kiesel", .{
        .target = target,
        .optimize = optimize,
        .@"enable-temporal" = false,
        .@"enable-intl" = false,
    });
    source_module.addImport("kiesel", kiesel_dep.module("kiesel"));

    // Match Kiesel's bdwgc dependency options exactly. Zig then reuses the
    // same dependency instance instead of linking a second collector.
    const bdwgc_cflags = if (optimize == .Debug)
        "-DNO_MSGBOX_ON_ERROR"
    else
        "-DNO_MSGBOX_ON_ERROR -DNO_GETENV";
    const enable_nan_boxing = switch (target.result.cpu.arch) {
        .x86_64, .aarch64 => true,
        else => false,
    };
    const bdwgc_dep = b.dependency("bdwgc_zig", .{
        .target = target,
        .optimize = optimize,
        .linkage = .static,
        .CFLAGS_EXTRA = bdwgc_cflags,
        .enable_gcj_support = false,
        .enable_java_finalization = false,
        .enable_large_config = true,
        .enable_gc_dump = false,
        .enable_dynamic_pointer_mask = enable_nan_boxing,
    });
    source_module.addImport("bdwgc", bdwgc_dep.module("bdwgc"));

    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });
    source_module.addImport("zigimg", zigimg_dep.module("zigimg"));

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    var comprehensive_unit_tests: *std.Build.Step = undefined;
    var focused_test_compilations: [unit_test_suites.len - 1]*std.Build.Step = undefined;
    var focused_test_index: usize = 0;
    for (unit_test_suites) |suite| {
        const suite_step = b.step(suite.step_name, suite.description);
        const test_module = b.createModule(.{
            .root_source_file = b.path(suite.root_source_file),
            .target = target,
            .optimize = optimize,
        });
        switch (suite.dependencies) {
            .document => {
                test_module.addImport("z2d", z2d_dep.module("z2d"));
                test_module.addImport("zigimg", zigimg_dep.module("zigimg"));
            },
            .network => {
                test_module.addImport("ada", ada_dep.module("ada"));
            },
            .script => {
                test_module.addImport("z2d", z2d_dep.module("z2d"));
                test_module.addImport("kiesel", kiesel_dep.module("kiesel"));
                test_module.addImport("bdwgc", bdwgc_dep.module("bdwgc"));
                test_module.addImport("zigimg", zigimg_dep.module("zigimg"));
            },
            .full => {
                test_module.addImport("sdl", sdl_mod);
                test_module.addImport("grapheme", zg.module("Graphemes"));
                test_module.addImport("emoji", zg.module("Emoji"));
                test_module.addImport("code_point", zg.module("code_point"));
                test_module.addImport("z2d", z2d_dep.module("z2d"));
                test_module.addImport("kiesel", kiesel_dep.module("kiesel"));
                test_module.addImport("bdwgc", bdwgc_dep.module("bdwgc"));
                test_module.addImport("zigimg", zigimg_dep.module("zigimg"));
                test_module.addImport("ada", ada_dep.module("ada"));
            },
        }

        const unit_tests = b.addTest(.{
            .root_module = test_module,
            .use_llvm = use_llvm,
        });
        if (suite.dependencies == .full) {
            // Browser input tests exercise real frame activation paths, whose
            // lazy code generation reaches the renderer and font modules.
            sdk.link(io, unit_tests, .static, sdl.Library.SDL2);
            sdk.link(io, unit_tests, .static, sdl.Library.SDL2_ttf);
        }
        const unit_tests_run = b.addRunArtifact(unit_tests);
        suite_step.dependOn(&unit_tests_run.step);
        if (suite.comprehensive) {
            comprehensive_unit_tests = &unit_tests_run.step;
        } else {
            focused_test_compilations[focused_test_index] = &unit_tests.step;
            focused_test_index += 1;
        }
    }

    const dump_dom_test_step = b.step(
        "test-dump-dom",
        "Capture and compare isolated DOM-dump regressions",
    );
    const text_compare_module = b.createModule(.{
        .root_source_file = b.path("tests/text_compare.zig"),
        .target = target,
        .optimize = optimize,
    });
    const text_compare = b.addExecutable(.{
        .name = "text-compare",
        .root_module = text_compare_module,
    });
    var previous_dom_comparison: ?*std.Build.Step = null;
    for (dump_dom_fixtures) |fixture| {
        const capture = b.addRunArtifact(exe);
        if (previous_dom_comparison) |previous| capture.step.dependOn(previous);
        capture.addArg("--dump-dom");
        switch (fixture.input) {
            .argument => |argument| capture.addArg(argument),
            .file => |path| capture.addPrefixedFileArg("file://", b.path(path)),
        }
        const actual = capture.captureStdOut(.{
            .basename = fixture.output_basename,
        });

        const compare = b.addRunArtifact(text_compare);
        compare.addFileArg(b.path(fixture.golden));
        compare.addFileArg(actual);
        dump_dom_test_step.dependOn(&compare.step);
        previous_dom_comparison = &compare.step;
    }

    const pipeline_test_step = b.step(
        "test-pipeline",
        "Capture and compare style, layout, and display-list regressions",
    );
    var previous_pipeline_comparison: ?*std.Build.Step = null;
    for (pipeline_manifest.cases) |case| {
        const capture = b.addRunArtifact(exe);
        if (previous_pipeline_comparison) |previous| capture.step.dependOn(previous);
        capture.addArg(case.mode.cliFlag());
        capture.addPrefixedFileArg("file://", b.path(case.fixture));
        if (case.mode != .style) {
            capture.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
            // Font discovery reports optional missing faces at warning level.
            // These text-free fixtures do not consume glyphs, so keep that
            // platform inventory out of successful output. A nonzero process
            // exit still reports the captured diagnostics.
            _ = capture.captureStdErr(.{
                .basename = b.fmt("{s}.stderr.txt", .{case.name}),
            });
        }
        const actual = capture.captureStdOut(.{
            .basename = b.fmt("{s}.txt", .{case.name}),
        });

        const compare = b.addRunArtifact(text_compare);
        compare.addFileArg(b.path(case.golden));
        compare.addFileArg(actual);
        pipeline_test_step.dependOn(&compare.step);
        previous_pipeline_comparison = &compare.step;
    }

    const wpt_test_step = b.step(
        "test-wpt",
        "Run local headless WPT result-protocol fixtures",
    );
    var previous_wpt_validation: ?*std.Build.Step = null;
    for (wpt_fixtures) |fixture| {
        const capture = b.addRunArtifact(exe);
        if (previous_wpt_validation) |previous| capture.step.dependOn(previous);
        capture.addArg("--wpt-test");
        capture.addPrefixedFileArg("file://", b.path(fixture.fixture));
        capture.addArg("--wpt-timeout-ms");
        capture.addArg(b.fmt("{d}", .{fixture.timeout_ms}));
        capture.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
        _ = capture.captureStdErr(.{
            .basename = b.fmt("{s}.stderr.txt", .{fixture.output_basename}),
        });
        const actual = capture.captureStdOut(.{
            .basename = fixture.output_basename,
        });

        const validate = b.addSystemCommand(&.{
            "python3",
            "tests/wpt/validate_result.py",
        });
        validate.addFileArg(actual);
        validate.addArgs(&.{ "--status", fixture.status });
        validate.addArgs(&.{ "--test-suffix", fixture.fixture });
        wpt_test_step.dependOn(&validate.step);
        previous_wpt_validation = &validate.step;
    }

    const screenshot_test_step = b.step(
        "test-screenshot",
        "Capture and compare the windowless macOS screenshot fixtures",
    );
    if (builtin.os.tag == .macos and
        target.result.os.tag == .macos and
        target.result.cpu.arch == builtin.cpu.arch)
    {
        const screenshot_compare_module = b.createModule(.{
            .root_source_file = b.path("tests/screenshot_compare.zig"),
            .target = target,
            .optimize = optimize,
        });
        screenshot_compare_module.addImport("zigimg", zigimg_dep.module("zigimg"));
        const screenshot_compare = b.addExecutable(.{
            .name = "screenshot-compare",
            .root_module = screenshot_compare_module,
        });

        var previous_screenshot_comparison: ?*std.Build.Step = null;
        for (screenshot_fixtures) |fixture| {
            const capture = b.addRunArtifact(exe);
            // SDL/SDL_ttf initialization is process-global. Serialize captures
            // even though screenshot mode creates no window or renderer.
            if (previous_screenshot_comparison) |previous| {
                capture.step.dependOn(previous);
            }
            capture.addArg("--screenshot");
            const actual = capture.addOutputFileArg(fixture.output_basename);
            capture.addPrefixedFileArg(
                fixture.input_prefix,
                b.path(fixture.fixture),
            );

            const compare = b.addRunArtifact(screenshot_compare);
            compare.addFileArg(b.path(fixture.golden));
            compare.addFileArg(actual);
            screenshot_test_step.dependOn(&compare.step);
            previous_screenshot_comparison = &compare.step;
        }
    } else {
        const unsupported = b.addFail(
            "test-screenshot currently requires a native macOS target",
        );
        screenshot_test_step.dependOn(&unsupported.step);
    }

    const server_tests = b.addSystemCommand(&.{
        "python3",
        "-m",
        "unittest",
        "tests/test_server_message_board.py",
    });
    const server_test_step = b.step(
        "test-server",
        "Run tutorial message-board server tests",
    );
    server_test_step.dependOn(&server_tests.step);

    const wpt_runner_tests = b.addSystemCommand(&.{
        "python3",
        "-m",
        "unittest",
        "tests/wpt/test_run.py",
    });
    const wpt_runner_test_step = b.step(
        "test-wpt-runner",
        "Run focused WPT manifest-runner tests",
    );
    wpt_runner_test_step.dependOn(&wpt_runner_tests.step);

    const docs_tests = b.addSystemCommand(&.{
        "python3",
        "tests/check_markdown_links.py",
    });
    const docs_test_step = b.step(
        "test-docs",
        "Check repository-local Markdown links",
    );
    docs_test_step.dependOn(&docs_tests.step);

    const format_check = b.addFmt(.{
        .paths = &.{ "build.zig", "src", "tests" },
        .check = true,
    });
    const format_test_step = b.step(
        "test-format",
        "Check Zig source formatting",
    );
    format_test_step.dependOn(&format_check.step);

    const check_step = b.step(
        "check",
        "Run portable build, format, unit, WPT, pipeline, server, and docs checks",
    );
    check_step.dependOn(b.getInstallStep());
    check_step.dependOn(&format_check.step);
    check_step.dependOn(comprehensive_unit_tests);
    for (focused_test_compilations) |compilation| {
        check_step.dependOn(compilation);
    }
    check_step.dependOn(dump_dom_test_step);
    check_step.dependOn(pipeline_test_step);
    check_step.dependOn(server_test_step);
    check_step.dependOn(wpt_runner_test_step);
    check_step.dependOn(wpt_test_step);
    check_step.dependOn(docs_test_step);
}
