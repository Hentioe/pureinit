const std = @import("std");
const model = @import("root.zig");
const patch_apply = @import("patch_apply.zig");

const UpdateError = error{
    InvalidRelativePath,
    UnsupportedFileCreation,
    UnsupportedFileDeletion,
    UnsupportedRename,
    NotRegularFile,
};

/// 更新项目目录中的一个已有文件。
///
/// 按 hunk 位置生成完整新内容；只有位置和行数有效后，才原子替换文件。
/// `root_dir` 应是项目根目录，`file_diff` 的路径必须是根目录下的相对路径。
pub fn updateFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    file_diff: model.FileDiff,
) !void {
    const old_path = file_diff.old_path orelse return error.UnsupportedFileCreation;
    const new_path = file_diff.new_path orelse return error.UnsupportedFileDeletion;
    if (!std.mem.eql(u8, old_path, new_path)) return error.UnsupportedRename;
    try validateRelativePath(old_path);

    // 不跟随最终路径上的符号链接，避免把项目目录之外的目标文件替换掉。
    const stat = try root_dir.statFile(io, old_path, .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.NotRegularFile;

    const source = try root_dir.readFileAlloc(io, old_path, allocator, .unlimited);
    defer allocator.free(source);

    const updated = try patch_apply.applyFileDiff(allocator, source, file_diff);
    defer allocator.free(updated);

    // 临时文件写完之前，原文件保持不变；replace 成功后再由 defer 清理 Atomic 状态。
    var atomic_file = try root_dir.createFileAtomic(io, old_path, .{
        .replace = true,
        .permissions = stat.permissions,
    });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, updated);
    try atomic_file.replace(io);
}

fn validateRelativePath(path: []const u8) UpdateError!void {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return error.InvalidRelativePath;

    // 相对路径仍可能通过 `..` 离开项目根目录，因此逐个检查路径组件。
    var components = std.mem.tokenizeScalar(u8, path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.InvalidRelativePath;
    }
}

test "updates an existing file after applying its diff" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "example.txt",
        .data = "before\nremove\nafter\n",
    });

    const diff_lines = [_]model.DiffLine{
        .{ .kind = .context, .text = "", .has_newline = true },
        .{ .kind = .deletion, .text = "remove", .has_newline = true },
        .{ .kind = .addition, .text = "insert", .has_newline = true },
        .{ .kind = .context, .text = "", .has_newline = true },
    };
    const hunks = [_]model.Hunk{
        .{ .old_start = 1, .old_count = 3, .new_start = 1, .new_count = 3, .lines = &diff_lines },
    };
    const file_diff = model.FileDiff{
        .old_path = "example.txt",
        .new_path = "example.txt",
        .hunks = &hunks,
    };
    try updateFile(std.testing.io, std.testing.allocator, tmp.dir, file_diff);

    const actual = try tmp.dir.readFileAlloc(std.testing.io, "example.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("before\ninsert\nafter\n", actual);
}

test "does not modify a file when a hunk is out of bounds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "example.txt",
        .data = "actual\n",
    });

    const diff_lines = [_]model.DiffLine{
        .{ .kind = .deletion, .text = "removed", .has_newline = true },
    };
    const hunks = [_]model.Hunk{
        .{ .old_start = 2, .old_count = 1, .new_start = 1, .new_count = 0, .lines = &diff_lines },
    };
    const file_diff = model.FileDiff{
        .old_path = "example.txt",
        .new_path = "example.txt",
        .hunks = &hunks,
    };
    try std.testing.expectError(
        error.HunkOutOfBounds,
        updateFile(std.testing.io, std.testing.allocator, tmp.dir, file_diff),
    );

    const actual = try tmp.dir.readFileAlloc(std.testing.io, "example.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("actual\n", actual);
}
