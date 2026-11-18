//---------------------------------------------------------------------------
// OOO_PTW.sv
//
// The Sv39 page table walker of the OoO core (step 1.8 V1, Plan/OOC.md 29.87):
// mmRISC-2's MMU_PTW (Rev.02, CPU_MMU/MMU_PTW) on OOO_LSU4's walk port.
//
//   OOO_LSU4's port 0 asks in W (tlb_miss, the page, the asker's id) for a µop
//   in flight, speculative or not; the asker waits and is tried again at an
//   event. One walk at a time: an ask while a walk is on is dropped (the walk's
//   end is an event, and the asker asks again then, as a full miss queue does).
//   Each level's entry is read through the D$'s miss handler (pt_*: OOO_DMISS2
//   reads it from the D$, filling the line if it is not there), so the tables are
//   cached and see every store the D$ has; SFENCE.VMA drains the SQ first.
//
//   As MMU_PTW, the walk checks no permission and sets no A or D bit (Svade): it
//   decides whether the leaf is well formed, and gives its U, R, W (with D), X to
//   the DTLBs (OOO_DTLB3 checks them at the lookup). A page fault (as Spike's
//   walk): an entry not valid, W without R, a bit of 63:54 (no Svnapot, no
//   Svpbmt), a pointer with D, A or U, no leaf at level 0, a superpage not
//   aligned, a leaf not accessed (A). It is written as an entry with no
//   permission. An access fault: an entry's address outside the cacheable memory
//   [CBASE, CTOP) (no PMP yet: step P1), or a leaf whose page is beyond PAW bits;
//   written with AF. A larger page is written as the 4 KB of it asked for.
//
//   The answer (tlb_done with tlb_we and done_id for the asker's first try) waits
//   for a cycle without the miss handler's fill_done (hold): both name an asker on
//   OOO_LSU4's one done_id.
//
//   cancel (a flush of the TLBs: SFENCE.VMA, a write of satp; or a recovery of
//   everything) ends a walk at once with no write: what it read may be stale, and
//   its asker is gone. A read still out is waited for and dropped.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_PTW
    #(
        parameter int PAW = 40,
        parameter int VA  = 39,
        parameter int IW  = 5,                                 // the askers' ids
        parameter logic [PAW-1:0] CBASE = 40'h00_8000_0000,   // the cacheable memory: [CBASE, CTOP)
        parameter logic [PAW-1:0] CTOP  = 40'h01_0000_0000
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,

        // ---- OOO_LSU4's ask
        input  logic                  req,
        input  logic [VA-1:12]        req_vpn,
        input  logic [IW-1:0]         req_id,
        input  logic [43:0]           satp_ppn,     // the root table
        input  logic                  cancel,
        output logic                  busy,

        // ---- an entry read through the D$'s miss handler
        output logic                  pt_req,       // one cycle; the answer comes later, one at a time
        output logic [PAW-1:3]        pt_addr,
        input  logic                  pt_done,
        input  logic [63:0]           pt_data,

        // ---- the answer, into both DTLBs
        input  logic                  hold,         // the miss handler's fill_done this cycle
        output logic                  tlb_done,
        output logic [IW-1:0]         done_id,
        output logic                  tlb_we,
        output logic [VA-1:12]        tlb_vpn,
        output logic [PAW-1:12]       tlb_ptag,
        output logic                  tlb_u,
        output logic                  tlb_r,
        output logic                  tlb_w,        // W and D
        output logic                  tlb_x,
        output logic                  tlb_af
    );

    typedef enum logic [2:0] { S_IDLE, S_REQ, S_WAIT, S_DONE, S_DROP } st_t;
    st_t          st;
    logic [43:0]  table_ppn;
    logic [1:0]   lvl;
    logic [26:0]  vpn_r;
    logic [IW-1:0] id_r;
    logic         r_u, r_r, r_w, r_x, r_af;
    logic [PAW-1:12] r_ptag;

    // the entry's address at this level
    logic [8:0]  vpn_sel;
    logic [55:0] e_addr;
    always @(*) begin
        case (lvl)
            2'd2:    vpn_sel = vpn_r[26:18];
            2'd1:    vpn_sel = vpn_r[17:9];
            default: vpn_sel = vpn_r[8:0];
        endcase
        e_addr = {table_ppn, vpn_sel, 3'd0};
    end
    logic e_bad;                                // outside what can be read: an access fault
    assign e_bad = e_addr[55:PAW] != '0 || e_addr[PAW-1:0] < CBASE || e_addr[PAW-1:0] >= CTOP;

    // the entry read
    /* verilator lint_off UNUSEDSIGNAL */      // (RSW and G mean nothing here)
    logic [63:0] pte;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [43:0] pte_ppn;
    logic        pte_leaf, pte_bad, mis, beyond;
    assign pte      = pt_data;
    assign pte_ppn  = pte[53:10];
    assign pte_leaf = pte[1] || pte[3];
    // not valid, W without R, 63:54 reserved; a pointer with D, A or U
    assign pte_bad  = !pte[0] || (pte[2] && !pte[1]) || pte[63:54] != '0 || (!pte_leaf && pte[7:6] != 2'd0) || (!pte_leaf && pte[4]);
    always @(*) begin
        case (lvl)
            2'd2:    mis = pte_ppn[17:0] != '0;
            2'd1:    mis = pte_ppn[8:0] != '0;
            default: mis = 1'b0;
        endcase
    end
    assign beyond = pte_ppn[43:PAW-12] != '0;
    // the 4 KB page asked for, of a superpage
    /* verilator lint_off UNUSEDSIGNAL */      // (above PAW: beyond, an access fault)
    logic [43:0] leaf_ppn;
    /* verilator lint_on UNUSEDSIGNAL */
    always @(*) begin
        case (lvl)
            2'd2:    leaf_ppn = {pte_ppn[43:18], vpn_r[17:0]};
            2'd1:    leaf_ppn = {pte_ppn[43:9], vpn_r[8:0]};
            default: leaf_ppn = pte_ppn;
        endcase
    end

    assign busy     = st != S_IDLE;
    assign pt_req   = st == S_REQ && !cancel && !e_bad;
    assign pt_addr  = e_addr[PAW-1:3];
    assign tlb_done = st == S_DONE && !hold && !cancel;
    assign tlb_we   = tlb_done;
    assign done_id  = id_r;
    assign tlb_vpn  = vpn_r[VA-13:0];
    assign tlb_ptag = r_ptag;
    assign tlb_u    = r_u;
    assign tlb_r    = r_r;
    assign tlb_w    = r_w;
    assign tlb_x    = r_x;
    assign tlb_af   = r_af;

    // a fault: an entry with no permission (and AF for an access fault)
    task automatic fault(input logic acc);
        r_u <= 1'b0; r_r <= 1'b0; r_w <= 1'b0; r_x <= 1'b0; r_af <= acc;
        r_ptag <= '0;
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) st <= S_IDLE;
        else begin
            case (st)
                S_IDLE:  if (req && !cancel) st <= S_REQ;
                S_REQ:   st <= cancel ? S_IDLE : e_bad ? S_DONE : S_WAIT;
                S_WAIT:  if (pt_done) st <= cancel ? S_IDLE : (pte_bad || pte_leaf || lvl == 2'd0) ? S_DONE : S_REQ;
                         else if (cancel) st <= S_DROP;
                S_DONE:  if (cancel || !hold) st <= S_IDLE;
                default: if (pt_done) st <= S_IDLE;     // S_DROP: the read still out, dropped
            endcase
        end
    end
    always_ff @(posedge clk) begin
        case (st)
            S_IDLE: begin
                table_ppn <= satp_ppn;
                lvl       <= 2'd2;
                vpn_r     <= 27'(req_vpn);
                id_r      <= req_id;
            end
            S_REQ: if (e_bad) fault(1'b1);
            S_WAIT: if (pt_done) begin
                if (pte_bad)                                fault(1'b0);
                else if (pte_leaf) begin
                    if (mis || !pte[6])                     fault(1'b0);     // a superpage not aligned; not accessed
                    else if (beyond)                        fault(1'b1);
                    else begin
                        r_u <= pte[4]; r_r <= pte[1]; r_w <= pte[2] && pte[7]; r_x <= pte[3]; r_af <= 1'b0;
                        r_ptag <= leaf_ppn[PAW-13:0];
                    end
                end
                else if (lvl == 2'd0)                       fault(1'b0);     // no leaf at the bottom
                else begin
                    table_ppn <= pte_ppn;
                    lvl       <= lvl - 2'd1;
                end
            end
            default: ;
        endcase
    end

endmodule : OOO_PTW
