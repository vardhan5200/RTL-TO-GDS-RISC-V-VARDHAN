# Post-placement / post-CTS STA + power summary for the quick PPA run.
#   make -C <ORFS>/flow DESIGN_CONFIG=.../config.mk FLOW_VARIANT=base \
#        WORK_HOME=... RUN_SCRIPT=$PWD/flow/sky130hd/ppa_report.tcl \
#        PPA_STAGE=4_cts run          (PPA_STAGE: 3_place or 4_cts)
# Parasitics: placement-based estimate (estimate_parasitics -placement), no routing.
# Power: OpenSTA default activity (inputs 0.1 toggles/cycle, propagated), no VCD/SAIF.
source $::env(SCRIPTS_DIR)/load.tcl
set stage [expr {[info exists ::env(PPA_STAGE)] ? $::env(PPA_STAGE) : "4_cts"}]
load_design $stage.odb $stage.sdc
if { $stage == "4_cts" } { set_propagated_clock [all_clocks] }
estimate_parasitics -placement

puts "=== PPA stage $stage ==="
report_design_area
puts "die_area_um  [ord::get_die_area]"
puts "core_area_um [ord::get_core_area]"
report_tns
report_wns
report_worst_slack -max
report_worst_slack -min
report_clock_min_period
report_checks -path_delay max -group_path_count 1 -format full_clock_expanded \
    -fields {slew cap input_pins fanout} -digits 3
report_checks -path_delay max -group_path_count 1 -from [all_inputs] -digits 3
report_checks -path_delay max -group_path_count 1 -to [all_outputs] -digits 3
puts "--- worst register-to-register path ---"
report_checks -path_delay max -group_path_count 1 \
    -from [all_registers -clock_pins] -to [all_registers -data_pins] -digits 3
puts "--- worst input-to-output (combinational feed-through) path ---"
report_checks -path_delay max -group_path_count 1 -from [all_inputs] -to [all_outputs] -digits 3
report_check_types -max_slew -max_capacitance -max_fanout -violators
puts "--- check_setup (unconstrained endpoints, loops, latches) ---"
check_setup -verbose -unconstrained_endpoints -multiple_clock -no_clock -loops -generated_clocks
puts "--- power (default activity) ---"
report_power
report_cell_usage -verbose
