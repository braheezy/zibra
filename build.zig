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
        .root_source_file = b.path("src/zibra.zig"),
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
    source_module.addImport("code_point", zg.module("code_point"));

    const ada_dep = b.dependency("adazig", .{});
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

    const js_test_module = b.createModule(.{
        .root_source_file = b.path("src/js.zig"),
        .target = target,
        .optimize = optimize,
    });
    js_test_module.addImport("kiesel", kiesel_dep.module("kiesel"));
    js_test_module.addImport("bdwgc", bdwgc_dep.module("bdwgc"));
    js_test_module.addImport("zigimg", zigimg_dep.module("zigimg"));
    const js_tests = b.addTest(.{ .root_module = js_test_module });
    const js_tests_run = b.addRunArtifact(js_tests);
    test_step.dependOn(&js_tests_run.step);

    const parser_test_module = b.createModule(.{
        .root_source_file = b.path("src/parser_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    parser_test_module.addImport("zigimg", zigimg_dep.module("zigimg"));
    const parser_tests = b.addTest(.{ .root_module = parser_test_module });
    const parser_tests_run = b.addRunArtifact(parser_tests);
    test_step.dependOn(&parser_tests_run.step);

    const url_test_module = b.createModule(.{
        .root_source_file = b.path("src/url.zig"),
        .target = target,
        .optimize = optimize,
    });
    url_test_module.addImport("ada", ada_dep.module("ada"));
    const url_tests = b.addTest(.{ .root_module = url_test_module });
    const url_tests_run = b.addRunArtifact(url_tests);
    test_step.dependOn(&url_tests_run.step);

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
    } else {
        const unsupported = b.addFail(
            "test-screenshot currently requires a native macOS target",
        );
        screenshot_test_step.dependOn(&unsupported.step);
    }
}
