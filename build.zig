const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The importable module. A consumer wires it in with:
    //
    //     const pkg = b.dependency("hkm_pkg", .{}).module("pkg");
    //     exe.root_module.addImport("pkg", pkg);
    //
    // or, for a sibling checkout with no package manager involved:
    //
    //     const pkg = b.createModule(.{
    //         .root_source_file = b.path("../modules/hkm-pkg/src/root.zig"),
    //         .target = target, .optimize = optimize,
    //     });
    //
    // Both work because this module has no dependencies of its own — the host's
    // output layer is injected at runtime through `report`, not at build time.
    _ = b.addModule("pkg", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // `zig build test` — rooted at src/root.zig so that every file is analysed,
    // including the ones no test happens to call. Zig only compiles what is
    // referenced; a module left out of the root is a module whose compile
    // errors nobody sees.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run the package manager unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // `zig build check -Dtarget=…` — COMPILE for a target without running.
    //
    // This exists because `zig build` on its own compiles nothing here: the
    // package exposes a module and installs no artifact, so the default step
    // succeeds instantly on code that does not build. A cross-compile job
    // written against it would have been green for every target, forever.
    //
    // Depending on the compile step rather than a run step is the point — the
    // binary is produced for a foreign target and never executed.
    const check = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const check_step = b.step("check", "Compile for the selected target without running");
    check_step.dependOn(&check.step);
}
