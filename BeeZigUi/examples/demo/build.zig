//! Builds the demo against Zui as a package, the way your own app would.
//! The dependency is declared in build.zig.zon.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zui = b.dependency("zui", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "zui-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui", .module = zui.module("zui") },
                .{ .name = "zui_software", .module = zui.module("zui_software") },
                .{ .name = "zui_sdl3", .module = zui.module("zui_sdl3") },
                .{ .name = "zui_opengl", .module = zui.module("zui_opengl") },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the demo").dependOn(&run.step);
}
