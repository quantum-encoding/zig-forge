#!/usr/bin/env bash
#
# doom.sh — Launch zig_doom
#
# Usage:
#   ./doom.sh                     # Play E1M1 in terminal (TUI)
#   ./doom.sh e1m3                # Play Episode 1 Map 3
#   ./doom.sh e1m5 uv             # E1M5 on Ultra-Violence
#   ./doom.sh sdl2                # Play with SDL2 window
#   ./doom.sh render e1m1         # Render E1M1 to frame.ppm
#   ./doom.sh demo DEMO1          # Play back a demo lump
#   ./doom.sh bench DEMO1         # Benchmark demo (timedemo)
#   ./doom.sh lumps               # Dump WAD lump directory
#   ./doom.sh map e1m1            # Dump map geometry
#   ./doom.sh test                # Run unit tests
#   ./doom.sh build               # Build without running
#   ./doom.sh help                # Show all options

set -e
cd "$(dirname "$0")"

WAD="wad/doom1.wad"
BUILD_ARGS=""
RUN_ARGS="--iwad $WAD"

# Lowercase helper (POSIX-compatible)
lc() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
uc() { echo "$1" | tr '[:lower:]' '[:upper:]'; }

# Download WAD if missing
if [ ! -f "$WAD" ]; then
    echo "doom1.wad not found, downloading shareware WAD..."
    bash tools/get-shareware-wad.sh
fi

# Skill name mapping
skill_from_name() {
    case "$(lc "$1")" in
        itytd|baby|1)      echo 1 ;;
        hntr|easy|2)        echo 2 ;;
        hmp|medium|3)       echo 3 ;;
        uv|hard|4)          echo 4 ;;
        nm|nightmare|5)     echo 5 ;;
        *)                  echo "" ;;
    esac
}

# Parse arguments
COMMAND=""
PLATFORM="tui"
MAP=""
SKILL=""
DEMO=""
OUTPUT="frame.ppm"

while [ $# -gt 0 ]; do
    ARG_LC="$(lc "$1")"
    case "$ARG_LC" in
        # Platforms
        tui|sdl2|fb|framebuffer)
            PLATFORM="$ARG_LC"
            [ "$PLATFORM" = "framebuffer" ] && PLATFORM="fb"
            ;;

        # Commands
        render)     COMMAND="render"; shift; [ $# -gt 0 ] && MAP="$(uc "$1")" ;;
        demo)       COMMAND="demo"; shift; [ $# -gt 0 ] && DEMO="$1" ;;
        bench)      COMMAND="bench"; shift; [ $# -gt 0 ] && DEMO="$1" ;;
        lumps)      COMMAND="lumps" ;;
        map)        COMMAND="map"; shift; [ $# -gt 0 ] && MAP="$(uc "$1")" ;;
        test)       COMMAND="test" ;;
        build)      COMMAND="build" ;;
        help|-h|--help) COMMAND="help" ;;

        # Map names (E1M1-E1M9)
        e[1-4]m[1-9])
            MAP="$(uc "$1")"
            ;;

        # Skill levels
        itytd|baby|hntr|easy|hmp|medium|uv|hard|nm|nightmare|[1-5])
            SKILL=$(skill_from_name "$1")
            ;;

        # Output path
        -o|--output)
            shift; [ $# -gt 0 ] && OUTPUT="$1"
            ;;

        # SDL2 build flag
        --sdl2)
            BUILD_ARGS="-Dsdl2=true"
            PLATFORM="sdl2"
            ;;

        # Pass-through for any other --flags
        --*)
            RUN_ARGS="$RUN_ARGS $1"
            if [ $# -gt 1 ] && [ "$(echo "$2" | cut -c1-2)" != "--" ]; then
                shift
                RUN_ARGS="$RUN_ARGS $1"
            fi
            ;;

        *)
            echo "Unknown argument: $1"
            echo "Run './doom.sh help' for usage"
            exit 1
            ;;
    esac
    shift
done

case "$COMMAND" in
    test)
        echo "Running zig_doom tests..."
        zig build test $BUILD_ARGS
        echo "All tests passed!"
        exit 0
        ;;

    build)
        echo "Building zig_doom..."
        zig build $BUILD_ARGS
        echo "Build complete: zig-out/bin/zig_doom"
        exit 0
        ;;

    help)
        cat <<'HELP'
doom.sh — zig_doom launcher

QUICK START:
  ./doom.sh                     Play E1M1 in terminal
  ./doom.sh e1m3                Play Episode 1, Map 3
  ./doom.sh e1m5 uv             E1M5 on Ultra-Violence
  ./doom.sh --sdl2              Play with SDL2 window
  ./doom.sh render e1m1         Render E1M1 start to frame.ppm

MAPS (shareware Episode 1):
  e1m1    Hangar                e1m6    Central Processing
  e1m2    Nuclear Plant         e1m7    Computer Station
  e1m3    Toxin Refinery        e1m8    Phobos Anomaly
  e1m4    Command Control       e1m9    Military Base (secret)
  e1m5    Phobos Lab

SKILL LEVELS:
  1 / itytd / baby          I'm Too Young To Die
  2 / hntr / easy           Hey, Not Too Rough
  3 / hmp / medium          Hurt Me Plenty (default)
  4 / uv / hard             Ultra-Violence
  5 / nm / nightmare        Nightmare!

PLATFORMS:
  tui                       Terminal (ANSI half-block characters)
  sdl2 / --sdl2             SDL2 window (requires -Dsdl2=true build)
  fb / framebuffer          Linux framebuffer (/dev/fb0)

COMMANDS:
  render <map>              Render single frame to PPM image
  demo <name>              Play back a WAD demo lump (DEMO1, DEMO2, DEMO3)
  bench <name>             Timedemo benchmark (fast as possible)
  lumps                     List all WAD lumps
  map <map>                Dump map geometry stats
  test                      Run unit tests
  build                     Build without running
  help                      This help

OPTIONS:
  -o / --output <path>      Output file for render/demo (default: frame.ppm)
  --sdl2                    Build and run with SDL2

EXAMPLES:
  ./doom.sh                         # Terminal, E1M1, default skill
  ./doom.sh e1m8 nightmare          # Boss level, nightmare mode
  ./doom.sh render e1m1 -o shot.ppm # Render to custom file
  ./doom.sh demo DEMO1              # Watch the shareware demo
  ./doom.sh bench DEMO1             # Benchmark: how fast can we render?
  ./doom.sh lumps                   # Explore the WAD structure
  ./doom.sh map e1m9                # Stats for the secret level
HELP
        exit 0
        ;;

    lumps)
        zig build $BUILD_ARGS run -- $RUN_ARGS --dump-lumps
        exit 0
        ;;

    map)
        zig build $BUILD_ARGS run -- $RUN_ARGS --dump-map "${MAP:-E1M1}"
        exit 0
        ;;

    render)
        zig build $BUILD_ARGS run -- $RUN_ARGS --render-frame "${MAP:-E1M1}" --output "$OUTPUT"
        exit 0
        ;;

    demo)
        zig build $BUILD_ARGS run -- $RUN_ARGS --playdemo "${DEMO:-DEMO1}" --output "$OUTPUT"
        exit 0
        ;;

    bench)
        zig build $BUILD_ARGS run -- $RUN_ARGS --timedemo "${DEMO:-DEMO1}"
        exit 0
        ;;

    "")
        # Default: run the game
        # Build first, then run binary directly (not via zig build run)
        # so the terminal is properly connected for TUI mode
        zig build $BUILD_ARGS
        RUN_ARGS="$RUN_ARGS --run --platform $PLATFORM"
        [ -n "$MAP" ] && RUN_ARGS="$RUN_ARGS --warp $MAP"
        [ -n "$SKILL" ] && RUN_ARGS="$RUN_ARGS --skill $SKILL"
        exec ./zig-out/bin/zig_doom $RUN_ARGS
        ;;
esac
