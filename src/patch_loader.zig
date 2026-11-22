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

pub fn loadFromFile(allocator: Allocator, path: []const u8) LoadError!PatchInfo {
    const cwd = Io.Dir.cwd();
    // 检查是否可访问
    cwd.access(io, path, .{ .read = true }) catch |err| {
        std.log.err("Failed to access patch file: {s}", .{path});
        return err;
    };
    return .{
        .name = path,
        .content = try cwd.readFileAlloc(io, path, allocator, .unlimited),
        .from = .external,
    };
}

pub fn getFromEnv(_: Allocator) ?PatchInfo {
    // todo: 读取 build.zig.zon 确定 Zig 版本
    return .{
        .name = "zig-init.0.17.1.patch",
        .content = @embedFile("diff_patchs/zig-init.0.17.1.patch"),
        .from = .builting,
        .env = .zig,
        .ver = "0.17.1",
    };
}
