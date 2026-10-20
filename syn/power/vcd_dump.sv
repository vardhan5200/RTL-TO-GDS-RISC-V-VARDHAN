// Extra simulation top: dumps the integrated core of core_int_tb to a VCD
// for activity-annotated power (OpenROAD read_vcd -scope core_int_tb/dut/core).
module vcd_dump;
    initial begin
        $dumpfile(`ifdef VCD_FILE `VCD_FILE `else "core_int.vcd" `endif);
        $dumpvars(0, core_int_tb.dut.core);
    end
endmodule
