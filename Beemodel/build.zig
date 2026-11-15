const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .fast });

    const exe = b.addExecutable(.{
        .name = "beemodel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = false,
            .strip = optimize != .debug,
        }),
    });
    b.installArtifact(exe);

    // The UI library, BeeZigUi (Zui), from ../BeeZigUi (build.zig.zon): the
    // core, its software renderer, and the node editor and file browser
    // add-ons. All pure Zig, no libc.
    const zui = b.dependency("zui", .{ .target = target, .optimize = optimize });
    for ([_][]const u8{ "zui", "zui_software", "zui_nodes", "zui_files" }) |name| {
        exe.root_module.addImport(name, zui.module(name));
    }

    // zig build test-ui: the Zui host and the panel kit (src/zuitest.zig).
    // The other unit tests run file by file (tests/verify.sh); these need Zui.
    const ui_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/zuitest.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    for ([_][]const u8{ "zui", "zui_software", "zui_nodes", "zui_files" }) |name| {
        ui_tests.root_module.addImport(name, zui.module(name));
    }
    b.step("test-ui", "Test the Zui host and the panel kit").dependOn(&b.addRunArtifact(ui_tests).step);

    // the optional GPU helper (beemodel-gpu), next to it: it loads the Vulkan
    // loader at run time and embeds src/gpu/spv/*.spv, so building it needs
    // neither Vulkan nor glslc (-Dgpu=false leaves it out)
    if (b.option(bool, "gpu", "Build the GPU helper (default: yes)") orelse true) {
        const helper = b.addExecutable(.{
            .name = "beemodel-gpu",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/gpu/helper.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .strip = optimize != .debug,
            }),
        });
        b.installArtifact(helper);
    }
    // the shaders again (needs glslc): the .spv files are checked in
    const spv = b.addSystemCommand(&.{ "python3", "tools/genspv.py" });
    b.step("shaders", "Compile src/gpu/*.comp to src/gpu/spv (needs glslc)").dependOn(&spv.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Build and start BeeModel (Zig)").dependOn(&run.step);
}
