const std = @import("std");

/// Mirror of terminal/build_options.zig Artifact enum.
/// Used for terminal_options; variant names must match upstream.
const Artifact = enum { ghostty, lib };

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const pic = b.option(bool, "pic", "Emit position independent code");

    // --- uucode unicode tables ---
    const uucode_tables = blk: {
        const dep = b.dependency("uucode", .{
            .build_config_path = b.path("ghostty_src/build/uucode_config.zig"),
        });
        break :blk dep.namedLazyPath("tables.zig");
    };

    const uucode_host = b.dependency("uucode", .{
        .target = b.graph.host,
        .tables_path = uucode_tables,
        .build_config_path = b.path("ghostty_src/build/uucode_config.zig"),
    });

    const uucode_target = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .tables_path = uucode_tables,
        .build_config_path = b.path("ghostty_src/build/uucode_config.zig"),
    });

    // --- unicode table generators (run on host) ---
    const props_exe = b.addExecutable(.{
        .name = "props-unigen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ghostty_src/unicode/props_uucode.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });
    props_exe.root_module.addImport("uucode", uucode_host.module("uucode"));

    const symbols_exe = b.addExecutable(.{
        .name = "symbols-unigen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ghostty_src/unicode/symbols_uucode.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });
    symbols_exe.root_module.addImport("uucode", uucode_host.module("uucode"));

    const props_run = b.addRunArtifact(props_exe);
    const symbols_run = b.addRunArtifact(symbols_exe);

    // Generated Zig files need .zig extension for import resolution.
    const wf = b.addWriteFiles();
    const props_output = wf.addCopyFile(props_run.captureStdOut(.{}), "props.zig");
    const symbols_output = wf.addCopyFile(symbols_run.captureStdOut(.{}), "symbols.zig");

    // --- terminal_options (required by terminal internals) ---
    const terminal_opts = b.addOptions();
    terminal_opts.addOption(Artifact, "artifact", .lib);
    terminal_opts.addOption(bool, "c_abi", false);
    terminal_opts.addOption(bool, "oniguruma", false);
    terminal_opts.addOption(bool, "simd", false);
    terminal_opts.addOption(bool, "slow_runtime_safety", false);
    // Kitty graphics: disable on wasm32-freestanding, enable otherwise (matches upstream).
    const resolved_target = target.result;
    terminal_opts.addOption(
        bool,
        "kitty_graphics",
        !(resolved_target.cpu.arch == .wasm32 and resolved_target.os.tag == .freestanding),
    );
    // tmux_control_mode is synthesized from oniguruma (matches upstream).
    terminal_opts.addOption(bool, "tmux_control_mode", false);

    // Version information (required by upstream terminal_options).
    const version_string = "0.0.0";
    terminal_opts.addOption([]const u8, "version_string", version_string);
    terminal_opts.addOption(usize, "version_major", 0);
    terminal_opts.addOption(usize, "version_minor", 0);
    terminal_opts.addOption(usize, "version_patch", 0);
    terminal_opts.addOption(?[]const u8, "version_pre", null);
    terminal_opts.addOption(?[]const u8, "version_build", null);

    // --- build_options (required by simd module, scalar fallback only) ---
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "simd", false);

    // --- static library ---
    // Emit a single object file rather than a static archive: zig 0.16's
    // archiver writes ar members Apple's ld rejects ("not 8-byte aligned").
    // build.rs archives the object with the system `ar` instead.
    const lib = b.addObject(.{
        .name = "ghostty_vt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("lib.zig"),
            .target = target,
            .optimize = optimize,
            .pic = pic,
            .link_libc = true,
        }),
        .use_llvm = true,
    });
    lib.root_module.addImport("uucode", uucode_target.module("uucode"));
    lib.root_module.addOptions("terminal_options", terminal_opts);
    lib.root_module.addOptions("build_options", build_opts);

    props_output.addStepDependencies(&lib.step);
    lib.root_module.addAnonymousImport("unicode_tables", .{
        .root_source_file = props_output,
    });
    symbols_output.addStepDependencies(&lib.step);
    lib.root_module.addAnonymousImport("symbols_tables", .{
        .root_source_file = symbols_output,
    });

    // --- install ---
    const include_step = b.addInstallHeaderFile(
        b.path("../include/ghostty_vt.h"),
        "ghostty_vt.h",
    );

    const lib_install = b.addInstallLibFile(lib.getEmittedBin(), "ghostty_vt.o");
    b.getInstallStep().dependOn(&include_step.step);
    b.getInstallStep().dependOn(&lib_install.step);
}
