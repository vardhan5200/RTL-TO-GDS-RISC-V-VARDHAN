#!/usr/bin/env python3
"""Synthesis-only workaround (does NOT modify rtl/): copy rtl/ to OUT_DIR and
rewrite the pattern

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n || flush) begin BODY end else ...

into the equivalent

        if (!rst_n) begin BODY end else if (flush) begin BODY end else ...

i.e. async reset on rst_n plus a synchronous flush with the same values, which
is what the original code does in simulation. Yosys (read_verilog -sv:
"Multiple edge sensitive events found for this signal!") and yosys-slang
("condition cannot be matched to any signal from the event list") both reject
the original form. Remove this step once the RTL itself is fixed.

usage: split_async_flush.py <repo>/rtl <OUT_DIR>
"""
import re, shutil, sys, pathlib

src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
if out.exists():
    shutil.rmtree(out)
shutil.copytree(src, out)
pat = re.compile(r"^(\s*)if \(!rst_n \|\| (\w+)\) begin(.*)$")
for f in out.rglob("*.sv"):
    lines = f.read_text().splitlines(keepends=True)
    res, i, n = [], 0, 0
    while i < len(lines):
        m = pat.match(lines[i])
        if not m:
            res.append(lines[i]); i += 1; continue
        ind, sig = m.group(1), m.group(2)
        body, j = [], i + 1
        while not re.match(rf"^{ind}end\b", lines[j]):
            body.append(lines[j]); j += 1
        res.append(f"{ind}if (!rst_n) begin{m.group(3)}\n")
        res += body
        res.append(f"{ind}end else if ({sig}) begin\n")
        res += body
        res.append(lines[j])          # original "end else ..." line
        i, n = j + 1, n + 1
    if n:
        f.write_text("".join(res))
        print(f"{f}: split {n} always_ff reset/flush block(s)")
