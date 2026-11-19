//! winrtgen OUT WINMD...: writes Zig bindings for every type in the WINMD files to OUT, one
//! file with a struct per namespace. Generic interfaces and delegates are functions of their
//! type arguments.
//!
//! Every type the metadata refers to must be in one of the WINMD files. Those that aren't are
//! listed at the end by the assembly that defines them (a .winmd of the same name), and
//! winrtgen fails.

pub const std_options: std.Options = .{
    // winmd logs every table it parses
    .log_level = .warn,
};

pub fn main(init: std.process.Init.Minimal) !void {
    // What lives as long as the process: the metadata (types refer into its string heaps),
    // the name index, the namespace tree. Freed by exiting.
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    // What one type's emission needs (its signatures, attributes, type names): reset after
    // each type, so it never holds more than the biggest type's.
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var args = init.args.iterateAllocator(arena) catch oom();
    _ = args.skip();
    const out_path = args.next() orelse errExit("usage: winrtgen OUT WINMD...", .{});
    var g: Gen = .{ .arena = arena, .scratch = &scratch };
    while (args.next()) |path| {
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |e| errExit("reading '{s}': {t}", .{ path, e });
        g.addFile(path, content);
    }
    if (g.files.items.len == 0) errExit("no WINMD files", .{});

    {
        const out = std.Io.Dir.cwd().createFile(io, out_path, .{}) catch |e| errExit("creating '{s}': {t}", .{ out_path, e });
        defer out.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var out_writer = out.writer(io, &buf);
        g.emit(&out_writer.interface) catch return out_writer.err.?;
        out_writer.interface.flush() catch return out_writer.err.?;
    }

    if (g.missing.count() > 0) {
        std.log.err("the metadata refers to types in {} more .winmd file(s):", .{g.missing.count()});
        for (g.missing.keys(), g.missing.values()) |assembly, m|
            std.log.err("    {s}.winmd ({} types, e.g. {f})", .{ assembly, m.count, m.example });
        std.process.exit(0xff);
    }
}

/// One .winmd file's metadata.
const File = struct {
    path: []const u8,
    strings: ?[]const u8,
    blobs: ?[]const u8,
    tables: winmd.Tables,
    attrs: winmd.Map(.CustomAttr),
    impls: winmd.Map(.InterfaceImpl),
    constants: winmd.Map(.Constant),

    fn str(f: *const File, index: winmd.StringHeapIndex) []const u8 {
        return winmd.getString(f.strings, index) orelse errExit("{s}: bad string index {}", .{ f.path, @backingInt(index) });
    }
    fn blob(f: *const File, index: winmd.BlobHeapIndex) []const u8 {
        return winmd.getBlob(f.blobs, index) orelse errExit("{s}: bad blob index {}", .{ f.path, @backingInt(index) });
    }
};

/// A TypeDef, in one of the files.
const TypeId = struct { file: u32, index: u32 };

const Kind = enum { interface, delegate, class, @"struct", @"enum", attribute };

const Prim = enum {
    void,
    bool,
    char,
    i8,
    u8,
    i16,
    u16,
    i32,
    u32,
    i64,
    u64,
    f32,
    f64,
    string,
    object,
    guid,

    fn zig(p: Prim) []const u8 {
        return switch (p) {
            .void => "void",
            .bool => "bool",
            .char => "u16",
            .string => "?win32.HSTRING",
            .object => "?*win32.IInspectable",
            .guid => "win32.Guid",
            else => @tagName(p),
        };
    }
    /// As a generic type argument: a type the runtime gives a signature.
    fn arg(p: Prim) ?[]const u8 {
        return switch (p) {
            .void => null,
            .char => "u16",
            .string => "win32.HSTRING",
            .object => "win32.IInspectable",
            .guid => "win32.Guid",
            else => @tagName(p),
        };
    }
    fn signature(p: Prim) []const u8 {
        return switch (p) {
            .void => unreachable,
            .bool => "b1",
            .char => "c2",
            .i8 => "i1",
            .u8 => "u1",
            .i16 => "i2",
            .u16 => "u2",
            .i32 => "i4",
            .u32 => "u4",
            .i64 => "i8",
            .u64 => "u8",
            .f32 => "f4",
            .f64 => "f8",
            .string => "string",
            .object => "cinterface(IInspectable)",
            .guid => "g16",
        };
    }
};

/// A type, as a signature describes it.
const Sig = union(enum) {
    prim: Prim,
    def: TypeId,
    /// A generic type's parameter, by number.
    generic_param: u32,
    inst: struct { def: TypeId, args: []const Sig },
    szarray: *const Sig,
    byref: *const Sig,
    /// Not in the metadata given.
    missing: Missing,
};

/// A type's full name, as the metadata has it: slices of a file's string heap.
const QName = struct {
    ns: []const u8,
    name: []const u8,

    /// From "Namespace.Name".
    fn parse(full: []const u8) ?QName {
        const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse return null;
        return .{ .ns = full[0..dot], .name = full[dot + 1 ..] };
    }
    fn is(q: QName, ns: []const u8, name: []const u8) bool {
        return std.mem.eql(u8, q.ns, ns) and std.mem.eql(u8, q.name, name);
    }
    pub fn format(q: QName, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}.{s}", .{ q.ns, q.name });
    }

    const Context = struct {
        pub fn hash(_: Context, q: QName) u64 {
            var h: std.hash.Wyhash = .init(0);
            h.update(q.ns);
            h.update(".");
            h.update(q.name);
            return h.final();
        }
        pub fn eql(_: Context, a: QName, b: QName) bool {
            return a.is(b.ns, b.name);
        }
    };
    fn Map(comptime V: type) type {
        return std.HashMapUnmanaged(QName, V, Context, std.hash_map.default_max_load_percentage);
    }
};

/// A type in none of the WINMD files, and the assembly that defines it.
const Missing = struct { name: QName, assembly: []const u8 };

const Gen = struct {
    /// For the life of the process.
    arena: std.mem.Allocator,
    /// For the type being emitted: reset after each.
    scratch: *std.heap.ArenaAllocator,
    files: std.ArrayList(File) = .empty,
    /// Every TypeDef by its full name.
    types: QName.Map(TypeId) = .empty,
    /// The types emitted code refers to that no WINMD file has, by the assembly defining them.
    missing: std.StringArrayHashMapUnmanaged(struct { count: u32, example: QName }) = .empty,
    /// Missing types already counted.
    missing_names: QName.Map(void) = .empty,
    /// The namespaces around what's being emitted, outermost first.
    scopes: std.ArrayList(*const Ns) = .empty,

    fn tmp(g: *const Gen) std.mem.Allocator {
        return g.scratch.allocator();
    }
    /// A string for the type being emitted.
    fn print(g: *const Gen, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(g.tmp(), fmt, args) catch oom();
    }

    fn addFile(g: *Gen, path: []const u8, content: []const u8) void {
        var err: winmd.MetadataError = undefined;
        const md = winmd.locateMetadata(&err, content) catch errExit("{s}: {f}", .{ path, err });
        const streams = winmd.parseStreams(&err, content, md) catch errExit("{s}: {f}", .{ path, err });
        const tables_stream = streams.tables orelse errExit("{s}: no tables stream", .{path});
        const tables = winmd.parseTables(&err, content, md + tables_stream.offset) catch errExit("{s}: {f}", .{ path, err });
        const new_file: File = .{
            .path = path,
            .strings = if (streams.strings) |s| content[md + s.offset ..][0..s.size] else null,
            .blobs = if (streams.blob) |s| content[md + s.offset ..][0..s.size] else null,
            .tables = tables,
            .attrs = winmd.Map(.CustomAttr).alloc(g.arena, &tables, .{}) catch oom(),
            .impls = winmd.Map(.InterfaceImpl).alloc(g.arena, &tables) catch oom(),
            .constants = winmd.Map(.Constant).alloc(g.arena, &tables) catch oom(),
        };
        const file_index: u32 = @intCast(g.files.items.len);
        g.files.append(g.arena, new_file) catch oom();
        const f = &g.files.items[file_index];
        for (0..tables.row_counts.TypeDef) |i| {
            const td = tables.row(.TypeDef, i);
            const q: QName = .{ .ns = f.str(td.namespace), .name = f.str(td.name) };
            // <Module> and nested types have no namespace
            if (q.ns.len == 0) continue;
            const entry = g.types.getOrPut(g.arena, q) catch oom();
            if (entry.found_existing) errExit("'{f}' is in both {s} and {s}", .{ q, g.files.items[entry.value_ptr.file].path, path });
            entry.value_ptr.* = .{ .file = file_index, .index = @intCast(i) };
        }
    }

    fn file(g: *const Gen, id: TypeId) *const File {
        return &g.files.items[id.file];
    }
    fn typeDef(g: *const Gen, id: TypeId) winmd.Row(.TypeDef) {
        return g.file(id).tables.row(.TypeDef, id.index);
    }
    fn namespace(g: *const Gen, id: TypeId) []const u8 {
        return g.file(id).str(g.typeDef(id).namespace);
    }
    /// The metadata's name: generic ones end in `N.
    fn rawName(g: *const Gen, id: TypeId) []const u8 {
        return g.file(id).str(g.typeDef(id).name);
    }
    fn name(g: *const Gen, id: TypeId) []const u8 {
        const raw = g.rawName(id);
        return raw[0 .. std.mem.indexOfScalar(u8, raw, '`') orelse raw.len];
    }
    fn fullName(g: *const Gen, id: TypeId) QName {
        return .{ .ns = g.namespace(id), .name = g.rawName(id) };
    }

    /// The full name of a TypeDefOrRef in `f`.
    fn typeRefName(f: *const File, table: winmd.TypeTable, index: u32) QName {
        return switch (table) {
            .TypeDef => blk: {
                const td = f.tables.row(.TypeDef, index);
                break :blk .{ .ns = f.str(td.namespace), .name = f.str(td.name) };
            },
            .TypeRef => blk: {
                const tr = f.tables.row(.TypeRef, index);
                break :blk .{ .ns = f.str(tr.namespace), .name = f.str(tr.name) };
            },
            .TypeSpec => errExit("{s}: a TypeSpec where a name was expected", .{f.path}),
        };
    }

    fn kind(g: *const Gen, id: TypeId) Kind {
        const td = g.typeDef(id);
        if (td.attributes.interface) return .interface;
        const extends = td.extends.value() orelse return .class;
        const base = typeRefName(g.file(id), switch (extends.table) {
            .TypeDef => .TypeDef,
            .TypeRef => .TypeRef,
            .TypeSpec => .TypeSpec,
            _ => errExit("{s}: bad extends table", .{g.file(id).path}),
        }, extends.index);
        if (base.is("System", "Enum")) return .@"enum";
        if (base.is("System", "ValueType")) return .@"struct";
        if (base.is("System", "MulticastDelegate")) return .delegate;
        if (base.is("System", "Attribute")) return .attribute;
        return .class;
    }

    /// Counts a type emitted code needs that no WINMD file has. What it emits in its place
    /// doesn't matter: winrtgen fails. (Its name and assembly are in a file's string heap,
    /// which lives as long as the process.)
    fn noteMissing(g: *Gen, m: Missing) void {
        if ((g.missing_names.getOrPut(g.arena, m.name) catch oom()).found_existing) return;
        const entry = g.missing.getOrPut(g.arena, m.assembly) catch oom();
        if (entry.found_existing) {
            entry.value_ptr.count += 1;
        } else entry.value_ptr.* = .{ .count = 1, .example = m.name };
    }

    fn typeDefOrRef(g: *const Gen, file_index: u32, t: winmd.Type) Sig {
        const v = t.value() orelse errExit("{s}: a null type", .{g.files.items[file_index].path});
        return g.resolve(file_index, switch (v.table) {
            .TypeDef => .TypeDef,
            .TypeRef => .TypeRef,
            .TypeSpec => .TypeSpec,
            _ => errExit("bad type table", .{}),
        }, v.index);
    }

    fn resolve(g: *const Gen, file_index: u32, table: winmd.TypeTable, index: u32) Sig {
        const f = &g.files.items[file_index];
        switch (table) {
            .TypeDef => return .{ .def = .{ .file = file_index, .index = index } },
            .TypeSpec => {
                var bytes = f.blob(f.tables.row(.TypeSpec, index).signature);
                return g.decodeType(file_index, &bytes);
            },
            .TypeRef => {
                const full = typeRefName(f, .TypeRef, index);
                if (full.is("System", "Guid")) return .{ .prim = .guid };
                if (g.types.get(full)) |id| return .{ .def = id };
                const scope = f.tables.row(.TypeRef, index).resolution_scope;
                const assembly_index = scope.index.asIndex() orelse errExit("{s}: type {f} has no resolution scope", .{ f.path, full });
                if (scope.table != .AssemblyRef) errExit("{s}: type {f} isn't in this file or another assembly ({t})", .{ f.path, full, scope.table });
                return .{ .missing = .{ .name = full, .assembly = f.str(f.tables.row(.AssemblyRef, assembly_index).name) } };
            },
        }
    }

    fn decodeType(g: *const Gen, file_index: u32, bytes: *[]const u8) Sig {
        const f = &g.files.items[file_index];
        const b = takeByte(f, bytes);
        // custom modifiers (IsConst, IsByValue) don't change the ABI
        if (b == 0x1f or b == 0x20) {
            _ = takeUnsigned(f, bytes);
            return g.decodeType(file_index, bytes);
        }
        const et = winmd.ElementType.decode(b) orelse errExit("{s}: unknown element type 0x{x}", .{ f.path, b });
        return switch (et) {
            .void => .{ .prim = .void },
            .boolean => .{ .prim = .bool },
            .char => .{ .prim = .char },
            .i1 => .{ .prim = .i8 },
            .u1 => .{ .prim = .u8 },
            .i2 => .{ .prim = .i16 },
            .u2 => .{ .prim = .u16 },
            .i4 => .{ .prim = .i32 },
            .u4 => .{ .prim = .u32 },
            .i8 => .{ .prim = .i64 },
            .u8 => .{ .prim = .u64 },
            .r4 => .{ .prim = .f32 },
            .r8 => .{ .prim = .f64 },
            .string => .{ .prim = .string },
            .object => .{ .prim = .object },
            .valuetype, .class => g.decodeTypeToken(file_index, bytes),
            .@"var" => .{ .generic_param = takeUnsigned(f, bytes) },
            .genericinst => blk: {
                _ = takeByte(f, bytes); // class or valuetype
                const generic = g.decodeTypeToken(file_index, bytes);
                const count = takeUnsigned(f, bytes);
                const args = g.tmp().alloc(Sig, count) catch oom();
                for (args) |*a| a.* = g.decodeType(file_index, bytes);
                break :blk switch (generic) {
                    .def => |d| .{ .inst = .{ .def = d, .args = args } },
                    else => generic,
                };
            },
            .szarray => .{ .szarray = g.decodeTypeAlloc(file_index, bytes) },
            .byref => .{ .byref = g.decodeTypeAlloc(file_index, bytes) },
            else => errExit("{s}: unsupported element type {t}", .{ f.path, et }),
        };
    }

    fn decodeTypeAlloc(g: *const Gen, file_index: u32, bytes: *[]const u8) *const Sig {
        const e = g.tmp().create(Sig) catch oom();
        e.* = g.decodeType(file_index, bytes);
        return e;
    }

    fn decodeTypeToken(g: *const Gen, file_index: u32, bytes: *[]const u8) Sig {
        const f = &g.files.items[file_index];
        const decoded = (@as(winmd.TypeToken, @fromBackingInt(@intCast(takeUnsigned(f, bytes))))).decode() catch errExit("{s}: bad type token", .{f.path});
        return g.resolve(file_index, switch (decoded.table) {
            .TypeDef => .TypeDef,
            .TypeRef => .TypeRef,
            .TypeSpec => .TypeSpec,
            _ => errExit("{s}: bad token table", .{f.path}),
        }, decoded.index);
    }

    const MethodSig = struct { ret: Sig, params: []const Sig };

    fn methodSig(g: *const Gen, file_index: u32, method: u32) MethodSig {
        const f = &g.files.items[file_index];
        var bytes = f.blob(f.tables.row(.MethodDef, method).signature);
        _ = takeByte(f, &bytes); // calling convention
        const count = takeUnsigned(f, &bytes);
        const ret = g.decodeType(file_index, &bytes);
        const params = g.tmp().alloc(Sig, count) catch oom();
        for (params) |*p| p.* = g.decodeType(file_index, &bytes);
        return .{ .ret = ret, .params = params };
    }

    fn fieldSig(g: *const Gen, file_index: u32, field: u32) Sig {
        const f = &g.files.items[file_index];
        var bytes = f.blob(f.tables.row(.Field, field).signature);
        if (takeByte(f, &bytes) != 0x06) errExit("{s}: field {} has no field signature", .{ f.path, field });
        return g.decodeType(file_index, &bytes);
    }

    // ---- custom attributes ----

    const Attr = struct { name: QName, args: []const AttrArg };
    const AttrArg = union(enum) { int: i64, string: ?[]const u8 };

    /// The attributes on a TypeDef, MethodDef or InterfaceImpl, with their fixed arguments.
    fn attrs(g: *const Gen, file_index: u32, parent: winmd.CustomAttrParent) []const Attr {
        const f = &g.files.items[file_index];
        var list: std.ArrayList(Attr) = .empty;
        var it = f.attrs.getIterator(parent);
        while (it.next()) |i| {
            const row = f.tables.row(.CustomAttr, i);
            const ctor_index = row.method.index.asIndex() orelse continue;
            const type_name: QName, const ctor_sig: []const u8 = switch (row.method.table) {
                .MemberRef => blk: {
                    const mr = f.tables.row(.MemberRef, ctor_index);
                    const p = mr.parent.index.asIndex() orelse continue;
                    break :blk .{ switch (mr.parent.table) {
                        .TypeRef => typeRefName(f, .TypeRef, p),
                        .TypeDef => typeRefName(f, .TypeDef, p),
                        else => continue,
                    }, f.blob(mr.signature) };
                },
                .MethodDef => .{ typeRefName(f, .TypeDef, g.methodOwner(file_index, ctor_index)), f.blob(f.tables.row(.MethodDef, ctor_index).signature) },
                _ => continue,
            };
            list.append(g.tmp(), .{ .name = type_name, .args = g.attrArgs(file_index, ctor_sig, f.blob(row.value)) }) catch oom();
        }
        return list.items;
    }

    fn methodOwner(g: *const Gen, file_index: u32, method: u32) u32 {
        const f = &g.files.items[file_index];
        for (0..f.tables.row_counts.TypeDef) |i| {
            const range = f.tables.typeDefRange(@intCast(i), .methods);
            if (method >= range.start and method < range.limit) return @intCast(i);
        }
        errExit("{s}: no TypeDef owns method {}", .{ f.path, method });
    }

    fn attrArgs(g: *const Gen, file_index: u32, ctor_sig: []const u8, value: []const u8) []const AttrArg {
        const f = &g.files.items[file_index];
        var sig = ctor_sig;
        _ = takeByte(f, &sig);
        const count = takeUnsigned(f, &sig);
        _ = g.decodeType(file_index, &sig); // void
        var v = value;
        if (v.len < 2 or v[0] != 1 or v[1] != 0) errExit("{s}: an attribute without its prolog", .{f.path});
        v = v[2..];
        const args = g.tmp().alloc(AttrArg, count) catch oom();
        for (args) |*a| {
            a.* = switch (g.decodeType(file_index, &sig)) {
                .prim => |prim| switch (prim) {
                    .bool, .u8 => .{ .int = takeLe(f, &v, u8) },
                    .i8 => .{ .int = @as(i8, @bitCast(takeLe(f, &v, u8))) },
                    .u16, .char => .{ .int = takeLe(f, &v, u16) },
                    .i16 => .{ .int = @as(i16, @bitCast(takeLe(f, &v, u16))) },
                    .u32 => .{ .int = takeLe(f, &v, u32) },
                    .i32 => .{ .int = @as(i32, @bitCast(takeLe(f, &v, u32))) },
                    .u64 => .{ .int = @bitCast(takeLe(f, &v, u64)) },
                    .i64 => .{ .int = @bitCast(takeLe(f, &v, u64)) },
                    .string => .{ .string = takeSerString(f, &v) },
                    else => errExit("{s}: unsupported attribute argument {t}", .{ f.path, prim }),
                },
                // System.Type: its name
                .missing => .{ .string = takeSerString(f, &v) },
                // an enum: its underlying int, which WinRT has as i4 or u4
                .def => .{ .int = takeLe(f, &v, u32) },
                else => errExit("{s}: unsupported attribute argument", .{f.path}),
            };
        }
        return args;
    }

    /// One of WinRT's attributes (Windows.Foundation.Metadata.NAME).
    fn findAttr(list: []const Attr, attr_name: []const u8) ?Attr {
        for (list) |a| if (a.name.is("Windows.Foundation.Metadata", attr_name)) return a;
        return null;
    }

    /// A TypeDef's GuidAttribute.
    fn guid(g: *const Gen, id: TypeId) [16]u8 {
        const list = g.attrs(id.file, .init(.TypeDef, @intCast(id.index)));
        const a = findAttr(list, "GuidAttribute") orelse errExit("{f} has no GuidAttribute", .{g.fullName(id)});
        if (a.args.len != 11) errExit("{f}: GuidAttribute has {} arguments", .{ g.fullName(id), a.args.len });
        var out: [16]u8 = undefined;
        std.mem.writeInt(u32, out[0..4], @intCast(a.args[0].int), .big);
        std.mem.writeInt(u16, out[4..6], @intCast(a.args[1].int), .big);
        std.mem.writeInt(u16, out[6..8], @intCast(a.args[2].int), .big);
        for (a.args[3..], out[8..]) |arg, *o| o.* = @intCast(arg.int);
        return out;
    }

    const ClassInfo = struct { default: ?Sig, statics: []const TypeId, factories: []const TypeId };

    fn classInfo(g: *Gen, id: TypeId) ClassInfo {
        const f = g.file(id);
        var default: ?Sig = null;
        var it = f.impls.getIterator(id.index);
        while (it.next()) |impl_index| {
            const list = g.attrs(id.file, .init(.InterfaceImpl, @intCast(impl_index)));
            if (findAttr(list, "DefaultAttribute") != null)
                default = g.typeDefOrRef(id.file, f.tables.row(.InterfaceImpl, impl_index).interface);
        }
        var statics: std.ArrayList(TypeId) = .empty;
        var factories: std.ArrayList(TypeId) = .empty;
        for (g.attrs(id.file, .init(.TypeDef, @intCast(id.index)))) |a| {
            const list = if (a.name.is("Windows.Foundation.Metadata", "StaticAttribute"))
                &statics
            else if (a.name.is("Windows.Foundation.Metadata", "ActivatableAttribute"))
                &factories
            else
                continue;
            // ActivatableAttribute(version) has no factory: activated with IActivationFactory
            if (a.args.len == 0) continue;
            const type_name = switch (a.args[0]) {
                .string => |s| s orelse continue,
                .int => continue,
            };
            // a type in another assembly is "Namespace.Name, Assembly, Version=..."
            const comma = std.mem.indexOfScalar(u8, type_name, ',');
            const q = QName.parse(type_name[0 .. comma orelse type_name.len]) orelse errExit("{f}: a type name without a namespace: '{s}'", .{ g.fullName(id), type_name });
            if (g.types.get(q)) |t| {
                list.append(g.tmp(), t) catch oom();
            } else if (comma) |c| {
                var rest = std.mem.splitScalar(u8, type_name[c + 1 ..], ',');
                g.noteMissing(.{ .name = q, .assembly = std.mem.trim(u8, rest.first(), " ") });
            } else errExit("{f}: no type '{s}'", .{ g.fullName(id), type_name });
        }
        return .{ .default = default, .statics = statics.items, .factories = factories.items };
    }

    // ---- emitting ----

    const Error = std.Io.Writer.Error;

    fn emit(g: *Gen, w: *std.Io.Writer) Error!void {
        try w.writeAll(
            \\//! Generated by winrt-zig's winrtgen: don't edit.
            \\
            \\const std = @import("std");
            \\const win32 = @import("win32").everything;
            \\pub const runtime = @import("winrt_runtime");
            \\
            \\
        );
        // namespaces as nested structs, their types in the files' order
        var root: Ns = .{};
        for ([_][]const u8{ "std", "win32", "runtime" }) |decl| root.decls.put(g.arena, decl, {}) catch oom();
        for (g.files.items, 0..) |*f, file_index| for (0..f.tables.row_counts.TypeDef) |i| {
            const id: TypeId = .{ .file = @intCast(file_index), .index = @intCast(i) };
            // <Module> and nested types have no namespace; attributes are metadata about types
            if (g.namespace(id).len == 0 or g.kind(id) == .attribute) continue;
            var node = &root;
            var parts = std.mem.splitScalar(u8, g.namespace(id), '.');
            while (parts.next()) |part| {
                const entry = node.children.getOrPut(g.arena, part) catch oom();
                if (!entry.found_existing) {
                    entry.value_ptr.* = g.arena.create(Ns) catch oom();
                    entry.value_ptr.*.* = .{};
                    node.decls.put(g.arena, part, {}) catch oom();
                }
                node = entry.value_ptr.*;
            }
            node.types.append(g.arena, id) catch oom();
            node.decls.put(g.arena, g.name(id), {}) catch oom();
        };
        try g.emitNs(w, &root, 0);
    }

    const Ns = struct {
        children: std.StringArrayHashMapUnmanaged(*Ns) = .empty,
        types: std.ArrayList(TypeId) = .empty,
        /// Its types' and child namespaces' names: what a parameter inside mustn't be named.
        decls: std.StringHashMapUnmanaged(void) = .empty,
    };

    fn emitNs(g: *Gen, w: *std.Io.Writer, ns: *const Ns, depth: usize) Error!void {
        g.scopes.append(g.arena, ns) catch oom();
        defer _ = g.scopes.pop();
        for (ns.types.items) |id| {
            try g.emitType(w, id, depth);
            _ = g.scratch.reset(.retain_capacity);
        }
        for (ns.children.keys(), ns.children.values()) |child_name, child| {
            try indent(w, depth);
            try w.print("pub const {f} = struct {{\n", .{std.zig.fmtId(child_name)});
            try g.emitNs(w, child, depth + 1);
            try indent(w, depth);
            try w.writeAll("};\n");
        }
    }

    /// A parameter's name, with _ appended while it would shadow a declaration (Zig forbids
    /// that) or another parameter.
    fn paramIdent(g: *const Gen, locals: *const Locals, taken: []const []const u8, metadata_name: []const u8) []const u8 {
        var n = metadata_name;
        while (g.declared(locals, n) or for (taken) |t| {
            if (std.mem.eql(u8, t, n)) break true;
        } else false) n = g.print("{s}_", .{n});
        return n;
    }

    fn declared(g: *const Gen, locals: *const Locals, ident: []const u8) bool {
        if (locals.contains(ident)) return true;
        for (g.scopes.items) |ns| if (ns.decls.contains(ident)) return true;
        return false;
    }

    /// What an interface declares, besides its namespace's names.
    const Locals = std.StringHashMapUnmanaged(void);

    fn emitType(g: *Gen, w: *std.Io.Writer, id: TypeId, d: usize) Error!void {
        switch (g.kind(id)) {
            .attribute => unreachable,
            .@"enum" => try g.emitEnum(w, id, d),
            .@"struct" => try g.emitStruct(w, id, d),
            .class => try g.emitClass(w, id, d),
            .interface, .delegate => try g.emitInterface(w, id, d),
        }
    }

    /// An enum's underlying type: its value__ field's.
    fn enumTag(g: *const Gen, id: TypeId) Prim {
        const f = g.file(id);
        const fields = f.tables.typeDefRange(id.index, .fields);
        for (fields.start..fields.limit) |fi| {
            if (std.mem.eql(u8, f.str(f.tables.row(.Field, fi).name), "value__"))
                return g.fieldSig(id.file, @intCast(fi)).prim;
        }
        errExit("enum {f} has no value__ field", .{g.fullName(id)});
    }

    fn emitEnum(g: *Gen, w: *std.Io.Writer, id: TypeId, d: usize) Error!void {
        const f = g.file(id);
        const fields = f.tables.typeDefRange(id.index, .fields);
        const tag = g.enumTag(id);
        try indent(w, d);
        try w.print("pub const {f} = enum({s}) {{\n", .{ std.zig.fmtId(g.name(id)), tag.zig() });
        for (fields.start..fields.limit) |fi| {
            const field_name = f.str(f.tables.row(.Field, fi).name);
            if (std.mem.eql(u8, field_name, "value__")) continue;
            const ci = f.constants.get(.init(.Field, @intCast(fi))) orelse errExit("{f}.{s} has no value", .{ g.fullName(id), field_name });
            const bytes = f.blob(f.tables.row(.Constant, ci).value);
            if (bytes.len != 4) errExit("{f}.{s}'s value is {} bytes", .{ g.fullName(id), field_name, bytes.len });
            try indent(w, d + 1);
            switch (tag) {
                .u32 => try w.print("{f} = {d},\n", .{ std.zig.fmtId(field_name), std.mem.readInt(u32, bytes[0..4], .little) }),
                else => try w.print("{f} = {d},\n", .{ std.zig.fmtId(field_name), std.mem.readInt(i32, bytes[0..4], .little) }),
            }
        }
        try indent(w, d + 1);
        try w.writeAll("_,\n");
        try indent(w, d + 1);
        try w.writeAll("pub const winrt_kind: runtime.Kind = .@\"enum\";\n");
        try indent(w, d + 1);
        try w.print("pub const winrt_signature = \"{s}\";\n", .{g.signature(.{ .def = id })});
        try indent(w, d);
        try w.writeAll("};\n");
    }

    fn emitStruct(g: *Gen, w: *std.Io.Writer, id: TypeId, d: usize) Error!void {
        const f = g.file(id);
        const fields = f.tables.typeDefRange(id.index, .fields);
        try indent(w, d);
        try w.print("pub const {f} = extern struct {{\n", .{std.zig.fmtId(g.name(id))});
        for (fields.start..fields.limit) |fi| {
            try indent(w, d + 1);
            try w.print("{f}: {s},\n", .{ std.zig.fmtId(f.str(f.tables.row(.Field, fi).name)), g.zigType(g.fieldSig(id.file, @intCast(fi)), .{}) });
        }
        try indent(w, d + 1);
        try w.writeAll("pub const winrt_kind: runtime.Kind = .@\"struct\";\n");
        try indent(w, d + 1);
        try w.print("pub const winrt_signature = \"{s}\";\n", .{g.signature(.{ .def = id })});
        try indent(w, d);
        try w.writeAll("};\n");
    }

    fn emitClass(g: *Gen, w: *std.Io.Writer, id: TypeId, d: usize) Error!void {
        const info = g.classInfo(id);
        try indent(w, d);
        try w.print("pub const {f} = struct {{\n", .{std.zig.fmtId(g.name(id))});
        try indent(w, d + 1);
        try w.writeAll("pub const winrt_kind: runtime.Kind = .class;\n");
        try indent(w, d + 1);
        try w.print("pub const winrt_name = \"{f}\";\n", .{g.fullName(id)});
        if (info.default) |default| {
            try indent(w, d + 1);
            try w.print("pub const Default = {s};\n", .{g.typeExpr(default, .{})});
            try indent(w, d + 1);
            try w.print("pub const winrt_signature = \"rc({f};{s})\";\n", .{ g.fullName(id), g.signature(default) });
        }
        for (info.statics) |s| {
            try indent(w, d + 1);
            try w.print("pub const {f} = {s};\n", .{ std.zig.fmtId(g.name(s)), g.typePath(s) });
        }
        for (info.factories) |s| {
            try indent(w, d + 1);
            try w.print("pub const {f} = {s};\n", .{ std.zig.fmtId(g.name(s)), g.typePath(s) });
        }
        try indent(w, d);
        try w.writeAll("};\n");
    }

    const Generic = struct { params: []const []const u8 = &.{} };

    fn genericParams(g: *const Gen, id: TypeId) []const []const u8 {
        const f = g.file(id);
        var list: std.ArrayList([]const u8) = .empty;
        const owner: u32 = (id.index + 1) << 1; // TypeOrMethodDef, TypeDef
        for (0..f.tables.row_counts.GenericParam) |i| {
            const gp = f.tables.row(.GenericParam, i);
            if (gp.owner != owner) continue;
            if (gp.number != list.items.len) errExit("{f}: generic parameters out of order", .{g.fullName(id)});
            list.append(g.tmp(), f.str(gp.name)) catch oom();
        }
        return list.items;
    }

    fn emitInterface(g: *Gen, w: *std.Io.Writer, id: TypeId, d: usize) Error!void {
        const f = g.file(id);
        const is_delegate = g.kind(id) == .delegate;
        const params = g.genericParams(id);
        const generic: Generic = .{ .params = params };
        const iid = g.guid(id);
        var b = d;
        try indent(w, d);
        if (params.len == 0) {
            try w.print("pub const {f} = extern union {{\n", .{std.zig.fmtId(g.name(id))});
        } else {
            try w.print("pub fn {f}(", .{std.zig.fmtId(g.name(id))});
            for (params, 0..) |p, i| try w.print("{s}comptime {f}: type", .{ if (i == 0) "" else ", ", std.zig.fmtId(p) });
            try w.writeAll(") type {\n");
            try indent(w, d + 1);
            try w.writeAll("return extern union {\n");
            b = d + 1;
        }
        const inner = b + 1;
        try indent(w, inner);
        try w.writeAll("const Self = @This();\n");
        try indent(w, inner);
        try w.print("pub const winrt_kind: runtime.Kind = .{s};\n", .{if (is_delegate) "delegate" else "interface"});
        if (params.len == 0) {
            try indent(w, inner);
            try w.print("pub const winrt_signature = \"{{{f}}}\";\n", .{fmtGuid(iid)});
            try indent(w, inner);
            try w.print("pub const IID = &win32.Guid.initString(\"{f}\");\n", .{fmtGuid(iid)});
        } else {
            try indent(w, inner);
            try w.print("pub const winrt_signature = runtime.pinterfaceSignature(\"{{{f}}}\", &.{{", .{fmtGuid(iid)});
            for (params, 0..) |p, i| try w.print("{s}{f}", .{ if (i == 0) "" else ", ", std.zig.fmtId(p) });
            try w.writeAll("});\n");
            try indent(w, inner);
            try w.writeAll("pub const IID = &runtime.guidFromSignature(winrt_signature);\n");
        }

        const methods = f.tables.typeDefRange(id.index, .methods);
        var locals: Locals = .empty;
        for ([_][]const u8{ "Self", "VTable", "IID", "winrt_kind", "winrt_signature" }) |decl| locals.put(g.tmp(), decl, {}) catch oom();
        for (params) |p| locals.put(g.tmp(), p, {}) catch oom();
        for (methods.start..methods.limit) |m| locals.put(g.tmp(), g.methodName(id.file, @intCast(m)), {}) catch oom();
        // the vtable
        try indent(w, inner);
        try w.writeAll("pub const VTable = extern struct {\n");
        try indent(w, inner + 1);
        try w.print("base: win32.{s}.VTable,\n", .{if (is_delegate) "IUnknown" else "IInspectable"});
        for (methods.start..methods.limit) |m| {
            // a delegate's constructor isn't in its vtable
            if (is_delegate and !std.mem.eql(u8, f.str(f.tables.row(.MethodDef, m).name), "Invoke")) continue;
            try indent(w, inner + 1);
            try w.print("{f}: *const fn (self: *const Self", .{std.zig.fmtId(g.methodName(id.file, @intCast(m)))});
            try g.emitParams(w, id.file, @intCast(m), generic, &locals, .types);
            try w.writeAll(") callconv(.winapi) win32.HRESULT,\n");
        }
        try indent(w, inner);
        try w.writeAll("};\n");
        try indent(w, inner);
        try w.writeAll("vtable: *const VTable,\n");
        try indent(w, inner);
        try w.writeAll("IUnknown: win32.IUnknown,\n");
        if (!is_delegate) {
            try indent(w, inner);
            try w.writeAll("IInspectable: win32.IInspectable,\n");
        }
        // the methods
        for (methods.start..methods.limit) |m| {
            if (is_delegate and !std.mem.eql(u8, f.str(f.tables.row(.MethodDef, m).name), "Invoke")) continue;
            const method_name = g.methodName(id.file, @intCast(m));
            try indent(w, inner);
            try w.print("pub inline fn {f}(self: *const Self", .{std.zig.fmtId(method_name)});
            try g.emitParams(w, id.file, @intCast(m), generic, &locals, .types);
            try w.writeAll(") win32.HRESULT {\n");
            try indent(w, inner + 1);
            try w.print("return self.vtable.{f}(self", .{std.zig.fmtId(method_name)});
            try g.emitParams(w, id.file, @intCast(m), generic, &locals, .names);
            try w.writeAll(");\n");
            try indent(w, inner);
            try w.writeAll("}\n");
        }
        if (params.len == 0) {
            try indent(w, d);
            try w.writeAll("};\n");
        } else {
            try indent(w, d + 1);
            try w.writeAll("};\n");
            try indent(w, d);
            try w.writeAll("}\n");
        }
    }

    /// A method's ABI name: its OverloadAttribute's, if it has one.
    fn methodName(g: *const Gen, file_index: u32, m: u32) []const u8 {
        const f = &g.files.items[file_index];
        const list = g.attrs(file_index, .init(.MethodDef, @intCast(m)));
        if (findAttr(list, "OverloadAttribute")) |a| {
            if (a.args.len == 1) if (a.args[0].string) |s| return s;
        }
        return f.str(f.tables.row(.MethodDef, m).name);
    }

    /// A method's parameters after self, as the ABI has them: arrays as a length and a pointer,
    /// and its return value as a last out parameter (result).
    fn emitParams(g: *Gen, w: *std.Io.Writer, file_index: u32, m: u32, generic: Generic, locals: *const Locals, what: enum { types, names }) Error!void {
        const f = &g.files.items[file_index];
        const sig = g.methodSig(file_index, m);
        const range = f.tables.methodParams(m);
        // self, the parameters, then result
        const names = g.tmp().alloc([]const u8, 1 + sig.params.len + 1) catch oom();
        names[0] = "self";
        for (sig.params, names[1..][0..sig.params.len], 1..) |_, *n, i|
            n.* = g.paramIdent(locals, names[0..i], g.paramName(file_index, range, @intCast(i)));
        const result_name = std.zig.fmtId(g.paramIdent(locals, names[0 .. 1 + sig.params.len], "result"));
        for (sig.params, names[1..][0..sig.params.len]) |p, n| {
            const param_name = std.zig.fmtId(n);
            switch (p) {
                .szarray => |e| switch (what) {
                    .types => try w.print(", {f}_len: u32, {f}: ?[*]{s}", .{ param_name, param_name, g.zigType(e.*, generic) }),
                    .names => try w.print(", {f}_len, {f}", .{ param_name, param_name }),
                },
                .byref => |e| switch (e.*) {
                    .szarray => |ae| switch (what) {
                        .types => try w.print(", {f}_len: *u32, {f}: *?[*]{s}", .{ param_name, param_name, g.zigType(ae.*, generic) }),
                        .names => try w.print(", {f}_len, {f}", .{ param_name, param_name }),
                    },
                    else => switch (what) {
                        .types => try w.print(", {f}: *{s}", .{ param_name, g.zigType(e.*, generic) }),
                        .names => try w.print(", {f}", .{param_name}),
                    },
                },
                else => switch (what) {
                    .types => try w.print(", {f}: {s}", .{ param_name, g.zigType(p, generic) }),
                    .names => try w.print(", {f}", .{param_name}),
                },
            }
        }
        switch (sig.ret) {
            .prim => |prim| if (prim == .void) return,
            else => {},
        }
        switch (sig.ret) {
            .szarray => |e| switch (what) {
                .types => try w.print(", {f}_len: *u32, {f}: *?[*]{s}", .{ result_name, result_name, g.zigType(e.*, generic) }),
                .names => try w.print(", {f}_len, {f}", .{ result_name, result_name }),
            },
            else => switch (what) {
                .types => try w.print(", {f}: *{s}", .{ result_name, g.zigType(sig.ret, generic) }),
                .names => try w.print(", {f}", .{result_name}),
            },
        }
    }

    fn paramName(g: *const Gen, file_index: u32, range: winmd.RowRange, sequence: u32) []const u8 {
        const f = &g.files.items[file_index];
        for (range.start..range.limit) |pi| {
            const p = f.tables.row(.Param, pi);
            if (p.sequence == sequence) return f.str(p.name);
        }
        return g.print("arg{d}", .{sequence});
    }

    /// The type a value has at the ABI.
    fn zigType(g: *Gen, sig: Sig, generic: Generic) []const u8 {
        return switch (sig) {
            .prim => |p| p.zig(),
            .def => |d| switch (g.kind(d)) {
                .@"struct", .@"enum" => g.typePath(d),
                .interface, .delegate => blk: {
                    if (g.genericParams(d).len != 0) errExit("generic {f} used without type arguments", .{g.fullName(d)});
                    break :blk g.print("?*{s}", .{g.typePath(d)});
                },
                .class => blk: {
                    if (g.classInfo(d).default == null) errExit("{f} has no instances (no default interface), yet a method uses one", .{g.fullName(d)});
                    break :blk g.print("?*{s}.Default", .{g.typePath(d)});
                },
                .attribute => errExit("a method uses the attribute {f}", .{g.fullName(d)}),
            },
            .generic_param => |n| g.print("runtime.Abi({f})", .{std.zig.fmtId(generic.params[n])}),
            .inst => |inst| switch (g.kind(inst.def)) {
                .interface, .delegate => g.print("?*{s}", .{g.typeExpr(sig, generic)}),
                else => |k| errExit("generic {t} {f} isn't supported", .{ k, g.fullName(inst.def) }),
            },
            .szarray => |e| g.print("?[*]{s}", .{g.zigType(e.*, generic)}),
            .byref => |e| g.print("*{s}", .{g.zigType(e.*, generic)}),
            .missing => |m| blk: {
                g.noteMissing(m);
                break :blk "?*anyopaque";
            },
        };
    }

    /// The Zig type that stands for a WinRT type, e.g. as a generic type argument.
    fn typeExpr(g: *Gen, sig: Sig, generic: Generic) []const u8 {
        return switch (sig) {
            .prim => |p| p.arg() orelse errExit("void as a type argument", .{}),
            .def => |d| g.typePath(d),
            .generic_param => |n| g.print("{f}", .{std.zig.fmtId(generic.params[n])}),
            .inst => |inst| blk: {
                var s: std.ArrayList(u8) = .empty;
                s.print(g.tmp(), "{s}(", .{g.typePath(inst.def)}) catch oom();
                for (inst.args, 0..) |a, i| s.print(g.tmp(), "{s}{s}", .{ if (i == 0) "" else ", ", g.typeExpr(a, generic) }) catch oom();
                s.append(g.tmp(), ')') catch oom();
                break :blk s.items;
            },
            .szarray, .byref => errExit("an array or reference as a type argument", .{}),
            .missing => |m| blk: {
                g.noteMissing(m);
                break :blk "anyopaque";
            },
        };
    }

    /// The path from the file's root: Windows.Graphics.SizeInt32.
    fn typePath(g: *const Gen, id: TypeId) []const u8 {
        var s: std.ArrayList(u8) = .empty;
        var parts = std.mem.splitScalar(u8, g.namespace(id), '.');
        while (parts.next()) |part| s.print(g.tmp(), "{f}.", .{std.zig.fmtId(part)}) catch oom();
        s.print(g.tmp(), "{f}", .{std.zig.fmtId(g.name(id))}) catch oom();
        return s.items;
    }

    /// The WinRT signature of a type, from which generic instances' IIDs are made.
    fn signature(g: *Gen, sig: Sig) []const u8 {
        return switch (sig) {
            .prim => |p| p.signature(),
            .def => |d| switch (g.kind(d)) {
                .@"struct" => blk: {
                    const f = g.file(d);
                    const fields = f.tables.typeDefRange(d.index, .fields);
                    var s: std.ArrayList(u8) = .empty;
                    s.print(g.tmp(), "struct({f}", .{g.fullName(d)}) catch oom();
                    for (fields.start..fields.limit) |fi| s.print(g.tmp(), ";{s}", .{g.signature(g.fieldSig(d.file, @intCast(fi)))}) catch oom();
                    s.append(g.tmp(), ')') catch oom();
                    break :blk s.items;
                },
                .@"enum" => g.print("enum({f};{s})", .{ g.fullName(d), g.enumTag(d).signature() }),
                .interface => g.print("{{{f}}}", .{fmtGuid(g.guid(d))}),
                .delegate => g.print("delegate({{{f}}})", .{fmtGuid(g.guid(d))}),
                .class => blk: {
                    const default = g.classInfo(d).default orelse errExit("{f} has no default interface", .{g.fullName(d)});
                    break :blk g.print("rc({f};{s})", .{ g.fullName(d), g.signature(default) });
                },
                .attribute => unreachable,
            },
            .inst => |inst| blk: {
                var s: std.ArrayList(u8) = .empty;
                s.print(g.tmp(), "pinterface({{{f}}}", .{fmtGuid(g.guid(inst.def))}) catch oom();
                for (inst.args) |a| s.print(g.tmp(), ";{s}", .{g.signature(a)}) catch oom();
                s.append(g.tmp(), ')') catch oom();
                break :blk s.items;
            },
            .missing => |m| blk: {
                g.noteMissing(m);
                break :blk "?";
            },
            .generic_param, .szarray, .byref => errExit("no signature for a {t}", .{sig}),
        };
    }
};

fn indent(w: *std.Io.Writer, depth: usize) std.Io.Writer.Error!void {
    try w.splatByteAll(' ', depth * 4);
}

/// A GUID's 16 bytes (big-endian, as in a UUID) as "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx".
fn fmtGuid(bytes: [16]u8) std.fmt.Alt([16]u8, formatGuid) {
    return .{ .data = bytes };
}
fn formatGuid(b: [16]u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{x}-{x}-{x}-{x}-{x}", .{ b[0..4], b[4..6], b[6..8], b[8..10], b[10..16] });
}

fn takeByte(f: *const File, bytes: *[]const u8) u8 {
    if (bytes.len == 0) errExit("{s}: a signature ends early", .{f.path});
    defer bytes.* = bytes.*[1..];
    return bytes.*[0];
}

fn takeUnsigned(f: *const File, bytes: *[]const u8) u32 {
    if (bytes.len == 0) errExit("{s}: a signature ends early", .{f.path});
    const len = @backingInt(winmd.decodeSigUnsignedLen(bytes.*[0]));
    if (bytes.len < len) errExit("{s}: a signature ends early", .{f.path});
    defer bytes.* = bytes.*[len..];
    return winmd.decodeSigUnsigned(bytes.*);
}

fn takeLe(f: *const File, bytes: *[]const u8, comptime T: type) T {
    if (bytes.len < @sizeOf(T)) errExit("{s}: an attribute's value ends early", .{f.path});
    defer bytes.* = bytes.*[@sizeOf(T)..];
    return std.mem.readInt(T, bytes.*[0..@sizeOf(T)], .little);
}

/// A SerString: a compressed length then UTF-8, or 0xff for null.
fn takeSerString(f: *const File, bytes: *[]const u8) ?[]const u8 {
    if (bytes.len > 0 and bytes.*[0] == 0xff) {
        bytes.* = bytes.*[1..];
        return null;
    }
    const len = takeUnsigned(f, bytes);
    if (bytes.len < len) errExit("{s}: an attribute's string ends early", .{f.path});
    defer bytes.* = bytes.*[len..];
    return bytes.*[0..len];
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

fn oom() noreturn {
    @panic("out of memory");
}

const std = @import("std");
const winmd = @import("winmd");
