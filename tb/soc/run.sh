#!/usr/bin/env bash
# Run the SoC tests (Icarus Verilog, iverilog -g2012 + vvp).
#   irq_ctrl_tb   - irq_ctrl unit test
#   timer_irq_tb  - timer -> irq_ctrl -> irq (no CPU)
#   soc_top_tb    - single-cycle soc_top: decode sweep, timer->irq poll, bus_err
#   uart_tb       - UART unit test (loopback, FIFO burst, overflow/overrun)
#   soc_sw_tb     - C program sw/nginx_lite on soc_core_top over the serial
#                   UART: MODE=0 GET / -> 200, MODE=1 POST -> 404
# The nginx-lite hex is committed; rebuild with `make -C sw/nginx_lite`.
set -e
cd "$(dirname "$0")/../.."
OUT=${SIM_OUT:-sim}; mkdir -p "$OUT"
SOC="rtl/soc/soc_map_pkg.sv rtl/soc/addr_decode.sv rtl/soc/timer.sv rtl/soc/irq_ctrl.sv"
CORE="rtl/cpu/decoder.sv rtl/cpu/imm_gen.sv rtl/cpu/alu.sv rtl/cpu/branch_unit.sv rtl/cpu/mul.sv
      rtl/cpu/div.sv rtl/cpu/div_unit.sv
      rtl/cache/dm_cache.sv rtl/priv/csr_file.sv rtl/priv/priv_unit.sv rtl/mmu/*.sv rtl/core/core_top.sv"
quiet() { "$@" 2> >(grep -v "sorry:" >&2); }
iverilog -g2012 -s irq_ctrl_tb  -o "$OUT/irq_ctrl.vvp"  $SOC tb/soc/irq_ctrl_tb.sv
iverilog -g2012 -s timer_irq_tb -o "$OUT/timer_irq.vvp" $SOC tb/soc/timer_irq_tb.sv
iverilog -g2012 -s soc_top_tb   -o "$OUT/soc_top.vvp"   $SOC rtl/soc/soc_top.sv rtl/cpu/*.sv tb/soc/soc_top_tb.sv
iverilog -g2012 -s uart_tb      -o "$OUT/uart.vvp"      rtl/soc/soc_map_pkg.sv rtl/soc/uart.sv tb/soc/uart_tb.sv
for m in 0 1; do
    quiet iverilog -g2012 -s soc_sw_tb -P soc_sw_tb.MODE=$m -o "$OUT/soc_sw$m.vvp" \
        $SOC rtl/soc/uart.sv rtl/soc/soc_core_top.sv $CORE tb/soc/soc_sw_tb.sv
done
fail=0
for t in irq_ctrl timer_irq soc_top uart soc_sw0 soc_sw1; do
    out=$(timeout 300 vvp -n "$OUT/$t.vvp")
    echo "$out"
    echo "$out" | grep -q ": PASS$" || fail=1
done
[ $fail -eq 0 ] && echo "ALL SOC TESTS PASSED" || { echo "SOC TESTS FAILED"; exit 1; }
