#!/usr/bin/env bash
# Run the SoC / interrupt-controller tests (Icarus Verilog).
#   irq_ctrl_tb      - irq_ctrl unit test
#   timer_irq_tb     - timer -> irq_ctrl -> irq (no CPU)
#   soc_top_tb       - single-cycle soc_top: decode, timer->irq poll, bus_err
#   soc_timer_irq_tb - integrated core (soc_core_top): timer irq -> meip ->
#                      MEI trap, handler W1C + ACK, mret, no re-entry
set -e
cd "$(dirname "$0")/../.."
OUT=${SIM_OUT:-sim}; mkdir -p "$OUT"
SOC="rtl/soc/soc_map_pkg.sv rtl/soc/addr_decode.sv rtl/soc/timer.sv rtl/soc/irq_ctrl.sv"
CORE="rtl/cpu/decoder.sv rtl/cpu/imm_gen.sv rtl/cpu/alu.sv rtl/cpu/branch_unit.sv rtl/cpu/mul.sv
      rtl/cpu/div.sv rtl/cpu/div_unit.sv
      rtl/cache/dm_cache.sv rtl/priv/csr_file.sv rtl/priv/priv_unit.sv rtl/mmu/*.sv rtl/core/core_top.sv"
python3 tb/soc/gen_timer_irq_prog.py >/dev/null
iverilog -g2012 -s irq_ctrl_tb  -o "$OUT/irq_ctrl.vvp"  $SOC tb/soc/irq_ctrl_tb.sv
iverilog -g2012 -s timer_irq_tb -o "$OUT/timer_irq.vvp" $SOC tb/soc/timer_irq_tb.sv
iverilog -g2012 -s soc_top_tb   -o "$OUT/soc_top.vvp"   $SOC rtl/soc/soc_top.sv rtl/cpu/*.sv tb/soc/soc_top_tb.sv
iverilog -g2012 -s soc_timer_irq_tb -o "$OUT/soc_timer_irq.vvp" \
    $SOC rtl/soc/soc_core_top.sv $CORE tb/soc/soc_timer_irq_tb.sv 2> >(grep -v "sorry:" >&2)
fail=0
for t in irq_ctrl timer_irq soc_top soc_timer_irq; do
    out=$(timeout 60 vvp -n "$OUT/$t.vvp")
    echo "$out"
    echo "$out" | grep -q ": PASS$" || fail=1
done
[ $fail -eq 0 ] && echo "ALL SOC TESTS PASSED" || { echo "SOC TESTS FAILED"; exit 1; }
