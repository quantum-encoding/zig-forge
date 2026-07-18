//! CMOS Real-Time Clock reader.
//!
//! Reads wall-clock time from the CMOS/RTC (I/O ports 0x70/0x71) once at boot
//! and converts it to a Unix epoch (seconds since 1970-01-01T00:00:00Z). The
//! `clock_gettime(CLOCK_REALTIME)` handler then reports `boot_epoch + uptime`,
//! giving userspace real calendar time.
//!
//! Without this, CLOCK_REALTIME was derived from the boot-relative tick counter
//! (0 at boot), so it read ~1970 — which makes TLS certificate validity checks
//! reject every otherwise-valid certificate. CLOCK_MONOTONIC keeps using the
//! tick counter and is unaffected.

const io = @import("io.zig");
const idt = @import("idt.zig");

const CMOS_ADDR: u16 = 0x70;
const CMOS_DATA: u16 = 0x71;

// RTC register indices.
const REG_SECONDS: u8 = 0x00;
const REG_MINUTES: u8 = 0x02;
const REG_HOURS: u8 = 0x04;
const REG_DAY: u8 = 0x07;
const REG_MONTH: u8 = 0x08;
const REG_YEAR: u8 = 0x09;
const REG_STATUS_A: u8 = 0x0A;
const REG_STATUS_B: u8 = 0x0B;

/// Unix epoch seconds captured at boot, and the tick count at that instant.
var boot_epoch_seconds: u64 = 0;
var boot_tick: u64 = 0;
var initialized: bool = false;

fn readReg(reg: u8) u8 {
    io.outb(CMOS_ADDR, reg);
    return io.inb(CMOS_DATA);
}

/// True while the RTC is mid-update (Status Register A bit 7). Reading time
/// registers during an update can return an inconsistent value.
fn updateInProgress() bool {
    return (readReg(REG_STATUS_A) & 0x80) != 0;
}

fn bcdToBin(v: u8) u8 {
    return (v & 0x0F) + ((v >> 4) *% 10);
}

const RawTime = struct {
    second: u8,
    minute: u8,
    hour: u8,
    day: u8,
    month: u8,
    year: u8,
};

fn readRawOnce() RawTime {
    return .{
        .second = readReg(REG_SECONDS),
        .minute = readReg(REG_MINUTES),
        .hour = readReg(REG_HOURS),
        .day = readReg(REG_DAY),
        .month = readReg(REG_MONTH),
        .year = readReg(REG_YEAR),
    };
}

fn eql(a: RawTime, b: RawTime) bool {
    return a.second == b.second and a.minute == b.minute and a.hour == b.hour and
        a.day == b.day and a.month == b.month and a.year == b.year;
}

/// Read raw registers until two consecutive update-free reads agree, so we
/// never latch a time that ticked over mid-read.
fn readStable() RawTime {
    while (updateInProgress()) {}
    var prev = readRawOnce();
    while (true) {
        while (updateInProgress()) {}
        const cur = readRawOnce();
        if (eql(cur, prev)) return cur;
        prev = cur;
    }
}

/// Days since 1970-01-01 for a proleptic-Gregorian date (Howard Hinnant's
/// algorithm). Valid for the years the RTC can represent here.
fn daysFromCivil(year: u16, month: u8, day: u8) i64 {
    var y: i64 = year;
    if (month <= 2) y -= 1;
    const era: i64 = @divTrunc(if (y >= 0) y else y - 399, 400);
    const yoe: i64 = y - era * 400; // [0, 399]
    const mp: i64 = @mod(@as(i64, month) + 9, 12); // Mar=0..Feb=11
    const doy: i64 = @divTrunc(153 * mp + 2, 5) + @as(i64, day) - 1; // [0, 365]
    const doe: i64 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// Read the RTC once and latch the boot wall-clock epoch. Idempotent.
pub fn init() void {
    const status_b = readReg(REG_STATUS_B);
    const is_binary = (status_b & 0x04) != 0;
    const is_24h = (status_b & 0x02) != 0;

    const raw = readStable();

    const conv = struct {
        fn f(v: u8, binary: bool) u8 {
            return if (binary) v else bcdToBin(v);
        }
    }.f;

    const sec = conv(raw.second, is_binary);
    const min = conv(raw.minute, is_binary);
    const day = conv(raw.day, is_binary);
    const month = conv(raw.month, is_binary);
    const yy = conv(raw.year, is_binary);

    // Hours need the 12/24h and PM handling before/around the BCD conversion.
    var hour_raw = raw.hour;
    const pm = (hour_raw & 0x80) != 0; // meaningful only in 12h mode
    hour_raw &= 0x7F;
    var hour = conv(hour_raw, is_binary);
    if (!is_24h) {
        hour %= 12; // 12 AM/PM -> 0
        if (pm) hour += 12; // 1..11 PM -> 13..23; 12 PM -> 12
    }

    // The RTC year register is 0..99. No reliable century register without the
    // ACPI FADT century offset, so assume the 2000..2099 window.
    const full_year: u16 = 2000 + @as(u16, yy);

    const days = daysFromCivil(full_year, month, day);
    const secs: i64 = days * 86400 + @as(i64, hour) * 3600 + @as(i64, min) * 60 + @as(i64, sec);
    boot_epoch_seconds = if (secs < 0) 0 else @intCast(secs);
    boot_tick = idt.getTickCount();
    initialized = true;
}

pub const Realtime = struct { sec: u64, nsec: u64 };

/// Current wall-clock time as (seconds, nanoseconds) since the Unix epoch.
/// Falls back to the boot-relative tick clock if `init` never ran.
pub fn realtimeNow() Realtime {
    if (!initialized) {
        const ticks = idt.getTickCount();
        return .{ .sec = ticks / 100, .nsec = (ticks % 100) * 10_000_000 };
    }
    const elapsed = idt.getTickCount() -% boot_tick; // ticks are monotonic
    return .{
        .sec = boot_epoch_seconds + elapsed / 100,
        .nsec = (elapsed % 100) * 10_000_000,
    };
}
