pub fn build(b: *std.Build) void {
    const fetch_exe = b.addExecutable(.{
        .name = "fetch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fetch.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    b.installArtifact(fetch_exe);

    const win32_mod = b.dependency("win32", .{}).module("win32");
    const runtime_mod = b.addModule("winrt_runtime", .{
        .root_source_file = b.path("src/runtime.zig"),
        .imports = &.{.{ .name = "win32", .module = win32_mod }},
    });
    const gen_exe = b.addExecutable(.{
        .name = "winrtgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "winmd", .module = b.dependency("winmd", .{}).module("winmd") }},
        }),
    });
    b.installArtifact(gen_exe);

    _ = b.addModule("winrt", .{
        .root_source_file = if (b.option([]const std.Build.LazyPath, "winmds", "The .winmd files module(\"winrt\") is generated from")) |winmds|
            generate(b, gen_exe, winmds)
        else
            failingFile(b, "winrt: module(\"winrt\") needs the winmds option: the .winmd files to generate bindings for"),
        .imports = &.{
            .{ .name = "win32", .module = win32_mod },
            .{ .name = "winrt_runtime", .module = runtime_mod },
        },
    });

    // the generated bindings are tested as a project uses them: test/build.zig
    const t = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/runtime.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "win32", .module = win32_mod }},
    }) });
    b.step("test", "Run the runtime's tests (the bindings': cd test && zig build test)").dependOn(&b.addRunArtifact(t).step);
}

fn generate(b: *std.Build, gen_exe: *std.Build.Step.Compile, winmds: []const std.Build.LazyPath) std.Build.LazyPath {
    const run = b.addRunArtifact(gen_exe);
    const out = run.addOutputFileArg("winrt.zig");
    for (winmds) |w| run.addFileArg(w);
    return out;
}

/// A file that fails the build with `msg` if anything uses it.
fn failingFile(b: *std.Build, msg: []const u8) std.Build.LazyPath {
    const write = b.addWriteFiles();
    write.step.dependOn(&b.addFail(msg).step);
    return write.add("winrt.zig", "");
}

const std = @import("std");
