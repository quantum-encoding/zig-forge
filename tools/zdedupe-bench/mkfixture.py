#!/usr/bin/env python3
"""Per-file-cost fixture: N small files (100 B - 48 KiB), ~40% duplicates,
~10% same-size distinct, spread over nested folders like a source tree."""
import os, random, sys
root = sys.argv[1]; n = int(sys.argv[2])
rnd = random.Random(7); originals = []; total = 0
for i in range(n):
    d = os.path.join(root, f"a{i % 64:02d}", f"b{(i // 64) % 32:02d}", f"c{(i // 2048) % 8}")
    os.makedirs(d, exist_ok=True)
    r = rnd.random()
    if originals and r < 0.40: data = rnd.choice(originals)
    elif originals and r < 0.50: data = rnd.randbytes(len(rnd.choice(originals)))
    else:
        data = rnd.randbytes(rnd.choice([rnd.randint(100, 4096), rnd.randint(4097, 49152)]))
        if len(originals) < 20000: originals.append(data)
    with open(os.path.join(d, f"f{i:07d}.dat"), "wb") as f: f.write(data)
    total += len(data)
print(f"{n} files, {total/1e9:.2f} GB")
