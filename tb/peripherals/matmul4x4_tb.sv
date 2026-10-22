// matmul4x4_tb.sv — unit test: random + corner-case 4x4 signed matrices
// against a TB-computed reference (32-bit wrap), register read-back,
// BUSY/DONE/CYCLES, writes ignored while busy.
`timescale 1ns/1ps
module matmul4x4_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic sel = 0, we = 0; logic [7:0] addr = 0; logic [31:0] wdata = 0, rdata; logic done_o;
    matmul4x4 dut (.clk, .rst_n, .sel, .we, .addr, .wdata, .rdata, .done_o);

    int errors = 0, checks = 0;
    task automatic wr(logic [7:0] a, logic [31:0] d);
        @(negedge clk); sel = 1; we = 1; addr = a; wdata = d;
        @(negedge clk); sel = 0; we = 0;
    endtask
    task automatic rd(logic [7:0] a, output logic [31:0] d);
        @(negedge clk); sel = 1; addr = a; #1 d = rdata; @(negedge clk); sel = 0;
    endtask

    logic signed [15:0] A [0:15], B [0:15];
    logic signed [31:0] R [0:15];
    task automatic reference();
        for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) begin
            logic signed [31:0] s; s = 0;
            for (int k = 0; k < 4; k++) s = s + 32'(A[4*r+k]) * 32'(B[4*k+c]);
            R[4*r+c] = s;
        end
    endtask

    task automatic run(string name);
        logic [31:0] v; int bad, polls;
        for (int n = 0; n < 16; n++) begin wr(8'h00 + 4*n, 32'(A[n])); wr(8'h40 + 4*n, 32'(B[n])); end
        for (int n = 0; n < 16; n++) begin
            rd(8'h00 + 4*n, v); if (v !== 32'(A[n])) begin errors++; $display("  FAIL %s A[%0d] readback %08h", name, n, v); end
        end
        reference();
        wr(8'hC0, 1);
        rd(8'hC4, v); if (v[0] !== 1'b1) begin errors++; $display("  FAIL %s BUSY not set", name); end
        wr(8'h00, 32'h1234);                                   // ignored while busy
        polls = 0;
        do begin rd(8'hC4, v); polls++; end while (!v[1] && polls < 200);
        bad = 0;
        for (int n = 0; n < 16; n++) begin
            rd(8'h80 + 4*n, v); checks++;
            if (v !== R[n]) begin bad++; $display("  FAIL %s C[%0d][%0d] got %0d exp %0d", name, n/4, n%4, $signed(v), R[n]); end
        end
        rd(8'h00, v); if (v !== 32'(A[0])) begin bad++; $display("  FAIL %s A write during BUSY not ignored", name); end
        rd(8'hC4, v); if (v !== 32'h2) begin bad++; $display("  FAIL %s STATUS %08h", name, v); end
        rd(8'hC8, v);
        errors += bad;
        $display("  %s %-28s 16 results, CYCLES=%0d, C[0][0]=%0d C[3][3]=%0d",
                 bad ? "FAIL" : "ok  ", name, v, R[0], R[15]);
    endtask

    initial begin
        #22 rst_n = 1;
        $display("matmul4x4_tb");
        // 1) small known values incl. negatives
        for (int n = 0; n < 16; n++) begin A[n] = n - 8; B[n] = (n % 3 == 0) ? -n : n + 1; end
        run("small mixed-sign");
        // 2) identity x M == M
        for (int n = 0; n < 16; n++) begin A[n] = (n % 5 == 0) ? 1 : 0; B[n] = 1000 * n - 7000; end
        run("identity");
        // 3) extremes (wraps at 32 bits)
        for (int n = 0; n < 16; n++) begin A[n] = (n & 1) ? 16'sh7FFF : -16'sh8000; B[n] = -16'sh8000; end
        run("extremes +-32767/-32768");
        // 4) random
        for (int t = 0; t < 5; t++) begin
            for (int n = 0; n < 16; n++) begin A[n] = $random; B[n] = $random; end
            run($sformatf("random #%0d", t));
        end
        if (errors == 0) $display("MATMUL4X4 TEST: PASS (%0d results checked)", checks);
        else             $display("MATMUL4X4 TEST: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
