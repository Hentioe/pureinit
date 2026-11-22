const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root.zig");

pub const ApplyError = Allocator.Error || error{
    InvalidHunkRange,
    HunksOutOfOrder,
    HunkOutOfBounds,
    InconsistentHunkCounts,
    InvalidLineEnding,
};

const Line = struct {
    text: []const u8,
    has_newline: bool,
};

/// 在内存中应用一个文件的 hunk，返回新内容；不读取或写入任何文件。
/// 调用者负责使用传入的 allocator 释放返回的字节切片。
pub fn applyFileDiff(allocator: std.mem.Allocator, source: []const u8, file_diff: root.FileDiff) ApplyError![]u8 {
    var source_lines = try splitLines(allocator, source);
    defer source_lines.deinit(allocator);

    var output_lines: std.ArrayList(Line) = .empty;
    defer output_lines.deinit(allocator);

    var source_cursor: usize = 0;
    for (file_diff.hunks) |hunk| {
        // unified diff 行号从 1 开始；零行范围的 start 表示插入点前有多少行。
        if (hunk.old_count > 0 and hunk.old_start == 0) return error.InvalidHunkRange;
        const old_index = if (hunk.old_count == 0) hunk.old_start else hunk.old_start - 1;
        if (old_index < source_cursor) return error.HunksOutOfOrder;
        if (old_index > source_lines.items.len) return error.HunkOutOfBounds;

        // hunk 之间未提及的行原样复制。hunk 的旧坐标都相对于原文件。
        while (source_cursor < old_index) : (source_cursor += 1) {
            try output_lines.append(allocator, source_lines.items[source_cursor]);
        }

        // 新侧起点也应落在当前输出位置；零行范围使用“之前已有的行数”作为起点。
        const expected_new_start = output_lines.items.len + @intFromBool(hunk.new_count > 0);
        if (hunk.new_start != expected_new_start) return error.InvalidHunkRange;

        var old_seen: usize = 0;
        var new_seen: usize = 0;
        for (hunk.lines) |diff_line| {
            const consumes_old = diff_line.kind != .addition;
            const consumes_new = diff_line.kind != .deletion;
            if ((consumes_old and old_seen >= hunk.old_count) or
                (consumes_new and new_seen >= hunk.new_count))
            {
                return error.InconsistentHunkCounts;
            }

            if (consumes_old) {
                if (source_cursor >= source_lines.items.len) return error.HunkOutOfBounds;
                source_cursor += 1;
                old_seen += 1;
            }

            if (diff_line.kind != .deletion) {
                if (diff_line.kind == .context) {
                    // 上下文只表示当前位置不变；不比较补丁中的文本，直接保留目标文件对应行。
                    try output_lines.append(allocator, source_lines.items[source_cursor - 1]);
                } else {
                    try output_lines.append(allocator, .{
                        .text = diff_line.text,
                        .has_newline = diff_line.has_newline,
                    });
                }
                new_seen += 1;
            }
        }

        if (old_seen != hunk.old_count or new_seen != hunk.new_count) {
            return error.InconsistentHunkCounts;
        }
    }

    while (source_cursor < source_lines.items.len) : (source_cursor += 1) {
        try output_lines.append(allocator, source_lines.items[source_cursor]);
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    for (output_lines.items, 0..) |line, index| {
        // 没有换行符的行只能出现在文件末尾，否则下一行无法与它分隔。
        if (!line.has_newline and index + 1 < output_lines.items.len) return error.InvalidLineEnding;
        try output.appendSlice(allocator, line.text);
        if (line.has_newline) try output.append(allocator, '\n');
    }
    return try output.toOwnedSlice(allocator);
}

fn splitLines(allocator: std.mem.Allocator, source: []const u8) Allocator.Error!std.ArrayList(Line) {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(allocator);

    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, source, start, '\n')) |end| {
        try lines.append(allocator, .{ .text = source[start..end], .has_newline = true });
        start = end + 1;
    }
    if (start < source.len) {
        try lines.append(allocator, .{ .text = source[start..], .has_newline = false });
    }
    return lines;
}

test "applies edits by position without matching context text" {
    const diff_lines = [_]root.DiffLine{
        .{ .kind = .context, .text = "", .has_newline = true },
        .{ .kind = .deletion, .text = "remove", .has_newline = true },
        .{ .kind = .addition, .text = "insert", .has_newline = true },
        .{ .kind = .context, .text = "", .has_newline = true },
    };
    const hunks = [_]root.Hunk{
        .{ .old_start = 1, .old_count = 3, .new_start = 1, .new_count = 3, .lines = &diff_lines },
    };
    const file_diff = root.FileDiff{
        .old_path = "example.txt",
        .new_path = "example.txt",
        .hunks = &hunks,
    };
    const actual = try applyFileDiff(std.testing.allocator, "project header\nremove\nproject footer\n", file_diff);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("project header\ninsert\nproject footer\n", actual);
}

test "applies an insertion at the beginning of a file" {
    const diff_lines = [_]root.DiffLine{
        .{ .kind = .addition, .text = "first", .has_newline = true },
    };
    const hunks = [_]root.Hunk{
        .{ .old_start = 0, .old_count = 0, .new_start = 1, .new_count = 1, .lines = &diff_lines },
    };
    const file_diff = root.FileDiff{ .old_path = null, .new_path = "example.txt", .hunks = &hunks };
    const actual = try applyFileDiff(std.testing.allocator, "rest\n", file_diff);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("first\nrest\n", actual);
}

test "rejects a hunk beyond the source line range" {
    const diff_lines = [_]root.DiffLine{
        .{ .kind = .deletion, .text = "removed", .has_newline = true },
    };
    const hunks = [_]root.Hunk{
        .{ .old_start = 2, .old_count = 1, .new_start = 1, .new_count = 0, .lines = &diff_lines },
    };
    const file_diff = root.FileDiff{ .old_path = "example.txt", .new_path = null, .hunks = &hunks };
    try std.testing.expectError(
        error.HunkOutOfBounds,
        applyFileDiff(std.testing.allocator, "actual\n", file_diff),
    );
}
