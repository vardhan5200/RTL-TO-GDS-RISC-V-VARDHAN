#!/usr/bin/env bash
# PPA flow for the integrated core: Yosys (sky130_fd_sc_hd, abc) + OpenSTA.
# Usage: syn/synth_core.sh <outdir> [USE_MMU=0|1]
# Needs: yosys, sta (OpenSTA), LIB=path to sky130_fd_sc_hd__tt_025C_1v80.lib
set -eu
cd "$(dirname "$0")/.."
OUT=${1:-/tmp/syn}; MMU=${2:-0}; mkdir -p "$OUT"
LIB=${LIB:-/workspace/pdk/hd_tt.lib}
PERIOD_NS=${PERIOD_NS:-10.0}            # docs/architecture.md: 10 ns target
SRC="rtl/cpu/decoder.sv rtl/cpu/imm_gen.sv rtl/cpu/alu.sv rtl/cpu/branch_unit.sv rtl/cpu/mul.sv
     rtl/cpu/div.sv rtl/cpu/div_unit.sv rtl/cache/dm_cache.sv rtl/priv/csr_file.sv
     rtl/priv/priv_unit.sv rtl/mmu/sv32_tlb.sv rtl/mmu/sv32_ptw.sv rtl/mmu/sv32_perm_check.sv
     rtl/mmu/sv32_mmu.sv rtl/core/core_top.sv"
PS=$(python3 -c "print(int(float('$PERIOD_NS')*1000))")
# ORFS-style ABC script: delay-driven mapping + buffering + gate sizing
cat > "$OUT/abc.constr" <<C
set_driving_cell sky130_fd_sc_hd__inv_2
set_load 0.01
C
cat > "$OUT/abc.script" <<A
strash; dch; map -B 0.9; topo; stime -c; buffer -c; upsize -c; dnsize -c; stime -p
A
cat > "$OUT/synth.ys" <<YS
read_verilog -sv -DSYNTHESIS $(echo $SRC)
chparam -set USE_MMU $MMU core_top
hierarchy -check -top core_top
synth -flatten -top core_top
dfflibmap -liberty $LIB
abc -D $PS -constr $OUT/abc.constr -script $OUT/abc.script -liberty $LIB
autoname
setundef -zero
splitnets
opt_clean -purge
hilomap -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO
stat -liberty $LIB
write_verilog -noattr -noexpr $OUT/core_top_net.v
YS
yosys -q -l "$OUT/yosys.log" -s "$OUT/synth.ys" >/dev/null
cat > "$OUT/sta.tcl" <<TCL
read_liberty $LIB
read_verilog $OUT/core_top_net.v
link_design core_top
create_clock -name clk -period $PERIOD_NS [get_ports clk]
set_input_delay  0 -clock clk [delete_from_list [all_inputs] [get_ports {clk rst_n}]]
set_output_delay 0 -clock clk [all_outputs]
set_load 0.01 [all_outputs]
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 [delete_from_list [all_inputs] [get_ports clk]]
puts "=== reg2reg / all worst paths"
report_checks -path_delay max -group_count 1 -fields {fanout} -digits 3
puts "=== reg-to-reg only"
report_checks -path_delay max -from [all_registers -clock_pins] -to [all_registers -data_pins] -digits 3
puts "=== top 10 endpoints"
report_checks -path_delay max -group_count 10 -endpoint_count 1 -format end -digits 3
report_tns
report_wns
puts "=== pipeline groups"
source syn/pipe_paths.tcl
catch {set_power_activity -global -activity 0.1; report_power} msg
puts \$msg
exit
TCL
sta -no_splash "$OUT/sta.tcl" > "$OUT/sta.log" 2>&1 || true
grep -E "Chip area|Number of cells" "$OUT/yosys.log" | tail -2
grep -E "^(wns|tns)" "$OUT/sta.log"; grep -E "^Total" "$OUT/sta.log"
awk '/=== pipeline groups/{f=1} f' "$OUT/sta.log" > "$OUT/pipe_paths.log"; syn/summarize.sh "$OUT/pipe_paths.log"
