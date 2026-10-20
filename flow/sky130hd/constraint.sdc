# 50 MHz target for the integrated core on sky130hd.
current_design core_top
set clk_name   core_clock
set clk_port   [get_ports clk]
set clk_period 20.0
set clk_io_pct 0.2

create_clock -name $clk_name -period $clk_period $clk_port

set non_clock_inputs [all_inputs -no_clocks]
set_input_delay  [expr $clk_period * $clk_io_pct] -clock $clk_name $non_clock_inputs
set_output_delay [expr $clk_period * $clk_io_pct] -clock $clk_name [all_outputs]
