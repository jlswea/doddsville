//! Copied from jlswea/ascii85 (main and benchmarks dropped).

const std = @import("std");

/// Ascii85 (also called Base85) encoding and decoding.
///
/// Ascii85 encodes binary data into printable ASCII characters. Each group of
/// 4 input bytes is interpreted as a big-endian 32-bit integer, then converted
/// to 5 base-85 digits mapped to the character range '!' (33) through 'u' (117).
/// This gives a 25% size overhead compared to 33% for Base64.
/// 85 is the minimum integer value of n so that n^5 ≥ 256^4 = 2^32.
///
/// Partial groups (1-3 trailing bytes) are zero-padded to 4 bytes for encoding,
/// and only the first N+1 output characters are kept (where N is the number of
/// remaining bytes). Decoding reverses this by padding with 'u' (the highest
/// digit, value 84) to reconstruct the original bytes.
///
/// This implementation uses the raw encoding without `<~ ~>` delimiters.
///
/// See: https://en.wikipedia.org/wiki/Ascii85
pub const Ascii85 = struct {
    pub fn _encode_len(input: []const u8) usize {
        return (input.len / 4) * 5 + if (input.len % 4 > 0) input.len % 4 + 1 else 0;
    }

    pub fn _decode_len(input: []const u8) usize {
        return (input.len / 5) * 4 + if (input.len % 5 > 0) input.len % 5 - 1 else 0;
    }

    /// Encode a byte slice into Ascii85.
    ///
    /// Each 4-byte group is read as a big-endian u32, then repeatedly divided
    /// by 85 to extract 5 digits (least-significant first). Each digit is
    /// offset by 33 to map into the printable ASCII range '!' .. 'u'.
    ///
    /// Trailing bytes (1-3) are zero-padded to 4, encoded into 5 digits, and
    /// truncated to N+1 output chars where N is the number of trailing bytes.
    pub fn encode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        if (input.len == 0) {
            return allocator.alloc(u8, 0);
        }

        const encode_len = _encode_len(input);
        var output = try allocator.alloc(u8, encode_len);
        var out_idx: usize = 0;

        var fourGrams = std.mem.window(u8, input, 4, 4);

        while (fourGrams.next()) |fourGram| {
            if (fourGram.len < 4) break;
            var value = std.mem.readInt(u32, fourGram[0..4], .big);

            var i: usize = 5;
            while (i > 0) {
                i -= 1;
                output[out_idx + i] = @intCast(value % 85 + 33);
                value /= 85;
            }
            out_idx += 5;
        }

        const remainder = input.len % 4;
        if (remainder > 0) {
            var padded: [4]u8 = .{ 0, 0, 0, 0 };
            @memcpy(padded[0..remainder], input[input.len - remainder ..]);
            var value = std.mem.readInt(u32, &padded, .big);

            // Extract all 5 base-85 digits, then keep only the first remainder+1
            var all5: [5]u8 = undefined;
            var i: usize = 5;
            while (i > 0) {
                i -= 1;
                all5[i] = @intCast(value % 85 + 33);
                value /= 85;
            }
            @memcpy(output[out_idx .. out_idx + remainder + 1], all5[0 .. remainder + 1]);
        }

        return output;
    }

    /// Decode an Ascii85-encoded byte slice back to raw bytes.
    ///
    /// Each 5-character group is converted back to a u32 by accumulating
    /// base-85 digits (char - 33), then split into 4 big-endian bytes.
    ///
    /// Trailing characters (1-4) are padded with 'u' (value 84, the highest
    /// base-85 digit) to 5, decoded, and truncated to N-1 output bytes where
    /// N is the number of trailing characters. The 'u' padding ensures the
    /// reconstructed value rounds up, matching the zero-padding used during
    /// encoding.
    pub fn decode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        if (input.len == 0) {
            return allocator.alloc(u8, 0);
        }

        const decode_len = _decode_len(input);
        var output = try allocator.alloc(u8, decode_len);
        var out_idx: usize = 0;

        const full_chunks = input.len / 5;
        var chunk_idx: usize = 0;

        while (chunk_idx < full_chunks) : (chunk_idx += 1) {
            const start = chunk_idx * 5;
            var value: u32 = 0;
            for (0..5) |i| {
                value = value * 85 + (input[start + i] - 33);
            }

            const bytes = std.mem.toBytes(std.mem.nativeToBig(u32, value));
            @memcpy(output[out_idx .. out_idx + 4], &bytes);
            out_idx += 4;
        }

        const remainder = input.len % 5;
        if (remainder > 0) {
            var padded: [5]u8 = .{ 'u', 'u', 'u', 'u', 'u' };
            @memcpy(padded[0..remainder], input[input.len - remainder ..]);

            var value: u32 = 0;
            for (0..5) |i| {
                value = value * 85 + (padded[i] - 33);
            }

            const bytes = std.mem.toBytes(std.mem.nativeToBig(u32, value));
            const out_bytes = remainder - 1;
            @memcpy(output[out_idx .. out_idx + out_bytes], bytes[0..out_bytes]);
        }

        return output;
    }
};

test "encode length for partial chunk" {
    const input = [_]u8{ 'H', 'i' };
    try std.testing.expectEqual(@as(usize, 3), Ascii85._encode_len(&input));
}

test "encode length for exact multiple of 4" {
    const input = [_]u8{ 'T', 'e', 's', 't' };
    try std.testing.expectEqual(@as(usize, 5), Ascii85._encode_len(&input));
}

test "encode length for 7 bytes" {
    const input = [_]u8{ 'd', 'e', 'f', 'a', 'u', 'l', 't' };
    try std.testing.expectEqual(@as(usize, 9), Ascii85._encode_len(&input));
}

test "encode length for empty input" {
    const input: []const u8 = "";
    try std.testing.expectEqual(@as(usize, 0), Ascii85._encode_len(input));
}

test "decode length for 5 chars" {
    const input: []const u8 = "abcde";
    try std.testing.expectEqual(@as(usize, 4), Ascii85._decode_len(input));
}

test "decode length for 3 chars" {
    const input: []const u8 = "abc";
    try std.testing.expectEqual(@as(usize, 2), Ascii85._decode_len(input));
}

test "decode length for empty input" {
    const input: []const u8 = "";
    try std.testing.expectEqual(@as(usize, 0), Ascii85._decode_len(input));
}

test "encode Leviathan quote" {
    const quote = "Man is distinguished, not only by his reason, but by this singular passion from other animals, which is a lust of the mind, that by a perseverance of delight in the continued and indefatigable generation of knowledge, exceeds the short vehemence of any carnal pleasure.";
    const expected_output = "9jqo^BlbD-BleB1DJ+*+F(f,q/0JhKF<GL>Cj@.4Gp$d7F!,L7@<6@)/0JDEF<G%<+EV:2F!,O<DJ+*.@<*K0@<6L(Df-\\0Ec5e;DffZ(EZee.Bl.9pF\"AGXBPCsi+DGm>@3BB/F*&OCAfu2/AKYi(DIb:@FD,*)+C]U=@3BN#EcYf8ATD3s@q?d$AftVqCh[NqF<G:8+EV:.+Cf>-FD5W8ARlolDIal(DId<j@<?3r@:F%a+D58'ATD4$Bl@l3De:,-DJs`8ARoFb/0JMK@qB4^F!,R<AKZ&-DfTqBG%G>uD.RTpAKYo'+CT/5+Cei#DII?(E,9)oF*2M7/c";
    var buffer: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    const allocator = fba.allocator();

    try std.testing.expectEqualSlices(u8, expected_output, try Ascii85.encode(allocator, quote));
}

test "decode Leviathan quote" {
    const encoded = "9jqo^BlbD-BleB1DJ+*+F(f,q/0JhKF<GL>Cj@.4Gp$d7F!,L7@<6@)/0JDEF<G%<+EV:2F!,O<DJ+*.@<*K0@<6L(Df-\\0Ec5e;DffZ(EZee.Bl.9pF\"AGXBPCsi+DGm>@3BB/F*&OCAfu2/AKYi(DIb:@FD,*)+C]U=@3BN#EcYf8ATD3s@q?d$AftVqCh[NqF<G:8+EV:.+Cf>-FD5W8ARlolDIal(DId<j@<?3r@:F%a+D58'ATD4$Bl@l3De:,-DJs`8ARoFb/0JMK@qB4^F!,R<AKZ&-DfTqBG%G>uD.RTpAKYo'+CT/5+Cei#DII?(E,9)oF*2M7/c";
    const expected = "Man is distinguished, not only by his reason, but by this singular passion from other animals, which is a lust of the mind, that by a perseverance of delight in the continued and indefatigable generation of knowledge, exceeds the short vehemence of any carnal pleasure.";
    var buffer: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    const allocator = fba.allocator();

    try std.testing.expectEqualSlices(u8, expected, try Ascii85.decode(allocator, encoded));
}

test "roundtrip empty input" {
    var buffer: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    const allocator = fba.allocator();
    const input: []const u8 = "";

    const encoded = try Ascii85.encode(allocator, input);
    const decoded = try Ascii85.decode(allocator, encoded);
    try std.testing.expectEqualSlices(u8, input, decoded);
}

test "roundtrip single byte" {
    var buffer: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    const allocator = fba.allocator();
    const input: []const u8 = "A";

    const encoded = try Ascii85.encode(allocator, input);
    const decoded = try Ascii85.decode(allocator, encoded);
    try std.testing.expectEqualSlices(u8, input, decoded);
}

test "roundtrip exactly 4 bytes" {
    var buffer: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    const allocator = fba.allocator();
    const input: []const u8 = "Test";

    const encoded = try Ascii85.encode(allocator, input);
    const decoded = try Ascii85.decode(allocator, encoded);
    try std.testing.expectEqualSlices(u8, input, decoded);
}

test "roundtrip 7 bytes" {
    var buffer: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    const allocator = fba.allocator();
    const input: []const u8 = "Hello!!";

    const encoded = try Ascii85.encode(allocator, input);
    const decoded = try Ascii85.decode(allocator, encoded);
    try std.testing.expectEqualSlices(u8, input, decoded);
}
