#!/usr/bin/env python3
"""
Fail if any hardware divide can run on secret data in ML-KEM-768 or ML-DSA-65.

Why this exists. Division latency depends on the operands on many CPUs. A `/`, `%`, `@mod` or
`@divTrunc` by a constant is only safe if the compiler lowers it to a multiply, and that is the
compiler's choice, not the source's: LLVM keeps a real divide on wasm32 in every optimisation
mode, and at -Oz on others. The KyberSlash attacks recovered ML-KEM keys through exactly this.
The source now reduces with multiplies, shifts and masks only; this check makes sure it stays
that way, by looking at what the compiler actually emitted.

Method. Compile src/ct_probe.zig (every secret-handling entry point) to assembly for a matrix of
targets and modes, find each divide instruction or software-divide call, and attribute it to its
enclosing function. A divide inside cryptographic code fails the check unless its divisor is a
Keccak rate (136 or 168 bytes): that is std.crypto's sponge doing position arithmetic on a public
byte count, inlined into its caller.

Debug builds are not checked. They keep divides for public index arithmetic (`i / 8`) that
cannot be told apart mechanically, and Debug must never be shipped.

Usage:  python3 tools/ct_divide_check.py [--zig zig] [--keep DIR]
Exit status 0 = clean, 1 = a secret-path divide was found, 2 = a build failed.
"""
from __future__ import annotations

import argparse
import collections
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROBE = ROOT / "src" / "ct_probe.zig"

MATRIX = [
    ("wasm32-freestanding", "ReleaseSmall"),  # what `zig build wasm` ships to the Worker
    ("wasm32-freestanding", "ReleaseFast"),
    ("wasm32-freestanding", "ReleaseSafe"),
    ("aarch64-linux-musl", "ReleaseSafe"),  # what `zig build cross` ships
    ("aarch64-linux-musl", "ReleaseSmall"),
    ("aarch64-macos", "ReleaseFast"),  # the iOS / macOS slices
    ("x86_64-linux-musl", "ReleaseSafe"),
    ("x86_64-linux-musl", "ReleaseSmall"),
    ("arm-linux-musleabihf", "ReleaseSmall"),  # no hardware divider: divides become runtime calls
]

DIVIDE = re.compile(r"^\s+(idivl?|idivq|divl?|divq|idiv|div|sdiv|udiv|i32\.(div|rem)_[su]|i64\.(div|rem)_[su])\b")
DIVIDE_CALL = re.compile(r"\b(bl|blx|call)\s+_?_?(aeabi_u?idiv(mod)?|aeabi_u?ldivmod|u?divsi3|u?modsi3|u?divmodsi4|u?divdi3|u?moddi3|u?divti3|u?modti3)\b")
LABEL = re.compile(r'^"?([^\s":][^":]*)"?:\s*(#.*|//.*)?$')
KECCAK_RATE = re.compile(r"(?<![\w.])(?:#|\$)?(136|168)\b")
CRYPTO = re.compile(
    r"ml_kem|ml_dsa|ct_probe|ntt|compress|decaps|encaps|keygen|kpke|poly|barrett|montgomery|modq|modreduce|"
    r"sample|byteencode|bytedecode|multiply|decompose|power2round|checknorm|makehint|usehint|sign|pack|expand",
    re.IGNORECASE,
)
LOOKBACK = 10  # lines searched backwards for the divisor constant


def build(zig: str, target: str, mode: str, out: pathlib.Path, cache: pathlib.Path) -> bool:
    command = [zig, "build-obj", str(PROBE), "-target", target, "-O", mode, "-fno-emit-bin", f"-femit-asm={out}", "--cache-dir", str(cache)]
    if not target.startswith("wasm32"):
        command.append("-lc")
    result = subprocess.run(command, cwd=ROOT / "src", capture_output=True, text=True)
    if result.returncode != 0 or not out.exists():
        sys.stderr.write(f"  build failed for {target} {mode}:\n{result.stderr[-800:]}\n")
        return False
    return True


def audit(path: pathlib.Path):
    """Returns (offending, allowed_keccak, outside_crypto): offending is {function: [line numbers]}."""
    lines = path.read_text(errors="replace").splitlines()
    offending, allowed, outside = collections.defaultdict(list), 0, 0
    current = "?"
    for number, line in enumerate(lines, 1):
        label = LABEL.match(line)
        if label and not label.group(1).lstrip(".").startswith(("L", "Ltmp", "LBB")) or (label and "ct_probe" in label.group(1)):
            current = label.group(1)
        if not (DIVIDE.match(line) or DIVIDE_CALL.search(line)):
            continue
        if not CRYPTO.search(current):
            outside += 1
            continue
        window = "\n".join(lines[max(0, number - 1 - LOOKBACK):number])
        if KECCAK_RATE.search(window):
            allowed += 1
            continue
        offending[current].append(number)
    return offending, allowed, outside


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--keep", help="write the assembly listings here instead of a temporary directory")
    args = parser.parse_args()

    failures = build_errors = 0
    with tempfile.TemporaryDirectory(prefix="ct-check-") as scratch:
        work = pathlib.Path(args.keep) if args.keep else pathlib.Path(scratch)
        work.mkdir(parents=True, exist_ok=True)
        print(f"{'target':<24}{'mode':<14}{'secret-path divides':>20}{'keccak (public)':>18}{'outside crypto':>16}")
        for target, mode in MATRIX:
            listing = work / f"{target}_{mode}.s"
            if not build(args.zig, target, mode, listing, work / "cache"):
                build_errors += 1
                continue
            offending, allowed, outside = audit(listing)
            count = sum(len(v) for v in offending.values())
            print(f"{target:<24}{mode:<14}{count:>20}{allowed:>18}{outside:>16}")
            for function, numbers in sorted(offending.items()):
                print(f"    DIVIDE in {function[:90]}  (lines {', '.join(map(str, numbers[:6]))}{' ...' if len(numbers) > 6 else ''})")
            failures += count
    if build_errors:
        print(f"\n{build_errors} configuration(s) failed to build")
        return 2
    if failures:
        print(f"\nFAIL: {failures} divide instruction(s) reachable with secret operands. Replace the `/`, `%`, `@mod` or "
              f"`@divTrunc` with ml_kem.modQ / ml_dsa.modReduce, a shift, or a mask.")
        return 1
    print("\nOK: no divide instruction in any secret-handling function, in any checked configuration.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
