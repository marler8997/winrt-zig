//! fetch URL SHA256 OUT: downloads URL to OUT, which it writes only if the download's sha256
//! is SHA256. For the build: Zig's package fetcher only takes archives it recognizes by
//! Content-Type or extension, and NuGet's .nupkg is neither.

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (debug_allocator.deinit() == .leak) std.debug.panic("fetch leaked memory", .{});
    const gpa = debug_allocator.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{ .environ = init.environ, .argv0 = .init(init.args) });
    defer threaded.deinit();
    const io = threaded.io();

    var args = try init.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();
    const url = args.next() orelse std.debug.panic("usage: fetch URL SHA256 OUT", .{});
    const sha256_hex = args.next() orelse std.debug.panic("usage: fetch URL SHA256 OUT", .{});
    const out_path = args.next() orelse std.debug.panic("usage: fetch URL SHA256 OUT", .{});
    if (args.next()) |extra| std.debug.panic("fetch takes URL, SHA256 and OUT, then got '{s}'", .{extra});
    var want: [32]u8 = undefined;
    if (sha256_hex.len != 64) std.debug.panic("SHA256 '{s}' isn't 64 hex digits", .{sha256_hex});
    _ = std.fmt.hexToBytes(&want, sha256_hex) catch std.debug.panic("SHA256 '{s}' isn't 64 hex digits", .{sha256_hex});

    // Beside OUT, renamed to it once checked: OUT is never a partial or wrong download.
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.fetching", .{out_path});
    defer gpa.free(tmp_path);
    const cwd = std.Io.Dir.cwd();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    {
        const file = cwd.createFile(io, tmp_path, .{}) catch |e| std.debug.panic("creating '{s}': {t}", .{ tmp_path, e });
        defer file.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var file_writer = file.writer(io, &buf);
        const result = client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &file_writer.interface,
        }) catch |e| switch (e) {
            error.WriteFailed => return file_writer.err.?,
            else => std.debug.panic("fetching '{s}': {t}", .{ url, e }),
        };
        if (result.status != .ok) std.debug.panic("fetching '{s}': HTTP {d} {s}", .{ url, @intFromEnum(result.status), result.status.phrase() orelse "" });
        file_writer.interface.flush() catch return file_writer.err.?;
    }

    const got = blk: {
        const file = cwd.openFile(io, tmp_path, .{}) catch |e| std.debug.panic("opening '{s}': {t}", .{ tmp_path, e });
        defer file.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var file_reader = file.reader(io, &buf);
        var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
        while (true) {
            const chunk = file_reader.interface.peekGreedy(1) catch |e| switch (e) {
                error.EndOfStream => break,
                error.ReadFailed => return file_reader.err.?,
            };
            hasher.update(chunk);
            file_reader.interface.toss(chunk.len);
        }
        break :blk hasher.finalResult();
    };
    if (!std.mem.eql(u8, &got, &want)) {
        cwd.deleteFile(io, tmp_path) catch |e| std.debug.panic("deleting '{s}': {t}", .{ tmp_path, e });
        std.debug.panic("'{s}' has sha256 {x}, not {s}", .{ url, &got, sha256_hex });
    }
    std.Io.Dir.rename(cwd, tmp_path, cwd, out_path, io) catch |e| std.debug.panic("renaming '{s}' to '{s}': {t}", .{ tmp_path, out_path, e });
}

const std = @import("std");
