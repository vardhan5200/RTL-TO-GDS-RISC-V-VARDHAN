// mul.sv — shift-and-add multiplier (low 32 bits of a*b), 32 iterations.
//   start (while idle) latches a/b; done pulses one cycle after the 32nd
//   iteration. `result` is the accumulator itself: it is only meaningful on
//   and after the done cycle and is held until the next start (consumers
//   sample it on done). All datapath flops are enable-gated (update only on
//   start or while running), so the unit does not toggle when idle.
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
    logic [4:0]  cnt;          // 0..31
    logic        running;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running <= 0;
            done    <= 0;
            acc     <= 0;
            cnt     <= 0;
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
                if (cnt == 5'd31) begin
                    running <= 0;
                    done    <= 1;
                end
            end
        end
    end
    assign result = acc;
endmodule
