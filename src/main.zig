const std = @import("std");
const codec = @import("codec");
const zig_init_patch = @embedFile("diff_patchs/zig-init.0.17.1.patch");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    // args[0] 是程序名；除此之外最多接收一个目标目录。
    if (args.len > 2) return error.TooManyArguments;
    const target_path = if (args.len == 2) args[1] else ".";

    const working_dir = std.Io.Dir.cwd();
    var patch = try codec.diff_parser.parse(allocator, zig_init_patch);
    defer patch.deinit();

    var target_dir = try working_dir.openDir(init.io, target_path, .{});
    defer target_dir.close(init.io);

    std.debug.print("Apply cleanup patch to '{s}'? [y/N] ", .{target_path});
    if (!try confirm(init.io)) {
        std.debug.print("Cancelled.\n", .{});
        return;
    }

    for (patch.files) |file_diff| {
        const path = file_diff.new_path orelse file_diff.old_path orelse return error.InvalidFileHeader;
        std.debug.print("Applying {s}\n", .{path});
        try codec.file_ops.updateFile(init.io, allocator, target_dir, file_diff);
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
