// sv32_perm_check.sv — Sv32 leaf-PTE permission check (combinational)
// Shared by the TLB-hit path (sv32_mmu) and the walker (sv32_ptw) so both
// apply exactly the same rules.
//
// perm = PTE[7:0] = {D, A, G, U, X, W, R, V}
// acc  : 2'd0 = load, 2'd1 = store, 2'd2 = fetch
// priv : 2'b00 = U, 2'b01 = S (M-mode never reaches here: MMU is bare in M)
//
// A/D policy: no hardware update. A=0 always faults, store with D=0 faults.
// Software must pre-set A (and D for writable pages).

module sv32_perm_check (
    input  logic [7:0] perm,
    input  logic [1:0] acc,
    input  logic [1:0] priv,
    input  logic       sum,
    input  logic       mxr,
    output logic       ok
);
    logic p_r, p_w, p_x, p_u, p_a, p_d;
    logic type_ok, priv_ok, ad_ok;

    assign p_r = perm[1];
    assign p_w = perm[2];
    assign p_x = perm[3];
    assign p_u = perm[4];
    assign p_a = perm[6];
    assign p_d = perm[7];

    always_comb begin
        // access-type permission
        case (acc)
            2'd0:    type_ok = p_r | (mxr & p_x);   // load
            2'd1:    type_ok = p_w;                 // store
            2'd2:    type_ok = p_x;                 // fetch
            default: type_ok = 1'b0;
        endcase

        // privilege
        if (priv == 2'b00)
            priv_ok = p_u;                          // U-mode needs U=1
        else if (p_u)
            priv_ok = (acc != 2'd2) & sum;          // S on U page: data only, needs SUM
        else
            priv_ok = 1'b1;

        // accessed / dirty (no HW update)
        ad_ok = p_a & ((acc != 2'd1) | p_d);

        ok = type_ok & priv_ok & ad_ok;
    end
endmodule
