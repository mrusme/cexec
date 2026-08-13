const Cache = @This();

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const crypt = @import("crypt.zig");
const Record = @import("Record.zig");

pub const Digest = [Sha256.digest_length]u8;
pub const FileName = [2 * Sha256.digest_length]u8;

/// Entries larger than this are treated as unusable.
pub const max_entry_bytes = 64 * 1024 * 1024;

gpa: Allocator,
io: Io,
dir: Io.Dir,
directory: []const u8,
key: ?[]const u8,

pub const OpenOptions = struct {
    /// Directory entries are stored in, created when missing, resolved from
    /// `environ` when null.
    directory: ?[]const u8 = null,
    /// Environment used to resolve cache directory, required unless `directory`
    /// is given.
    environ: Environ = .empty,
    /// Key entries are encrypted with, stored in clear text when null.
    key: ?[]const u8 = null,
};

pub const OpenError = error{
    CacheDirectoryUnavailable,
} || Allocator.Error ||
    Environ.CreateMapError ||
    Io.Dir.CreateDirPathOpenError;

pub const GetError = Allocator.Error || Io.Dir.ReadFileAllocError;

pub const PutError = Allocator.Error || Io.Dir.CreateFileAtomicError ||
    Io.File.Writer.Error || Io.File.Atomic.ReplaceError;

pub const RemoveError = Io.Dir.DeleteFileError;

/// Cached command result, entries returned by `get` own their memory.
pub const Entry = struct {
    /// Unix time
    timestamp: i64,
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
    storage: []u8 = &.{},

    pub fn deinit(entry: *Entry, gpa: Allocator) void {
        gpa.free(entry.storage);
        entry.* = undefined;
    }
};

pub fn open(gpa: Allocator, io: Io, options: OpenOptions) OpenError!Cache {
    const directory = if (options.directory) |given|
        try gpa.dupe(u8, given)
    else
        try defaultDirectory(gpa, options.environ);
    errdefer gpa.free(directory);

    const dir = try Io.Dir.cwd().createDirPathOpen(io, directory, .{});

    return .{
        .gpa = gpa,
        .io = io,
        .dir = dir,
        .directory = directory,
        .key = options.key,
    };
}

pub fn close(cache: *Cache) void {
    cache.dir.close(cache.io);
    cache.gpa.free(cache.directory);
    cache.* = undefined;
}

pub fn now(cache: Cache) i64 {
    return Io.Timestamp.now(cache.io, .real).toSeconds();
}

/// Returns entry for `argv` if one exists and is newer than `ttl`.
pub fn get(
    cache: *Cache,
    argv: []const []const u8,
    ttl: Io.Duration,
) GetError!?Entry {
    const command = try std.mem.join(cache.gpa, " ", argv);
    defer cache.gpa.free(command);

    const stored = cache.dir.readFileAlloc(
        cache.io,
        &fileName(digest(command)),
        cache.gpa,
        .limited(max_entry_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong, error.IsDir => return null,
        else => |remaining| return remaining,
    };

    var storage = stored;
    errdefer cache.gpa.free(storage);

    const entry: ?Entry = found: {
        if (crypt.isSealed(storage)) {
            const key = cache.key orelse break :found null;
            const opened = crypt.open(
                cache.gpa,
                key,
                digest(command),
                storage,
            ) catch |err| switch (err) {
                error.MalformedEnvelope, error.AuthenticationFailed => break :found null,
                else => |remaining| return remaining,
            };
            cache.gpa.free(storage);
            storage = opened;
        } else if (cache.key != null) {
            break :found null;
        }

        const record = Record.decode(storage) catch break :found null;
        if (!std.mem.eql(u8, record.command, command)) break :found null;
        if (cache.now() >= @as(i128, record.timestamp) + ttl.toSeconds()) break :found null;

        break :found .{
            .timestamp = record.timestamp,
            .exit_code = record.exit_code,
            .stdout = record.stdout,
            .stderr = record.stderr,
            .storage = storage,
        };
    };

    if (entry == null) cache.gpa.free(storage);
    return entry;
}

/// Stores `entry` as result of `argv`, replacing any existing entry.
pub fn put(
    cache: *Cache,
    argv: []const []const u8,
    entry: Entry,
) PutError!void {
    const command = try std.mem.join(cache.gpa, " ", argv);
    defer cache.gpa.free(command);

    const record: Record = .{
        .command = command,
        .timestamp = entry.timestamp,
        .exit_code = entry.exit_code,
        .stdout = entry.stdout,
        .stderr = entry.stderr,
    };

    const encoded = try record.encodeAlloc(cache.gpa);
    defer cache.gpa.free(encoded);

    const contents = if (cache.key) |key|
        try crypt.seal(cache.gpa, cache.io, key, digest(command), encoded)
    else
        encoded;
    defer if (cache.key != null) cache.gpa.free(contents);

    var file: Io.File.Atomic = try cache.dir.createFileAtomic(
        cache.io,
        &fileName(digest(command)),
        .{ .replace = true },
    );
    defer file.deinit(cache.io);

    try file.file.writeStreamingAll(cache.io, contents);
    try file.replace(cache.io);
}

/// Drops entry for `argv`, if any.
pub fn remove(cache: *Cache, argv: []const []const u8) RemoveError!void {
    const command = std.mem.join(cache.gpa, " ", argv) catch return;
    defer cache.gpa.free(command);

    cache.dir.deleteFile(
        cache.io,
        &fileName(digest(command)),
    ) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |remaining| return remaining,
    };
}

/// Digest of command, as joined by `get` and `put`.
pub fn digest(command: []const u8) Digest {
    var hasher: Sha256 = .init(.{});
    hasher.update(command);
    return hasher.finalResult();
}

/// Name of file an entry is stored in.
pub fn fileName(command_digest: Digest) FileName {
    return std.fmt.bytesToHex(command_digest, .lower);
}

fn defaultDirectory(gpa: Allocator, environ: Environ) OpenError![]u8 {
    var map = try environ.createMap(gpa);
    defer map.deinit();

    if (unempty(map.get("XDG_CACHE_HOME"))) |base| {
        return Io.Dir.path.join(gpa, &.{ base, "cexec" });
    }

    switch (builtin.os.tag) {
        .windows => {
            if (unempty(map.get("LOCALAPPDATA"))) |base| {
                return Io.Dir.path.join(gpa, &.{ base, "cexec" });
            }
        },
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => {
            if (unempty(map.get("HOME"))) |home| {
                return Io.Dir.path.join(gpa, &.{ home, "Library", "Caches", "cexec" });
            }
        },
        else => {
            if (unempty(map.get("HOME"))) |home| {
                return Io.Dir.path.join(gpa, &.{ home, ".cache", "cexec" });
            }
        },
    }

    return error.CacheDirectoryUnavailable;
}

fn unempty(value: ?[]const u8) ?[]const u8 {
    const present = value orelse return null;
    return if (present.len == 0) null else present;
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

    fn open(fixture: Fixture, key: ?[]const u8) OpenError!Cache {
        return Cache.open(testing.allocator, testing.io, .{
            .directory = fixture.directory,
            .key = key,
        });
    }

    fn deinit(fixture: *Fixture) void {
        testing.allocator.free(fixture.directory);
        fixture.tmp.cleanup();
        fixture.* = undefined;
    }
};

const one_hour: Io.Duration = .fromSeconds(3600);
const test_argv: []const []const u8 = &.{ "curl", "http://localhost:8080" };

test "a stored entry is returned until it expires" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var cache = try fixture.open(null);
    defer cache.close();

    try testing.expect(try cache.get(test_argv, one_hour) == null);

    try cache.put(test_argv, .{
        .timestamp = cache.now(),
        .exit_code = 7,
        .stdout = "<html>\n",
        .stderr = "curl: warning\n",
    });

    var entry = (try cache.get(test_argv, one_hour)).?;
    defer entry.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 7), entry.exit_code);
    try testing.expectEqualStrings("<html>\n", entry.stdout);
    try testing.expectEqualStrings("curl: warning\n", entry.stderr);

    try testing.expect(try cache.get(test_argv, .fromSeconds(0)) == null);
}

test "an entry older than the lifetime is a miss" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var cache = try fixture.open(null);
    defer cache.close();

    try cache.put(test_argv, .{
        .timestamp = cache.now() - 120,
        .exit_code = 0,
        .stdout = "stale",
        .stderr = "",
    });

    try testing.expect(try cache.get(test_argv, .fromSeconds(60)) == null);

    var entry = (try cache.get(test_argv, .fromSeconds(180))).?;
    defer entry.deinit(testing.allocator);
    try testing.expectEqualStrings("stale", entry.stdout);
}

test "entries are keyed by the whole command" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var cache = try fixture.open(null);
    defer cache.close();

    try cache.put(test_argv, .{
        .timestamp = cache.now(),
        .exit_code = 0,
        .stdout = "first",
        .stderr = "",
    });

    try testing.expect(try cache.get(&.{ "curl", "http://localhost:9090" }, one_hour) == null);

    var entry = (try cache.get(test_argv, one_hour)).?;
    defer entry.deinit(testing.allocator);
    try testing.expectEqualStrings("first", entry.stdout);
}

test "removing an entry is a miss afterwards" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var cache = try fixture.open(null);
    defer cache.close();

    try cache.remove(test_argv);
    try cache.put(test_argv, .{
        .timestamp = cache.now(),
        .exit_code = 0,
        .stdout = "gone soon",
        .stderr = "",
    });
    try cache.remove(test_argv);

    try testing.expect(try cache.get(test_argv, one_hour) == null);
}

test "a keyed entry is unreadable without the key" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    {
        var cache = try fixture.open("hunter2");
        defer cache.close();
        try cache.put(test_argv, .{
            .timestamp = cache.now(),
            .exit_code = 0,
            .stdout = "secret payload",
            .stderr = "",
        });
    }

    const stored_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{
        fixture.directory,
        &fileName(digest("curl http://localhost:8080")),
    });
    defer testing.allocator.free(stored_path);

    const stored = try Io.Dir.cwd().readFileAlloc(
        testing.io,
        stored_path,
        testing.allocator,
        .limited(max_entry_bytes),
    );
    defer testing.allocator.free(stored);
    try testing.expect(crypt.isSealed(stored));
    try testing.expect(std.mem.find(u8, stored, "secret payload") == null);

    {
        var cache = try fixture.open(null);
        defer cache.close();
        try testing.expect(try cache.get(test_argv, one_hour) == null);
    }

    {
        var cache = try fixture.open("hunter3");
        defer cache.close();
        try testing.expect(try cache.get(test_argv, one_hour) == null);
    }

    {
        var cache = try fixture.open("hunter2");
        defer cache.close();
        var entry = (try cache.get(test_argv, one_hour)).?;
        defer entry.deinit(testing.allocator);
        try testing.expectEqualStrings("secret payload", entry.stdout);
    }
}

test "a plain entry is a miss when a key is in use" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    {
        var cache = try fixture.open(null);
        defer cache.close();
        try cache.put(test_argv, .{
            .timestamp = cache.now(),
            .exit_code = 0,
            .stdout = "plain",
            .stderr = "",
        });
    }

    var cache = try fixture.open("hunter2");
    defer cache.close();
    try testing.expect(try cache.get(test_argv, one_hour) == null);
}

test "damaged entries are a miss rather than an error" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var cache = try fixture.open(null);
    defer cache.close();

    try cache.dir.writeFile(cache.io, .{
        .sub_path = &fileName(digest("curl http://localhost:8080")),
        .data = "CMD\n+curl http://localhost:8080\nEND\nTRUNCATED",
    });

    try testing.expect(try cache.get(test_argv, one_hour) == null);
}

test "the file name is the digest of the joined command" {
    try testing.expectEqualStrings(
        "537e0b5d2266eb360a853699f584b6b2adfb055e8f200b390cc1ec2b42a1006d",
        &fileName(digest("curl http://localhost:8080")),
    );
}
