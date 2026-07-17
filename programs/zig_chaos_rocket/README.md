# zig_chaos_rocket

A terminal-based, single-binary chaos-engineering demo that simulates a Falcon 9-style rocket launch (from T-10 through orbit insertion) while a chaos engine injects faults modeled on 20 real-world software disasters — Ariane 5 Flight 501, the Mars Climate Orbiter unit mix-up, the Boeing 737 MAX MCAS, the Patriot missile Dhahran clock drift, Therac-25, and others — to show how Zig's language-level safety guarantees (checked arithmetic, typed units, sentinel slices, explicit error handling) turn those failure classes into structurally impossible states.

## What it actually does

- Runs a physics/propulsion/guidance/flight-control simulation loop with a suite of sensors (IMU, AoA, GPS, barometric, temperature, fuel gauge, radar altimeter).
- On each timestep the chaos engine may inject a fault; the simulation records how many faults were injected and how many were caught, then prints a timeline, a chaos report, and a final mission status.
- Renders everything as ANSI-colored text to stdout (optional TUI dashboard mode).
- Includes a C-comparison module (`src/c_compare/`) that contrasts equivalent C bugs, and a fuzz mode.

This is a standalone demo executable, not a library — `build.zig` exposes an executable, a `run` step, and a `test` step; it does not export a module, C-ABI, or WASM surface.

## Build & run

```sh
zig build            # build the executable
zig build run        # build and run the simulation
zig build test       # run the unit tests
```

## Configuration (environment variables)

Configuration is read from the environment (no command-line flags):

| Variable | Values | Meaning |
|---|---|---|
| `CHAOS_MODE` | `clean`/`off`, `scripted` (default), `random`, `stress`, `fuzz` | Fault-injection mode |
| `CHAOS_TUI` | any value | Enable the live TUI dashboard |
| `CHAOS_SCENARIO` | e.g. `ARIANE`, `MCO`, `MCAS`, … | Run one specific scenario |
| `CHAOS_SEED` | integer (default `42`) | RNG seed |
| `CHAOS_ITERATIONS` | integer (default `100000`) | Fuzz iterations per subsystem |
| `CHAOS_COMPARISONS` | any value | Render the Zig-vs-disaster comparison writeups |
| `CHAOS_C_COMPARE` | any value | Render the C-bug comparison |

Example:

```sh
CHAOS_MODE=scripted CHAOS_SEED=7 zig build run
CHAOS_SCENARIO=MCAS zig build run
```
