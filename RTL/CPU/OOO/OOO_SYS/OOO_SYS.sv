//---------------------------------------------------------------------------
// OOO_SYS.sv
//
// The system µops of mmRISC-3 that act on the rest of the core (Doc/UARCH.md
// 3.9, Plan/OOC.md 22). They are non-speculative: issued (sys_*, behind port
// 0) only at the ROB head, so nothing older is left and nothing younger has
// committed; one at a time. CSR reads and writes are the CSRs' (mmRISC-2's
// CORE_CSR at the assembly).
//
//   FENCE       waits until every committed store is in the D$
//               (sq_drained): a store to a device before the fence reaches
//               it before an access after (MMIO loads run at the head)
//   FENCE.I     the same, then FLUSH of the D$ (the dirty lines to memory,
//               through OOO_DCAD), then the I$ invalidated (ic_flush until
//               ic_done), as mmRISC-2 does; completes marked for replay, so
//               what follows is fetched again from the new I$. The
//               predictors are not cleared: predecode reads the targets of
//               branches and jal from the instructions themselves, and a
//               stale uBTB / BTB entry costs a misprediction, not a wrong
//               instruction
//   SFENCE.VMA  waits for the stores (page tables), tlb_flush (the TLBs of
//               Phase 2), completes marked for replay (fetch translates
//               again)
//   MRET, SRET  x_ret (x_sret) (OOO_TRAP: its replay fetches from mepc /
//               sepc and updates mstatus and the level), completes marked
//               for replay
// Privilege (CORE_CSR: the level, mstatus.TW / TSR / TVM): MRET below M,
// SRET in U or in S with TSR, SFENCE.VMA in U or in S with TVM, WFI below M
// with TW are illegal instructions: they complete with that exception and
// the instruction bits as tval (tv_*), doing nothing.
//   WFI         completes when an interrupt is pending and enabled in mie
//               (wfi_wake, whatever mstatus.MIE says); the interrupt is
//               then taken before the next µop (OOO_TRAP)
//
// The completion goes out a cycle after the last step (cmp_*). flush
// (OOO_CTRL flush_all) abandons a µop in progress; it does not happen while
// one runs (nothing older can trap or replay, and no interrupt is taken
// while the head's non-speculative µop has issued).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_SYS
    #(
        parameter int ROBW = 5
    )
    (
        input  logic                clk,
        input  logic                rst_n,
        input  logic                flush,

        // issue (at the ROB head)
        input  logic                sys_valid,
        input  logic [2:0]          sys_op,     // 0 FENCE, 1 FENCE.I, 2 SFENCE.VMA, 3 MRET, 4 WFI, 5 SRET
        input  logic [ROBW-1:0]     sys_rob,
        input  logic [31:0]         sys_inst,   // the instruction (tval of an illegal one)
        input  logic [1:0]          priv,       // CORE_CSR
        input  logic                tw,
        input  logic                tsr,
        input  logic                tvm,

        // the rest of the core
        input  logic                sq_drained, // OOO_LSU
        output logic                fl_req,     // OOO_DCAD: FLUSH of the D$
        input  logic                fl_take,
        input  logic                fl_done,
        output logic                ic_flush,   // the I$: invalidate (until ic_done)
        input  logic                ic_done,
        output logic                tlb_flush,
        output logic                x_ret,      // OOO_TRAP: an MRET / SRET runs
        output logic                x_sret,
        input  logic                wfi_wake,   // the CSRs: mip & mie != 0

        // completion
        output logic                cmp_valid,
        output logic [ROBW-1:0]     cmp_rob,
        output logic                cmp_rp,
        output logic                cmp_exc,    // an illegal instruction (cause 2)
        output logic                tv_valid,   // OOO_TRAP: its tval
        output logic [ROBW-1:0]     tv_rob,
        output logic [63:0]         tv_val
    );

    localparam logic [2:0] OP_FENCE = 3'd0, OP_FENCEI = 3'd1, OP_SFENCE = 3'd2, OP_MRET = 3'd3, OP_WFI = 3'd4, OP_SRET = 3'd5;
    localparam logic [1:0] PRIV_U = 2'b00, PRIV_S = 2'b01, PRIV_M = 2'b11;
    typedef enum logic [2:0] {S_IDLE, S_SQ, S_DFL, S_DWAIT, S_IFL, S_WFI, S_DONE} st_t;
    st_t        st;
    logic [2:0] op;
    logic       rp, ex;
    logic       ill;                    // the µop issued now is not allowed at this level

    always @(*) begin
        case (sys_op)
            OP_MRET:   ill = priv != PRIV_M;
            OP_SRET:   ill = priv == PRIV_U || (priv == PRIV_S && tsr);
            OP_SFENCE: ill = priv == PRIV_U || (priv == PRIV_S && tvm);
            OP_WFI:    ill = priv != PRIV_M && tw;
            default:   ill = 1'b0;
        endcase
        fl_req    = st == S_DFL;
        ic_flush  = st == S_IFL;
        tlb_flush = st == S_SQ && op == OP_SFENCE && sq_drained;
        x_ret     = sys_valid && st == S_IDLE && (sys_op == OP_MRET || sys_op == OP_SRET) && !ill;
        x_sret    = sys_op == OP_SRET;
        tv_valid  = sys_valid && st == S_IDLE && ill;
        tv_rob    = sys_rob;
        tv_val    = {32'd0, sys_inst};
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            cmp_valid <= 1'b0;
        end else begin
            cmp_valid <= 1'b0;
            if (flush) begin
                st <= S_IDLE;
            end else begin
                case (st)
                    S_IDLE:  if (sys_valid && ill) begin
                                 st <= S_DONE;
                             end else if (sys_valid) begin
                                 case (sys_op)
                                     OP_FENCE, OP_FENCEI, OP_SFENCE: st <= S_SQ;
                                     OP_WFI:                         st <= S_WFI;
                                     default:                        st <= S_DONE;   // MRET, SRET
                                 endcase
                             end
                    S_SQ:    if (sq_drained) st <= (op == OP_FENCEI) ? S_DFL : S_DONE;
                    S_DFL:   if (fl_take)    st <= S_DWAIT;
                    S_DWAIT: if (fl_done)    st <= S_IFL;
                    S_IFL:   if (ic_done)    st <= S_DONE;
                    S_WFI:   if (wfi_wake)   st <= S_DONE;
                    S_DONE:  begin st <= S_IDLE; cmp_valid <= 1'b1; end
                    default: st <= S_IDLE;
                endcase
            end
        end
    end
    always_ff @(posedge clk) begin
        if (st == S_IDLE && sys_valid) begin
            op      <= sys_op;
            cmp_rob <= sys_rob;
            rp      <= !ill && (sys_op == OP_FENCEI || sys_op == OP_SFENCE || sys_op == OP_MRET || sys_op == OP_SRET);
            ex      <= ill;
        end
    end
    assign cmp_rp  = rp;
    assign cmp_exc = ex;

endmodule : OOO_SYS
