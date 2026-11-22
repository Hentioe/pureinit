const std = @import("std");
const pt = @import("prettytable");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const io = std.Io.Threaded.global_single_threaded.io();

pub const LoadError = Io.Dir.AccessError || Io.Dir.ReadFileAllocError || error{
    PatchNotFound,
};

pub const PatchInfo = struct {
    const Self = @This();

    name: []const u8,
    content: []const u8,
    from: enum { builting, external },
    env: ?enum { zig } = null,
    ver: ?[]const u8 = null,

    pub fn printTable(self: *const Self, allocator: Allocator) !void {
        var table = pt.Table.init(allocator);
        defer table.deinit();

        try table.setTitle(&.{
            "name", "from", "env", "ver",
        });

        var env: []const u8 = undefined;
        if (self.env) |t| env = @tagName(t) else env = "unknown";

        try table.addRows(&.{
            &.{ self.name, @tagName(self.from), env, self.ver orelse "unknown" },
        });

        try table.printStdout(io);
    }
};

pub fn loadFromFile(allocator: Allocator, file: []const u8) LoadError!PatchInfo {
    const cwd = Io.Dir.cwd();
    // 检查是否可访问
    cwd.access(io, file, .{ .read = true }) catch |err| {
        std.log.err("Failed to access patch file: {s}", .{file});
        return err;
    };
    return .{
        .name = file,
        .content = try cwd.readFileAlloc(io, file, allocator, .unlimited),
        .from = .external,
    };
}

pub fn getFromEnv(allocator: Allocator, dir: []const u8) !PatchInfo {
    var project_dir = Io.Dir.cwd().openDir(io, dir, .{}) catch |err| {
        std.log.err("Failed to open target directory: {s}", .{dir});
        return err;
    };
    defer project_dir.close(io);

    project_dir.access(io, "build.zig", .{}) catch {
        std.log.err("Target '{s}' is not a Zig project: build.zig was not found", .{dir});
        return error.UnknownEnvironment;
    };

    project_dir.access(io, "build.zig.zon", .{}) catch {
        std.log.err("Target '{s}' is not a Zig project: build.zig.zon was not found", .{dir});
        return error.UnknownEnvironment;
    };

    const zon_bytes = project_dir.readFileAlloc(io, "build.zig.zon", allocator, .unlimited) catch |err| {
        std.log.err("Failed to read build.zig.zon in: {s}", .{dir});
        return err;
    };
    const zon_source_mut = try allocator.alloc(u8, zon_bytes.len + 1);
    @memcpy(zon_source_mut[0..zon_bytes.len], zon_bytes);
    zon_source_mut[zon_bytes.len] = 0;
    const zon_source: [:0]const u8 = zon_source_mut[0..zon_bytes.len :0];

    const Manifest = struct {
        minimum_zig_version: ?[]const u8 = null,
    };

    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const manifest = std.zon.parse.fromSlice(Manifest, .{
        .gpa = allocator,
        .arena = allocator,
        .source = zon_source,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.ParseZon => {
            std.log.err("Failed to extract Zig version from build.zig.zon in '{s}'", .{dir});
            return error.VersionNotFound;
        },
    };

    const version = manifest.minimum_zig_version orelse {
        std.log.err("Failed to extract Zig version from build.zig.zon in '{s}'", .{dir});
        return error.VersionNotFound;
    };

    return patches.get(version) orelse {
        std.log.err("Patch for Zig version '{s}' was not found", .{version});
        return error.PatchNotFound;
    };
}

const versions = .{
    "0.16.0",
    "0.17.0",
    "0.17.1",
};

pub const patches: std.StaticStringMap(PatchInfo) = .initComptime(blk: {
    var entries: [versions.len]struct { []const u8, PatchInfo } = undefined;
    for (versions, 0..) |ver, i| {
        entries[i] = .{ ver, .{
            .name = "zig-init." ++ ver ++ ".patch",
            .content = @embedFile("diff_patchs/zig-init." ++ ver ++ ".patch"),
            .from = .builting,
            .env = .zig,
            .ver = ver,
        } };
    }
    break :blk entries;
});
