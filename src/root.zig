//! By convention, root.zig is the root source file when making a package.

const std = @import("std");
pub const diff_parser = @import("diff_parser.zig");
pub const patch_apply = @import("patch_apply.zig");
pub const file_ops = @import("file_ops.zig");

pub const Patch = struct {
    /// 为 files 及其所有嵌套字符串和数组提供存储；调用者必须调用 deinit。
    arena: std.heap.ArenaAllocator,
    /// 补丁中按出现顺序排列的文件变更。
    files: []const FileDiff,

    /// 一次释放解析结果持有的所有内存。
    pub fn deinit(self: *Patch) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const FileDiff = struct {
    /// 变更前的文件路径；新建文件时为 null（补丁中对应 /dev/null）。
    old_path: ?[]const u8,
    /// 变更后的文件路径；删除文件时为 null（补丁中对应 /dev/null）。
    new_path: ?[]const u8,
    /// 该文件变更中按出现顺序排列的代码块。
    hunks: []const Hunk,
};

pub const Hunk = struct {
    /// unified diff 头部中旧文件范围的起始行号。
    old_start: usize,
    /// unified diff 头部中旧文件范围包含的行数。
    old_count: usize,
    /// unified diff 头部中新文件范围的起始行号。
    new_start: usize,
    /// unified diff 头部中新文件范围包含的行数。
    new_count: usize,
    /// 代码块中的行，保留原有顺序。
    lines: []const DiffLine,
};

pub const DiffLine = struct {
    /// 该行是上下文、添加内容还是删除内容。
    kind: Kind,
    /// 新增/删除行的内容，不包含前导标记；上下文行的文本为空，仅用于计数定位。
    text: []const u8,
    /// 对应文件中的这一行是否以换行符结束。
    has_newline: bool,

    pub const Kind = enum {
        /// 同时存在于旧文件和新文件中的上下文行。
        context,
        /// 只存在于新文件中的行。
        addition,
        /// 只存在于旧文件中的行。
        deletion,
    };
};

test {
    _ = diff_parser;
    _ = patch_apply;
    _ = file_ops;
}
