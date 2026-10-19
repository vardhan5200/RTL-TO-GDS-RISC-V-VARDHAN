// dm_cache_tb.sv — clean expected values
`timescale 1ns/1ps
module dm_cache_tb;
    logic clk=0, rst_n=0;
    always #5 clk = ~clk;

    logic req_valid, req_ready, resp_valid, mem_re;
    logic [31:0] req_addr, resp_rdata, mem_addr, mem_rdata;

    logic [31:0] backing[0:255];
    initial for (int i=0; i<256; i++) backing[i] = i;  // word i contains i

    dm_cache dut (.*);
    assign mem_rdata = backing[mem_addr[9:2]];

    initial begin
        rst_n = 0; req_valid = 0;
        #20 rst_n = 1;

        // miss
        req_valid = 1; req_addr = 0;
        @(posedge clk);
        wait (resp_valid);
        $display("miss  read 0 = %0d (exp 0)", resp_rdata);
        req_valid = 0; @(posedge clk);

        // hit
        req_valid = 1; req_addr = 0;
        @(posedge clk);
        wait (resp_valid);
        $display("hit   read 0 = %0d (exp 0)", resp_rdata);
        req_valid = 0; @(posedge clk);

        // same line, next word
        req_valid = 1; req_addr = 4;
        @(posedge clk);
        wait (resp_valid);
        $display("hit   read 4 = %0d (exp 1)", resp_rdata);
        req_valid = 0;

        $display("DONE");
        $finish;
    end
endmodule
