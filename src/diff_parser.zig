const std = @import("std");
const model = @import("root.zig");

const ParseError = error{
    InvalidPatch,
    InvalidFileHeader,
    InvalidHunkHeader,
    InvalidHunkLine,
    InvalidNoNewlineMarker,
    InconsistentHunkCounts,
};

const Range = struct {
    start: usize,
    count: usize,
};

const HunkHeader = struct {
    old: Range,
    new: Range,
};

/// 解析 Git 生成的 unified diff。
///
/// 一个文件的 diff 通常包含 `diff --git` 文件标记、`---`/`+++` 两侧路径，
/// 然后是一个或多个以 `@@` 开始的 hunk。hunk 中每行开头的空格、`-`、`+`
/// 分别表示上下文、删除和新增。
///
/// 返回的 Patch 会复制解析结果，因此不依赖 input 的生命周期；调用者需要调用
/// Patch.deinit() 释放这些副本。
pub fn parse(parent_allocator: std.mem.Allocator, input: []const u8) !model.Patch {
    // 把本次解析产生的所有分配集中到一个 arena。失败时整体释放，成功时交给 Patch 持有。
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    // 按 LF 切开便于逐行识别语法；暂时保留 CR，因为它也可能是 CRLF 文件内容的一部分。
    var source_lines: std.ArrayList([]const u8) = .empty;
    var offset: usize = 0;
    while (std.mem.indexOfScalarPos(u8, input, offset, '\n')) |end| {
        try source_lines.append(allocator, input[offset..end]);
        offset = end + 1;
    }
    if (offset < input.len) try source_lines.append(allocator, input[offset..]);

    var files: std.ArrayList(model.FileDiff) = .empty;
    var cursor: usize = 0;
    while (cursor < source_lines.items.len) {
        // 一个 `diff --git` 标记一个文件；跳过它之前的邮件说明或其他补丁外文本。
        while (cursor < source_lines.items.len and
            !std.mem.startsWith(u8, source_lines.items[cursor], "diff --git ")) : (cursor += 1)
        {}
        if (cursor == source_lines.items.len) break;
        cursor += 1;

        var old_path: ?[]const u8 = null;
        var new_path: ?[]const u8 = null;
        var found_old_path = false;
        var found_new_path = false;

        // index、文件模式等头部元数据不参与文本改动；这里只提取 --- 和 +++ 指定的路径。
        while (cursor < source_lines.items.len) {
            const line = source_lines.items[cursor];
            if (std.mem.startsWith(u8, line, "diff --git ") or
                std.mem.startsWith(u8, line, "@@ ")) break;

            if (std.mem.startsWith(u8, line, "--- ")) {
                old_path = try parsePath(allocator, line, "--- ");
                found_old_path = true;
            } else if (std.mem.startsWith(u8, line, "+++ ")) {
                new_path = try parsePath(allocator, line, "+++ ");
                found_new_path = true;
            }
            cursor += 1;
        }

        if (!found_old_path or !found_new_path) return error.InvalidFileHeader;

        var hunks: std.ArrayList(model.Hunk) = .empty;
        // 一个文件可以有多个彼此分开的改动区域，每个区域都由 @@ 头部开始。
        while (cursor < source_lines.items.len and
            std.mem.startsWith(u8, source_lines.items[cursor], "@@ "))
        {
            try hunks.append(allocator, try parseHunk(allocator, source_lines.items, &cursor));
        }

        try files.append(allocator, .{
            .old_path = old_path,
            .new_path = new_path,
            .hunks = try hunks.toOwnedSlice(allocator),
        });
    }

    if (files.items.len == 0) return error.InvalidPatch;
    return .{
        .arena = arena,
        .files = try files.toOwnedSlice(allocator),
    };
}

fn parsePath(allocator: std.mem.Allocator, line: []const u8, header: []const u8) !?[]const u8 {
    var path = stripTrailingCarriageReturn(line[header.len..]);
    if (std.mem.indexOfScalar(u8, path, '\t')) |tab| path = path[0..tab];
    // /dev/null 表示文件只存在于一侧：旧路径为空是新建文件，新路径为空是删除文件。
    if (std.mem.eql(u8, path, "/dev/null")) return null;

    // Git 通常给旧、新路径加 a/ 和 b/ 前缀；模型只保留项目内的相对路径。
    if (std.mem.startsWith(u8, path, "a/") or std.mem.startsWith(u8, path, "b/")) {
        path = path[2..];
    }
    return try allocator.dupe(u8, path);
}

fn parseHunk(allocator: std.mem.Allocator, lines: []const []const u8, cursor: *usize) !model.Hunk {
    const header = try parseHunkHeader(lines[cursor.*]);
    cursor.* += 1;

    var diff_lines: std.ArrayList(model.DiffLine) = .empty;
    var old_seen: usize = 0;
    var new_seen: usize = 0;

    while (cursor.* < lines.len) {
        const line = lines[cursor.*];
        if (std.mem.startsWith(u8, line, "\\")) {
            // 这是 diff 的说明行，不是文件内容；它修饰紧邻的上一行，也不计入 hunk 行数。
            if (!std.mem.eql(u8, stripTrailingCarriageReturn(line), "\\ No newline at end of file") or
                diff_lines.items.len == 0)
            {
                return error.InvalidNoNewlineMarker;
            }
            diff_lines.items[diff_lines.items.len - 1].has_newline = false;
            cursor.* += 1;
            continue;
        }

        // 两侧声明的行数都读完后，hunk 结束；若仍出现内容行，说明头部计数不可信。
        if (old_seen == header.old.count and new_seen == header.new.count) {
            if (line.len > 0 and (line[0] == ' ' or line[0] == '+' or line[0] == '-')) {
                return error.InconsistentHunkCounts;
            }
            break;
        }
        if (line.len == 0) return error.InvalidHunkLine;

        // 首字符是 diff 的操作标记，后面的字节才是实际文本。
        const kind: model.DiffLine.Kind = switch (line[0]) {
            ' ' => .context,
            '+' => .addition,
            '-' => .deletion,
            else => return error.InvalidHunkLine,
        };

        // 上下文行同时计入新旧两侧；删除只推进旧文件计数，新增只推进新文件计数。
        // 一侧计数已满却还要向该侧添加行时，补丁与 @@ 头部矛盾，必须拒绝。
        if ((kind != .addition and old_seen == header.old.count) or
            (kind != .deletion and new_seen == header.new.count))
        {
            return error.InconsistentHunkCounts;
        }

        if (kind != .addition) old_seen += 1;
        if (kind != .deletion) new_seen += 1;
        try diff_lines.append(allocator, .{
            .kind = kind,
            // 应用时只需要上下文行占据的位置；仅保存新增和删除行的文本。
            .text = if (kind == .context) "" else try allocator.dupe(u8, line[1..]),
            .has_newline = true,
        });
        cursor.* += 1;
    }

    if (old_seen != header.old.count or new_seen != header.new.count) {
        return error.InconsistentHunkCounts;
    }

    return .{
        .old_start = header.old.start,
        .old_count = header.old.count,
        .new_start = header.new.start,
        .new_count = header.new.count,
        .lines = try diff_lines.toOwnedSlice(allocator),
    };
}

fn parseHunkHeader(line: []const u8) ParseError!HunkHeader {
    // `@@ -旧起点,旧行数 +新起点,新行数 @@` 描述 hunk 在两份文件中的位置和长度。
    // 行数可以省略；例如 `-5 +5` 表示两侧各一行。
    if (!std.mem.startsWith(u8, line, "@@ -")) return error.InvalidHunkHeader;
    const old_start = 4;
    const old_end = (std.mem.indexOfScalar(u8, line[old_start..], ' ') orelse
        return error.InvalidHunkHeader) + old_start;
    const old_range = try parseRange(line[old_start..old_end]);

    const new_token_start = old_end + 2;
    if (new_token_start > line.len or line[old_end + 1] != '+') return error.InvalidHunkHeader;
    const new_end = (std.mem.indexOfScalar(u8, line[new_token_start..], ' ') orelse
        return error.InvalidHunkHeader) + new_token_start;
    if (!std.mem.startsWith(u8, line[new_end..], " @@")) return error.InvalidHunkHeader;
    const new_range = try parseRange(line[new_token_start..new_end]);

    return .{ .old = old_range, .new = new_range };
}

fn parseRange(token: []const u8) ParseError!Range {
    // 范围 token 是 `起点,行数`；没有逗号时，unified diff 约定行数为 1。
    if (std.mem.indexOfScalar(u8, token, ',')) |comma| {
        return .{
            .start = std.fmt.parseInt(usize, token[0..comma], 10) catch return error.InvalidHunkHeader,
            .count = std.fmt.parseInt(usize, token[comma + 1 ..], 10) catch return error.InvalidHunkHeader,
        };
    }
    return .{
        .start = std.fmt.parseInt(usize, token, 10) catch return error.InvalidHunkHeader,
        .count = 1,
    };
}

fn stripTrailingCarriageReturn(line: []const u8) []const u8 {
    // CRLF 按 LF 切行后会留下末尾 CR；语法头需要去掉它，hunk 正文则保留它。
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

test "parses file paths, hunk ranges, and line kinds" {
    const input =
        "diff --git a/src/file.zig b/src/file.zig\n" ++
        "index 1111111..2222222 100644\n" ++
        "--- a/src/file.zig\n" ++
        "+++ b/src/file.zig\n" ++
        "@@ -2,3 +2,4 @@\n" ++
        " keep\n" ++
        "-old\n" ++
        "+new\n" ++
        "+tail\n" ++
        " end\n";
    var patch = try parse(std.testing.allocator, input);
    defer patch.deinit();

    try std.testing.expectEqual(@as(usize, 1), patch.files.len);
    try std.testing.expectEqualStrings("src/file.zig", patch.files[0].old_path.?);
    try std.testing.expectEqualStrings("src/file.zig", patch.files[0].new_path.?);
    try std.testing.expectEqual(@as(usize, 2), patch.files[0].hunks[0].old_start);
    try std.testing.expectEqual(@as(usize, 3), patch.files[0].hunks[0].old_count);
    try std.testing.expectEqual(@as(usize, 4), patch.files[0].hunks[0].new_count);
    try std.testing.expectEqual(model.DiffLine.Kind.context, patch.files[0].hunks[0].lines[0].kind);
    try std.testing.expectEqualStrings("", patch.files[0].hunks[0].lines[0].text);
    try std.testing.expectEqual(model.DiffLine.Kind.deletion, patch.files[0].hunks[0].lines[1].kind);
    try std.testing.expectEqual(model.DiffLine.Kind.addition, patch.files[0].hunks[0].lines[2].kind);
}

test "records lines without a final newline" {
    const input =
        "diff --git a/file b/file\n" ++
        "--- a/file\n" ++
        "+++ b/file\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "\\ No newline at end of file\n" ++
        "+new\n" ++
        "\\ No newline at end of file\n";
    var patch = try parse(std.testing.allocator, input);
    defer patch.deinit();

    const diff_lines = patch.files[0].hunks[0].lines;
    try std.testing.expect(!diff_lines[0].has_newline);
    try std.testing.expect(!diff_lines[1].has_newline);
}

test "rejects hunk lines beyond the declared ranges" {
    const input =
        "diff --git a/file b/file\n" ++
        "--- a/file\n" ++
        "+++ b/file\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+new\n" ++
        "+extra\n";
    try std.testing.expectError(error.InconsistentHunkCounts, parse(std.testing.allocator, input));
}
