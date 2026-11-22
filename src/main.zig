const std = @import("std");
const Cli = @import("Cli.zig");
const logger = @import("logger");
const pureinit = @import("pureinit");
const zig_init_patch = @embedFile("diff_patchs/zig-init.0.17.1.patch");

pub const std_options: std.Options = .{ .logFn = logger.logFn };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var cli = try Cli.parse(init);
    defer cli.deinit();

    if (cli.isHelp()) return cli.help();

    // 获取目标路径
    const target_path = cli.target() orelse ".";

    const working_dir = std.Io.Dir.cwd();
    var patch = try pureinit.diff_parser.parse(arena, zig_init_patch);
    defer patch.deinit();

    var target_dir = try working_dir.openDir(init.io, target_path, .{});
    defer target_dir.close(init.io);

    std.debug.print("Apply cleanup patch to: '{s}'? [y/N] ", .{target_path});
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
