# Apply per-net activity (from vcd2activity.py) to the driver pin of each
# matching net, then report power. Unmatched nets keep propagated activity.
source $::env(SCRIPTS_DIR)/load.tcl
load_design 4_cts.odb 4_cts.sdc
set_propagated_clock [all_clocks]
estimate_parasitics -placement
set ::n_ok 0; set ::n_miss 0
proc act {net a d} {
  # skip clk (CTS-propagated) and rst_n (async)
  if {$net == "clk" || $net == "rst_n"} { return }
  set n [get_nets -quiet $net]
  if {$n == ""} { incr ::n_miss; return }
  set drv [get_pins -quiet -of_objects $n -filter "direction == output"]
  if {$drv == ""} { incr ::n_miss; return }
  if {[catch {set_power_activity -pins $drv -activity $a -duty $d}]} { incr ::n_miss; return }
  incr ::n_ok
}
if {[catch {source $::env(ACT_TCL)} err]} { puts "ACT ERROR: $err" }
puts "=== activity-annotated power: $::n_ok nets annotated, $::n_miss unmatched ($::env(ACT_TCL)) ==="
report_power
