//! Regression guard for the canonical legal-document sample inputs.
//!
//! Loops every templates/legal/<type>.json through its matching renderer under
//! std.testing.allocator (so any leak fails the test) and asserts a valid PDF
//! is produced. This keeps the checked-in samples honest as the parsers evolve:
//! a schema change that breaks a sample — or reintroduces a parser leak — fails
//! `zig build test`.
//!
//! Paths are resolved relative to the package root; build.zig pins the test
//! run's cwd so `zig build test` works regardless of where it is invoked.

const std = @import("std");
const lib = @import("lib.zig");

fn readSample(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 * 1024 * 1024)) catch |err| {
        std.debug.print("sample_tests: cannot read '{s}': {s} (run from the package root)\n", .{ path, @errorName(err) });
        return err;
    };
}

test "canonical legal samples generate valid PDFs (leak-checked)" {
    const a = std.testing.allocator;
    // Each entry pairs the checked-in sample with the generator the CLI's
    // `--certificate <type>` flag dispatches to. inline for keeps the function
    // comptime-known (no fn-pointer error-set juggling).
    inline for (.{
        .{ "templates/legal/contract.json", lib.generateContractFromJson },
        .{ "templates/legal/share-certificate.json", lib.generateShareCertificateFromJson },
        .{ "templates/legal/dividend-voucher.json", lib.generateDividendVoucherFromJson },
        .{ "templates/legal/stock-transfer.json", lib.generateStockTransferFromJson },
        .{ "templates/legal/board-resolution.json", lib.generateBoardResolutionFromJson },
        .{ "templates/legal/director-consent.json", lib.generateDirectorConsentFromJson },
        .{ "templates/legal/director-appointment.json", lib.generateDirectorAppointmentFromJson },
        .{ "templates/legal/director-resignation.json", lib.generateDirectorResignationFromJson },
        .{ "templates/legal/written-resolution.json", lib.generateWrittenResolutionFromJson },
    }) |case| {
        const json = try readSample(a, case[0]);
        defer a.free(json);
        const pdf = try case[1](a, json);
        defer a.free(pdf);
        try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF"));
        try std.testing.expect(pdf.len > 800);
    }
}
