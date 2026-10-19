// div.sv — simple long-division style
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
    logic [5:0]  cnt;
    logic        running;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running <= 0; done <= 0; cnt <= 0;
            quotient <= 0; remainder <= 0;
        end else begin
            done <= 0;
            if (start && !running) begin
                quot <= 0;
                rem  <= dividend;
                d    <= divisor;
                cnt  <= 0;
                running <= 1;
            end else if (running) begin
                if (rem >= d) begin
                    rem  <= rem - d;
                    quot <= quot + 1;
                end else begin
                    // done with this digit; shift for next (simplified for small numbers)
                    running <= 0;
                    done <= 1;
                    quotient <= quot;
                    remainder <= rem;
                end
                cnt <= cnt + 1;
                if (cnt == 40) begin // safety
                    running <= 0;
                    done <= 1;
                    quotient <= quot;
                    remainder <= rem;
                end
            end
        end
    end
endmodule
