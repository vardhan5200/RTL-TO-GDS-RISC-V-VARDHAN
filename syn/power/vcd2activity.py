#!/usr/bin/env python3
"""vcd2activity.py <vcd> <scope> <period_ps> <out.tcl>
Per-bit toggle rate (transitions per clock period) and duty from an RTL VCD,
written as Tcl 'act <net> <activity> <duty>' lines for apply_activity.tcl.
Counting starts at the first clock edge after rst_n goes high; X/Z ignored."""
import sys, re
vcd, scope, period, out = sys.argv[1], sys.argv[2].split('/'), int(sys.argv[3]), sys.argv[4]
ids = {}            # code -> list of (name, width, lsb)
stack = []
t = 0; t0 = None; tend = 0
val = {}; last_t = {}; ones = {}; tog = {}
rst_code = None
with open(vcd) as f:
    for line in f:
        tok = line.split()
        if not tok: continue
        if tok[0] == '$scope': stack.append(tok[2]); continue
        if tok[0] == '$upscope': stack.pop(); continue
        if tok[0] == '$var':
            w, code, name = int(tok[2]), tok[3], tok[4]
            m = re.match(r'\[(\d+):(\d+)\]', tok[5]) if len(tok) > 6 else None
            lsb = int(m.group(2)) if m else 0
            if stack[:len(scope)] == scope:
                rel = stack[len(scope):]
                rel = [s for s in rel if not s.startswith('$ivl') and not s.startswith('g_')]
                full = '/'.join(rel + [name])
                ids.setdefault(code, []).append((full, w, lsb))
                if not rel and name == 'rst_n': rst_code = code
            continue
        if tok[0].startswith('$'): continue
        c = tok[0][0]
        if c == '#':
            t = int(tok[0][1:]); tend = t; continue
        if c in 'bBrR':
            v, code = tok[0][1:], tok[1]
        else:
            v, code = tok[0][0], tok[0][1:]
        if code == rst_code and v == '1' and t0 is None: t0 = t
        if code not in ids: continue
        for (name, w, lsb) in ids[code]:
            vv = v.rjust(w, v[0] if v[0] in 'xz' else '0')[-w:]
            for i in range(w):
                b = vv[w - 1 - i]; key = (name, w, lsb + i)
                old = val.get(key)
                if t0 is not None and old in ('0', '1'):
                    if old == '1': ones[key] = ones.get(key, 0) + (t - last_t[key])
                    if b in '01' and b != old: tog[key] = tog.get(key, 0) + 1
                val[key] = b; last_t[key] = max(t, t0) if t0 is not None else t
dur = max(1, tend - (t0 or 0)); cycles = dur / period
n = 0
with open(out, 'w') as o:
    for key, b in val.items():
        name, w, bit = key
        if b == '1' and t0 is not None: ones[key] = ones.get(key, 0) + (tend - last_t[key])
        net = f"{name}[{bit}]" if w > 1 else name
        o.write(f"act {{{net}}} {tog.get(key,0)/cycles:.5f} {min(1.0, ones.get(key,0)/dur):.5f}\n"); n += 1
print(f"{n} bits, {cycles:.0f} cycles after reset")
