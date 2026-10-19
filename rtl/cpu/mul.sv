// mul.sv — corrected shift-and-add
module mul (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] result,
    output logic        done
);
    logic [31:0] multiplicand, multiplier, acc;
    logic [5:0]  cnt;
    logic        running;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running <= 0;
            done    <= 0;
            acc     <= 0;
            cnt     <= 0;
            result  <= 0;
        end else begin
            done <= 0;
            if (start && !running) begin
                multiplicand <= a;
                multiplier   <= b;
                acc          <= 0;
                cnt          <= 0;
                running      <= 1;
            end else if (running) begin
                if (multiplier[0])
                    acc <= acc + multiplicand;
                multiplier   <= multiplier >> 1;
                multiplicand <= multiplicand << 1;
                cnt <= cnt + 1;
                if (cnt == 6'd31) begin
                    running <= 0;
                    done    <= 1;
                    result  <= multiplier[0] ? (acc + multiplicand) : acc;
                end
            end
        end
    end
endmodule
