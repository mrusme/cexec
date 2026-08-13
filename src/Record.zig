//! On-disk representation of a single cached command.
//!
//! A record is a sequence of blocks, each of which opens with a keyword line,
//! contains zero or more payload lines prefixed with `+`, and closes with a
//! line reading `END`:
//!
//! ```
//! CMD
//! +curl http://localhost:8080
//! END
//! TIMESTAMP
//! +1786440275
//! END
//! EXIT
//! +0
//! END
//! STDOUT
//! +<!DOCTYPE html>
//! END
//! STDERR
//! END
//! ```
//!
//! Lines are separated by `\n` on every platform. Blocks may appear in any
//! order and unknown keywords are skipped.

const Record = @This();

const std = @import("std");
const Writer = std.Io.Writer;

command: []const u8,
timestamp: i64,
exit_code: u8,
stdout: []const u8,
stderr: []const u8,

pub const DecodeError = error{
    MalformedRecord,
    MissingField,
};

pub fn encode(record: Record, writer: *Writer) Writer.Error!void {
    try writeBlock(writer, "CMD", record.command);
    try writeIntBlock(writer, "TIMESTAMP", record.timestamp);
    try writeIntBlock(writer, "EXIT", record.exit_code);
    try writeBlock(writer, "STDOUT", record.stdout);
    try writeBlock(writer, "STDERR", record.stderr);
}

pub fn encodeAlloc(
    record: Record,
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error![]u8 {
    var writer: Writer.Allocating = .init(gpa);
    defer writer.deinit();
    record.encode(&writer.writer) catch return error.OutOfMemory;
    return writer.toOwnedSlice();
}

/// Decodes `bytes` in place, returned record borrows from `bytes`, caller
/// keeps ownership of, must outlive the record.
pub fn decode(bytes: []u8) DecodeError!Record {
    var command: ?[]const u8 = null;
    var timestamp: ?i64 = null;
    var exit_code: ?u8 = null;
    var stdout: []const u8 = "";
    var stderr: []const u8 = "";

    var pos: usize = 0;
    while (takeLine(bytes, &pos)) |keyword| {
        if (keyword.len == 0) return error.MalformedRecord;
        const payload = try takePayload(bytes, &pos);

        if (std.mem.eql(u8, keyword, "CMD")) {
            command = payload;
        } else if (std.mem.eql(u8, keyword, "TIMESTAMP")) {
            timestamp = std.fmt.parseInt(i64, payload, 10) catch
                return error.MalformedRecord;
        } else if (std.mem.eql(u8, keyword, "EXIT")) {
            exit_code = std.fmt.parseInt(u8, payload, 10) catch
                return error.MalformedRecord;
        } else if (std.mem.eql(u8, keyword, "STDOUT")) {
            stdout = payload;
        } else if (std.mem.eql(u8, keyword, "STDERR")) {
            stderr = payload;
        }
    }

    return .{
        .command = command orelse return error.MissingField,
        .timestamp = timestamp orelse return error.MissingField,
        .exit_code = exit_code orelse return error.MissingField,
        .stdout = stdout,
        .stderr = stderr,
    };
}

fn writeBlock(
    writer: *Writer,
    keyword: []const u8,
    payload: []const u8,
) Writer.Error!void {
    try writer.writeAll(keyword);
    try writer.writeByte('\n');
    if (payload.len != 0) {
        var rest = payload;
        while (true) {
            const newline = std.mem.findScalar(u8, rest, '\n');
            try writer.writeByte('+');
            try writer.writeAll(if (newline) |end| rest[0..end] else rest);
            try writer.writeByte('\n');
            rest = rest[(newline orelse break) + 1 ..];
        }
    }
    try writer.writeAll("END\n");
}

fn writeIntBlock(
    writer: *Writer,
    keyword: []const u8,
    value: anytype,
) Writer.Error!void {
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
    return writeBlock(writer, keyword, text);
}

fn takeLine(bytes: []u8, pos: *usize) ?[]u8 {
    if (pos.* >= bytes.len) return null;
    const rest = bytes[pos.*..];
    const end = std.mem.findScalar(u8, rest, '\n') orelse {
        pos.* = bytes.len;
        return rest;
    };
    pos.* += end + 1;
    return rest[0..end];
}

/// Joins payload lines of block starting at `pos` into storage the lines
/// already occupy. Decoding only ever removes bytes, hence result always fits
/// ahead of the read position.
fn takePayload(bytes: []u8, pos: *usize) DecodeError![]u8 {
    const start = pos.*;
    var end = start;
    var lines: usize = 0;

    while (takeLine(bytes, pos)) |line| {
        if (std.mem.eql(u8, line, "END")) {
            return bytes[start..end];
        }
        if (line.len == 0 or line[0] != '+') return error.MalformedRecord;

        const content = line[1..];
        if (lines != 0) {
            bytes[end] = '\n';
            end += 1;
        }
        @memmove(bytes[end..][0..content.len], content);
        end += content.len;
        lines += 1;
    }

    return error.MalformedRecord;
}

const testing = std.testing;

fn expectRoundTrip(payload: []const u8) !void {
    const original: Record = .{
        .command = "cmd",
        .timestamp = 1786440275,
        .exit_code = 3,
        .stdout = payload,
        .stderr = payload,
    };

    const encoded = try original.encodeAlloc(testing.allocator);
    defer testing.allocator.free(encoded);

    const decoded = try decode(encoded);
    try testing.expectEqualStrings("cmd", decoded.command);
    try testing.expectEqual(@as(i64, 1786440275), decoded.timestamp);
    try testing.expectEqual(@as(u8, 3), decoded.exit_code);
    try testing.expectEqualStrings(payload, decoded.stdout);
    try testing.expectEqualStrings(payload, decoded.stderr);
}

test "round trip preserves arbitrary payloads" {
    try expectRoundTrip("");
    try expectRoundTrip("a");
    try expectRoundTrip("\n");
    try expectRoundTrip("\n\n\n");
    try expectRoundTrip("no trailing newline");
    try expectRoundTrip("trailing newline\n");
    try expectRoundTrip("two\nlines");
    try expectRoundTrip("two\nlines\n");
    try expectRoundTrip("END");
    try expectRoundTrip("END\n");
    try expectRoundTrip("CMD\nEND\nTIMESTAMP\n");
    try expectRoundTrip("+leading plus");
    try expectRoundTrip("++\n+\n");
    try expectRoundTrip("\x00\x01\xff binary \x00");
    try expectRoundTrip("crlf\r\nkept\r\n");
    try expectRoundTrip("マリウス über café");
}

test "encodes the documented layout" {
    const record: Record = .{
        .command = "curl http://localhost:8080",
        .timestamp = 1786440275,
        .exit_code = 0,
        .stdout = "<html>\n</html>",
        .stderr = "",
    };

    const encoded = try record.encodeAlloc(testing.allocator);
    defer testing.allocator.free(encoded);

    try testing.expectEqualStrings(
        \\CMD
        \\+curl http://localhost:8080
        \\END
        \\TIMESTAMP
        \\+1786440275
        \\END
        \\EXIT
        \\+0
        \\END
        \\STDOUT
        \\+<html>
        \\+</html>
        \\END
        \\STDERR
        \\END
        \\
    , encoded);
}

test "unknown blocks are skipped" {
    var bytes = "FUTURE\n+whatever\nEND\nCMD\n+ls\nEND\nTIMESTAMP\n+1\nEND\nEXIT\n+0\nEND\n".*;
    const record = try decode(&bytes);
    try testing.expectEqualStrings("ls", record.command);
    try testing.expectEqual(@as(i64, 1), record.timestamp);
}

test "absent output blocks decode as empty" {
    var bytes = "CMD\n+ls\nEND\nTIMESTAMP\n+1\nEND\nEXIT\n+0\nEND\n".*;
    const record = try decode(&bytes);
    try testing.expectEqualStrings("", record.stdout);
    try testing.expectEqualStrings("", record.stderr);
}

test "malformed records are rejected" {
    const cases = [_][]const u8{
        "CMD\n+ls\n",
        "CMD\n+ls\nEND\nTIMESTAMP\n+1\n",
        "CMD\nls\nEND\n",
        "\nCMD\n+ls\nEND\n",
        "CMD\n+ls\nEND\nTIMESTAMP\n+not a number\nEND\nEXIT\n+0\nEND\n",
        "CMD\n+ls\nEND\nTIMESTAMP\n+1\nEND\nEXIT\n+999\nEND\n",
    };
    for (cases) |case| {
        const bytes = try testing.allocator.dupe(u8, case);
        defer testing.allocator.free(bytes);
        try testing.expectError(error.MalformedRecord, decode(bytes));
    }
}

test "incomplete records are rejected" {
    const cases = [_][]const u8{
        "",
        "CMD\n+ls\nEND\n",
        "TIMESTAMP\n+1\nEND\nEXIT\n+0\nEND\n",
        "CMD\n+ls\nEND\nTIMESTAMP\n+1\nEND\n",
    };
    for (cases) |case| {
        const bytes = try testing.allocator.dupe(u8, case);
        defer testing.allocator.free(bytes);
        try testing.expectError(error.MissingField, decode(bytes));
    }
}
