const std = @import("std");
// The package's own manifest. Its `version` is what a build stamps into the
// binary unless told otherwise, so the two cannot drift apart by accident.
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The importable module. A consumer wires it in with:
    //
    //     const ppkg = b.dependency("hkm_ppkg", .{}).module("ppkg");
    //     exe.root_module.addImport("ppkg", ppkg);
    //
    // or, for a sibling checkout with no package manager involved:
    //
    //     const ppkg = b.createModule(.{
    //         .root_source_file = b.path("../modules/hkm-ppkg/src/root.zig"),
    //         .target = target, .optimize = optimize,
    //     });
    //
    // Both work because this module has no dependencies of its own — the host's
    // output layer is injected at runtime through `report`, not at build time.
    const ppkg = b.addModule("ppkg", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── the standalone binary ────────────────────────────────────────────────
    //
    // `ppkg`, built from app/ against the module above exactly as any other host
    // consumes it. The version defaults to build.zig.zon's; the release workflow
    // passes the tag's version explicitly AND refuses a tag the manifest does
    // not agree with, so a published binary always reports its own release.
    const version = b.option([]const u8, "version", "Version stamped into the ppkg binary (default: build.zig.zon)") orelse zon.version;
    const strip = b.option(bool, "strip", "Omit debug information from the binary");

    const build_info = b.addOptions();
    build_info.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{
        .name = "ppkg",
        .root_module = appModule(b, target, optimize, strip, ppkg, build_info),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run ppkg — `zig build run -- install`");
    run_step.dependOn(&run.step);

    // `zig build test` — the library rooted at src/root.zig so that every file
    // is analysed, including the ones no test happens to call. Zig only compiles
    // what is referenced; a module left out of the root is a module whose
    // compile errors nobody sees. The binary's own files are tested beside it.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const app_tests = b.addTest(.{
        .root_module = appModule(b, target, optimize, strip, ppkg, build_info),
    });

    const test_step = b.step("test", "Run the package manager unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(app_tests).step);

    // `zig build check -Dtarget=…` — COMPILE for a target without running.
    //
    // Both the library's test binary and the `ppkg` executable: a compile error
    // behind an `if (builtin.os.tag == .windows)` branch is invisible on a
    // native build, and a cross-compile job that built only one of the two
    // would be green for the other forever. Depending on the compile steps
    // rather than on run steps is the point — the output is for a foreign
    // target and never executed.
    const check = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const check_step = b.step("check", "Compile for the selected target without running");
    check_step.dependOn(&check.step);
    check_step.dependOn(&exe.step);
}

fn appModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: ?bool,
    ppkg: *std.Build.Module,
    build_info: *std.Build.Step.Options,
) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path("app/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    m.addImport("ppkg", ppkg);
    m.addOptions("build_info", build_info);
    return m;
}
