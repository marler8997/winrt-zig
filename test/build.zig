//! winrt as a project uses it: the Windows SDK's metadata, fetched and given as winmds, and
//! the bindings generated from it, tested against what Windows does.

pub fn build(b: *std.Build) void {
    // the Windows SDK's metadata, as NuGet publishes it for .NET
    const fetch = b.addRunArtifact(b.dependency("winrt", .{}).artifact("fetch"));
    fetch.addArg(sdk_contracts_url);
    fetch.addArg(sdk_contracts_sha256);
    const nupkg = fetch.addOutputFileArg("Microsoft.Windows.SDK.Contracts.nupkg");
    const unzip = b.addRunArtifact(b.dependency("zipcmdline", .{}).artifact("unzip"));
    unzip.addArg("-d");
    const contracts = unzip.addOutputDirectoryArg("contracts");
    unzip.addFileArg(nupkg);
    var winmds: [sdk_winmds.len]std.Build.LazyPath = undefined;
    for (sdk_winmds, &winmds) |name, *w| w.* = contracts.path(b, b.fmt("ref/netstandard2.0/{s}", .{name}));

    const winrt = b.dependency("winrt", .{ .winmds = @as([]const std.Build.LazyPath, &winmds) });
    const win32_mod = b.dependency("win32", .{}).module("win32");
    const t = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("capture.zig"),
        .target = b.graph.host,
        .imports = &.{
            .{ .name = "win32", .module = win32_mod },
            .{ .name = "winrt", .module = winrt.module("winrt") },
        },
    }) });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(t).step);
}

const sdk_contracts_url = "https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.contracts/10.0.28000.2957/microsoft.windows.sdk.contracts.10.0.28000.2957.nupkg";
const sdk_contracts_sha256 = "9fa4ef0e9046d17ded567cc69431924ffe0dc39eed86caea543be3bc23abb971";
/// The platform's types (UniversalApiContract), and the contracts it refers to.
const sdk_winmds = [_][]const u8{
    "Windows.Foundation.FoundationContract.winmd",
    "Windows.Foundation.UniversalApiContract.winmd",
    "Windows.Networking.Connectivity.WwanContract.winmd",
};

const std = @import("std");
