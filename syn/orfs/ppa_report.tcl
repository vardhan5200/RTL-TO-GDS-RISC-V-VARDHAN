# Post-CTS PPA summary (placement-estimated parasitics, default activity power)
source $::env(SCRIPTS_DIR)/load.tcl
set stage [expr {[info exists ::env(PPA_STAGE)] ? $::env(PPA_STAGE) : "4_cts"}]
load_design $stage.odb $stage.sdc
if { $stage == "4_cts" } { set_propagated_clock [all_clocks] }
estimate_parasitics -placement
puts "=== PPA stage $stage ==="
report_design_area
report_tns
report_wns
report_worst_slack -max
report_clock_min_period
puts "--- worst register-to-register path ---"
report_checks -path_delay max -group_path_count 1 \
    -from [all_registers -clock_pins] -to [all_registers -data_pins] -digits 3
puts "--- pipeline groups ---"
source $::env(PIPE_PATHS_TCL)
puts "--- power (default activity) ---"
report_power
