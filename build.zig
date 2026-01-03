const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    // This will link SDL2 and SDL2_TTF
    sdk.link(exe, .static, sdl.Library.SDL2_ttf);
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

    const js_test_module = b.createModule(.{
        .root_source_file = b.path("src/js.zig"),
        .target = target,
        .optimize = optimize,
    });
    js_test_module.addImport("kiesel", kiesel_dep.module("kiesel"));
    const js_tests = b.addTest(.{ .root_module = js_test_module });
    const js_tests_run = b.addRunArtifact(js_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&js_tests_run.step);
}
