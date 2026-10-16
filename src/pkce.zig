//! PKCE (RFC 7636), S256 only (the server refuses `plain`), and the random
//! `state` the browser login checks the redirect against.
const std = @import("std");

const b64 = std.base64.url_safe_no_pad.Encoder;

/// 32 random bytes as unpadded base64url: 43 characters, the shortest
/// verifier RFC 7636 allows and the challenge shape the server checks
/// (`[A-Za-z0-9_-]{43}`).
pub const Verifier = [43]u8;
pub const Challenge = [43]u8;

/// A verifier made from `random` (32 bytes from a CSPRNG).
pub fn verifierFrom(random: [32]u8) Verifier {
    var out: Verifier = undefined;
    _ = b64.encode(&out, &random);
    return out;
}

/// BASE64URL(SHA256(ASCII(verifier))).
pub fn challenge(verifier: []const u8) Challenge {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    var out: Challenge = undefined;
    _ = b64.encode(&out, &digest);
    return out;
}

/// A fresh verifier and state from the operating system's CSPRNG.
pub fn generate(io: std.Io) error{EntropyUnavailable}!struct { verifier: Verifier, state: Verifier } {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    io.randomSecure(&a) catch return error.EntropyUnavailable;
    io.randomSecure(&b) catch return error.EntropyUnavailable;
    return .{ .verifier = verifierFrom(a), .state = verifierFrom(b) };
}

const testing = std.testing;

test "the RFC 7636 Appendix B example" {
    const random = [32]u8{
        116, 24,  223, 180, 151, 153, 224, 37,  79, 250, 96, 125, 216, 173, 187, 186,
        22,  212, 37,  77,  105, 214, 191, 240, 91, 88,  5,  88,  83,  132, 141, 121,
    };
    const verifier = verifierFrom(random);
    try testing.expectEqualStrings("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", &verifier);
    try testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", &challenge(&verifier));
}

test "a verifier is 43 URL-safe characters" {
    const random: [32]u8 = @splat(0xff);
    const verifier = verifierFrom(random);
    for (verifier) |c| try testing.expect(std.ascii.isAlphanumeric(c) or c == '-' or c == '_');
    const c = challenge(&verifier);
    try testing.expectEqual(@as(usize, 43), c.len);
}
