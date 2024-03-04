const std = @import("std");

fn equivUnsigned(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .Int => |inner| @Type(.{
            .Int = .{
                .signedness = .unsigned,
                .bits = inner.bits,
            },
        }),
        else => @compileError("cannot generate equivalent unsigned type for " ++ @typeName(T)),
    };
}

/// Encodes an integer into a buffer, using a provided endianness.
pub fn encodeInt(comptime byteOrder: std.builtin.Endian, buf: []u8, val: anytype) void {
    const T = @TypeOf(val);
    const size = @sizeOf(T);
    std.debug.assert(buf.len >= size);
    const utype = comptime equivUnsigned(T);
    const equiv = @as(utype, @bitCast(val));
    inline for (0..size) |i| {
        const index = if (comptime byteOrder == .little) i else comptime size - 1 - i;
        buf[index] = @as(u8, @truncate(equiv >> (comptime i * 8)));
    }
}

/// Decodes an integer from a buffer which was encoded with a provided endianness.
pub fn decodeInt(comptime T: type, comptime byteOrder: std.builtin.Endian, encoded: []const u8) T {
    const size = @sizeOf(T);
    std.debug.assert(encoded.len >= size);
    const utype = comptime equivUnsigned(T);
    var res: utype = 0;
    inline for (0..size) |i| {
        const index = if (comptime byteOrder == .little) i else comptime size - 1 - i;
        res |= @as(utype, @intCast(encoded[index])) << (comptime i * 8);
    }
    return @as(T, @bitCast(res));
}

const integer_types = [_]type{ u8, i8, u16, i16, u32, i32, u64, i64, u128, i128 };

test "fixed encoding/decoding of integers" {
    inline for (integer_types) |typ| {
        var buf: [@sizeOf(typ)]u8 = undefined;
        inline for (&[_]std.builtin.Endian{ .little, .big }) |ord| {
            {
                const min: typ = std.math.minInt(typ);
                encodeInt(ord, &buf, min);
                const dec = decodeInt(typ, ord, &buf);
                try std.testing.expectEqual(min, dec);
            }
            {
                const max: typ = std.math.maxInt(typ);
                encodeInt(ord, &buf, max);
                const dec = decodeInt(typ, ord, &buf);
                try std.testing.expectEqual(max, dec);
            }
        }
    }
}

fn signedVarIntTransform(val: anytype) equivUnsigned(@TypeOf(val)) {
    const T = @TypeOf(val);
    const utype = comptime equivUnsigned(T);
    return switch (@typeInfo(T)) {
        .Int => |inner| if (comptime inner.signedness == .signed) sm: {
            var v = @as(utype, @bitCast(val)) << 1;
            if (val < 0) {
                v = ~v;
            }
            break :sm v;
        } else val,
        else => unreachable,
    };
}

/// Encodes a variable-length integer into a writer and returns the number
/// of bytes written. Caller should use `std.io.fixedBufferStream` alongside
/// this function when writing to a buffer.
/// Supports both signed and unsigned integers.
pub fn encodeVarInt(writer: anytype, val: anytype) !usize {
    var ux = signedVarIntTransform(val);
    var w: usize = 1;
    while (ux > 0x80) : (ux >>= 7) {
        try writer.writeByte(@as(u8, @truncate(ux)) | 0x80);
        w += 1;
    }
    try writer.writeByte(@as(u8, @truncate(ux)));
    return w;
}

/// Returns the maximum number of bytes an integer of type T could take
/// when varint encoded. If you want to see how many bytes a specific value
/// of type T would take, use `varIntSize`.
pub fn maximumVarIntSize(comptime T: type) comptime_int {
    const v: T = std.math.maxInt(T);
    return @intCast(varIntSize(v));
}

/// Returns the number of bytes needed to varint-encode an integer. See `maximumVarIntSize`.
pub fn varIntSize(val: anytype) usize {
    const equiv = signedVarIntTransform(val);
    const hs = @typeInfo(@TypeOf(val)).Int.bits - @clz(equiv);
    return @divFloor(hs + 6, 7);
}

/// Decodes a variable-length integer from a buffer and returns it as a value
/// of a given type in addition to the number of bytes read.
///
/// Errors:
/// - error.VarIntNoFit if the decoded varint won't fit in the chosen type
/// - error.InvalidVarInt if encoded.len == 0 or last byte in buffer doesn't start w/ 0
pub fn decodeVarInt(comptime T: type, encoded: []const u8) !struct { val: T, read: usize } {
    if (encoded.len == 0) return error.InvalidVarInt;
    const utype = comptime equivUnsigned(T);
    const max_bits = @typeInfo(T).Int.bits;
    var s: usize = 0;
    const decoded: utype = blk: {
        var x: utype = 0;
        for (encoded) |b| {
            if (s >= max_bits) return error.VarIntNoFit;
            if (b < 0x80) {
                break :blk x | std.math.shl(utype, @intCast(b), s);
            }
            x |= std.math.shl(utype, @intCast(b & 0x7f), s);
            s += 7;
        }
        return error.InvalidVarInt;
    };
    const read = (s / 7) + 1;
    if (comptime @typeInfo(T).Int.signedness == .signed) {
        var x = @as(T, @bitCast(decoded >> 1));
        if (decoded & 1 != 0) {
            x = ~x;
        }
        return .{ .val = x, .read = read };
    }
    return .{ .val = decoded, .read = read };
}

test "varint encoding/decoding" {
    var buf: [19]u8 = undefined;
    inline for (integer_types) |typ| {
        {
            const min: typ = std.math.minInt(typ);
            var fbs = std.io.fixedBufferStream(&buf);
            const n = try encodeVarInt(fbs.writer(), min);
            const decoded = try decodeVarInt(typ, buf[0..n]);
            try std.testing.expectEqual(decoded.read, n);
            try std.testing.expectEqual(decoded.val, min);
        }
        {
            const max: typ = std.math.maxInt(typ);
            var fbs = std.io.fixedBufferStream(&buf);
            const n = try encodeVarInt(fbs.writer(), max);
            const decoded = try decodeVarInt(typ, buf[0..n]);
            try std.testing.expectEqual(decoded.read, n);
            try std.testing.expectEqual(decoded.val, max);
        }
    }

    var fbs = std.io.fixedBufferStream(&buf);
    const n = try encodeVarInt(fbs.writer(), @as(u64, 65535));
    try std.testing.expectError(error.InvalidVarInt, decodeVarInt(u64, buf[0 .. n - 1]));
    try std.testing.expectError(error.VarIntNoFit, decodeVarInt(u8, buf[0..n]));
}

// All credit goes to Jarred Sumner (Bun).
// Original version:
// https://github.com/oven-sh/bun/blob/e171f04ce6233b7d2360902c758b87a72de77dfd/src/string_immutable.zig#L896
inline fn eqlComptimeInternal(
    a: []const u8,
    comptime b: []const u8,
    comptime check_len: bool,
) bool {
    @setEvalBranchQuota(9999);

    if (comptime check_len) {
        if (a.len != b.len) return false;
    }

    comptime var b_ptr: usize = 0;

    inline while (b.len - b_ptr >= @sizeOf(usize)) {
        if (@as(usize, @bitCast(a[b_ptr..][0..@sizeOf(usize)].*)) !=
            comptime @as(usize, @bitCast(b[b_ptr..][0..@sizeOf(usize)].*)))
            return false;
        comptime b_ptr += @sizeOf(usize);
        if (comptime b_ptr == b.len) return true;
    }

    if (comptime @sizeOf(usize) == 8) {
        if (comptime (b.len & 4) != 0) {
            if (@as(u32, @bitCast(a[b_ptr..][0..@sizeOf(u32)].*)) !=
                comptime @as(u32, @bitCast(b[b_ptr..][0..@sizeOf(u32)].*)))
                return false;
            comptime b_ptr += @sizeOf(u32);
            if (comptime b_ptr == b.len) return true;
        }
    }

    if (comptime (b.len & 2) != 0) {
        if (@as(u16, @bitCast(a[b_ptr..][0..@sizeOf(u16)].*)) !=
            comptime @as(u16, @bitCast(b[b_ptr..][0..@sizeOf(u16)].*)))
            return false;
        comptime b_ptr += @sizeOf(u16);
        if (comptime b_ptr == b.len) return true;
    }

    if ((comptime (b.len & 1) != 0) and a[b_ptr] != comptime b[b_ptr]) return false;

    return true;
}

inline fn eqlComptimeKnownType(
    comptime T: type,
    a: []const T,
    comptime b: []const T,
    comptime check_len: bool,
) bool {
    if (comptime T != u8) {
        return eqlComptimeInternal(
            std.mem.sliceAsBytes(a),
            comptime std.mem.sliceAsBytes(b),
            comptime check_len,
        );
    }
    return eqlComptimeInternal(a, comptime b, comptime check_len);
}

/// Checks equality of two slices (any type), where the contents of one of the slices
/// is known at compile time. Automatically derives the optimal comparison code.
pub fn eqlComptime(
    comptime T: type,
    a: []const T,
    comptime b: anytype,
) bool {
    return eqlComptimeKnownType(
        comptime T,
        a,
        if (@typeInfo(@TypeOf(b)) != .Pointer) &b else b,
        true,
    );
}

test "eql comptime" {
    try std.testing.expect(eqlComptime(u8, "hello", "hello"));
    try std.testing.expect(!eqlComptime(u8, "hello", "world"));
}
