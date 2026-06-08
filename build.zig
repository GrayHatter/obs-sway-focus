const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const module = b.addModule("obs_sway_plugin", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const lib = b.addLibrary(.{
        .name = "obs_sway_plugin",
        .root_module = module,
        .linkage = .dynamic,
    });

    const obs = b.dependency("obzig", .{ .target = target });
    lib.root_module.addImport("OBS", obs.module("OBS"));
    lib.root_module.linkLibrary(obs.artifact("obzig"));

    b.getInstallStep().dependOn(
        &b.addInstallArtifact(lib, .{
            .dest_dir = .{ .override = std.Build.InstallDir{ .custom = "" } },
            .dest_sub_path = "obs-sway-focus/bin/64bit/obs-sway-focus.so",
        }).step,
    );

    const lib_unit_tests = b.addTest(.{
        .root_module = module,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
