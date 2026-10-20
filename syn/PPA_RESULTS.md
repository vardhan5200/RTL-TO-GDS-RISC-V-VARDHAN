# PPA results: feat/ppa-pipeline vs integrate/core-v2 (53f6ec9)

All numbers are MEASURED with ORFS (OpenROAD-flow-scripts), sky130hd, tt corner,
10 ns clock (syn/orfs/constraint.sdc), same config.mk for both. Post-CTS, parasitics
estimated from placement (no detailed route). Power: OpenSTA with RTL-VCD activity
from tb/integration program (syn/power + syn/orfs/power_act.sh, ~1.47k nets annotated);
"default" = OpenSTA default activity. Base RTL needs commit a0868fe to synthesize at all.

| metric                      | base (a0868fe RTL) | final (this branch) | delta |
|-----------------------------|--------------------|---------------------|-------|
| design area (um^2)          | 601,976            | 601,492             | -484 (-0.08%) |
| cells post-CTS (incl. taps) | 53,650             | 54,845              | +1,195 (+2.2%) |
| sequential cells            | 11,661             | 11,670              | +9 |
| timing-repair buffers       | 3,204              | 3,073               | -131 |
| min period (ns) / fmax      | 9.53 / 104.90 MHz  | 9.20 / 108.70 MHz   | -0.33 ns (+3.6%) |
| worst slack @10 ns          | 0.467 ns           | 0.800 ns            | +0.333 |
| power, VCD-annotated (mW)   | 113                | 111                 | -2 (-1.8%) |
| power, default activity     | 120                | 132                 | +12 (not meaningful: default toggle rate) |

Worst path, base:  opcode_ex[1] (ID/EX reg) -> EX opcode decode -> ALU A mux -> adder (vaddr)
  -> u_dcache/data[53][38]; arrival 10.565 ns (incl. 1.382 ns clock latency), slack 0.467.
Worst path, final: alu_src_b_ex (ID/EX reg) -> ALU B mux -> adder -> u_dcache/resp_rdata[8];
  arrival 10.178 ns (incl. 1.303 ns clock latency), slack 0.800.
The critical path is EX address generation into the D-cache (MEM). The remaining
cost is inside u_dcache (out of scope: cache RTL).

Variants tried and rejected (same flow): dedicated AGU adder (9.80 ns, 115 mW),
no-reset datapath ID/EX regs with enable (9.89 ns / 116 mW and 9.20 ns / 116 mW):
no gain after CTS.
