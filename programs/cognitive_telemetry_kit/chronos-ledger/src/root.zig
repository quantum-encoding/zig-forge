//! chronos_ledger — tamper-evident accountability log for AI agents.
//!
//! Public Zig surface. See DESIGN.md for the architecture and AGENT-GUIDE in
//! ../chronos-hook for the sibling (squashable) tick system this complements.

pub const canonical = @import("canonical.zig");
pub const ledger = @import("ledger.zig");
pub const emit = @import("emit_client.zig");

// Re-exports for ergonomic `chronos_ledger.X` access.
pub const Chain = ledger.Chain;
pub const Appended = ledger.Appended;
pub const Verdict = ledger.Verdict;
pub const verifyEvent = ledger.verifyEvent;
pub const generateKeypair = ledger.generateKeypair;
pub const KeyPairBytes = ledger.KeyPairBytes;
pub const toCanonical = ledger.toCanonical;

pub const HEAD_LEN = ledger.HEAD_LEN;
pub const PK_LEN = ledger.PK_LEN;
pub const SK_LEN = ledger.SK_LEN;
pub const SIG_LEN = ledger.SIG_LEN;
pub const SCHEMA_VERSION = ledger.SCHEMA_VERSION;

test {
    _ = canonical;
    _ = ledger;
    _ = emit;
}
