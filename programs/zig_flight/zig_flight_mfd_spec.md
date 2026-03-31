# Plan: zig_flight_mfd — X-Plane 12 Avionics Toolkit in Zig

## Context

Inspired by LaurieWired's video "Why Fighter Jets Ban 90% of C++ Features" and her [XplaneFlightData](https://github.com/LaurieWired/XplaneFlightData) project. She demonstrated the JSF AV C++ coding standard using X-Plane 12's Web API to drive a custom MFD (Multi-Function Display) with flight calculators.

**The thesis**: The JSF AV C++ standard bans exceptions, dynamic allocation, recursion, and implicit conversions — restrictions that Zig enforces by default at the language level. This project demonstrates that Zig is a natural fit for safety-critical avionics code by building a full avionics toolkit that connects to X-Plane 12 and runs flight calculators with zero runtime exceptions possible.

**Strategic value**: Demonstrates the full Quantum Encoding stack — from bare-metal Zigix OS on the Orange Pi to application-level avionics displays. Compelling investor demo: X-Plane running on one screen, Orange Pi running Zigix displaying a live MFD on another.

This is a new program in the quantum-zig-forge monorepo. Named "zig_flight_mfd".

---

## Directory Structure

```
programs/zig_flight_mfd/
  build.zig
  build.zig.zon
  LICENSE
  README.md
  src/
    main.zig                — Entry point: CLI argument parsing, mode selection
    xplane_client.zig       — X-Plane 12 Web API client (REST + WebSocket)
    dataref_registry.zig    — Dataref name→ID resolution and subscription management
    protocol.zig            — JSON message parsing/encoding for X-Plane WebSocket protocol
    flight_data.zig         — Flight data structures (attitude, navigation, engine, etc.)

    # Flight calculators (JSF AV C++ compliant by Zig's nature)
    calc/
      wind.zig              — Wind correction angle, crosswind/headwind components
      turn.zig              — Standard rate turns, bank angle, turn radius
      vnav.zig              — Vertical navigation: TOD, descent rate, gradient
      density_alt.zig       — Density altitude from pressure alt, temp, dewpoint
      fuel.zig              — Fuel burn rate, endurance, range estimation
      performance.zig       — V-speeds, takeoff/landing distances, weight & balance
      nav.zig               — Great circle distance, bearing, ETA calculations
      approach.zig          — ILS/VNAV glide path deviation, MDA/DH calculations

    # MFD display rendering
    display/
      mfd.zig               — MFD compositor: layout engine, page switching
      pfd.zig               — Primary Flight Display (attitude, airspeed, altitude, heading)
      nd.zig                — Navigation Display (bearing, distance, waypoints)
      eicas.zig             — Engine Indicating and Crew Alerting System
      fms.zig               — Flight Management System page (fuel, performance, nav)
      renderer.zig          — Abstract renderer interface (TUI + framebuffer backends)
      tui_backend.zig       — Terminal UI backend using ANSI escape codes
      fb_backend.zig        — Linux framebuffer backend (for Zigix bare-metal)

    # Alerting and safety
    alerts.zig              — TAWS-like terrain alerts, speed/config warnings
    limits.zig              — Aircraft performance envelope definitions
```

---

## Key Data Structures

### X-Plane Client (xplane_client.zig)

```zig
pub const XPlaneClient = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,                          // default 8086
    ws_fd: ?std.posix.socket_t,         // WebSocket connection
    recv_buffer: [65536]u8,
    recv_len: usize,
    next_req_id: u64,
    subscribed_datarefs: std.AutoHashMap(u64, DatarefMeta),

    // REST API
    pub fn getCapabilities(self: *@This()) !ApiCapabilities
    pub fn findDatarefByName(self: *@This(), name: []const u8) !DatarefInfo
    pub fn getDatarefValue(self: *@This(), id: u64) !DatarefValue
    pub fn setDatarefValue(self: *@This(), id: u64, value: DatarefValue) !void
    pub fn activateCommand(self: *@This(), id: u64, duration: f32) !void
    pub fn initFlight(self: *@This(), config: FlightConfig) !void

    // WebSocket API
    pub fn connectWebSocket(self: *@This()) !void
    pub fn subscribeDatarefs(self: *@This(), ids: []const DatarefSubscription) !void
    pub fn unsubscribeDatarefs(self: *@This(), ids: []const u64) !void
    pub fn unsubscribeAll(self: *@This()) !void
    pub fn poll(self: *@This()) !?DatarefUpdate  // non-blocking, returns null if no data
    pub fn close(self: *@This()) void
};
```

### Dataref Registry (dataref_registry.zig)

Resolves human-readable dataref names to session-specific numeric IDs at startup.
Pre-populates the MFD-critical datarefs on connect.

```zig
pub const DatarefRegistry = struct {
    client: *XPlaneClient,
    name_to_id: std.StringHashMap(u64),
    id_to_name: std.AutoHashMap(u64, []const u8),

    pub fn init(allocator: std.mem.Allocator, client: *XPlaneClient) DatarefRegistry
    pub fn resolve(self: *@This(), name: []const u8) !u64
    pub fn resolveBatch(self: *@This(), names: []const []const u8) ![]u64
    pub fn subscribeAll(self: *@This()) !void
};

// Pre-defined dataref sets for MFD pages
pub const PFD_DATAREFS = [_][]const u8{
    "sim/cockpit2/gauges/indicators/airspeed_kts_pilot",
    "sim/cockpit2/gauges/indicators/altitude_ft_pilot",
    "sim/cockpit2/gauges/indicators/vvi_fpm_pilot",
    "sim/cockpit2/gauges/indicators/heading_AHARS_deg_mag_pilot",
    "sim/cockpit2/gauges/indicators/pitch_AHARS_deg_pilot",
    "sim/cockpit2/gauges/indicators/roll_AHARS_deg_pilot",
    "sim/cockpit2/gauges/indicators/slip_deg",
    "sim/cockpit/misc/barometer_setting",
    "sim/cockpit2/gauges/indicators/radio_altimeter_height_ft_pilot",
    "sim/cockpit2/gauges/indicators/airspeed_acceleration",
};

pub const ENGINE_DATAREFS = [_][]const u8{
    "sim/cockpit2/engine/indicators/N1_percent",
    "sim/cockpit2/engine/indicators/N2_percent",
    "sim/cockpit2/engine/indicators/ITT_deg_C",
    "sim/cockpit2/engine/indicators/oil_pressure_psi",
    "sim/cockpit2/engine/indicators/oil_temperature_deg_C",
    "sim/cockpit2/engine/indicators/fuel_flow_kg_sec",
    "sim/cockpit2/engine/indicators/EPR_ratio",
    "sim/cockpit2/engine/indicators/engine_speed_rpm",
};

pub const NAV_DATAREFS = [_][]const u8{
    "sim/cockpit2/radios/indicators/nav1_dme_distance_nm",
    "sim/cockpit2/radios/indicators/nav1_hdef_dots_pilot",
    "sim/cockpit2/radios/indicators/nav1_vdef_dots_pilot",
    "sim/cockpit2/radios/indicators/gps_dme_distance_nm",
    "sim/cockpit2/radios/indicators/gps_bearing_deg_mag",
    "sim/flightmodel/position/latitude",
    "sim/flightmodel/position/longitude",
    "sim/flightmodel/position/groundspeed",
    "sim/cockpit2/gauges/indicators/ground_track_mag_pilot",
    "sim/weather/wind_direction_degt",
    "sim/weather/wind_speed_kt",
};

pub const FUEL_DATAREFS = [_][]const u8{
    "sim/cockpit2/fuel/fuel_quantity",
    "sim/cockpit2/fuel/fuel_totalizer_sum_kg",
    "sim/aircraft/weight/acf_m_fuel_tot",
    "sim/flightmodel/weight/m_fuel_total",
};

pub const AUTOPILOT_DATAREFS = [_][]const u8{
    "sim/cockpit2/autopilot/altitude_dial_ft",
    "sim/cockpit2/autopilot/heading_dial_deg_mag_pilot",
    "sim/cockpit2/autopilot/airspeed_dial_kts_mach",
    "sim/cockpit2/autopilot/vvi_dial_fpm",
    "sim/cockpit2/autopilot/autopilot_state",
    "sim/cockpit2/autopilot/autothrottle_enabled",
};
```

### Flight Data (flight_data.zig)

All data uses fixed-point or bounded floating-point — no unbounded allocations.

```zig
pub const FlightData = struct {
    // Attitude
    pitch_deg: f32 = 0,
    roll_deg: f32 = 0,
    heading_mag_deg: f32 = 0,
    slip_deg: f32 = 0,

    // Air data
    airspeed_kts: f32 = 0,
    altitude_ft: f32 = 0,
    vsi_fpm: f32 = 0,
    radio_alt_ft: f32 = 0,
    barometer_inhg: f32 = 29.92,
    mach: f32 = 0,
    airspeed_trend: f32 = 0,    // acceleration

    // Navigation
    latitude: f64 = 0,
    longitude: f64 = 0,
    groundspeed_kts: f32 = 0,
    ground_track_deg: f32 = 0,
    wind_dir_deg: f32 = 0,
    wind_speed_kts: f32 = 0,
    nav1_dme_nm: f32 = 0,
    nav1_hdef_dots: f32 = 0,
    nav1_vdef_dots: f32 = 0,
    gps_dme_nm: f32 = 0,
    gps_bearing_deg: f32 = 0,

    // Engine (up to 4 engines)
    n1_percent: [4]f32 = .{ 0, 0, 0, 0 },
    n2_percent: [4]f32 = .{ 0, 0, 0, 0 },
    itt_deg_c: [4]f32 = .{ 0, 0, 0, 0 },
    oil_psi: [4]f32 = .{ 0, 0, 0, 0 },
    oil_temp_c: [4]f32 = .{ 0, 0, 0, 0 },
    fuel_flow_kgs: [4]f32 = .{ 0, 0, 0, 0 },
    num_engines: u8 = 1,

    // Fuel
    fuel_total_kg: f32 = 0,
    fuel_capacity_kg: f32 = 0,

    // Autopilot state
    ap_alt_ft: f32 = 0,
    ap_hdg_deg: f32 = 0,
    ap_speed_kts: f32 = 0,
    ap_vsi_fpm: f32 = 0,
    ap_state: u32 = 0,         // bitfield
    autothrottle_on: bool = false,

    // Derived (computed by calculators each frame)
    density_alt_ft: f32 = 0,
    wind_correction_deg: f32 = 0,
    crosswind_kts: f32 = 0,
    headwind_kts: f32 = 0,
    fuel_endurance_hrs: f32 = 0,
    fuel_range_nm: f32 = 0,

    // Timestamp
    update_tick: u64 = 0,

    /// Update from a dataref update message
    pub fn applyUpdate(self: *@This(), id: u64, value: DatarefValue, registry: *DatarefRegistry) void
};
```

---

## Flight Calculators (calc/)

All calculators are pure functions — no allocations, no side effects, no exceptions.
They take FlightData and return computed values. This is the JSF AV C++ compliance story:
Zig enforces all of it at the language level.

### wind.zig

```zig
/// Compute headwind and crosswind components
/// runway_heading: magnetic heading of the runway in degrees
/// wind_dir: wind direction (from) in degrees
/// wind_speed: wind speed in knots
/// Returns: .{ .headwind_kts, .crosswind_kts, .correction_deg }
pub fn windComponents(runway_heading: f32, wind_dir: f32, wind_speed: f32) WindResult

/// Compute wind correction angle for a desired track
/// track: desired ground track in degrees
/// tas: true airspeed in knots
/// wind_dir: wind direction in degrees
/// wind_speed: wind speed in knots
pub fn windCorrectionAngle(track: f32, tas: f32, wind_dir: f32, wind_speed: f32) f32
```

### turn.zig

```zig
/// Standard rate turn parameters
/// speed_kts: true airspeed
/// bank_deg: bank angle (if 0, computes standard rate bank)
pub fn turnRate(speed_kts: f32, bank_deg: f32) TurnResult

/// Time to turn from current heading to target heading
pub fn timeToTurn(current_hdg: f32, target_hdg: f32, rate_deg_per_sec: f32) f32

/// Turn radius in nautical miles
pub fn turnRadius(speed_kts: f32, bank_deg: f32) f32
```

### vnav.zig

```zig
/// Top of descent calculation
/// current_alt_ft: current altitude
/// target_alt_ft: target altitude
/// distance_nm: distance to target
/// groundspeed_kts: current groundspeed
pub fn topOfDescent(current_alt_ft: f32, target_alt_ft: f32, descent_angle_deg: f32) f32

/// Required descent rate for 3-degree glide path
pub fn requiredDescentRate(groundspeed_kts: f32, glide_angle_deg: f32) f32

/// Vertical deviation from desired path
pub fn verticalDeviation(current_alt: f32, target_alt: f32, distance_nm: f32, angle_deg: f32) f32
```

### density_alt.zig

```zig
/// Density altitude calculation
/// pressure_alt_ft: pressure altitude
/// oat_c: outside air temperature in Celsius
pub fn densityAltitude(pressure_alt_ft: f32, oat_c: f32) f32

/// ISA temperature deviation
pub fn isaDeviation(pressure_alt_ft: f32, oat_c: f32) f32

/// Pressure altitude from field elevation and altimeter setting
pub fn pressureAltitude(field_elev_ft: f32, altimeter_inhg: f32) f32
```

### fuel.zig

```zig
/// Fuel endurance at current burn rate
pub fn endurance(fuel_remaining_kg: f32, fuel_flow_total_kgs: f32) f32

/// Range at current groundspeed and fuel flow
pub fn range(fuel_remaining_kg: f32, fuel_flow_total_kgs: f32, groundspeed_kts: f32) f32

/// Specific range (nm per kg)
pub fn specificRange(groundspeed_kts: f32, fuel_flow_total_kgs: f32) f32
```

### nav.zig

```zig
/// Great circle distance between two coordinates (Haversine)
pub fn greatCircleDistance(lat1: f64, lon1: f64, lat2: f64, lon2: f64) f64

/// Initial bearing from point 1 to point 2
pub fn initialBearing(lat1: f64, lon1: f64, lat2: f64, lon2: f64) f64

/// ETA given distance and groundspeed
pub fn eta(distance_nm: f64, groundspeed_kts: f32) f32
```

---

## Display System (display/)

### Renderer Interface (renderer.zig)

Abstract rendering interface allowing both TUI (terminal) and framebuffer (bare-metal) backends.

```zig
pub const Color = struct { r: u8, g: u8, b: u8 };

pub const Renderer = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        clear: *const fn (self: *anyopaque) void,
        drawText: *const fn (self: *anyopaque, x: u16, y: u16, text: []const u8, color: Color) void,
        drawLine: *const fn (self: *anyopaque, x1: u16, y1: u16, x2: u16, y2: u16, color: Color) void,
        drawRect: *const fn (self: *anyopaque, x: u16, y: u16, w: u16, h: u16, color: Color, filled: bool) void,
        drawArc: *const fn (self: *anyopaque, cx: u16, cy: u16, r: u16, start_deg: f32, end_deg: f32, color: Color) void,
        present: *const fn (self: *anyopaque) void,
        width: *const fn (self: *anyopaque) u16,
        height: *const fn (self: *anyopaque) u16,
    };

    pub fn clear(self: @This()) void { self.vtable.clear(self.ptr); }
    // ... delegate methods
};
```

### TUI Backend (tui_backend.zig)

Terminal rendering using ANSI escape sequences. Works over SSH for remote development.
Uses the existing TUI patterns from the monorepo where applicable.

- 256-color or truecolor depending on terminal capability
- Double-buffered: compose full frame then flush
- Box-drawing characters for instrument bezels
- Block characters (▀▄█) for pseudo-pixel rendering of attitude indicator

### Framebuffer Backend (fb_backend.zig)

Direct Linux framebuffer rendering for Zigix bare-metal deployment.

- Opens `/dev/fb0`, mmaps framebuffer
- Direct pixel writes — no GPU dependency
- Suitable for Orange Pi HDMI output under Zigix
- Same Renderer interface, swappable at compile time

### Primary Flight Display (pfd.zig)

The main instrument panel rendering:

```
┌─────────────────────────────────────────────────────┐
│  ASI          ATTITUDE INDICATOR          ALTIMETER  │
│ ┌───┐    ┌───────────────────────┐      ┌───┐      │
│ │280│    │         ___           │      │FL350│     │
│ │270│    │   ──── /   \ ────     │      │34900│     │
│ │260│◄── │  ───── | W | ─────   │  ──► │34800│     │
│ │250│    │   ──── \___/ ────     │      │34700│     │
│ │240│    │                       │      │34600│     │
│ └───┘    └───────────────────────┘      └───┘      │
│                                                      │
│  ┌─────────────────────────────────────────────┐    │
│  │         HEADING / HSI        N               │    │
│  │      330    360/000   030                     │    │
│  │        ──── ─▼─ ────                          │    │
│  └─────────────────────────────────────────────┘    │
│                                                      │
│  VSI: -500 fpm    GS: 450 kts    WIND: 270/25       │
│  RA: 35000 ft     TAS: 480 kts   HDG: 275°M         │
└─────────────────────────────────────────────────────┘
```

### EICAS Display (eicas.zig)

Engine instruments and crew alerts:

```
┌──────────────────────────────────────┐
│  ENGINE 1          ENGINE 2          │
│  N1: 92.3%         N1: 91.8%        │
│  ████████████░     ████████████░     │
│  N2: 88.1%         N2: 87.9%        │
│  ITT: 625°C        ITT: 622°C       │
│  OIL P: 45 psi     OIL P: 44 psi    │
│  OIL T: 85°C       OIL T: 84°C      │
│  FF: 0.82 kg/s     FF: 0.81 kg/s    │
│                                      │
│  FUEL: 12,450 kg   ENDUR: 3.2h      │
│  RANGE: 1,440 nm   GW: 65,200 kg    │
│                                      │
│  ──── ALERTS ────                    │
│  (none)                              │
└──────────────────────────────────────┘
```

### MFD Compositor (mfd.zig)

Page-switching MFD with keyboard controls:

```zig
pub const MfdPage = enum {
    pfd,        // Primary Flight Display
    nd,         // Navigation Display
    eicas,      // Engine/Crew Alerting
    fms,        // Flight Management (fuel, performance, nav calcs)
    status,     // System status and connection info
};

pub const Mfd = struct {
    current_page: MfdPage,
    flight_data: *FlightData,
    renderer: Renderer,
    registry: *DatarefRegistry,

    pub fn init(renderer: Renderer, flight_data: *FlightData, registry: *DatarefRegistry) Mfd
    pub fn render(self: *@This()) void
    pub fn handleInput(self: *@This(), key: u8) void    // page switching: 1-5, q=quit
    pub fn switchPage(self: *@This(), page: MfdPage) void
};
```

---

## X-Plane 12 Web API Integration

### REST API (used at startup)

Base URL: `http://localhost:8086/api/v3`

1. **GET `/api/capabilities`** — Verify X-Plane is running and get API version
2. **GET `/datarefs?filter[name]=sim/cockpit2/...`** — Resolve dataref names to session IDs
3. **GET `/datarefs/{id}/value`** — One-off reads during initialization
4. **PATCH `/datarefs/{id}/value`** — Write values (e.g., set autopilot targets)
5. **POST `/command/{id}/activate`** — Fire commands (e.g., toggle autopilot modes)
6. **POST `/flight`** — Initialize a flight scenario for demos

### WebSocket API (used at runtime, 10Hz updates)

Connect: `ws://localhost:8086/api/v3`

Message flow:
```
Client → Server:  dataref_subscribe_values { datarefs: [{ id: 123 }, { id: 456 }] }
Server → Client:  result { success: true }
Server → Client:  dataref_update_values { data: { "123": 250.5, "456": 35000 } }  // 10Hz
Server → Client:  dataref_update_values { data: { "123": 251.2 } }  // only changed values
```

**Key design point**: The WebSocket only sends changed values after the initial snapshot. The client must maintain full state and merge updates incrementally.

### Connection Lifecycle

```
1. HTTP GET /api/capabilities → verify X-Plane running, check API version ≥ v3
2. HTTP GET /datarefs?filter[name]=<each needed dataref> → build name→ID map
3. WebSocket connect to ws://localhost:8086/api/v3
4. Send dataref_subscribe_values for all MFD datarefs
5. Receive initial dataref_update_values with all current values
6. Enter main loop: poll WebSocket, merge updates, run calculators, render MFD
7. On disconnect: attempt reconnect with exponential backoff
```

---

## Implementation Phases

### Phase 1: X-Plane Client + Flight Data

**Files**: `xplane_client.zig`, `protocol.zig`, `dataref_registry.zig`, `flight_data.zig`, `main.zig`, `build.zig`

1. **protocol.zig**: JSON parser for X-Plane WebSocket messages. Parse `dataref_update_values`, encode `dataref_subscribe_values`. Use `std.json` for REST responses. Zero-allocation parsing where possible — extract numeric values directly from the JSON buffer.

2. **xplane_client.zig**: HTTP client for REST API (use `std.http.Client` for REST calls). WebSocket client for streaming data. Handle the HTTP→WebSocket upgrade handshake. Non-blocking poll for updates.

3. **dataref_registry.zig**: On connect, resolve all needed dataref names to IDs via REST API batch queries. Cache the mapping for the session. Subscribe all resolved datarefs via WebSocket.

4. **flight_data.zig**: FlightData struct with `applyUpdate()` that maps dataref IDs to struct fields.

5. **main.zig**: CLI entry point. Connect to X-Plane, subscribe to PFD datarefs, print raw values to stdout as proof of life.

6. **build.zig**: Standard monorepo pattern. Executables: `zig-flight-mfd` (main), `zig-flight-dump` (raw dataref dumper for debugging).

**Verification**:
```bash
# Start X-Plane 12 with any aircraft
# Terminal:
zig build run-dump -- --host localhost --port 8086
# Should print streaming dataref values at 10Hz
```

### Phase 2: Flight Calculators

**Files**: All files in `calc/`

1. Implement all calculator modules as pure functions.
2. Comprehensive unit tests for each — these are math functions, easily testable.
3. Wire calculators into FlightData update loop: after each WebSocket update batch, recompute derived values.

**Verification**:
```bash
zig build test  # All calculator unit tests pass
```

### Phase 3: TUI Display

**Files**: `display/renderer.zig`, `display/tui_backend.zig`, `display/pfd.zig`, `display/eicas.zig`, `display/nd.zig`, `display/fms.zig`, `display/mfd.zig`

1. **renderer.zig**: Define the abstract Renderer interface.
2. **tui_backend.zig**: ANSI terminal renderer with double-buffering. Raw mode input for keyboard handling. Detect terminal size.
3. **pfd.zig**: Render airspeed tape, altitude tape, attitude indicator (using block characters), heading indicator, VSI.
4. **eicas.zig**: Engine gauges with bar indicators, fuel status, alerts.
5. **nd.zig**: Compass rose, bearing pointer, DME readout.
6. **fms.zig**: Calculator results page — density altitude, fuel endurance, wind components, VNAV.
7. **mfd.zig**: Page compositor with keyboard switching (keys 1-5).

**Verification**:
```bash
zig build run -- --host localhost --port 8086
# Full TUI MFD with live data from X-Plane
# Press 1=PFD, 2=ND, 3=EICAS, 4=FMS, 5=Status, q=quit
```

### Phase 4: Framebuffer Backend + Alerts

**Files**: `display/fb_backend.zig`, `alerts.zig`, `limits.zig`

1. **fb_backend.zig**: Linux framebuffer rendering via `/dev/fb0`. Pixel-level drawing. Font rendering from embedded bitmap font (no freetype dependency). Same Renderer interface as TUI.

2. **alerts.zig**: Basic alerting logic:
   - Overspeed warning (airspeed > Vmo)
   - Bank angle warning (> 30° in normal flight)
   - Excessive descent rate
   - Low fuel warning
   - Radio altitude callouts (2500, 1000, 500, 200, 100, 50, 30, 20, 10)

3. **limits.zig**: Aircraft envelope definitions. Configurable via comptime struct for different aircraft types.

4. Compile-time backend selection:
```zig
const backend = if (@import("builtin").os.tag == .freestanding)
    fb_backend
else
    tui_backend;
```

**Verification**:
```bash
# On Orange Pi running Zigix:
./zig-flight-mfd --host <xplane_host> --port 8086 --backend fb
# MFD renders directly to HDMI via framebuffer
```

### Phase 5: Demo Mode + Polish

**Files**: Update `main.zig`, add `demo.zig`

1. **demo.zig**: Replay mode — record a flight's dataref stream to a file, replay it without X-Plane running. Useful for investor demos without needing X-Plane running.

2. **Flight initialization**: Use the REST `/flight` endpoint to set up a demo scenario (specific airport, aircraft, weather).

3. **README.md**: Full documentation matching monorepo style. Include the JSF AV C++ narrative — table comparing JSF rules to Zig's defaults.

4. **Command integration**: Map keyboard inputs to X-Plane commands (toggle autopilot, change heading/altitude) so the MFD is interactive, not just a display.

---

## Reusable Code from Monorepo

| Component | Source | Usage |
|-----------|--------|-------|
| HTTP client | `http_sentinel` | REST API calls to X-Plane (or use std.http.Client) |
| TUI rendering | Existing TUI framework in monorepo | Terminal rendering patterns, box drawing |
| JSON parsing | `std.json` | X-Plane API message parsing |
| WebSocket | May need custom impl or adapt from `http_sentinel` | Streaming dataref updates |
| Build pattern | `http_sentinel/build.zig` | Module + executable pattern |
| Atomic running flag | Common pattern across monorepo | Clean shutdown |

---

## Key Design Decisions

1. **Zero-allocation calculator functions** — All calc/ functions take value parameters and return value results. No heap allocation in the hot path. This is the core JSF AV C++ compliance narrative.

2. **Fixed-size FlightData struct** — Pre-allocated, fixed layout. Dataref updates write directly to known offsets. No dynamic dispatch, no maps in the hot path.

3. **10Hz update cycle** — X-Plane sends WebSocket updates at 10Hz. This is our frame rate. Each tick: receive updates → merge into FlightData → run calculators → render display.

4. **Compile-time backend selection** — TUI or framebuffer chosen at compile time, not runtime. Zero overhead from abstraction. Both implement the same Renderer interface via Zig's comptime polymorphism.

5. **std.http.Client for REST** — Zig 0.16+ has a usable HTTP client in std. Use it for the REST calls during startup. No external dependency needed.

6. **Custom WebSocket client** — X-Plane's WebSocket is standard RFC 6455. The handshake is an HTTP upgrade. Implement minimal WebSocket framing (we only need text frames for JSON). This is simpler than pulling in a dependency.

7. **Abstract Renderer, not abstract MFD** — The display logic (PFD, EICAS, etc.) doesn't change between backends. Only the pixel/character output changes. So the abstraction is at the renderer level, not the display level.

8. **Dataref resolution at startup, not runtime** — The X-Plane API requires looking up string names to get numeric IDs. We do this once at connection time, cache the mapping, and use only numeric IDs during runtime. This keeps the hot path allocation-free.

---

## JSF AV C++ Compliance Narrative

This table maps JSF AV C++ rules to Zig's built-in guarantees for the README:

| JSF AV C++ Rule | Requirement | Zig Equivalent |
|-----------------|-------------|----------------|
| AV Rule 208 | No exceptions | Error unions — caller must handle all errors |
| AV Rule 119 | No recursion | Detectable, auditable stack (no hidden stack growth) |
| AV Rule 206 | No dynamic allocation in critical paths | Explicit allocator parameter, comptime-known sizes |
| AV Rule 210 | No `goto` | No goto in Zig |
| AV Rule 97 | No implicit type conversions | Zig has zero implicit coercions |
| AV Rule 176 | Initialize all variables | Zig requires explicit initialization or `undefined` |
| AV Rule 202 | No use-after-free | Optional pointers, no dangling references |
| AV Rule 100 | No union type punning | Zig unions are tagged by default |
| AV Rule 167 | No null pointer dereference | Optional types, checked access |

---

## Hardware Demo Vision

```
┌─────────────────┐     WiFi/Ethernet      ┌──────────────────┐
│  Mac/PC         │ ◄──────────────────────►│  Orange Pi 6+    │
│  X-Plane 12     │     WebSocket 10Hz      │  Running Zigix   │
│  Flight Sim     │                         │                  │
│  Port 8086      │                         │  zig-flight-mfd  │
│                 │                         │  → /dev/fb0      │
│  [Main Display] │                         │  [HDMI → MFD]    │
└─────────────────┘                         └──────────────────┘
```

Investor sees: X-Plane running a flight on the main screen. The Orange Pi, running a custom OS written in Zig from bootloader to application, displaying a live avionics MFD on a second screen. Same language, same safety guarantees, kernel to cockpit.

---

## Testing Strategy

1. **Unit tests**: All calculator functions — pure math, easily testable with known inputs/outputs
2. **Protocol tests**: Parse sample X-Plane WebSocket messages, verify correct FlightData population
3. **Integration test**: Connect to X-Plane, subscribe, verify data flows
4. **Visual regression**: Capture TUI output, compare against reference renders
5. **Offline replay**: Record real X-Plane sessions, replay for deterministic testing

---

## Build Targets

```bash
# Native (TUI backend for development)
zig build

# Run with X-Plane connection
zig build run -- --host localhost --port 8086

# Run dataref dumper
zig build run-dump -- --host localhost --port 8086

# Run all tests
zig build test

# Cross-compile for Orange Pi (ARM64, framebuffer backend)
zig build -Dtarget=aarch64-linux-gnu -Dbackend=framebuffer

# Build for Zigix (freestanding ARM64)
zig build -Dtarget=aarch64-freestanding-none -Dbackend=framebuffer
```
