#!/usr/bin/env python3
"""bin2hex.py in.bin out.hex — raw little-endian binary -> $readmemh words
(one 32-bit word per line, word 0 = load address of the binary)."""
import sys
data = open(sys.argv[1], "rb").read()
data += b"\0" * (-len(data) % 4)
with open(sys.argv[2], "w") as f:
    for i in range(0, len(data), 4):
        f.write("%08x\n" % int.from_bytes(data[i:i + 4], "little"))
