//! Encryption for cache entries.
//!
//! Sealed entry is laid out as a fixed header followed by the ciphertext:
//!
//! ```
//! "CEXECBOX" | version | salt[16] | nonce[24] | tag[16] | ciphertext
//! ```
//!
//! The encryption key is derived from the caller supplied key with
//! HKDF-SHA256 over a per-entry random salt. The header and the caller's
//! context are authenticated alongside the ciphertext, so a sealed entry
//! cannot be moved to another command's cache file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;

pub const magic = "CEXECBOX";
pub const version: u8 = 1;
pub const salt_length = 16;
pub const context_length = 32;

const salt_offset = magic.len + 1;
const nonce_offset = salt_offset + salt_length;
const tag_offset = nonce_offset + Aead.nonce_length;

pub const header_length = tag_offset + Aead.tag_length;

pub const SealError = Allocator.Error;

pub const OpenError = error{
    MalformedEnvelope,
    AuthenticationFailed,
} || Allocator.Error;

/// Reports whether `bytes` carries envelope header. Plain records always begin
/// with a keyword line, so the two forms never overlap.
pub fn isSealed(bytes: []const u8) bool {
    return bytes.len >= header_length and
        std.mem.eql(u8, bytes[0..magic.len], magic);
}

pub fn seal(
    gpa: Allocator,
    io: Io,
    key: []const u8,
    context: [context_length]u8,
    plaintext: []const u8,
) SealError![]u8 {
    const sealed = try gpa.alloc(u8, header_length + plaintext.len);
    errdefer gpa.free(sealed);

    @memcpy(sealed[0..magic.len], magic);
    sealed[magic.len] = version;
    io.random(sealed[salt_offset..][0..salt_length]);
    io.random(sealed[nonce_offset..][0..Aead.nonce_length]);

    Aead.encrypt(
        sealed[header_length..],
        sealed[tag_offset..][0..Aead.tag_length],
        plaintext,
        &associatedData(sealed[0..nonce_offset].*, context),
        sealed[nonce_offset..][0..Aead.nonce_length].*,
        deriveKey(key, sealed[salt_offset..][0..salt_length].*),
    );

    return sealed;
}

pub fn open(
    gpa: Allocator,
    key: []const u8,
    context: [context_length]u8,
    sealed: []const u8,
) OpenError![]u8 {
    if (!isSealed(sealed) or sealed[magic.len] != version)
        return error.MalformedEnvelope;

    const plaintext = try gpa.alloc(u8, sealed.len - header_length);
    errdefer gpa.free(plaintext);

    Aead.decrypt(
        plaintext,
        sealed[header_length..],
        sealed[tag_offset..][0..Aead.tag_length].*,
        &associatedData(sealed[0..nonce_offset].*, context),
        sealed[nonce_offset..][0..Aead.nonce_length].*,
        deriveKey(key, sealed[salt_offset..][0..salt_length].*),
    ) catch return error.AuthenticationFailed;

    return plaintext;
}

fn deriveKey(key: []const u8, salt: [salt_length]u8) [Aead.key_length]u8 {
    const prk = Hkdf.extract(&salt, key);
    var derived: [Aead.key_length]u8 = undefined;
    Hkdf.expand(&derived, "cexec v1 record", prk);
    return derived;
}

fn associatedData(
    header: [nonce_offset]u8,
    context: [context_length]u8,
) [nonce_offset + context_length]u8 {
    return header ++ context;
}

const testing = std.testing;

const test_context: [context_length]u8 = @splat(0xab);
const test_plaintext = "CMD\n+ls\nEND\nTIMESTAMP\n+1786440275\nEND\nEXIT\n+0\nEND\n";

test "sealed entries round trip" {
    const sealed = try seal(testing.allocator, testing.io, "hunter2", test_context, test_plaintext);
    defer testing.allocator.free(sealed);

    try testing.expect(isSealed(sealed));
    try testing.expectEqual(header_length + test_plaintext.len, sealed.len);
    try testing.expect(std.mem.find(u8, sealed, "TIMESTAMP") == null);

    const opened = try open(testing.allocator, "hunter2", test_context, sealed);
    defer testing.allocator.free(opened);
    try testing.expectEqualStrings(test_plaintext, opened);
}

test "empty plaintext round trips" {
    const sealed = try seal(testing.allocator, testing.io, "hunter2", test_context, "");
    defer testing.allocator.free(sealed);

    const opened = try open(testing.allocator, "hunter2", test_context, sealed);
    defer testing.allocator.free(opened);
    try testing.expectEqualStrings("", opened);
}

test "every entry uses a fresh salt and nonce" {
    const first = try seal(testing.allocator, testing.io, "hunter2", test_context, test_plaintext);
    defer testing.allocator.free(first);
    const second = try seal(testing.allocator, testing.io, "hunter2", test_context, test_plaintext);
    defer testing.allocator.free(second);

    try testing.expect(!std.mem.eql(u8, first[salt_offset..header_length], second[salt_offset..header_length]));
    try testing.expect(!std.mem.eql(u8, first[header_length..], second[header_length..]));
}

test "a wrong key does not open an entry" {
    const sealed = try seal(testing.allocator, testing.io, "hunter2", test_context, test_plaintext);
    defer testing.allocator.free(sealed);

    try testing.expectError(
        error.AuthenticationFailed,
        open(testing.allocator, "hunter3", test_context, sealed),
    );
}

test "a wrong context does not open an entry" {
    const sealed = try seal(testing.allocator, testing.io, "hunter2", test_context, test_plaintext);
    defer testing.allocator.free(sealed);

    const other_context: [context_length]u8 = @splat(0xcd);
    try testing.expectError(
        error.AuthenticationFailed,
        open(testing.allocator, "hunter2", other_context, sealed),
    );
}

test "tampering is detected" {
    const positions = [_]usize{ salt_offset, nonce_offset, tag_offset, header_length };
    for (positions) |position| {
        const sealed = try seal(testing.allocator, testing.io, "hunter2", test_context, test_plaintext);
        defer testing.allocator.free(sealed);

        sealed[position] +%= 1;
        try testing.expectError(
            error.AuthenticationFailed,
            open(testing.allocator, "hunter2", test_context, sealed),
        );
    }
}

test "truncated and foreign input is rejected" {
    const sealed = try seal(testing.allocator, testing.io, "hunter2", test_context, test_plaintext);
    defer testing.allocator.free(sealed);

    try testing.expectError(
        error.MalformedEnvelope,
        open(testing.allocator, "hunter2", test_context, sealed[0 .. header_length - 1]),
    );

    sealed[magic.len] = version + 1;
    try testing.expectError(
        error.MalformedEnvelope,
        open(testing.allocator, "hunter2", test_context, sealed),
    );

    try testing.expect(!isSealed(test_plaintext));
    try testing.expect(!isSealed(""));
}
