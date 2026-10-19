// div.sv — 32-bit unsigned restoring divider (one quotient bit per cycle).
//   start (1-cycle pulse while idle) latches dividend/divisor; 32 iteration
//   cycles later `done` pulses for one cycle with quotient/remainder valid
//   (they stay registered until the next start). Latency: done is seen 33
//   clock edges after the start edge.
// Divide-by-zero falls out of restoring division as the RISC-V spec wants:
//   quotient = 0xFFFF_FFFF, remainder = dividend.
// Signed DIV/REM handling lives in div_unit.sv (sign fix-up around this core).
module div (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic [31:0] dividend,
    input  logic [31:0] divisor,
    output logic [31:0] quotient,
    output logic [31:0] remainder,
    output logic        done
);
    logic [31:0] quot, rem, d;
    logic [4:0]  cnt;
    logic        running;
    logic [32:0] trial;   // {rem, next dividend bit} - divisor
    logic [31:0] rem_sh;

    assign rem_sh = {rem[30:0], quot[31]};
    assign trial  = {rem[31], rem_sh} - {1'b0, d};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running <= 0; done <= 0; cnt <= 0;
            quot <= 0; rem <= 0; d <= 0;
            quotient <= 0; remainder <= 0;
        end else begin
            done <= 0;
            if (start && !running) begin
                quot    <= dividend;
                rem     <= 0;
                d       <= divisor;
                cnt     <= 0;
                running <= 1;
            end else if (running) begin
                logic [31:0] nrem, nquot;
                if (!trial[32]) begin nrem = trial[31:0]; nquot = {quot[30:0], 1'b1}; end
                else            begin nrem = rem_sh;      nquot = {quot[30:0], 1'b0}; end
                rem  <= nrem;
                quot <= nquot;
                cnt  <= cnt + 1;
                if (cnt == 5'd31) begin
                    running   <= 0;
                    done      <= 1;
                    quotient  <= nquot;
                    remainder <= nrem;
                end
            end
        end
    end
endmodule
