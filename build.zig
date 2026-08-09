//! Build, run, unit-test, and native screenshot-test steps for Zibra.

const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const io = b.graph.io;

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
    });

    // SDL2_ttf uses SDL2, but does not make SDL2's symbols available to this
    // executable on every linker/platform. Link both libraries explicitly.
    sdk.link(io, exe, .static, sdl.Library.SDL2);
    sdk.link(io, exe, .static, sdl.Library.SDL2_ttf);
    b.installArtifact(exe);

    const known_folders = b.dependency("known_folders", .{}).module("known-folders");
    source_module.addImport("known-folders", known_folders);

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

    const test_step = b.step("test", "Run unit tests");

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/test_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("sdl", sdl_mod);
    test_module.addImport("known-folders", known_folders);
    test_module.addImport("grapheme", zg.module("Graphemes"));
    test_module.addImport("emoji", zg.module("Emoji"));
    test_module.addImport("code_point", zg.module("code_point"));
    test_module.addImport("z2d", z2d_dep.module("z2d"));
    test_module.addImport("kiesel", kiesel_dep.module("kiesel"));
    test_module.addImport("bdwgc", bdwgc_dep.module("bdwgc"));
    test_module.addImport("zigimg", zigimg_dep.module("zigimg"));
    test_module.addImport("ada", ada_dep.module("ada"));
    const unit_tests = b.addTest(.{ .root_module = test_module });
    const unit_tests_run = b.addRunArtifact(unit_tests);
    test_step.dependOn(&unit_tests_run.step);

    const dump_dom_test_step = b.step(
        "test-dump-dom",
        "Capture and compare isolated DOM-dump regressions",
    );
    const dump_dom_compare_module = b.createModule(.{
        .root_source_file = b.path("tests/dump_dom_compare.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dump_dom_compare = b.addExecutable(.{
        .name = "dump-dom-compare",
        .root_module = dump_dom_compare_module,
    });
    const dump_dom = b.addRunArtifact(exe);
    dump_dom.addArg("--dump-dom");
    dump_dom.addPrefixedFileArg("file://", b.path("tests/manual/dump-dom.html"));
    const actual_dom_dump = dump_dom.captureStdOut(.{ .basename = "dump-dom.txt" });

    const compare_dom_dump = b.addRunArtifact(dump_dom_compare);
    compare_dom_dump.addFileArg(b.path("tests/golden/dump-dom.txt"));
    compare_dom_dump.addFileArg(actual_dom_dump);

    const dump_about_blank = b.addRunArtifact(exe);
    dump_about_blank.step.dependOn(&compare_dom_dump.step);
    dump_about_blank.addArg("--dump-dom");
    dump_about_blank.addArg("about:blank");
    const actual_about_blank_dump = dump_about_blank.captureStdOut(.{
        .basename = "about-blank-dom.txt",
    });

    const compare_about_blank_dump = b.addRunArtifact(dump_dom_compare);
    compare_about_blank_dump.addFileArg(b.path("tests/golden/about-blank-dom.txt"));
    compare_about_blank_dump.addFileArg(actual_about_blank_dump);

    const dump_malformed_url = b.addRunArtifact(exe);
    dump_malformed_url.step.dependOn(&compare_about_blank_dump.step);
    dump_malformed_url.addArg("--dump-dom");
    dump_malformed_url.addArg("http://[");
    const actual_malformed_url_dump = dump_malformed_url.captureStdOut(.{
        .basename = "malformed-url-dom.txt",
    });

    const compare_malformed_url_dump = b.addRunArtifact(dump_dom_compare);
    compare_malformed_url_dump.addFileArg(b.path("tests/golden/about-blank-dom.txt"));
    compare_malformed_url_dump.addFileArg(actual_malformed_url_dump);

    const dump_unsupported_scheme = b.addRunArtifact(exe);
    dump_unsupported_scheme.step.dependOn(&compare_malformed_url_dump.step);
    dump_unsupported_scheme.addArg("--dump-dom");
    dump_unsupported_scheme.addArg("mailto:test@example.com");
    const actual_unsupported_scheme_dump = dump_unsupported_scheme.captureStdOut(.{
        .basename = "unsupported-scheme-dom.txt",
    });

    const compare_unsupported_scheme_dump = b.addRunArtifact(dump_dom_compare);
    compare_unsupported_scheme_dump.addFileArg(b.path("tests/golden/about-blank-dom.txt"));
    compare_unsupported_scheme_dump.addFileArg(actual_unsupported_scheme_dump);
    dump_dom_test_step.dependOn(&compare_unsupported_scheme_dump.step);

    const screenshot_test_step = b.step(
        "test-screenshot",
        "Capture and compare the native macOS screenshot fixture",
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

        const capture = b.addRunArtifact(exe);
        capture.addArg("--screenshot");
        const actual_screenshot = capture.addOutputFileArg("native-screenshot.png");
        capture.addPrefixedFileArg("file://", b.path("tests/manual/native-screenshot.html"));

        const compare = b.addRunArtifact(screenshot_compare);
        compare.addFileArg(b.path("tests/golden/native-screenshot.macos.png"));
        compare.addFileArg(actual_screenshot);
        screenshot_test_step.dependOn(&compare.step);

        const view_source_capture = b.addRunArtifact(exe);
        // The native hidden-window path is process-global on macOS. Serialize
        // the captures so the native screenshot fixtures cannot race SDL setup.
        view_source_capture.step.dependOn(&compare.step);
        view_source_capture.addArg("--screenshot");
        const actual_view_source_screenshot = view_source_capture.addOutputFileArg("view-source-screenshot.png");
        view_source_capture.addPrefixedFileArg("view-source:file://", b.path("tests/manual/view-source.html"));

        const compare_view_source = b.addRunArtifact(screenshot_compare);
        compare_view_source.addFileArg(b.path("tests/golden/view-source.macos.png"));
        compare_view_source.addFileArg(actual_view_source_screenshot);
        screenshot_test_step.dependOn(&compare_view_source.step);

        const scrollbar_capture = b.addRunArtifact(exe);
        scrollbar_capture.step.dependOn(&compare_view_source.step);
        scrollbar_capture.addArg("--screenshot");
        const actual_scrollbar_screenshot = scrollbar_capture.addOutputFileArg("scrollbar-screenshot.png");
        scrollbar_capture.addPrefixedFileArg("file://", b.path("tests/manual/scrollbar.html"));

        const compare_scrollbar = b.addRunArtifact(screenshot_compare);
        compare_scrollbar.addFileArg(b.path("tests/golden/scrollbar.macos.png"));
        compare_scrollbar.addFileArg(actual_scrollbar_screenshot);
        screenshot_test_step.dependOn(&compare_scrollbar.step);

        const emoji_capture = b.addRunArtifact(exe);
        emoji_capture.step.dependOn(&compare_scrollbar.step);
        emoji_capture.addArg("--screenshot");
        const actual_emoji_screenshot = emoji_capture.addOutputFileArg("emoji-screenshot.png");
        emoji_capture.addPrefixedFileArg("file://", b.path("tests/manual/emoji.html"));

        const compare_emoji = b.addRunArtifact(screenshot_compare);
        compare_emoji.addFileArg(b.path("tests/golden/emoji.macos.png"));
        compare_emoji.addFileArg(actual_emoji_screenshot);
        screenshot_test_step.dependOn(&compare_emoji.step);

        const text_direction_capture = b.addRunArtifact(exe);
        text_direction_capture.step.dependOn(&compare_emoji.step);
        text_direction_capture.addArg("--screenshot");
        const actual_text_direction_screenshot = text_direction_capture.addOutputFileArg("alternate-text-direction-screenshot.png");
        text_direction_capture.addPrefixedFileArg("file://", b.path("tests/manual/alternate-text-direction.html"));

        const compare_text_direction = b.addRunArtifact(screenshot_compare);
        compare_text_direction.addFileArg(b.path("tests/golden/alternate-text-direction.macos.png"));
        compare_text_direction.addFileArg(actual_text_direction_screenshot);
        screenshot_test_step.dependOn(&compare_text_direction.step);
    } else {
        const unsupported = b.addFail(
            "test-screenshot currently requires a native macOS target",
        );
        screenshot_test_step.dependOn(&unsupported.step);
    }
}
