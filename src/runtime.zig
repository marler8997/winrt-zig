//! What the generated bindings use that isn't generated: the ABI types of generic type
//! arguments, WinRT type signatures, and the IIDs of generic instances (computed at comptime
//! from their signatures, as the WinRT type system specifies).

/// Every generated type says what kind it is.
pub const Kind = enum { interface, delegate, class, @"struct", @"enum" };

/// The type a value of `T` has at the ABI: a pointer to the interface for interfaces and
/// delegates (and to its default interface for a runtime class), the value itself otherwise.
pub fn Abi(comptime T: type) type {
    if (T == win32.IInspectable) return ?*win32.IInspectable;
    if (T == win32.HSTRING) return ?win32.HSTRING;
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => if (@hasDecl(T, "winrt_kind")) return switch (T.winrt_kind) {
            .interface, .delegate => ?*T,
            .class => if (@hasDecl(T, "Default")) ?*T.Default else @compileError(@typeName(T) ++ " is a static class, it has no instances"),
            .@"struct", .@"enum" => T,
        },
        else => {},
    }
    return T;
}

/// The WinRT signature of `T`, from which generic instances' IIDs are made.
pub fn signature(comptime T: type) []const u8 {
    return switch (T) {
        win32.IInspectable => "cinterface(IInspectable)",
        win32.HSTRING => "string",
        win32.Guid => "g16",
        bool => "b1",
        u8 => "u1",
        i16 => "i2",
        u16 => "u2",
        i32 => "i4",
        u32 => "u4",
        i64 => "i8",
        u64 => "u8",
        f32 => "f4",
        f64 => "f8",
        else => if (@hasDecl(T, "winrt_signature")) T.winrt_signature else @compileError(@typeName(T) ++ " has no WinRT signature"),
    };
}

/// A generic instance's signature: its generic type's IID (as "{...}") and its arguments'.
pub fn pinterfaceSignature(comptime generic_iid: []const u8, comptime args: []const type) []const u8 {
    comptime var s: []const u8 = "pinterface(" ++ generic_iid;
    inline for (args) |arg| s = s ++ ";" ++ comptime signature(arg);
    return s ++ ")";
}

/// The IID of a type with this signature: a version 5 UUID, the SHA-1 of the signature in the
/// WinRT namespace (11f47ad5-7b73-42c0-abae-878b1e16adee).
pub fn guidFromSignature(comptime sig: []const u8) win32.Guid {
    return comptime blk: {
        @setEvalBranchQuota(100_000 + 1000 * sig.len);
        break :blk uuidV5(sig);
    };
}

fn uuidV5(sig: []const u8) win32.Guid {
    const namespace = [16]u8{ 0x11, 0xf4, 0x7a, 0xd5, 0x7b, 0x73, 0x42, 0xc0, 0xab, 0xae, 0x87, 0x8b, 0x1e, 0x16, 0xad, 0xee };
    var hash = std.crypto.hash.Sha1.init(.{});
    hash.update(&namespace);
    hash.update(sig);
    var digest: [20]u8 = undefined;
    hash.final(&digest);
    digest[6] = (digest[6] & 0x0f) | 0x50;
    digest[8] = (digest[8] & 0x3f) | 0x80;
    // The UUID's bytes are big-endian; a Guid's integers are native.
    return .{ .Ints = .{
        .a = std.mem.readInt(u32, digest[0..4], .big),
        .b = std.mem.readInt(u16, digest[4..6], .big),
        .c = std.mem.readInt(u16, digest[6..8], .big),
        .d = digest[8..16].*,
    } };
}

/// For tests: Guid is a union, which std.testing.expectEqual can't compare.
pub fn expectGuid(expected: win32.Guid, actual: win32.Guid) !void {
    try std.testing.expectEqualSlices(u8, &expected.Bytes, &actual.Bytes);
}

// The IIDs wcap (mmozeiko/wcap) declares for the two capture handlers.
test "a generic instance's IID" {
    const typed_event_handler = "{9de1c534-6ae1-11e0-84e1-18a905bcc53f}";
    const frame_pool = "rc(Windows.Graphics.Capture.Direct3D11CaptureFramePool;{24eb6d22-1975-422e-82e7-780dbd8ddf24})";
    const item = "rc(Windows.Graphics.Capture.GraphicsCaptureItem;{79c3f95b-31f7-4ec2-a464-632ef5d30760})";
    const object = "cinterface(IInspectable)";
    try expectGuid(
        win32.Guid.initString("51a947f7-79cf-5a3e-a3a5-1289cfa6dfe8"),
        guidFromSignature("pinterface(" ++ typed_event_handler ++ ";" ++ frame_pool ++ ";" ++ object ++ ")"),
    );
    try expectGuid(
        win32.Guid.initString("e9c610c0-a68c-5bd9-8021-8589346eeee2"),
        guidFromSignature("pinterface(" ++ typed_event_handler ++ ";" ++ item ++ ";" ++ object ++ ")"),
    );
}

const std = @import("std");
const win32 = @import("win32").everything;
