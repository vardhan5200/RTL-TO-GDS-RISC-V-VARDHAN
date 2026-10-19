#!/usr/bin/env bash
# Run the SoC / interrupt-controller tests (Icarus Verilog).
set -e
cd "$(dirname "$0")/../.."
mkdir -p sim
SOC="rtl/soc/soc_map_pkg.sv rtl/soc/addr_decode.sv rtl/soc/timer.sv rtl/soc/irq_ctrl.sv rtl/soc/soc_top.sv"
iverilog -g2012 -s irq_ctrl_tb  -o sim/irq_ctrl.vvp  $SOC tb/soc/irq_ctrl_tb.sv
iverilog -g2012 -s timer_irq_tb -o sim/timer_irq.vvp $SOC tb/soc/timer_irq_tb.sv
iverilog -g2012 -s soc_top_tb   -o sim/soc_top.vvp   $SOC rtl/cpu/*.sv tb/soc/soc_top_tb.sv
fail=0
for t in irq_ctrl timer_irq soc_top; do
    out=$(vvp -n sim/$t.vvp)
    echo "$out"
    echo "$out" | grep -q ": PASS$" || fail=1
done
[ $fail -eq 0 ] && echo "ALL SOC TESTS PASSED" || { echo "SOC TESTS FAILED"; exit 1; }
