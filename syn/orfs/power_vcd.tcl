# Post-CTS power with switching activity from an RTL VCD of core_int_tb
# (registers/ports annotated by name, activity propagated to the rest).
source $::env(SCRIPTS_DIR)/load.tcl
load_design 4_cts.odb 4_cts.sdc
set_propagated_clock [all_clocks]
estimate_parasitics -placement
read_vcd -scope core_int_tb/dut/core $::env(VCD)
puts "=== VCD power ($::env(VCD)) ==="
report_power
