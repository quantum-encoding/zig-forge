//! Externally-anchored tests for zsudo.
//!
//! There is no runnable GNU/BSD sudo reference available in this environment:
//! /usr/bin/sudo is setuid-root and refuses to run unprivileged ("setuid
//! cannot open: Permission denied"), and it would require an interactive
//! password/tty even if it did. So the anchors below are the DOCUMENTED sudo
//! behaviors, with the expected results written literally and each rule cited
//! to its source (sudoers(5), the sudo(8) man page, and sudo's env.c). These
//! are not roundtrip tests — every expectation is an independent statement of
//! what sudo is specified to do, checked against zsudo's actual logic.
//!
//! Run under: `zig build test`.

const std = @import("std");
const testing = std.testing;
const main = @import("main.zig");

// ---------------------------------------------------------------------------
// sudoers user-spec matching  (main.sudoersLineGrants)
//
// Anchor: sudoers(5), "SUDOERS FILE FORMAT" — a user specification is
//   User_List Host_List = (Runas_List) Cmnd_Spec_List
// The user field is the first token and is matched by exact login name, NOT by
// prefix. This is the concrete bug the audit flagged: with `bobby ALL=(ALL) ALL`
// present, a *different* user `bob` must NOT be authorized.
// ---------------------------------------------------------------------------

test "sudoers: exact username grant authorizes that user" {
    // sudoers(5) worked example: " USER  ALL=(ALL:ALL) ALL "
    try testing.expect(main.sudoersLineGrants("bob ALL=(ALL) ALL", "bob"));
    try testing.expect(main.sudoersLineGrants("bob ALL=(ALL:ALL) ALL", "bob"));
    try testing.expect(main.sudoersLineGrants("root ALL=(ALL) ALL", "root"));
}

test "sudoers: NOPASSWD ALL grant is honored" {
    // sudoers(5), "Tag_Spec": NOPASSWD is a valid command tag; `) NOPASSWD: ALL`
    // still grants ALL commands.
    try testing.expect(main.sudoersLineGrants("deploy ALL=(ALL) NOPASSWD: ALL", "deploy"));
}

test "sudoers: prefix of a longer username is NOT authorized (the audit bug)" {
    // The pre-fix std.mem.startsWith made `bobby ALL=(ALL) ALL` match user `bob`.
    // sudoers matches the whole login name, so bob must be rejected here.
    try testing.expect(!main.sudoersLineGrants("bobby ALL=(ALL) ALL", "bob"));
    try testing.expect(!main.sudoersLineGrants("administrator ALL=(ALL) ALL", "admin"));
    // And the reverse: a shorter rule name must not match a longer user.
    try testing.expect(!main.sudoersLineGrants("bob ALL=(ALL) ALL", "bobby"));
}

test "sudoers: group and netgroup specs are not username grants" {
    // sudoers(5): a leading % is a Unix group, + is a netgroup. Group membership
    // is authorized by a separate code path (getgrouplist), never by matching a
    // login name against a %group line.
    try testing.expect(!main.sudoersLineGrants("%wheel ALL=(ALL) ALL", "wheel"));
    try testing.expect(!main.sudoersLineGrants("%admin ALL=(ALL) ALL", "admin"));
    try testing.expect(!main.sudoersLineGrants("+netgroup ALL=(ALL) ALL", "netgroup"));
}

test "sudoers: comments, blank lines and Defaults are ignored" {
    // sudoers(5): lines beginning with '#' are comments; Defaults lines are not
    // user specifications.
    try testing.expect(!main.sudoersLineGrants("# bob ALL=(ALL) ALL", "bob"));
    try testing.expect(!main.sudoersLineGrants("", "bob"));
    try testing.expect(!main.sudoersLineGrants("   ", "bob"));
    try testing.expect(!main.sudoersLineGrants("Defaults env_reset", "bob"));
}

test "sudoers: leading whitespace before the username is tolerated" {
    // Indentation is not significant in sudoers; the user token is still first.
    try testing.expect(main.sudoersLineGrants("\t  bob ALL=(ALL) ALL", "bob"));
}

test "sudoers: a line that does not grant ALL commands is not a wildcard grant" {
    // Per-command restrictions are not (yet) modeled; zsudo fails closed and
    // only treats an ALL command spec as a grant, never a narrower one.
    try testing.expect(!main.sudoersLineGrants("bob ALL=(ALL) /usr/bin/systemctl", "bob"));
    try testing.expect(!main.sudoersLineGrants("bob host=(ALL) ALL", "bob"));
}

// ---------------------------------------------------------------------------
// -E environment scrubbing  (main.envVarShouldDrop)
//
// Anchor: sudoers(5) "Restricting environment variables" / sudo(8), and sudo's
// env.c initial_badenv_table: even with the environment preserved, sudo
// unconditionally removes variables that can subvert the dynamic loader, the
// shell, or a scripting interpreter. Forwarding these into a root process is a
// documented privilege-escalation vector.
// ---------------------------------------------------------------------------

test "-E: dynamic-loader variables are always dropped" {
    try testing.expect(main.envVarShouldDrop("LD_PRELOAD=/tmp/evil.so"));
    try testing.expect(main.envVarShouldDrop("LD_LIBRARY_PATH=/tmp"));
    try testing.expect(main.envVarShouldDrop("DYLD_INSERT_LIBRARIES=/tmp/evil.dylib")); // macOS loader
}

test "-E: shell / interpreter injection variables are always dropped" {
    // sudo env.c: IFS, ENV, BASH_ENV, BASH_FUNC_*, SHELLOPTS, GLOBIGNORE, PS4,
    // PERL5LIB, PYTHONPATH, RUBYLIB, ... are all in the always-removed set.
    try testing.expect(main.envVarShouldDrop("IFS=$' \\t\\n'"));
    try testing.expect(main.envVarShouldDrop("BASH_ENV=/tmp/rc"));
    try testing.expect(main.envVarShouldDrop("ENV=/tmp/rc"));
    try testing.expect(main.envVarShouldDrop("BASH_FUNC_foo%%=() { :; }"));
    try testing.expect(main.envVarShouldDrop("GLOBIGNORE=*"));
    try testing.expect(main.envVarShouldDrop("PS4=evil"));
    try testing.expect(main.envVarShouldDrop("PERL5LIB=/tmp"));
    try testing.expect(main.envVarShouldDrop("PYTHONPATH=/tmp"));
    try testing.expect(main.envVarShouldDrop("RUBYLIB=/tmp"));
}

test "-E: variables zsudo sets itself are dropped from the inherited set" {
    // HOME/USER/LOGNAME/SHELL/PATH/TERM and SUDO_* are re-emitted by zsudo, so
    // the caller's copies must not be forwarded (they'd duplicate/override).
    try testing.expect(main.envVarShouldDrop("PATH=/attacker/bin"));
    try testing.expect(main.envVarShouldDrop("HOME=/attacker"));
    try testing.expect(main.envVarShouldDrop("SUDO_USER=spoofed"));
}

test "-E: ordinary safe variables are preserved" {
    // sudoers(5): env_keep passes benign variables through unchanged under -E.
    try testing.expect(!main.envVarShouldDrop("EDITOR=vim"));
    try testing.expect(!main.envVarShouldDrop("LANG=en_US.UTF-8"));
    try testing.expect(!main.envVarShouldDrop("COLORTERM=truecolor"));
    try testing.expect(!main.envVarShouldDrop("MY_APP_TOKEN=abc"));
    // Not a false-positive: a name that merely *contains* a bad substring but
    // is not the exact dangerous name must survive.
    try testing.expect(!main.envVarShouldDrop("PATH_TO_MY_THING=/x")); // not PATH, not PATH_LOCALE
    try testing.expect(!main.envVarShouldDrop("TERMINAL_APP=iTerm")); // not TERM, not TERMINFO
}
