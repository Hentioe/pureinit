const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Args = std.process.Args;
const clap = @import("clap");
const Self = @This();

const params = clap.parseParamsComptime(
    \\-h, --help            Display this help and exit.
    \\-t, --target <str>    Specify the target path.
    \\-p, --patch <str>     Specify the patch file.
    \\
);
const Res = clap.Result(clap.Help, &params, clap.parsers.default);

io: Io,
gpa: Allocator,
args: Args,
res: Res,

pub fn deinit(self: *Self) void {
    self.res.deinit();
}

pub fn parse(app_init: std.process.Init) !Self {
    var diag = clap.Diagnostic{};
    const res = clap.parse(clap.Help, &params, clap.parsers.default, app_init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = app_init.gpa,
    }) catch |err| {
        try diag.reportToFile(app_init.io, .stderr(), err);
        return err;
    };

    return .{
        .io = app_init.io,
        .gpa = app_init.gpa,
        .args = app_init.minimal.args,
        .res = res,
    };
}

pub fn target(self: *const Self) ?[]const u8 {
    return self.res.args.target;
}

pub fn patch(self: *const Self) ?[]const u8 {
    return self.res.args.patch;
}

pub fn isHelp(self: *const Self) bool {
    return self.res.args.help != 0;
}

pub fn help(self: *const Self) !void {
    try clap.helpToFile(self.io, .stderr(), clap.Help, &params, .{});
}
