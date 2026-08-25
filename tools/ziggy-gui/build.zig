const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ziggy-gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const zglfw = b.dependency("zglfw", .{ .target = target });
    exe.root_module.addImport("zglfw", zglfw.module("root"));
    exe.linkLibrary(zglfw.artifact("glfw"));

    const zopengl = b.dependency("zopengl", .{});
    exe.root_module.addImport("zopengl", zopengl.module("root"));

    const zgui = b.dependency("zgui", .{
        .target = target,
        .backend = .glfw_opengl3,
    });
    exe.root_module.addImport("zgui", zgui.module("root"));
    exe.linkLibrary(zgui.artifact("imgui"));

    if (target.result.os.tag == .linux) {
        if (b.lazyDependency("system_sdk", .{})) |system_sdk| {
            exe.addLibraryPath(system_sdk.path("linux/lib/x86_64-linux-gnu"));
        }
    } else if (target.result.os.tag == .macos) {
        if (b.lazyDependency("system_sdk", .{})) |system_sdk| {
            exe.addLibraryPath(system_sdk.path("macos12/usr/lib"));
            exe.addSystemFrameworkPath(system_sdk.path("macos12/System/Library/Frameworks"));
        }
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run ziggy-gui");
    run_step.dependOn(&run_cmd.step);

    const toml_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/toml.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_toml_tests = b.addRunArtifact(toml_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_toml_tests.step);
}
