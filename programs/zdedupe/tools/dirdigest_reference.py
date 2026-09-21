#!/usr/bin/env python3
"""Independent reference for the zdedupe directory digest (format: src/dirs.zig
module doc). Written against the documented format only, using os + hashlib;
shares no code with the Zig implementation. Valid for trees in which every file
was content-hashed by the scan (i.e. has a twin), SHA-256 mode."""
import hashlib, os, struct, sys

DOMAIN = b"zdedupe-dir-v1\x00"

def u64(n): return struct.pack("<Q", n)

def digest(path):
    h = hashlib.sha256(); h.update(DOMAIN)
    for name in sorted(os.listdir(path), key=os.fsencode):
        full = os.path.join(path, name); raw = os.fsencode(name)
        if os.path.islink(full):
            target = os.fsencode(os.readlink(full))
            h.update(b"L" + u64(len(raw)) + raw + u64(len(target)) + target)
        elif os.path.isdir(full):
            h.update(b"D" + u64(len(raw)) + raw + digest(full))
        else:
            with open(full, "rb") as f: content = hashlib.sha256(f.read()).digest()
            token = (b"H" + content).ljust(33, b"\0")
            h.update(b"F" + u64(len(raw)) + raw + token)
    return h.digest()

print(digest(sys.argv[1]).hex())
