# zig_flight

X-Plane 12 avionics MFD toolkit in Zig 0.16 — real-time flight data streaming, 5-page TUI display, formal alert system, and flight recording/replay.

> **Zero heap allocation in the hot path.** All flight calculators are pure functions. Zig naturally enforces the JSF AV C++ coding standard.

**Developed by [QUANTUM ENCODING LTD](https://quantumencoding.io)**
Contact: [info@quantumencoding.io](mailto:info@quantumencoding.io)

---

## Features

- **X-Plane 12 Integration** — REST API for dataref resolution, WebSocket streaming at 10Hz, automatic reconnection
- **8 Flight Calculators** — Wind, turn, VNAV, density altitude, fuel, navigation, performance, approach — all pure functions, 150+ unit tests
- **5-Page TUI Display** — PFD, NAV, EICAS, FMS, STATUS with double-buffered ANSI rendering
- **Alert System** — Overspeed, bank angle, descent rate, low fuel warnings; radio altitude callouts (2500 down to 10 ft)
- **Aircraft Presets** — Generic jet, Cessna 172, transport category with configurable envelope limits
- **Interactive Commands** — Adjust autopilot heading, altitude, speed, VS directly from the MFD
- **Demo Recording** — Record flights to binary files, replay without X-Plane for demos and testing
- **Framebuffer Backend** — Linux `/dev/fb0` rendering with embedded 8x16 VGA font for bare-metal deployment

---

## Architecture

```
 X-Plane 12                         zig_flight
 ┌──────────┐    REST (startup)    ┌──────────────────────────────┐
 │           │◄────────────────────│  dataref_registry            │
 │  Web API  │    WebSocket 10Hz   │  xplane_client               │
 │  :8086    │◄───────────────────►│  protocol                    │
 │           │    Commands ───────►│                              │
 └──────────┘                      │  flight_data ──► 8 calcs     │
                                   │       │                      │
                                   │       ▼                      │
                                   │  alerts + limits             │
                                   │       │                      │
                                   │       ▼                      │
                                   │  MFD ──► TUI / Framebuffer   │
                                   │       │                      │
                                   │  demo recorder/player        │
                                   └──────────────────────────────┘
```

---

## Quick Start

### Build

```bash
cd programs/zig_flight
zig build
```

### Run MFD (requires X-Plane 12 running)

```bash
zig build run -- --host localhost --port 8086
```

### Record a flight

```bash
zig build run -- --host localhost --port 8086 --record my_flight.zflt
```

### Play back a recording (no X-Plane needed)

```bash
zig build run -- --play my_flight.zflt
```

### Select aircraft preset

```bash
zig build run -- --aircraft cessna172   # or: jet, transport
```

### Run tests

```bash
zig build test
```

---

## Display Pages

| Key | Page | Content |
|-----|------|---------|
| `1` | **PFD** | Airspeed tape, attitude indicator, altitude tape, VSI, heading strip |
| `2` | **NAV** | Compass rose, NAV1 radio (DME + deviation), GPS, position, wind |
| `3` | **EICAS** | Dual engine columns (N1/N2/ITT/oil/FF), fuel summary, active alerts |
| `4` | **FMS** | Atmosphere, wind components, fuel calculations, VNAV, performance |
| `5` | **STATUS** | Version, connection stats, alert count, aircraft limits, mode |

## Command Keys (Live Mode)

| Key | Action |
|-----|--------|
| `a` | Toggle autopilot |
| `h` / `H` | Heading bug +1 / -1 |
| `v` / `V` | Altitude +100 / -100 |
| `s` / `S` | Speed +1 / -1 |
| `w` / `W` | VS +100 / -100 |
| `q` | Quit |

---

## Modules

| Module | Description |
|--------|-------------|
| `xplane_client` | REST + WebSocket client with reconnection |
| `protocol` | Zero-allocation JSON message construction/parsing |
| `dataref_registry` | Dataref name-to-ID resolution and subscription |
| `flight_data` | Fixed-size flight data struct with update dispatch |
| `alerts` | Alert evaluation with radio altitude callouts |
| `limits` | Aircraft envelope definitions (3 presets) |
| `commands` | Keyboard-to-X-Plane command integration |
| `demo` | Binary flight recording and replay |
| `calc/wind` | Headwind, crosswind, wind correction angle |
| `calc/turn` | Standard rate turns, bank angle, turn radius |
| `calc/vnav` | Top of descent, descent rate, vertical deviation |
| `calc/density_alt` | Density altitude, pressure altitude, TAS, ISA |
| `calc/fuel` | Endurance, range, specific range, flow conversions |
| `calc/nav` | Great circle distance, bearing, ETA, cross-track |
| `calc/performance` | V-speeds, takeoff/landing distance, weight & balance |
| `calc/approach` | ILS deviation, PAPI, DH/MDA, missed approach point |
| `display/renderer` | Cell-based frame buffer with ANSI output |
| `display/tui_backend` | Terminal control: raw mode, ANSI escapes, input |
| `display/fb_backend` | Linux framebuffer backend with VGA font |
| `display/pfd` | Primary Flight Display page |
| `display/nd` | Navigation Display page |
| `display/eicas` | Engine/Crew Alerting page |
| `display/fms` | Flight Management page |
| `display/mfd` | Multi-Function Display controller |

---

## JSF AV C++ Compliance

Zig's language design provides the same safety guarantees that the Joint Strike Fighter Air Vehicle C++ Coding Standard mandates — but as compiler-enforced defaults rather than coding guidelines.

| JSF AV C++ Rule | Requirement | Zig Equivalent |
|-----------------|-------------|----------------|
| AV Rule 208 | No exceptions | Error unions — caller must handle all errors |
| AV Rule 119 | No recursion | Detectable, auditable stack (no hidden growth) |
| AV Rule 206 | No dynamic allocation in critical paths | Explicit allocator parameter, comptime-known sizes |
| AV Rule 210 | No `goto` | No goto in Zig |
| AV Rule 97 | No implicit type conversions | Zero implicit coercions |
| AV Rule 176 | Initialize all variables | Requires explicit initialization or `undefined` |
| AV Rule 202 | No use-after-free | Optional pointers, no dangling references |
| AV Rule 100 | No union type punning | Tagged unions by default |
| AV Rule 167 | No null pointer dereference | Optional types, checked access |

All 8 flight calculators and the alert evaluation system are **pure functions** operating on **fixed-size structs** with **zero heap allocation** in the 10Hz update path.

---

## Hardware Demo Vision

```
┌─────────────────┐     WiFi/Ethernet      ┌──────────────────┐
│  Mac/PC         │ <───────────────────── >│  Orange Pi 6+    │
│  X-Plane 12     │     WebSocket 10Hz      │  Running Zigix   │
│  Flight Sim     │                         │                  │
│  Port 8086      │                         │  zig-flight-mfd  │
│                 │                         │  -> /dev/fb0     │
│  [Main Display] │                         │  [HDMI -> MFD]   │
└─────────────────┘                         └──────────────────┘
```

Cross-compile for Orange Pi:
```bash
zig build -Dtarget=aarch64-linux-gnu
```

---

## License

MIT License. See [LICENSE](../../LICENSE) for details.
