const std = @import("std");
const Io = std.Io;

const build_options = @import("build_options");
const cexec = @import("cexec");

const usage =
    \\Usage: cexec [options] command [args...]
    \\
    \\Runs a command and caches its output, so that running it again within the
    \\caching period replays the stored output instead of executing anything.
    \\
    \\Options:
    \\  -t, --ttl <seconds>  how long the output stays cached (default 60)
    \\  -k, --key <key>      encrypt the cache entry with <key>
    \\  -h, --help           show this help
    \\      --version        show the version
    \\
    \\Option parsing stops at the first argument that is not an option.
    \\The key can also be given in env CEXEC_KEY.
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    var ttl: u32 = 60;
    var key: ?[]const u8 = null;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            write(io, .stdout(), usage) catch |err| passOn(io, err);
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            write(io, .stdout(), "cexec " ++ build_options.version ++ "\n") catch |err| passOn(io, err);
            return;
        } else if (valueFor(args, &index, arg, "-t", "--ttl") catch
            fatal(io, "option '{s}' needs a value", .{arg})) |value|
        {
            ttl = std.fmt.parseInt(u32, value, 10) catch
                fatal(io, "'{s}' is not a number of seconds", .{value});
        } else if (valueFor(args, &index, arg, "-k", "--key") catch
            fatal(io, "option '{s}' needs a value", .{arg})) |value|
        {
            key = value;
        } else {
            fatal(io, "unknown option '{s}'", .{arg});
        }
    }

    const command = args[index..];
    if (command.len == 0) {
        write(io, .stderr(), usage) catch |err| passOn(io, err);
        std.process.exit(1);
    }

    const argv = try arena.alloc([]const u8, command.len);
    for (command, argv) |source, *destination| destination.* = source;

    var result = cexec.run(init.gpa, io, .{
        .argv = argv,
        .ttl = .fromSeconds(ttl),
        .key = unempty(key orelse init.environ_map.get("CEXEC_KEY")),
        .environ = init.minimal.environ,
    }) catch |err| switch (err) {
        error.CommandNotFound => fatal(io, "no such command: {s}", .{argv[0]}),
        error.CacheDirectoryUnavailable => fatal(
            io,
            "no cache directory, set XDG_CACHE_HOME or HOME",
            .{},
        ),
        else => fatal(io, "{s}: {t}", .{ argv[0], err }),
    };
    defer result.deinit(init.gpa);

    write(io, .stdout(), result.stdout) catch |err| passOn(io, err);
    write(io, .stderr(), result.stderr) catch |err| passOn(io, err);

    std.process.exit(result.exit_code);
}

/// Status a shell reports for process killed by SIGPIPE (a reader closing the
/// pipe early).
const broken_pipe_status = 141;

fn passOn(io: Io, err: Io.File.Writer.Error) noreturn {
    if (err == error.BrokenPipe) std.process.exit(broken_pipe_status);
    fatal(io, "{t}", .{err});
}

fn unempty(value: ?[]const u8) ?[]const u8 {
    const present = value orelse return null;
    return if (present.len == 0) null else present;
}

/// Value of option named `short` or `long` when `arg` names it, taking next
/// argument when value is not attached to option itself.
fn valueFor(
    args: []const [:0]const u8,
    index: *usize,
    arg: []const u8,
    short: []const u8,
    long: []const u8,
) error{MissingValue}!?[]const u8 {
    if (std.mem.eql(u8, arg, short) or
        std.mem.eql(u8, arg, long))
    {
        index.* += 1;
        if (index.* >= args.len)
            return error.MissingValue;
        return args[index.*];
    }
    if (std.mem.startsWith(u8, arg, long) and
        arg.len > long.len and
        arg[long.len] == '=')
    {
        return arg[long.len + 1 ..];
    }
    if (std.mem.startsWith(u8, arg, short) and
        arg.len > short.len)
    {
        return arg[short.len..];
    }
    return null;
}

fn write(io: Io, file: Io.File, bytes: []const u8) Io.File.Writer.Error!void {
    if (bytes.len != 0) try file.writeStreamingAll(io, bytes);
}

fn fatal(io: Io, comptime format: []const u8, args: anytype) noreturn {
    var buffer: [512]u8 = undefined;
    var writer: Io.File.Writer = .init(.stderr(), io, &buffer);
    writer.interface.print("cexec: " ++ format ++ "\n", args) catch {};
    writer.interface.flush() catch {};
    std.process.exit(1);
}

const testing = std.testing;

fn expectValue(expected: ?[]const u8, args: []const [:0]const u8, at: usize) !void {
    var index = at;
    const value = try valueFor(args, &index, args[at], "-t", "--ttl");
    if (expected) |text| {
        try testing.expectEqualStrings(text, value.?);
    } else {
        try testing.expectEqual(@as(?[]const u8, null), value);
    }
}

test "options are recognised in every accepted spelling" {
    try expectValue("120", &.{ "-t", "120" }, 0);
    try expectValue("120", &.{"-t120"}, 0);
    try expectValue("120", &.{"--ttl=120"}, 0);
    try expectValue("120", &.{ "--ttl", "120" }, 0);
    try expectValue("", &.{"--ttl="}, 0);
    try expectValue(null, &.{"-k"}, 0);
    try expectValue(null, &.{"--key=x"}, 0);
    try expectValue(null, &.{"curl"}, 0);
}

test "an option without its value is reported" {
    var index: usize = 0;
    const args: []const [:0]const u8 = &.{"-t"};
    try testing.expectError(error.MissingValue, valueFor(args, &index, args[0], "-t", "--ttl"));
}
