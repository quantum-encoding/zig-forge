//! secrets — Cross-platform encrypted secret manager
//!
//! AES-256-GCM encrypted vault. Key derivation:
//!   - v2 (current writes): Argon2id, t=3, m=64 MiB, p=1
//!   - v1 (legacy read-compat): PBKDF2-HMAC-SHA256, 600k rounds
//! New writes always produce v2; a v1 vault is transparently re-encrypted as
//! v2 on the next mutating command. Single static binary, zero runtime deps.
//!
//! Vault format (binary):
//!   [4]  magic: "QVLT"
//!   [1]  version: 0x01 (PBKDF2) | 0x02 (Argon2id)
//!   [16] KDF salt
//!   [12] AES-GCM nonce
//!   [16] AES-GCM auth tag
//!   [..] ciphertext (encrypted key-value pairs)
//!
//! Plaintext format: repeated [2 BE keylen][key][4 BE vallen][value], terminated [0x00 0x00]

const std = @import("std");
const builtin = @import("builtin");
const crypto = std.crypto;
const Aes256Gcm = crypto.aead.aes_gcm.Aes256Gcm;
const pbkdf2 = crypto.pwhash.pbkdf2;
const argon2 = crypto.pwhash.argon2;
const mem = std.mem;
const fs = std.fs;

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("termios.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("sys/stat.h");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
});

/// Cross-platform secure random bytes. Fails closed: a short/failed read of the
/// kernel CSPRNG aborts the process rather than leaving the AES-GCM salt/nonce
/// as uninitialized stack memory (nonce reuse is catastrophic for an AEAD vault).
/// macOS: arc4random_buf (always available, kernel CSPRNG, cannot fail)
/// Linux: getrandom(2) with a fill loop that handles EINTR/short reads (kernel 3.17+)
fn secureRandom(buf: []u8) void {
    if (comptime builtin.os.tag.isDarwin()) {
        const arc4random = @extern(*const fn ([*]u8, usize) callconv(.c) void, .{ .name = "arc4random_buf" });
        arc4random(buf.ptr, buf.len);
    } else if (comptime builtin.os.tag == .linux) {
        // Linux: getrandom(2) syscall — blocking, CSPRNG, no fd needed.
        var remaining = buf;
        while (remaining.len > 0) {
            const result = std.os.linux.getrandom(remaining.ptr, remaining.len, 0);
            const signed: isize = @bitCast(result);
            if (signed < 0) {
                const errno: std.os.linux.E = @enumFromInt(@as(usize, @intCast(-signed)));
                if (errno == .INTR) continue; // interrupted, retry
                write_stderr("Error: kernel RNG (getrandom) failed\n");
                c.exit(1);
            }
            const n: usize = @intCast(signed);
            if (n == 0) {
                write_stderr("Error: kernel RNG returned no entropy\n");
                c.exit(1);
            }
            remaining = remaining[n..];
        }
    } else {
        @compileError("secureRandom: unsupported OS");
    }
}

// ── Constants ──

const MAGIC = [4]u8{ 'Q', 'V', 'L', 'T' };
const VERSION_PBKDF2: u8 = 0x01; // legacy vaults, read-only compat
const VERSION_ARGON2: u8 = 0x02; // current write format
const VERSION: u8 = VERSION_ARGON2; // what new writes emit
const SALT_LEN = 16;
const NONCE_LEN = 12;
const TAG_LEN = 16;
const HEADER_LEN = 4 + 1 + SALT_LEN + NONCE_LEN + TAG_LEN; // 49
const KEY_LEN = 32;
const MAX_VAULT_SIZE = 4 * 1024 * 1024; // 4 MiB
const MAX_KEY_LEN = 256;
const MAX_VALUE_LEN = 64 * 1024; // 64 KiB per value

// Argon2id parameters (v2 write path). m is in KiB; 65536 KiB = 64 MiB.
// p=1 keeps derivation single-threaded (no std.Io worker pool needed for a
// one-shot CLI unlock); t=3/64 MiB exceeds OWASP's Argon2id minimum.
const ARGON2_T: u32 = 3;
const ARGON2_M: u32 = 64 * 1024;
const ARGON2_P: u24 = 1;

// PBKDF2-HMAC-SHA256 rounds (v1 legacy read path only).
const PBKDF2_ROUNDS = 600_000; // OWASP 2023 recommendation for SHA-256

// ── I/O helpers (no std.io in Zig 0.16) ──

fn write_stdout(msg: []const u8) void {
    _ = c.write(1, msg.ptr, msg.len);
}

fn write_stderr(msg: []const u8) void {
    _ = c.write(2, msg.ptr, msg.len);
}

fn print_stderr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    write_stderr(msg);
}

fn print_stdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    write_stdout(msg);
}

fn read_line_stdin(buf: []u8) ?[]u8 {
    var pos: usize = 0;
    while (pos < buf.len) {
        var byte: [1]u8 = undefined;
        const n = c.read(0, &byte, 1);
        if (n <= 0) break;
        if (byte[0] == '\n') break;
        buf[pos] = byte[0];
        pos += 1;
    }
    if (pos == 0) return null;
    return buf[0..pos];
}

// ── Types ──

const Entry = struct {
    key: []u8,
    value: []u8,
};

const Vault = struct {
    entries: [512]Entry = undefined,
    count: usize = 0,

    fn get(self: *const Vault, key: []const u8) ?[]const u8 {
        for (self.entries[0..self.count]) |entry| {
            if (mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }

    /// Returns true if stored, false if rejected (oversize key/value or vault full).
    /// Enforcing the limits here (not only on deserialize) is what keeps `serialize`
    /// from ever overflowing `work_buf` and prevents a >MAX_VALUE_LEN entry from being
    /// written and then silently dropped on the next load.
    fn set(self: *Vault, key: []const u8, value: []const u8) bool {
        if (key.len == 0 or key.len > MAX_KEY_LEN) {
            write_stderr("Error: key length out of range\n");
            return false;
        }
        if (value.len > MAX_VALUE_LEN) {
            write_stderr("Error: value exceeds 64 KiB limit\n");
            return false;
        }
        // Update existing
        for (self.entries[0..self.count]) |*entry| {
            if (mem.eql(u8, entry.key, key)) {
                @memset(entry.value, 0); // zero old value
                freeSlice(entry.value); // free old allocation before overwriting the pointer
                allocCopy(&entry.value, value);
                return true;
            }
        }
        // Add new
        if (self.count >= 512) {
            write_stderr("Error: vault full (max 512 entries)\n");
            return false;
        }
        allocCopy(&self.entries[self.count].key, key);
        allocCopy(&self.entries[self.count].value, value);
        self.count += 1;
        return true;
    }

    fn delete(self: *Vault, key: []const u8) bool {
        for (self.entries[0..self.count], 0..) |*entry, i| {
            if (mem.eql(u8, entry.key, key)) {
                freeSlice(entry.key);
                @memset(entry.value, 0);
                freeSlice(entry.value);
                // Shift remaining
                var j = i;
                while (j + 1 < self.count) : (j += 1) {
                    self.entries[j] = self.entries[j + 1];
                }
                self.count -= 1;
                return true;
            }
        }
        return false;
    }

    /// Serialize into `buf`. Returns null (rather than overflowing `buf`) if the
    /// entries plus the 2-byte terminator don't fit — 512 entries × ~64 KiB values
    /// can exceed the 4 MiB work buffer even though each entry is individually capped.
    fn serialize(self: *const Vault, buf: []u8) ?usize {
        var pos: usize = 0;
        for (self.entries[0..self.count]) |entry| {
            // Need: 2 (klen) + key + 4 (vlen) + value, and later 2 for the terminator.
            const need = 2 + entry.key.len + 4 + entry.value.len;
            if (pos + need + 2 > buf.len) return null;
            // Key: [2 BE len][bytes]
            buf[pos] = @intCast(entry.key.len >> 8);
            buf[pos + 1] = @intCast(entry.key.len & 0xFF);
            pos += 2;
            @memcpy(buf[pos .. pos + entry.key.len], entry.key);
            pos += entry.key.len;
            // Value: [4 BE len][bytes]
            const vlen = entry.value.len;
            buf[pos] = @intCast((vlen >> 24) & 0xFF);
            buf[pos + 1] = @intCast((vlen >> 16) & 0xFF);
            buf[pos + 2] = @intCast((vlen >> 8) & 0xFF);
            buf[pos + 3] = @intCast(vlen & 0xFF);
            pos += 4;
            @memcpy(buf[pos .. pos + vlen], entry.value);
            pos += vlen;
        }
        if (pos + 2 > buf.len) return null;
        buf[pos] = 0;
        buf[pos + 1] = 0;
        return pos + 2;
    }

    fn deserialize(data: []const u8) Vault {
        var vault = Vault{};
        var pos: usize = 0;
        while (pos + 2 <= data.len and vault.count < 512) {
            const klen: usize = (@as(usize, data[pos]) << 8) | @as(usize, data[pos + 1]);
            pos += 2;
            if (klen == 0) break;
            if (klen > MAX_KEY_LEN or pos + klen > data.len) break;
            allocCopy(&vault.entries[vault.count].key, data[pos .. pos + klen]);
            pos += klen;
            if (pos + 4 > data.len) break;
            const vlen: usize = (@as(usize, data[pos]) << 24) |
                (@as(usize, data[pos + 1]) << 16) |
                (@as(usize, data[pos + 2]) << 8) |
                @as(usize, data[pos + 3]);
            pos += 4;
            if (vlen > MAX_VALUE_LEN or pos + vlen > data.len) break;
            allocCopy(&vault.entries[vault.count].value, data[pos .. pos + vlen]);
            pos += vlen;
            vault.count += 1;
        }
        return vault;
    }

    fn deinit(self: *Vault) void {
        for (self.entries[0..self.count]) |*entry| {
            freeSlice(entry.key);
            @memset(entry.value, 0);
            freeSlice(entry.value);
        }
        self.count = 0;
    }
};

// ── Allocation via libc ──

fn allocCopy(dst: *[]u8, src: []const u8) void {
    const ptr = c.malloc(src.len) orelse {
        write_stderr("Error: out of memory\n");
        c.exit(1);
    };
    const slice: [*]u8 = @ptrCast(ptr);
    @memcpy(slice[0..src.len], src);
    dst.* = slice[0..src.len];
}

fn freeSlice(s: []u8) void {
    c.free(s.ptr);
}

// ── Crypto ──

/// v2 KDF: Argon2id (t=3, m=64 MiB, p=1). Fatal on failure.
fn deriveKeyArgon2(passphrase: []const u8, salt: *const [SALT_LEN]u8) [KEY_LEN]u8 {
    var dk: [KEY_LEN]u8 = undefined;
    // p=1 → argon2 takes the single-threaded sync path and never touches `io`,
    // so a statically-initialized single-threaded Io is sufficient here.
    var threaded = std.Io.Threaded.init_single_threaded;
    argon2.kdf(
        std.heap.c_allocator,
        &dk,
        passphrase,
        salt,
        .{ .t = ARGON2_T, .m = ARGON2_M, .p = ARGON2_P },
        .argon2id,
        threaded.io(),
    ) catch {
        write_stderr("Error: key derivation failed\n");
        c.exit(1);
    };
    return dk;
}

/// v1 KDF: PBKDF2-HMAC-SHA256, 600k rounds. Legacy read path only. Fatal on failure.
fn deriveKeyPbkdf2(passphrase: []const u8, salt: *const [SALT_LEN]u8) [KEY_LEN]u8 {
    var dk: [KEY_LEN]u8 = undefined;
    pbkdf2(&dk, passphrase, salt, PBKDF2_ROUNDS, crypto.auth.hmac.sha2.HmacSha256) catch {
        write_stderr("Error: key derivation failed\n");
        c.exit(1);
    };
    return dk;
}

fn encryptVault(plaintext: []const u8, passphrase: []const u8, out: []u8) usize {
    var salt: [SALT_LEN]u8 = undefined;
    secureRandom(&salt);
    var nonce: [NONCE_LEN]u8 = undefined;
    secureRandom(&nonce);

    var key = deriveKeyArgon2(passphrase, &salt);
    defer @memset(&key, 0);

    const ct = out[HEADER_LEN .. HEADER_LEN + plaintext.len];
    var tag: [TAG_LEN]u8 = undefined;
    Aes256Gcm.encrypt(ct, &tag, plaintext, "", nonce, key);

    @memcpy(out[0..4], &MAGIC);
    out[4] = VERSION;
    @memcpy(out[5 .. 5 + SALT_LEN], &salt);
    @memcpy(out[5 + SALT_LEN .. 5 + SALT_LEN + NONCE_LEN], &nonce);
    @memcpy(out[5 + SALT_LEN + NONCE_LEN .. HEADER_LEN], &tag);

    return HEADER_LEN + plaintext.len;
}

fn decryptVault(data: []const u8, passphrase: []const u8, out: []u8) ?usize {
    if (data.len < HEADER_LEN) return null;
    if (!mem.eql(u8, data[0..4], &MAGIC)) return null;
    const version = data[4];
    if (version != VERSION_ARGON2 and version != VERSION_PBKDF2) return null;

    const salt: *const [SALT_LEN]u8 = data[5 .. 5 + SALT_LEN];
    const nonce: *const [NONCE_LEN]u8 = data[5 + SALT_LEN ..][0..NONCE_LEN];
    const tag: *const [TAG_LEN]u8 = data[5 + SALT_LEN + NONCE_LEN ..][0..TAG_LEN];
    const ct = data[HEADER_LEN..];

    // Dispatch KDF on the stored version so legacy v1 (PBKDF2) vaults still open;
    // saveVault re-encrypts as v2 (Argon2id) on the next mutating command.
    var key = if (version == VERSION_ARGON2)
        deriveKeyArgon2(passphrase, salt)
    else
        deriveKeyPbkdf2(passphrase, salt);
    defer @memset(&key, 0);

    Aes256Gcm.decrypt(out[0..ct.len], ct, tag.*, "", nonce.*, key) catch return null;
    return ct.len;
}

// ── File I/O ──

var vault_path_buf: [1024]u8 = undefined;
var vault_path_len: usize = 0;

fn getVaultPath() []const u8 {
    if (vault_path_len > 0) return vault_path_buf[0..vault_path_len];

    // Check SECRETS_DIR
    if (c.getenv("SECRETS_DIR")) |dir| {
        const dlen = c.strlen(dir);
        const d: [*]const u8 = @ptrCast(dir);
        @memcpy(vault_path_buf[0..dlen], d[0..dlen]);
        const suffix = "/vault.qvlt";
        @memcpy(vault_path_buf[dlen .. dlen + suffix.len], suffix);
        vault_path_len = dlen + suffix.len;
        return vault_path_buf[0..vault_path_len];
    }

    // Default: ~/.config/secrets/vault.qvlt
    if (c.getenv("HOME")) |home| {
        const hlen = c.strlen(home);
        const h: [*]const u8 = @ptrCast(home);
        const suffix = "/.config/secrets/vault.qvlt";
        @memcpy(vault_path_buf[0..hlen], h[0..hlen]);
        @memcpy(vault_path_buf[hlen .. hlen + suffix.len], suffix);
        vault_path_len = hlen + suffix.len;
        return vault_path_buf[0..vault_path_len];
    }

    write_stderr("Error: HOME not set\n");
    c.exit(1);
}

fn ensureDir(path: []const u8) void {
    // Find last /
    var last_slash: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '/') last_slash = i;
    }
    if (last_slash == 0) return;

    var dir_buf: [1024]u8 = undefined;
    @memcpy(dir_buf[0..last_slash], path[0..last_slash]);
    dir_buf[last_slash] = 0;
    _ = c.mkdir(&dir_buf, 0o700);
}

var file_buf: [MAX_VAULT_SIZE]u8 = undefined;

fn readFile(path: []const u8) ?[]u8 {
    var path_z: [1024]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const fd = c.open(&path_z, c.O_RDONLY, @as(c_uint, 0));
    if (fd < 0) return null;
    defer _ = c.close(fd);

    var total: usize = 0;
    while (total < MAX_VAULT_SIZE) {
        const n = c.read(fd, &file_buf[total], MAX_VAULT_SIZE - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return file_buf[0..total];
}

fn writeFile(path: []const u8, data: []const u8) bool {
    ensureDir(path);
    var path_z: [1024]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const fd = c.open(&path_z, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o600));
    if (fd < 0) return false;
    defer _ = c.close(fd);

    var written: usize = 0;
    while (written < data.len) {
        const n = c.write(fd, data[written..].ptr, data.len - written);
        if (n <= 0) return false;
        written += @intCast(n);
    }
    return true;
}

// ── Passphrase ──

var pp_buf: [1024]u8 = undefined;

fn getPassphrase() []const u8 {
    // 1. Env var
    if (c.getenv("SECRETS_PASSPHRASE")) |pp| {
        const len = c.strlen(pp);
        return @as([*]const u8, @ptrCast(pp))[0..len];
    }

    // 2. Prompt with echo disabled
    write_stderr("Vault passphrase: ");

    var old_termios: c.struct_termios = undefined;
    const have_tty = c.tcgetattr(0, &old_termios) == 0;
    if (have_tty) {
        var new_termios = old_termios;
        new_termios.c_lflag &= ~@as(c_uint, c.ECHO);
        _ = c.tcsetattr(0, 0, &new_termios);
    }

    const line = read_line_stdin(&pp_buf);

    if (have_tty) {
        _ = c.tcsetattr(0, 0, &old_termios);
        write_stderr("\n");
    }

    return line orelse {
        write_stderr("Error: no passphrase\n");
        c.exit(1);
    };
}

// ── Commands ──

var work_buf: [MAX_VAULT_SIZE]u8 = undefined;
var encrypt_buf: [MAX_VAULT_SIZE + HEADER_LEN]u8 = undefined;

fn loadVault(passphrase: []const u8, path: []const u8) Vault {
    const data = readFile(path) orelse return Vault{};

    const pt_len = decryptVault(data, passphrase, &work_buf) orelse {
        write_stderr("Error: wrong passphrase\n");
        c.exit(1);
    };

    return Vault.deserialize(work_buf[0..pt_len]);
}

fn saveVault(vault: *const Vault, passphrase: []const u8, path: []const u8) void {
    const pt_len = vault.serialize(&work_buf) orelse {
        write_stderr("Error: vault too large to serialize\n");
        c.exit(1);
    };
    const enc_len = encryptVault(work_buf[0..pt_len], passphrase, &encrypt_buf);

    // Zero plaintext
    @memset(work_buf[0..pt_len], 0);

    if (!writeFile(path, encrypt_buf[0..enc_len])) {
        write_stderr("Error: failed to write vault\n");
        c.exit(1);
    }
}

fn cmdSet(args: []const [*:0]const u8) void {
    if (args.len < 1) {
        write_stderr("Usage: secrets set KEY [VALUE]\n");
        c.exit(1);
    }
    const key = cstr(args[0]);

    // Validate key
    for (key) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') {
            print_stderr("Invalid key: use A-Z, 0-9, _\n", .{});
            c.exit(1);
        }
    }

    var value_buf: [MAX_VALUE_LEN]u8 = undefined;
    var value: []const u8 = undefined;
    if (args.len >= 2) {
        value = cstr(args[1]);
    } else if (c.isatty(0) == 0) {
        // Piped stdin
        value = read_line_stdin(&value_buf) orelse {
            write_stderr("Error: empty value\n");
            c.exit(1);
        };
    } else {
        print_stderr("Enter value for {s}: ", .{key});
        // Disable echo for value entry
        var old: c.struct_termios = undefined;
        const have_tty = c.tcgetattr(0, &old) == 0;
        if (have_tty) {
            var new = old;
            new.c_lflag &= ~@as(c_uint, c.ECHO);
            _ = c.tcsetattr(0, 0, &new);
        }
        value = read_line_stdin(&value_buf) orelse {
            write_stderr("\nError: empty value\n");
            c.exit(1);
        };
        if (have_tty) {
            _ = c.tcsetattr(0, 0, &old);
            write_stderr("\n");
        }
    }

    const path = getVaultPath();
    const passphrase = getPassphrase();

    var vault = loadVault(passphrase, path);
    defer vault.deinit();

    if (!vault.set(key, value)) c.exit(1);
    saveVault(&vault, passphrase, path);

    print_stderr("Stored: {s}\n", .{key});
}

fn cmdGet(args: []const [*:0]const u8) void {
    if (args.len < 1) {
        write_stderr("Usage: secrets get KEY\n");
        c.exit(1);
    }
    const key = cstr(args[0]);
    const path = getVaultPath();
    const passphrase = getPassphrase();

    var vault = loadVault(passphrase, path);
    defer vault.deinit();

    if (vault.get(key)) |value| {
        write_stdout(value);
    } else {
        print_stderr("Not found: {s}\n", .{key});
        c.exit(1);
    }
}

fn cmdDelete(args: []const [*:0]const u8) void {
    if (args.len < 1) {
        write_stderr("Usage: secrets delete KEY\n");
        c.exit(1);
    }
    const key = cstr(args[0]);
    const path = getVaultPath();
    const passphrase = getPassphrase();

    var vault = loadVault(passphrase, path);
    defer vault.deinit();

    if (vault.delete(key)) {
        saveVault(&vault, passphrase, path);
        print_stderr("Deleted: {s}\n", .{key});
    } else {
        print_stderr("Not found: {s}\n", .{key});
        c.exit(1);
    }
}

fn cmdList() void {
    const path = getVaultPath();
    const passphrase = getPassphrase();

    var vault = loadVault(passphrase, path);
    defer vault.deinit();

    for (vault.entries[0..vault.count]) |entry| {
        write_stdout(entry.key);
        write_stdout("\n");
    }
}

fn cmdEnv(json: bool) void {
    const path = getVaultPath();
    const passphrase = getPassphrase();

    var vault = loadVault(passphrase, path);
    defer vault.deinit();

    if (json) {
        write_stdout("{\n");
        for (vault.entries[0..vault.count], 0..) |entry, i| {
            write_stdout("  \"");
            write_stdout(entry.key);
            write_stdout("\": \"");
            writeJsonEscaped(entry.value);
            write_stdout("\"");
            if (i + 1 < vault.count) write_stdout(",");
            write_stdout("\n");
        }
        write_stdout("}\n");
    } else {
        for (vault.entries[0..vault.count]) |entry| {
            write_stdout("export ");
            write_stdout(entry.key);
            write_stdout("='");
            writeShellEscaped(entry.value);
            write_stdout("'\n");
        }
    }
}

fn cmdImport() void {
    const path = getVaultPath();
    const passphrase = getPassphrase();

    var vault = loadVault(passphrase, path);
    defer vault.deinit();

    var count: usize = 0;
    var line_buf: [MAX_VALUE_LEN + MAX_KEY_LEN]u8 = undefined;

    while (read_line_stdin(&line_buf)) |line| {
        var trimmed = line;
        // Skip empty/comments
        while (trimmed.len > 0 and (trimmed[0] == ' ' or trimmed[0] == '\t')) trimmed = trimmed[1..];
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Strip "export "
        if (trimmed.len > 7 and mem.eql(u8, trimmed[0..7], "export ")) trimmed = trimmed[7..];

        // Find '='
        var eq: usize = 0;
        while (eq < trimmed.len and trimmed[eq] != '=') eq += 1;
        if (eq >= trimmed.len or eq == 0) continue;

        const key = mem.trim(u8, trimmed[0..eq], &[_]u8{ ' ', '\t' });
        var value = trimmed[eq + 1 ..];

        // Strip quotes
        if (value.len >= 2) {
            if ((value[0] == '"' and value[value.len - 1] == '"') or
                (value[0] == '\'' and value[value.len - 1] == '\''))
            {
                value = value[1 .. value.len - 1];
            }
        }

        // Validate key
        var valid = key.len > 0;
        for (key) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '_') valid = false;
        }
        if (valid and value.len > 0) {
            if (vault.set(key, value)) count += 1;
        }
    }

    saveVault(&vault, passphrase, path);
    print_stderr("Imported {d} secrets\n", .{count});
}

fn cmdExport() void {
    const path = getVaultPath();
    const passphrase = getPassphrase();

    var vault = loadVault(passphrase, path);
    defer vault.deinit();

    for (vault.entries[0..vault.count]) |entry| {
        write_stdout(entry.key);
        write_stdout("=");
        write_stdout(entry.value);
        write_stdout("\n");
    }
}

fn writeJsonEscaped(s: []const u8) void {
    for (s) |ch| {
        switch (ch) {
            '"' => write_stdout("\\\""),
            '\\' => write_stdout("\\\\"),
            '\n' => write_stdout("\\n"),
            '\t' => write_stdout("\\t"),
            '\r' => write_stdout("\\r"),
            else => {
                const b = [1]u8{ch};
                write_stdout(&b);
            },
        }
    }
}

fn writeShellEscaped(s: []const u8) void {
    for (s) |ch| {
        if (ch == '\'') {
            write_stdout("'\\''");
        } else {
            const b = [1]u8{ch};
            write_stdout(&b);
        }
    }
}

fn cstr(s: [*:0]const u8) []const u8 {
    return mem.sliceTo(s, 0);
}

fn printHelp() void {
    write_stdout(
        \\secrets v1.0.0 — Encrypted secret manager
        \\
        \\Commands:
        \\  set KEY [VALUE]   Store a secret (prompts if no value)
        \\  get KEY           Retrieve a secret
        \\  list              List all stored key names
        \\  delete KEY        Remove a secret
        \\  env               Output as shell exports (for eval)
        \\  env --json        Output as JSON
        \\  import            Import KEY=VALUE lines from stdin
        \\  export            Export all as KEY=VALUE
        \\  version           Show version
        \\
        \\Setup — add to .zshrc / .bashrc:
        \\  eval $(secrets env 2>/dev/null)
        \\
        \\Crypto: AES-256-GCM + Argon2id (t=3, 64 MiB, p=1); reads legacy PBKDF2 vaults
        \\Vault:  ~/.config/secrets/vault.qvlt
        \\Env:    SECRETS_PASSPHRASE, SECRETS_DIR
        \\
    );
}

// ── Main ──

pub fn main(init: std.process.Init) !void {
    // Cross-platform arg parsing via Zig 0.16 std.process.Init
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    var args_buf: [128][*:0]const u8 = undefined;
    var argc: usize = 0;
    while (args_iter.next()) |arg| {
        if (argc >= 128) break;
        args_buf[argc] = arg;
        argc += 1;
    }
    const args: [][*:0]const u8 = args_buf[0..argc];

    if (args.len < 2) {
        printHelp();
        return;
    }

    const cmd = cstr(args[1]);
    const rest = blk: {
        var ptrs: [64][*:0]const u8 = undefined;
        const n = if (args.len > 2) args.len - 2 else 0;
        for (0..n) |i| ptrs[i] = args[i + 2];
        break :blk ptrs[0..n];
    };

    if (mem.eql(u8, cmd, "set") or mem.eql(u8, cmd, "put")) {
        cmdSet(rest);
    } else if (mem.eql(u8, cmd, "get") or mem.eql(u8, cmd, "read")) {
        cmdGet(rest);
    } else if (mem.eql(u8, cmd, "delete") or mem.eql(u8, cmd, "rm")) {
        cmdDelete(rest);
    } else if (mem.eql(u8, cmd, "list") or mem.eql(u8, cmd, "ls")) {
        cmdList();
    } else if (mem.eql(u8, cmd, "env")) {
        const json = rest.len > 0 and mem.eql(u8, cstr(rest[0]), "--json");
        cmdEnv(json);
    } else if (mem.eql(u8, cmd, "import")) {
        cmdImport();
    } else if (mem.eql(u8, cmd, "export")) {
        cmdExport();
    } else if (mem.eql(u8, cmd, "version") or mem.eql(u8, cmd, "--version")) {
        write_stdout("secrets v1.0.0\n");
    } else if (mem.eql(u8, cmd, "help") or mem.eql(u8, cmd, "--help")) {
        printHelp();
    } else {
        print_stderr("Unknown command: {s}\nRun 'secrets help'\n", .{cmd});
        c.exit(1);
    }
}

// ── Tests ──
//
// Exercise the pure vault primitives (serialize/deserialize, set bounds,
// encrypt/decrypt) that the CLI I/O layer sits on top of. Findings 1-3 of the
// 2026-07 audit (KDF mislabel, unchecked RNG, unbounded write path) had zero
// coverage before these; the KDF is additionally pinned to an external vector.

const testing = std.testing;

test "serialize/deserialize roundtrip" {
    var v = Vault{};
    defer v.deinit();
    try testing.expect(v.set("API_KEY", "sk-secret-123"));
    try testing.expect(v.set("DB_URL", "postgres://user:pw@host/db"));
    try testing.expect(v.set("EMPTY", "")); // zero-length value is legal

    var buf: [4096]u8 = undefined;
    const n = v.serialize(&buf).?;

    var v2 = Vault.deserialize(buf[0..n]);
    defer v2.deinit();
    try testing.expectEqual(@as(usize, 3), v2.count);
    try testing.expectEqualStrings("sk-secret-123", v2.get("API_KEY").?);
    try testing.expectEqualStrings("postgres://user:pw@host/db", v2.get("DB_URL").?);
    try testing.expectEqualStrings("", v2.get("EMPTY").?);
    try testing.expect(v2.get("MISSING") == null);
}

test "set enforces key/value bounds" {
    var v = Vault{};
    defer v.deinit();

    try testing.expect(!v.set("", "x")); // empty key rejected

    var big_key: [MAX_KEY_LEN + 1]u8 = undefined;
    @memset(&big_key, 'k');
    try testing.expect(!v.set(&big_key, "x")); // oversize key rejected

    const big_val = try testing.allocator.alloc(u8, MAX_VALUE_LEN + 1);
    defer testing.allocator.free(big_val);
    @memset(big_val, 'v');
    try testing.expect(!v.set("K", big_val)); // oversize value rejected

    try testing.expectEqual(@as(usize, 0), v.count); // nothing stored

    // A max-length value at exactly the limit is accepted.
    try testing.expect(v.set("K", big_val[0..MAX_VALUE_LEN]));
    try testing.expectEqual(@as(usize, 1), v.count);
}

test "set update frees old value (no leak) and overwrites" {
    var v = Vault{};
    defer v.deinit();
    try testing.expect(v.set("K", "first"));
    try testing.expect(v.set("K", "second-longer"));
    try testing.expectEqual(@as(usize, 1), v.count);
    try testing.expectEqualStrings("second-longer", v.get("K").?);
}

test "serialize refuses to overflow the buffer" {
    var v = Vault{};
    defer v.deinit();
    try testing.expect(v.set("KEY", "0123456789ABCDEF"));
    var tiny: [8]u8 = undefined; // too small for even one entry + terminator
    try testing.expect(v.serialize(&tiny) == null);
}

test "encryptVault/decryptVault v2 roundtrip + wrong passphrase" {
    var v = Vault{};
    defer v.deinit();
    try testing.expect(v.set("TOKEN", "hunter2"));

    var pt: [1024]u8 = undefined;
    const pt_len = v.serialize(&pt).?;

    var enc: [1024 + HEADER_LEN]u8 = undefined;
    const enc_len = encryptVault(pt[0..pt_len], "correct horse battery staple", &enc);
    try testing.expectEqual(VERSION_ARGON2, enc[4]); // new writes are v2

    var out: [1024]u8 = undefined;
    try testing.expect(decryptVault(enc[0..enc_len], "wrong passphrase", &out) == null);

    const dec_len = decryptVault(enc[0..enc_len], "correct horse battery staple", &out).?;
    var v2 = Vault.deserialize(out[0..dec_len]);
    defer v2.deinit();
    try testing.expectEqualStrings("hunter2", v2.get("TOKEN").?);
}

test "decryptVault reads a legacy v1 (PBKDF2) vault" {
    var v = Vault{};
    defer v.deinit();
    try testing.expect(v.set("LEGACY", "v1value"));

    var pt: [1024]u8 = undefined;
    const pt_len = v.serialize(&pt).?;

    // Hand-build a v1 blob the way the pre-Argon2id tool wrote it.
    var salt: [SALT_LEN]u8 = undefined;
    @memset(&salt, 0xAB);
    var nonce: [NONCE_LEN]u8 = undefined;
    @memset(&nonce, 0xCD);
    var key = deriveKeyPbkdf2("legacy-pass", &salt);
    defer @memset(&key, 0);

    var blob: [1024]u8 = undefined;
    @memcpy(blob[0..4], &MAGIC);
    blob[4] = VERSION_PBKDF2;
    @memcpy(blob[5 .. 5 + SALT_LEN], &salt);
    @memcpy(blob[5 + SALT_LEN .. 5 + SALT_LEN + NONCE_LEN], &nonce);
    var tag: [TAG_LEN]u8 = undefined;
    const ct = blob[HEADER_LEN .. HEADER_LEN + pt_len];
    Aes256Gcm.encrypt(ct, &tag, pt[0..pt_len], "", nonce, key);
    @memcpy(blob[5 + SALT_LEN + NONCE_LEN .. HEADER_LEN], &tag);
    const blob_len = HEADER_LEN + pt_len;

    var out: [1024]u8 = undefined;
    const dec_len = decryptVault(blob[0..blob_len], "legacy-pass", &out).?;
    var v2 = Vault.deserialize(out[0..dec_len]);
    defer v2.deinit();
    try testing.expectEqualStrings("v1value", v2.get("LEGACY").?);
}

test "decryptVault rejects bad magic / unknown version / truncation" {
    var out: [64]u8 = undefined;
    // Too short for a header.
    try testing.expect(decryptVault("QVLT", "p", &out) == null);
    // Valid length, wrong magic.
    var bad = [_]u8{0} ** HEADER_LEN;
    try testing.expect(decryptVault(&bad, "p", &out) == null);
    // Right magic, unknown version byte.
    @memcpy(bad[0..4], &MAGIC);
    bad[4] = 0x7F;
    try testing.expect(decryptVault(&bad, "p", &out) == null);
}

// External anchor: RFC 9106 §5.3 Argon2id test vector. Pins the KDF this vault
// depends on to an output produced by neither this repo nor its author.
test "argon2id RFC 9106 known-answer (external anchor)" {
    const password = [_]u8{0x01} ** 32;
    const salt = [_]u8{0x02} ** 16;
    const secret = [_]u8{0x03} ** 8;
    const ad = [_]u8{0x04} ** 12;

    var dk: [32]u8 = undefined;
    try argon2.kdf(
        testing.allocator,
        &dk,
        &password,
        &salt,
        .{ .t = 3, .m = 32, .p = 4, .secret = &secret, .ad = &ad },
        .argon2id,
        testing.io,
    );

    const want = [_]u8{
        0x0d, 0x64, 0x0d, 0xf5, 0x8d, 0x78, 0x76, 0x6c,
        0x08, 0xc0, 0x37, 0xa3, 0x4a, 0x8b, 0x53, 0xc9,
        0xd0, 0x1e, 0xf0, 0x45, 0x2d, 0x75, 0xb6, 0x5e,
        0xb5, 0x25, 0x20, 0xe9, 0x6b, 0x01, 0xe6, 0x59,
    };
    try testing.expectEqualSlices(u8, &want, &dk);
}
