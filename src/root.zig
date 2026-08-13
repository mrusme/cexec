const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Child = std.process.Child;
const Io = std.Io;

pub const Cache = @import("Cache.zig");
pub const Record = @import("Record.zig");
pub const crypt = @import("crypt.zig");

pub const default_ttl: Io.Duration = .fromSeconds(60);

pub const Options = struct {
    /// Command to run, starting with program name.
    argv: []const []const u8,
    ttl: Io.Duration = default_ttl,
    key: ?[]const u8 = null,
    directory: ?[]const u8 = null,
    environ: std.process.Environ = .empty,
    stdin: std.process.SpawnOptions.StdIo = .inherit,
    /// Largest output that is still captured.
    output_limit: Io.Limit = .limited(Cache.max_entry_bytes),
};

pub const Outcome = enum {
    /// Output came from cache.
    hit,
    /// Command was executed.
    miss,
};

pub const Result = struct {
    outcome: Outcome,
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
    storage: []u8,

    pub fn deinit(result: *Result, gpa: Allocator) void {
        gpa.free(result.storage);
        result.* = undefined;
    }
};

pub const ExecuteError = error{
    /// `argv[0]` could not be resolved to a program.
    CommandNotFound,
    StreamTooLong,
} || Allocator.Error || std.process.SpawnError || Child.WaitError ||
    Io.File.MultiReader.UnendingError || Io.Timeout.Error;

pub const RunError = ExecuteError || Cache.OpenError || Cache.GetError;

/// Returns stored output of `options.argv` if it is < `options.ttl`, otherwise
/// runs command and stores its output.
pub fn run(gpa: Allocator, io: Io, options: Options) RunError!Result {
    var cache: Cache = try .open(gpa, io, .{
        .directory = options.directory,
        .environ = options.environ,
        .key = options.key,
    });
    defer cache.close();

    if (try cache.get(options.argv, options.ttl)) |entry| return .{
        .outcome = .hit,
        .exit_code = entry.exit_code,
        .stdout = entry.stdout,
        .stderr = entry.stderr,
        .storage = entry.storage,
    };

    const result = try execute(gpa, io, options);
    errdefer {
        var owned = result;
        owned.deinit(gpa);
    }

    cache.put(options.argv, .{
        .timestamp = cache.now(),
        .exit_code = result.exit_code,
        .stdout = result.stdout,
        .stderr = result.stderr,
    }) catch {};

    return result;
}

/// Runs `options.argv` and captures what it writes, without consulting the
/// cache.
pub fn execute(gpa: Allocator, io: Io, options: Options) ExecuteError!Result {
    var child = std.process.spawn(io, .{
        .argv = options.argv,
        .stdin = options.stdin,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.CommandNotFound,
        else => |remaining| return remaining,
    };
    defer child.kill(io);

    var streams: Io.File.MultiReader.Buffer(2) = undefined;
    var output: Io.File.MultiReader = undefined;
    output.init(
        gpa,
        io,
        streams.toStreams(),
        &.{ child.stdout.?, child.stderr.? },
    );
    defer output.deinit();

    const stdout = output.reader(0);
    const stderr = output.reader(1);

    while (output.fill(64, .none)) |_| {
        if (options.output_limit.toInt()) |limit| {
            if (stdout.buffered().len > limit or
                stderr.buffered().len > limit)
            {
                return error.StreamTooLong;
            }
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |remaining| return remaining,
    }

    try output.checkAnyError();
    const term = try child.wait(io);

    const captured_stdout = stdout.buffered();
    const captured_stderr = stderr.buffered();

    const storage = try gpa.alloc(
        u8,
        captured_stdout.len + captured_stderr.len,
    );
    @memcpy(storage[0..captured_stdout.len], captured_stdout);
    @memcpy(storage[captured_stdout.len..], captured_stderr);

    return .{
        .outcome = .miss,
        .exit_code = exitCode(term),
        .stdout = storage[0..captured_stdout.len],
        .stderr = storage[captured_stdout.len..],
        .storage = storage,
    };
}

/// Status a shell reports for `term`. Death by signal becomes 128 plus signal
/// number, matching convention of every common shell.
pub fn exitCode(term: Child.Term) u8 {
    return switch (term) {
        .exited => |status| status,
        .signal => |signal| signalExitCode(signal),
        .stopped, .unknown => 1,
    };
}

fn signalExitCode(signal: std.posix.SIG) u8 {
    if (comptime std.posix.SIG == void) return 1;
    return 128 +| @as(u8, @truncate(@intFromEnum(signal)));
}

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    directory: []u8,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{
            .tmp = tmp,
            .directory = try std.fmt.allocPrint(
                testing.allocator,
                ".zig-cache/tmp/{s}/cache",
                .{tmp.sub_path},
            ),
        };
    }

    fn deinit(fixture: *Fixture) void {
        testing.allocator.free(fixture.directory);
        fixture.tmp.cleanup();
        fixture.* = undefined;
    }
};

fn shell(script: []const u8) [3][]const u8 {
    return .{ "/bin/sh", "-c", script };
}

fn skipUnlessPosixShell() !void {
    switch (builtin.os.tag) {
        .windows, .wasi => return error.SkipZigTest,
        else => {},
    }
}

test "the first run executes and later runs replay" {
    try skipUnlessPosixShell();

    var fixture = try Fixture.init();
    defer fixture.deinit();

    const script = shell("echo out; echo err >&2; exit 3");
    const options: Options = .{
        .argv = &script,
        .ttl = .fromSeconds(3600),
        .directory = fixture.directory,
        .stdin = .ignore,
    };

    var first = try run(testing.allocator, testing.io, options);
    defer first.deinit(testing.allocator);
    try testing.expectEqual(Outcome.miss, first.outcome);
    try testing.expectEqual(@as(u8, 3), first.exit_code);
    try testing.expectEqualStrings("out\n", first.stdout);
    try testing.expectEqualStrings("err\n", first.stderr);

    var second = try run(testing.allocator, testing.io, options);
    defer second.deinit(testing.allocator);
    try testing.expectEqual(Outcome.hit, second.outcome);
    try testing.expectEqual(@as(u8, 3), second.exit_code);
    try testing.expectEqualStrings("out\n", second.stdout);
    try testing.expectEqualStrings("err\n", second.stderr);
}

test "a lifetime of zero always executes" {
    try skipUnlessPosixShell();

    var fixture = try Fixture.init();
    defer fixture.deinit();

    const script = shell("echo $$");
    const options: Options = .{
        .argv = &script,
        .ttl = .fromSeconds(0),
        .directory = fixture.directory,
        .stdin = .ignore,
    };

    var first = try run(testing.allocator, testing.io, options);
    defer first.deinit(testing.allocator);
    var second = try run(testing.allocator, testing.io, options);
    defer second.deinit(testing.allocator);

    try testing.expectEqual(Outcome.miss, first.outcome);
    try testing.expectEqual(Outcome.miss, second.outcome);
    try testing.expect(!std.mem.eql(u8, first.stdout, second.stdout));
}

test "a keyed run replays only with the same key" {
    try skipUnlessPosixShell();

    var fixture = try Fixture.init();
    defer fixture.deinit();

    const script = shell("echo secret");
    const options: Options = .{
        .argv = &script,
        .ttl = .fromSeconds(3600),
        .directory = fixture.directory,
        .key = "hunter2",
        .stdin = .ignore,
    };

    var first = try run(testing.allocator, testing.io, options);
    defer first.deinit(testing.allocator);
    try testing.expectEqual(Outcome.miss, first.outcome);

    var keyed = try run(testing.allocator, testing.io, options);
    defer keyed.deinit(testing.allocator);
    try testing.expectEqual(Outcome.hit, keyed.outcome);

    var unkeyed_options = options;
    unkeyed_options.key = null;
    var unkeyed = try run(testing.allocator, testing.io, unkeyed_options);
    defer unkeyed.deinit(testing.allocator);
    try testing.expectEqual(Outcome.miss, unkeyed.outcome);
}

test "large output survives the round trip" {
    try skipUnlessPosixShell();

    var fixture = try Fixture.init();
    defer fixture.deinit();

    const script = shell("head -c 200000 /dev/zero | tr '\\0' 'x'");
    const options: Options = .{
        .argv = &script,
        .ttl = .fromSeconds(3600),
        .directory = fixture.directory,
        .stdin = .ignore,
    };

    var first = try run(testing.allocator, testing.io, options);
    defer first.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 200000), first.stdout.len);

    var second = try run(testing.allocator, testing.io, options);
    defer second.deinit(testing.allocator);
    try testing.expectEqual(Outcome.hit, second.outcome);
    try testing.expectEqualStrings(first.stdout, second.stdout);
}

test "output beyond the limit is refused" {
    try skipUnlessPosixShell();

    var fixture = try Fixture.init();
    defer fixture.deinit();

    const script = shell("head -c 100000 /dev/zero | tr '\\0' 'x'");
    try testing.expectError(error.StreamTooLong, run(testing.allocator, testing.io, .{
        .argv = &script,
        .directory = fixture.directory,
        .output_limit = .limited(1024),
        .stdin = .ignore,
    }));
}

test "a command killed by a signal reports the shell status" {
    try skipUnlessPosixShell();

    var fixture = try Fixture.init();
    defer fixture.deinit();

    const script = shell("kill -TERM $$");
    var result = try run(testing.allocator, testing.io, .{
        .argv = &script,
        .directory = fixture.directory,
        .stdin = .ignore,
    });
    defer result.deinit(testing.allocator);

    try testing.expect(result.exit_code >= 128);
}

test {
    _ = Cache;
    _ = Record;
    _ = crypt;
}
