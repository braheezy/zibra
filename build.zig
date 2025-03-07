const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zibra",
        .root_source_file = b.path("src/zibra.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add dependencies
    if (builtin.target.os.tag == .macos) {
        // allyourcodebase/SDL_ttf doesn't work on macos
        // `brew install sdl2_ttf`
        exe.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        exe.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    }

    exe.linkSystemLibrary("SDL2");
    exe.linkSystemLibrary("SDL2_ttf");

    const known_folders = b.dependency("known_folders", .{}).module("known-folders");
    exe.root_module.addImport("known-folders", known_folders);

    const zg = b.dependency("zg", .{});
    exe.root_module.addImport("grapheme", zg.module("grapheme"));
    exe.root_module.addImport("code_point", zg.module("code_point"));

    const ada_dep = b.dependency("adazig", .{});
    exe.root_module.addImport("ada", ada_dep.module("ada"));

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/url.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
