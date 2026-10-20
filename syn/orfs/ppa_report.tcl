# Post-CTS (or post-place) PPA summary for the integrated core.
# Parasitics: placement-based estimate (no routing).
# Power: OpenSTA default (vectorless) activity; for VCD-based power use
# power_only.sh / power_act.sh.
# Env: PPA_STAGE (3_place | 4_cts, default 4_cts), PIPE_PATHS_TCL (optional,
# per-register-group worst paths, see pipe_paths_orfs.tcl).
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
puts "--- worst register-to-register path ---"
report_checks -path_delay max -group_path_count 1 \
    -from [all_registers -clock_pins] -to [all_registers -data_pins] -digits 3
puts "--- worst input -> register / register -> output / input -> output paths ---"
report_checks -path_delay max -group_path_count 1 -from [all_inputs] -to [all_registers -data_pins] -digits 3
report_checks -path_delay max -group_path_count 1 -to [all_outputs] -digits 3
report_checks -path_delay max -group_path_count 1 -from [all_inputs] -to [all_outputs] -digits 3
puts "--- slew / cap / fanout violators ---"
report_check_types -max_slew -max_capacitance -max_fanout -violators
puts "--- check_setup (unconstrained endpoints, loops, missing clocks) ---"
check_setup -verbose -unconstrained_endpoints -multiple_clock -no_clock -loops -generated_clocks
if { [info exists ::env(PIPE_PATHS_TCL)] && $::env(PIPE_PATHS_TCL) != "" } {
  puts "--- pipeline groups ---"
  source $::env(PIPE_PATHS_TCL)
}
puts "--- power (default activity) ---"
report_power
report_cell_usage -verbose
