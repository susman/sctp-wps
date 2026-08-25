const std = @import("std");

/// Define library, dependency, and test build steps.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = optimize != .Debug;

    const host_os = b.graph.host.result.os.tag;
    const target_os = target.result.os.tag;
    const is_native = target.query.isNative();

    const macos_universal = b.option(
        bool,
        "macos-universal",
        "Build universal macOS static lib (lipo/llvm-lipo)",
    ) orelse false;

    if (!macos_universal and target_os != .linux and target_os != .macos) {
        @panic("sctp-wps supports only Linux and macOS targets");
    }

    const have_system_wp: bool = if (is_native and target_os == .linux)
        haveSystemWavpackStream(b)
    else
        false;

    if (macos_universal) {
        buildMacosUniversal(b, optimize, strip, host_os);
    } else {
        const lib_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .link_libc = true,
        });
        addWavpackStream(b, lib_mod, have_system_wp, target, optimize);
        addUsrsctp(b, lib_mod, target, optimize, host_os);

        const lib = b.addLibrary(.{
            .name = "sctp-wps",
            .root_module = lib_mod,
        });
        b.installArtifact(lib);
        b.installFile("include/sctp-wps.h", "include/sctp-wps.h");
    }

    setupTests(b, target, optimize, strip, have_system_wp, host_os);
}

/// Configure the test module and the peer helper executable.
fn setupTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
    have_system_wp: bool,
    host_os: std.Target.Os.Tag,
) void {
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
    });
    addWavpackStream(b, test_mod, have_system_wp, target, optimize);
    addUsrsctp(b, test_mod, target, optimize, host_os);

    // The peer is the second endpoint for cross-process loopback tests.
    // The selected SCTP backend determines whether it uses UDP encapsulation.
    const peer_mod = b.createModule(.{
        .root_source_file = b.path("src/peer.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
    });
    addWavpackStream(b, peer_mod, have_system_wp, target, optimize);
    addUsrsctp(b, peer_mod, target, optimize, host_os);

    const peer_exe = b.addExecutable(.{
        .name = "sctp-wps-peer",
        .root_module = peer_mod,
    });
    const peer_install = b.addInstallArtifact(peer_exe, .{});

    const test_options = b.addOptions();
    test_options.addOptionPath("peer_path", peer_exe.getEmittedBin());
    test_mod.addOptions("build_options", test_options);

    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    run_tests.step.dependOn(&peer_install.step);
    const test_step = b.step("test", "Run unit and network tests");
    test_step.dependOn(&run_tests.step);
}

/// Build a universal macOS static archive.
/// Install it under zig-out/macos-universal/{lib,include}/.
/// Use lipo on a macOS host. Use llvm-lipo on a Linux host.
fn buildMacosUniversal(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
    host_os: std.Target.Os.Tag,
) void {
    const x64_lib = buildMacosLib(b, optimize, strip, .x86_64, host_os);
    const arm64_lib = buildMacosLib(b, optimize, strip, .aarch64, host_os);

    const lipo_exe: []const u8 = if (host_os == .macos)
        "lipo"
    else
        b.findProgram(&.{"llvm-lipo"}, &.{}) catch
            @panic("llvm-lipo not found in PATH");

    const lipo = b.addSystemCommand(&.{ lipo_exe, "-create" });
    lipo.addArtifactArg(x64_lib);
    lipo.addArtifactArg(arm64_lib);
    lipo.addArg("-output");
    const fat_out = lipo.addOutputFileArg("libsctp-wps.a");

    const install_fat = b.addInstallFileWithDir(
        fat_out,
        .{ .custom = "macos-universal/lib" },
        "libsctp-wps.a",
    );
    const install_header = b.addInstallFileWithDir(
        b.path("include/sctp-wps.h"),
        .{ .custom = "macos-universal/include" },
        "sctp-wps.h",
    );
    b.getInstallStep().dependOn(&install_fat.step);
    b.getInstallStep().dependOn(&install_header.step);
}

/// Build a static macOS library for one CPU architecture.
fn buildMacosLib(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
    arch: std.Target.Cpu.Arch,
    host_os: std.Target.Os.Tag,
) *std.Build.Step.Compile {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = arch,
        .os_tag = .macos,
    });
    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
    });
    addWavpackStream(b, mod, false, target, optimize);
    addUsrsctp(b, mod, target, optimize, host_os);
    return b.addLibrary(.{
        .name = b.fmt("sctp-wps-{s}", .{@tagName(arch)}),
        .root_module = mod,
    });
}

/// Create the TranslateC module for the WavPack-stream header.
/// Expose the module as "wpstream_c".
/// Native Linux builds use one of these link sources:
///     - A system library found with pkg-config.
///     - C sources in the wavpack-stream submodule.
fn addWavpackStream(
    b: *std.Build,
    mod: *std.Build.Module,
    have_system: bool,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    // Translate the WavPack-stream C header through the local shim.
    const wp_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c/wavpack-stream.zig.h"),
        .target = target,
        .optimize = optimize,
    });

    if (have_system) {
        // Use the system WavPack-stream library.
        wp_translate.linkSystemLibrary("wavpack-stream", .{});
        mod.addImport("wpstream_c", wp_translate.createModule());
        mod.linkSystemLibrary("wavpack-stream", .{});
        return;
    }

    wp_translate.addIncludePath(b.path("wavpack-stream/include"));
    mod.addImport("wpstream_c", wp_translate.createModule());

    const wp_src = b.path("wavpack-stream/src");
    const wp_include = b.path("wavpack-stream/include");
    const c_files = collectCFiles(b, wp_src) catch
        @panic("failed to find C sources in wavpack-stream/src");

    // Enable x86_64 assembly for Linux and macOS x86_64 targets.
    const enable_x64_asm = target.result.cpu.arch == .x86_64 and
        (target.result.os.tag == .linux or target.result.os.tag == .macos);

    // The C encoder leaves out2buff null when no correction stream is
    // configured (pack_utils.c:845-846). Adding an offset to null is UB.
    // Disable the undefined-behavior sanitizer for this dependency.
    var c_flags: std.ArrayList([]const u8) = .empty;
    c_flags.appendSlice(b.allocator, &.{
        "-O3",
        "-pipe",
        "-fomit-frame-pointer",
        "-fno-sanitize=undefined",
    }) catch @panic("oom");
    if (target.query.isNative()) {
        c_flags.appendSlice(b.allocator, &.{
            "-march=native",
            "-mtune=native",
        }) catch @panic("oom");
    }
    if (enable_x64_asm) {
        c_flags.append(b.allocator, "-DOPT_ASM_X64") catch @panic("oom");
    }

    mod.addCSourceFiles(.{
        .root = wp_src,
        .files = c_files,
        .flags = c_flags.items,
    });

    if (enable_x64_asm) {
        mod.addCSourceFiles(.{
            .root = wp_src,
            .files = &.{ "pack_x64.S", "unpack_x64.S" },
            .flags = &.{},
        });
    }

    mod.addIncludePath(wp_include);
}

/// Check for a system-wide WavPack-stream installation.
fn haveSystemWavpackStream(b: *std.Build) bool {
    // SAFETY: runAllowFail writes exitCode through its u8 pointer before it is read.
    var exitCode: u8 = undefined;
    _ = b.runAllowFail(
        &[_][]const u8{ "pkg-config", "--exists", "wavpack-stream" },
        &exitCode,
        .ignore,
    ) catch |err| {
        if (err == error.ExitCodeFailure) {
            return false; // pkg-config returned a nonzero status
        }
        return false; // another error occurred
    };
    return true;
}

/// Create the TranslateC module for the usrsctp header.
/// Expose the module as "usrsctp_c" for non-Linux targets.
///
/// SDK requirements for a macOS target:
///     - A macOS host uses the SDK detected by Zig.
///     - A Linux host needs ../macos/MacOSX.sdk.
fn addUsrsctp(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    host_os: std.Target.Os.Tag,
) void {
    if (target.result.os.tag == .linux) return;

    // Translate the usrsctp C header through the local shim.
    const usrsctp_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c/usrsctp.zig.h"),
        .target = target,
        .optimize = optimize,
    });
    usrsctp_translate.addIncludePath(b.path("usrsctp/usrsctplib"));
    mod.addImport("usrsctp_c", usrsctp_translate.createModule());

    const usrsctp_root = b.path("usrsctp/usrsctplib");

    const usrsctp_flags = &.{
        "-D__Userspace__",
        "-DSCTP_SIMPLE_ALLOCATOR",
        "-DSCTP_PROCESS_LEVEL_LOCKS",
        "-DINET",
        "-DINET6",
        "-D__APPLE_USE_RFC_2292",
        "-DHAVE_SA_LEN",
        "-DHAVE_SIN_LEN",
        "-DHAVE_SIN6_LEN",
        "-DHAVE_SCONN_LEN",
        "-Wno-address-of-packed-member",
        "-Wno-deprecated-declarations",
        "-Wno-unused-function",
        "-Wno-unused-variable",
    };

    if (target.result.os.tag == .macos) {
        if (host_os == .macos) {
            if (!std.zig.system.darwin.isSdkInstalled(b.allocator, b.graph.io)) {
                @panic("macOS SDK is not installed. Install Xcode or Command Line Tools");
            }
        } else {
            const sdk = localSDKRoot(b) orelse
                @panic("macOS SDK at ../macos/MacOSX.sdk is expected");
            mod.addSystemIncludePath(.{
                .cwd_relative = b.pathJoin(&.{ sdk, "usr", "include" }),
            });
            mod.addSystemFrameworkPath(.{
                .cwd_relative = b.pathJoin(&.{ sdk, "System", "Library", "Frameworks" }),
            });
        }
    }

    const subdirs = [_][]const u8{ ".", "netinet", "netinet6" };
    for (subdirs) |sub| {
        const src = b.path(b.pathJoin(&.{ "usrsctp/usrsctplib", sub }));
        const files = collectCFiles(b, src) catch
            @panic("failed to find C sources in usrsctp/usrsctplib");
        if (files.len == 0) continue;
        mod.addCSourceFiles(.{
            .root = src,
            .files = files,
            .flags = usrsctp_flags,
        });
    }
    mod.addIncludePath(usrsctp_root);
}

/// Resolve ../macos/MacOSX.sdk to an absolute path when it exists.
fn localSDKRoot(b: *std.Build) ?[]const u8 {
    const root = b.build_root.path orelse return null;
    const path = std.fs.path.join(b.allocator, &.{ root, "..", "macos", "MacOSX.sdk" }) catch
        return null;
    std.Io.Dir.accessAbsolute(b.graph.io, path, .{}) catch return null;
    return path;
}

/// Scan one directory for direct .c files.
fn collectCFiles(b: *std.Build, root: std.Build.LazyPath) ![]const []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer files.deinit(b.allocator);
    const dir_path = root.getPath(b);
    var dir = try std.Io.Dir.openDirAbsolute(b.graph.io, dir_path, .{ .iterate = true });
    defer dir.close(b.graph.io);
    var iter = dir.iterate();
    while (try iter.next(b.graph.io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".c")) {
            try files.append(b.allocator, b.dupe(entry.name));
        }
    }
    return files.toOwnedSlice(b.allocator);
}
