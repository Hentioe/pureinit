const std = @import("std");
const Cli = @import("Cli.zig");
const logger = @import("logger");
const pureinit = @import("pureinit");

pub const std_options: std.Options = .{ .logFn = logger.logFn };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var cli = try Cli.parse(init);
    defer cli.deinit();

    if (cli.isHelp()) return cli.help();

    // 获取目标路径
    const target_path = cli.target() orelse ".";

    // 加载/获取补丁内容
    var patch_info: pureinit.patch_loader.PatchInfo = undefined;
    if (cli.patch()) |patch_path| {
        patch_info = try pureinit.patch_loader.loadFromFile(arena, patch_path);
    } else {
        patch_info = try pureinit.patch_loader.getFromEnv(arena, target_path);
    }

    std.debug.print("Patch info:\n", .{});
    // 输出补丁信息
    try patch_info.printTable(arena);

    var patch = try pureinit.diff_parser.parse(arena, patch_info.content);
    defer patch.deinit();

    const working_dir = std.Io.Dir.cwd();
    var target_dir = try working_dir.openDir(init.io, target_path, .{});
    defer target_dir.close(init.io);

    std.debug.print("Apply patch to: '{s}'? [y/N]: ", .{target_path});
    if (!try confirm(init.io)) {
        std.log.warn("Cancelled", .{});
        return;
    }

    for (patch.files) |file_diff| {
        const path = file_diff.new_path orelse file_diff.old_path orelse return error.InvalidFileHeader;
        std.log.info("Applying {s}", .{path});
        try pureinit.file_ops.updateFile(init.io, arena, target_dir, file_diff);
    }
}

fn confirm(io: std.Io) !bool {
    const stdin = std.Io.File.stdin();
    var byte_buffer: [1]u8 = undefined;
    var response: enum { empty, yes, no } = .empty;

    while (true) {
        const count = try stdin.readStreaming(io, &.{&byte_buffer});
        if (count == 0) break;

        switch (byte_buffer[0]) {
            '\n' => break,
            '\r' => continue,
            'y' => if (response == .empty) {
                response = .yes;
            } else {
                response = .no;
            },
            else => response = .no,
        }
    }

    return response == .yes;
}
