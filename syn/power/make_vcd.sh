#!/usr/bin/env bash
# make_vcd.sh <rtl_dir> <out.vcd>: run core_int_tb (USE_MMU=0) on the given RTL tree and dump the core.
set -euo pipefail
cd "$(dirname "$0")/../.."
R=$1; OUTV=$2
python3 tb/integration/gen_prog.py >/dev/null
CORE="$R/cpu/decoder.sv $R/cpu/imm_gen.sv $R/cpu/alu.sv $R/cpu/branch_unit.sv $R/cpu/mul.sv
      $R/cpu/div.sv $R/cpu/div_unit.sv $R/cache/dm_cache.sv $R/cache/icache.sv $R/priv/csr_file.sv $R/priv/priv_unit.sv
      $R/mmu/sv32_tlb.sv $R/mmu/sv32_perm_check.sv $R/mmu/sv32_ptw.sv $R/mmu/sv32_mmu.sv $R/core/core_top.sv"
SOC="$R/soc/soc_map_pkg.sv $R/soc/addr_decode.sv $R/soc/timer.sv $R/soc/irq_ctrl.sv $R/soc/uart.sv $R/soc/soc_core_top.sv"
iverilog -g2012 -DVCD_FILE=\"$OUTV\" -s core_int_tb -s vcd_dump -o /tmp/vcd_$$.vvp $SOC $CORE \
    tb/integration/core_int_tb.sv syn/power/vcd_dump.sv 2>/dev/null
vvp -n /tmp/vcd_$$.vvp | grep -E "CORE INTEGRATION|cycles"
rm -f /tmp/vcd_$$.vvp
