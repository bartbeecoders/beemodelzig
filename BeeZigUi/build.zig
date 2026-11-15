const std = @import("std");

/// How an example is put together.
const Kind = enum {
    /// A phase demo driven by `examples/common/harness.zig`.
    harness,
    /// A complete app with its own main loop, SDL3 window and renderer.
    app,
    /// No window and no C: the library and the software renderer only.
    headless,
};

/// Examples in `examples/<name>/main.zig`. Each gets a `zig build run-<name>` step.
const examples = [_]struct { []const u8, Kind }{
    .{ "01_shapes", .harness },
    .{ "02_text", .harness },
    .{ "03_buttons", .harness },
    .{ "04_layout", .harness },
    .{ "05_windows", .harness },
    .{ "06_widgets", .harness },
    .{ "07_text_input", .harness },
    .{ "08_keyboard", .harness },
    .{ "09_style", .harness },
    .{ "10_overlays", .harness },
    .{ "11_containers", .harness },
    .{ "13_drawing", .harness },
    .{ "15_properties", .harness },
    .{ "16_menus", .harness },
    .{ "17_docking", .harness },
    .{ "18_feedback", .harness },
    .{ "19_outliner", .harness },
    .{ "20_console", .harness },
    .{ "21_colour", .harness },
    .{ "22_pies", .harness },
    .{ "23_views", .harness },
    .{ "24_nodes", .harness },
    .{ "25_files", .harness },
    .{ "demo", .app },
    .{ "render_png", .headless },
    .{ "embed", .headless },
};

/// Demos with a script in tests/scenarios/<name>.txt, for `zig build scenarios`.
const scenario_demos = [_][]const u8{ "05_windows", "07_text_input", "08_keyboard", "10_overlays", "11_containers", "13_drawing", "15_properties", "16_menus", "17_docking", "18_feedback", "19_outliner", "20_console", "21_colour", "22_pies", "23_views", "24_nodes", "25_files" };

fn hasScenario(name: []const u8) bool {
    for (scenario_demos) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

/// Where the SDL3 library for the window backend comes from.
const SdlSource = enum {
    /// Link the SDL3 installed on the system.
    system,
    /// Build SDL3 from source with the Zig package manager
    /// (github.com/castholm/SDL) and link it statically. Nothing to install,
    /// and it can cross-compile to Windows.
    source,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdl_source = b.option(SdlSource, "sdl", "Where SDL3 comes from: system (default) or source") orelse .system;

    // Core library: pure Zig, no libc, no backend.
    const zui = b.addModule("zui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Pure-Zig CPU rasterizer. Works with any window system.
    const software = b.addModule("zui_software", .{
        .root_source_file = b.path("backends/software.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zui", .module = zui }},
    });

    // The only C dependency in the project lives behind this module.
    const sdl3 = b.addModule("zui_sdl3", .{
        .root_source_file = b.path("backends/sdl3.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zui", .module = zui }},
    });
    linkSdl(b, sdl3, sdl_source, target, optimize);

    // GPU renderer: OpenGL 3.3, functions looked up at runtime, no libc.
    const opengl = b.addModule("zui_opengl", .{
        .root_source_file = b.path("backends/opengl.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zui", .module = zui }},
    });

    // Native backends, no C: Wayland (Linux, no libc) and Win32.
    const wayland = b.addModule("zui_wayland", .{
        .root_source_file = b.path("backends/wayland.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "zui", .module = zui }, .{ .name = "zui_software", .module = software } },
    });
    const win32 = b.addModule("zui_win32", .{
        .root_source_file = b.path("backends/win32.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "zui", .module = zui }, .{ .name = "zui_software", .module = software } },
    });

    // The native demo: the system's own window protocol, no C library.
    {
        const exe = nativeDemo(b, target, optimize, "native", zui, software);
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        b.step("native", "Run the demo on the native backend (Wayland or Win32, no libc)").dependOn(&run.step);
    }

    // Add-ons built only on the public API: the node editor and the file
    // browser.
    const nodes = b.addModule("zui_nodes", .{
        .root_source_file = b.path("addons/nodes.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zui", .module = zui }},
    });

    const files = b.addModule("zui_files", .{
        .root_source_file = b.path("addons/files.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zui", .module = zui }},
    });

    const harness = b.createModule(.{
        .root_source_file = b.path("examples/common/harness.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui", .module = zui },
            .{ .name = "zui_software", .module = software },
            .{ .name = "zui_sdl3", .module = sdl3 },
            .{ .name = "zui_opengl", .module = opengl },
        },
    });

    // Renders a scene with both renderers and compares the pixels.
    const gl_check = b.addExecutable(.{
        .name = "gl_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gl_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui", .module = zui },
                .{ .name = "zui_software", .module = software },
                .{ .name = "zui_sdl3", .module = sdl3 },
                .{ .name = "zui_opengl", .module = opengl },
            },
        }),
    });
    const run_gl_check = b.addRunArtifact(gl_check);
    run_gl_check.addPassthruArgs();
    b.step("gl-check", "Compare the OpenGL renderer's pixels with the software renderer's").dependOn(&run_gl_check.step);

    // Scripted scenarios: tests/scenarios/<demo>.txt played headless
    // against that demo. A failed line fails the step; shots land in
    // zig-out/scenarios.
    const scenarios = b.step("scenarios", "Play the scripts in tests/scenarios against their demos");
    for (examples) |example| {
        const name, const kind = example;
        const imports: []const std.Build.Module.Import = switch (kind) {
            .harness => &.{
                .{ .name = "zui", .module = zui },
                .{ .name = "harness", .module = harness },
                .{ .name = "zui_nodes", .module = nodes },
                .{ .name = "zui_files", .module = files },
            },
            .app => &.{
                .{ .name = "zui", .module = zui },
                .{ .name = "zui_software", .module = software },
                .{ .name = "zui_sdl3", .module = sdl3 },
                .{ .name = "zui_opengl", .module = opengl },
            },
            .headless => &.{
                .{ .name = "zui", .module = zui },
                .{ .name = "zui_software", .module = software },
            },
        };
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = imports,
            }),
        });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        run.addPassthruArgs();
        b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the {s} example", .{name})).dependOn(&run.step);

        const script_path = b.fmt("tests/scenarios/{s}.txt", .{name});
        if (kind == .harness and hasScenario(name)) {
            const play = b.addRunArtifact(exe);
            play.setCwd(b.path("."));
            play.addArgs(&.{ "--script", script_path });
            play.addFileInput(b.path(script_path));
            play.has_side_effects = true;
            scenarios.dependOn(&play.step);
        }
    }

    // Hot reload: a host program and the app library it reloads.
    {
        const hot_zui = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
        });
        const lib = b.addLibrary(.{
            .name = "hot_app",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/12_hot_reload/app.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zui", .module = hot_zui }},
            }),
        });
        const install_lib = b.addInstallArtifact(lib, .{});
        b.step("hot-app", "Rebuild only the hot reload example's app library").dependOn(&install_lib.step);

        const host = b.addExecutable(.{
            .name = "12_hot_reload",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/12_hot_reload/host.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zui", .module = zui },
                    .{ .name = "zui_software", .module = software },
                    .{ .name = "zui_sdl3", .module = sdl3 },
                },
            }),
        });
        b.installArtifact(host);
        b.getInstallStep().dependOn(&install_lib.step);
        const lib_file = switch (target.result.os.tag) {
            .windows => "bin/hot_app.dll",
            .macos => "lib/libhot_app.dylib",
            else => "lib/libhot_app.so",
        };
        const run = b.addRunArtifact(host);
        run.step.dependOn(b.getInstallStep());
        // The installed copy, whose path stays the same across rebuilds.
        run.addFileArg(b.graph.path(.install_prefix, lib_file));
        run.addPassthruArgs();
        b.step("run-12_hot_reload", "Run the hot reload example").dependOn(&run.step);
    }

    // Tests
    const test_step = b.step("test", "Run all unit tests");
    const test_roots = [_]*std.Build.Module{
        zui,
        software,
        opengl,
        nodes,
        files,
        wayland,
        win32,
        b.createModule(.{
            .root_source_file = b.path("tests/all.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui", .module = zui },
                .{ .name = "zui_software", .module = software },
                .{ .name = "zui_nodes", .module = nodes },
                .{ .name = "zui_files", .module = files },
            },
        }),
        b.createModule(.{
            .root_source_file = b.path("tools/check_docs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    };
    for (test_roots) |root| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = root })).step);
    }

    // Frame-time benchmark. Always optimized: debug timings mean nothing.
    const fast_zui = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const fast_software = b.createModule(.{
        .root_source_file = b.path("backends/software.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "zui", .module = fast_zui }},
    });
    const fast_nodes = b.createModule(.{
        .root_source_file = b.path("addons/nodes.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "zui", .module = fast_zui }},
    });
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zui", .module = fast_zui },
                .{ .name = "zui_software", .module = fast_software },
                .{ .name = "zui_nodes", .module = fast_nodes },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    run_bench.addPassthruArgs();
    b.step("bench", "Measure frame times (ReleaseFast)").dependOn(&run_bench.step);

    // Doc comment check over the public sources.
    const check_docs = b.addExecutable(.{
        .name = "check_docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_docs.zig"),
            .target = b.graph.host,
        }),
    });
    const run_check = b.addRunArtifact(check_docs);
    run_check.setCwd(b.path("."));
    run_check.addArgs(&.{ "src", "backends", "addons" });
    b.step("check-docs", "Fail if a public declaration has no doc comment").dependOn(&run_check.step);

    // Compile the backend-free stack for the platforms we can't run here.
    const cross_step = b.step("cross", "Compile the core, software renderer and render_png for Windows and macOS");
    for ([_][]const u8{ "x86_64-windows", "aarch64-macos", "x86_64-macos", "x86_64-linux" }) |triple| {
        const cross_target = b.resolveTargetQuery(std.Build.parseTargetQuery(.{ .arch_os_abi = triple }) catch unreachable);
        const cross_zui = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = cross_target,
        });
        const cross_sw = b.createModule(.{
            .root_source_file = b.path("backends/software.zig"),
            .target = cross_target,
            .imports = &.{.{ .name = "zui", .module = cross_zui }},
        });
        const obj = b.addObject(.{ .name = b.fmt("zui-{s}", .{triple}), .root_module = cross_sw });
        cross_step.dependOn(&obj.step);
        const gl_obj = b.addObject(.{ .name = b.fmt("zui-opengl-{s}", .{triple}), .root_module = b.createModule(.{
            .root_source_file = b.path("backends/opengl.zig"),
            .target = cross_target,
            .imports = &.{.{ .name = "zui", .module = cross_zui }},
        }) });
        cross_step.dependOn(&gl_obj.step);
        // The native demo, on Win32 or Wayland as the target has.
        if (cross_target.result.os.tag == .windows or cross_target.result.os.tag == .linux) {
            const native_exe = nativeDemo(b, cross_target, .ReleaseSmall, b.fmt("native-{s}", .{triple}), cross_zui, cross_sw);
            cross_step.dependOn(&b.addInstallArtifact(native_exe, .{}).step);
        }
        // The add-ons, each through a small root that uses all of it.
        for ([_][]const u8{ "nodes", "files" }) |addon| {
            const addon_obj = b.addObject(.{ .name = b.fmt("zui-{s}-{s}", .{ addon, triple }), .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("addons/{s}.zig", .{addon})),
                .target = cross_target,
                .imports = &.{.{ .name = "zui", .module = cross_zui }},
            }) });
            cross_step.dependOn(&addon_obj.step);
        }
        // A whole program too: the headless example, with file output.
        const exe = b.addExecutable(.{
            .name = b.fmt("render_png-{s}", .{triple}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/render_png/main.zig"),
                .target = cross_target,
                .optimize = .ReleaseSmall,
                .imports = &.{
                    .{ .name = "zui", .module = cross_zui },
                    .{ .name = "zui_software", .module = cross_sw },
                },
            }),
        });
        cross_step.dependOn(&b.addInstallArtifact(exe, .{ .dest_sub_path = b.fmt("cross/{s}", .{exe.out_filename}) }).step);
    }
}

/// Links SDL3 into `module`, from the system or built from source.
fn linkSdl(b: *std.Build, module: *std.Build.Module, source: SdlSource, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    switch (source) {
        .system => module.linkSystemLibrary("SDL3", .{}),
        .source => if (b.lazyDependency("sdl", .{
            .target = target,
            .optimize = optimize,
            .preferred_linkage = .static,
        })) |sdl| module.linkLibrary(sdl.artifact("SDL3")),
    }
}


/// The native demo for `target`: Wayland on Linux, Win32 on Windows, with
/// no C library either way.
fn nativeDemo(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, name: []const u8, zui: *std.Build.Module, software: *std.Build.Module) *std.Build.Step.Compile {
    const windows = target.result.os.tag == .windows;
    const backend = b.createModule(.{
        .root_source_file = b.path(if (windows) "backends/win32.zig" else "backends/wayland.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "zui", .module = zui }, .{ .name = "zui_software", .module = software } },
    });
    const module = b.createModule(.{
        .root_source_file = b.path("examples/native/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .imports = &.{ .{ .name = "zui", .module = zui }, .{ .name = "zui_native", .module = backend } },
    });
    if (windows) {
        for ([_][]const u8{ "user32", "gdi32", "kernel32", "shell32" }) |lib| module.linkSystemLibrary(lib, .{});
    }
    const exe = b.addExecutable(.{ .name = name, .root_module = module, .linkage = if (windows) null else .static });
    if (windows) exe.subsystem = .windows;
    return exe;
}
