// csr_file.sv — RV32 CSR file: M-mode CSRs, M/S/U privilege mode, Sv32 satp.
`timescale 1ns/1ps
//
// Implemented CSRs:
//   0x180 satp     Sv32: MODE[31], ASID[30:22] (WARL, hardwired 0), PPN[21:0].
//                  Reset 0 (Bare). Exported as satp_o for the MMU; satp_wr_o
//                  pulses on the cycle a write commits (used as a TLB flush).
//                  Accessible from S and M (csr_addr[9:8] = 01).
//   0x300 mstatus  MIE[3], MPIE[7], MPP[12:11], MPRV[17], SUM[18], MXR[19].
//                  MPP is WARL over {U=00, S=01, M=11}; a write of 2'b10
//                  clamps to S (01). MPP resets to M.
//   0x301 misa     read-only RV32I + M + S + U (0x40141100); writes ignored
//
// Privilege mode (cur_priv, 00 U / 01 S / 11 M, reset M; exported):
//   trap : MPP <= cur_priv, cur_priv <= M (all traps go to M, no delegation)
//   MRET : cur_priv <= MPP, MPP <= U, MIE <= MPIE, MPIE <= 1,
//          MPRV <= 0 if the new mode is not M
//   CSR access with csr_addr[9:8] > cur_priv is illegal (csr_illegal).
//   0x304 mie      MSIE[3], MTIE[7], MEIE[11]
//   0x305 mtvec    BASE[31:2], MODE[1:0] (0=direct, 1=vectored; MODE[1] reads 0)
//   0x340 mscratch
//   0x341 mepc     bits[1:0] read as 0
//   0x342 mcause
//   0x343 mtval
//   0x344 mip      MSIP[3], MTIP[7], MEIP[11] (all driven by inputs, read-only)
//   0xB00/0xB80 mcycle/mcycleh, 0xB02/0xB82 minstret/minstreth (writable)
//   0xC00/0xC80 cycle/cycleh, 0xC02/0xC82 instret/instreth (read-only aliases)
//   0xF11-0xF13 mvendorid/marchid/mimpid (0), 0xF14 mhartid (HART_ID)
//
// CSR access port: the caller presents csr_op (instr funct3) for one valid
// cycle. Reads are combinational (old value); the write commits at the clock
// edge if csr_commit is high. csr_illegal flags an unknown CSR or a write to a
// read-only CSR (addr[11:10]==2'b11). CSRRS/CSRRC with rs1=x0 / uimm=0 do not
// write, so they may read read-only CSRs legally.
module csr_file #(
    parameter logic [31:0] HART_ID = 32'd0
) (
    input  logic        clk,
    input  logic        rst_n,
    // CSR instruction port
    input  logic        csr_valid,     // a CSR instruction is present
    input  logic        csr_commit,    // ... and it may update state this cycle
    input  logic [2:0]  csr_op,        // funct3: 1 RW,2 RS,3 RC,5 RWI,6 RSI,7 RCI
    input  logic [11:0] csr_addr,
    input  logic [31:0] csr_src,       // rs1 value or zero-extended uimm
    input  logic        csr_src_zero,  // rs1 field == 0 (x0 / uimm==0)
    output logic [31:0] csr_rdata,
    output logic        csr_illegal,
    // Trap / return port
    input  logic        trap_take,
    input  logic [31:0] trap_cause,
    input  logic [31:0] trap_epc,
    input  logic [31:0] trap_tval,
    input  logic        mret_take,
    input  logic        instret_inc,   // one instruction retired
    // Interrupt inputs (level)
    input  logic        mtip, msip, meip,
    // State outputs
    output logic [1:0]  cur_priv_o,    // current privilege mode
    output logic [1:0]  mpp_o,         // mstatus.MPP
    output logic        mprv_o, sum_o, mxr_o,
    output logic [31:0] mtvec_o,
    output logic [31:0] mepc_o,
    output logic        mstatus_mie_o,
    output logic [31:0] mie_o,
    output logic [31:0] mip_o,
    output logic [31:0] satp_o,        // Sv32 satp (MODE/ASID/PPN) for the MMU
    output logic        satp_wr_o      // satp written this cycle (TLB flush)
);
    localparam logic [31:0] MISA_VAL = 32'h4014_1100; // MXL=1, I, M, S, U

    logic        mie_bit, mpie_bit, mprv_bit, sum_bit, mxr_bit;
    logic [1:0]  mpp_r, cur_priv;
    localparam logic [1:0] PRIV_U = 2'b00, PRIV_S = 2'b01, PRIV_M = 2'b11;
    // MPP WARL: U/S/M legal, the reserved 2'b10 clamps to S
    function automatic logic [1:0] legal_mpp(input logic [1:0] v);
        legal_mpp = (v == 2'b10) ? PRIV_S : v;
    endfunction
    logic [31:0] mie_r, mtvec_r, mscratch_r, mepc_r, mcause_r, mtval_r;
    logic [63:0] mcycle_r, minstret_r;
    logic [31:0] mstatus_v, mip_v;

    assign mstatus_v = {12'b0, mxr_bit, sum_bit, mprv_bit, 4'b0, mpp_r, 3'b0, mpie_bit, 3'b0, mie_bit, 3'b0};
    assign mip_v     = {20'b0, meip, 3'b0, mtip, 3'b0, msip, 3'b0};
    localparam logic [31:0] MIE_MASK = 32'h0000_0888;
    // satp WARL mask: MODE[31] + PPN[21:0] writable, ASID[30:22] reads 0
    localparam logic [31:0] SATP_MASK = 32'h803F_FFFF;
    logic [31:0] satp_r;

    // ---- read mux ----
    logic known;
    always @(*) begin
        known = 1'b1;
        case (csr_addr)
            12'h180: csr_rdata = satp_r;
            12'h300: csr_rdata = mstatus_v;
            12'h301: csr_rdata = MISA_VAL;
            12'h304: csr_rdata = mie_r;
            12'h305: csr_rdata = mtvec_r;
            12'h340: csr_rdata = mscratch_r;
            12'h341: csr_rdata = mepc_r;
            12'h342: csr_rdata = mcause_r;
            12'h343: csr_rdata = mtval_r;
            12'h344: csr_rdata = mip_v;
            12'hB00, 12'hC00: csr_rdata = mcycle_r[31:0];
            12'hB80, 12'hC80: csr_rdata = mcycle_r[63:32];
            12'hB02, 12'hC02: csr_rdata = minstret_r[31:0];
            12'hB82, 12'hC82: csr_rdata = minstret_r[63:32];
            12'hF11, 12'hF12, 12'hF13: csr_rdata = 32'b0;
            12'hF14: csr_rdata = HART_ID;
            default: begin csr_rdata = 32'b0; known = 1'b0; end
        endcase
    end

    // ---- write data / legality ----
    logic        do_write;
    logic [31:0] wval;
    always @(*) begin
        // CSRRW/CSRRWI always write; CSRRS/CSRRC (and imm forms) only if src != x0/0
        do_write = (csr_op[1:0] == 2'b01) ? 1'b1 : !csr_src_zero;
        case (csr_op[1:0])
            2'b01:   wval = csr_src;
            2'b10:   wval = csr_rdata | csr_src;
            2'b11:   wval = csr_rdata & ~csr_src;
            default: wval = csr_rdata;
        endcase
        csr_illegal = csr_valid && (!known || (csr_op[1:0] == 2'b00) ||
                                    (do_write && csr_addr[11:10] == 2'b11) ||
                                    (csr_addr[9:8] > cur_priv));
    end

    wire wr = csr_valid && csr_commit && !csr_illegal && do_write;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mie_bit <= 1'b0; mpie_bit <= 1'b0;
            mprv_bit <= 1'b0; sum_bit <= 1'b0; mxr_bit <= 1'b0;
            mpp_r <= PRIV_M; cur_priv <= PRIV_M;
            mie_r <= 0; mtvec_r <= 0; mscratch_r <= 0; mepc_r <= 0;
            mcause_r <= 0; mtval_r <= 0; mcycle_r <= 0; minstret_r <= 0;
            satp_r <= 32'b0;
        end else begin
            mcycle_r <= mcycle_r + 64'd1;
            if (instret_inc) minstret_r <= minstret_r + 64'd1;

            if (trap_take) begin
                mepc_r   <= {trap_epc[31:2], 2'b00};
                mcause_r <= trap_cause;
                mtval_r  <= trap_tval;
                mpie_bit <= mie_bit;
                mie_bit  <= 1'b0;
                mpp_r    <= cur_priv;
                cur_priv <= PRIV_M;
            end else if (mret_take) begin
                mie_bit  <= mpie_bit;
                mpie_bit <= 1'b1;
                cur_priv <= mpp_r;
                mpp_r    <= PRIV_U;
                if (mpp_r != PRIV_M) mprv_bit <= 1'b0;
            end else if (wr) begin
                case (csr_addr)
                    12'h180: satp_r     <= wval & SATP_MASK;
                    12'h300: begin
                        mie_bit <= wval[3]; mpie_bit <= wval[7];
                        mpp_r <= legal_mpp(wval[12:11]);
                        mprv_bit <= wval[17]; sum_bit <= wval[18]; mxr_bit <= wval[19];
                    end
                    12'h304: mie_r      <= wval & MIE_MASK;
                    12'h305: mtvec_r    <= {wval[31:2], 1'b0, wval[0]};
                    12'h340: mscratch_r <= wval;
                    12'h341: mepc_r     <= {wval[31:2], 2'b00};
                    12'h342: mcause_r   <= wval;
                    12'h343: mtval_r    <= wval;
                    12'hB00: mcycle_r[31:0]    <= wval;
                    12'hB80: mcycle_r[63:32]   <= wval;
                    12'hB02: minstret_r[31:0]  <= wval;
                    12'hB82: minstret_r[63:32] <= wval;
                    default: ; // misa / mip: WARL, writes ignored
                endcase
            end
        end
    end

    assign mtvec_o       = mtvec_r;
    assign mepc_o        = mepc_r;
    assign mstatus_mie_o = mie_bit;
    assign cur_priv_o    = cur_priv;
    assign mpp_o         = mpp_r;
    assign mprv_o        = mprv_bit;
    assign sum_o         = sum_bit;
    assign mxr_o         = mxr_bit;
    assign mie_o         = mie_r;
    assign mip_o         = mip_v;
    assign satp_o        = satp_r;
    // Same condition as the satp_r update above (a trap/mret suppresses it).
    assign satp_wr_o     = wr && !trap_take && !mret_take && (csr_addr == 12'h180);
endmodule
