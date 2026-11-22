//---------------------------------------------------------------------------
// OOO_DBG.sv
//
// The hart's side of debug in mmRISC-3 (step 1.8 J1, Plan/OOC.md 29.101): what
// answers mmRISC-2's Debug Module (RTL/CPU/DBG, its hart_* signals) for the
// out-of-order core. Halt, step and EBREAK are OOO_TRAP's (at the ROB head);
// here are the register accesses, the resume, and the words the core
// fetches in debug mode.
//
// In debug mode (dmode) the core fetches from DBG_PC (0x800, physical page 0),
// and OOO_ICACHE answers page 0 from `words` (DBG_PC's 32-byte block; the
// other blocks EBREAKs). Unarmed, the block is 8 EBREAKs: the park, each
// EBREAK taken at the head (OOO_TRAP d_take) and DBG_PC fetched again.
// Armed, it is a sequence of the core's own, run as any instructions
// (renamed, committed; not counted, not traced: OOO_CORE), ending in EBREAK:
//
//   GPR xN read   nop; csrw dscratch0, xN; ebreak       then dscratch0 by the port
//   GPR xN write  dscratch0 written by the port first;  nop; csrr xN, dscratch0; ebreak
//   FPR fN read   nop; csrw dscratch1, x1; fmv.x.d x1, fN; csrw dscratch0, x1; csrr x1, dscratch1; ebreak
//   FPR fN write  dscratch0 by the port first;          nop; csrw dscratch1, x1; csrr x1, dscratch0;
//                                                       fmv.d.x fN, x1; csrr x1, dscratch1; ebreak
//   resume after a memory write                         nop; fence.i; ebreak   (the D$ to the L2, the I$ swept)
//
// A sequence has ended at the first take in debug mode at a pc other than
// DBG_PC (its first word, a nop, never faults; a park EBREAK is always at
// DBG_PC: every take fetches DBG_PC again, and a replay inside a sequence
// fetches the sequence again while it is armed): its last EBREAK (cause 3),
// or an exception in it (then the access is the DM's error, cmderr 3). A
// CSR (regno 0x0000 .. 0x0fff) is read or written in a cycle through the CSR
// unit's debugger port (c_*: CORE_CSR's rights for the debugger; a CSR that
// does not exist, or a write of a read-only one, is the error). A 32-bit
// write keeps the upper half: read, merged, written (mmRISC-2's rule). Any
// access while the hart runs is the error (the DM gives cmderr 4 first).
//
// The resume (hart_resumereq, a pulse while halted): after a debugger's
// write to memory (mem_wr, since the last resume) the fence.i sequence
// first, so a software breakpoint is fetched; then d_resume until OOO_TRAP
// takes it at the next park EBREAK (d_resumed: hart_resumed).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_DBG
    #(
        parameter int VA = 39,
        parameter logic [VA-1:1] DBG_PC = (VA-1)'(64'h800 >> 1)
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,

        // the DM (mmRISC-2's DBG_DM, its hart_* / reg_*)
        input  logic                  hart_resumereq, // a pulse
        output logic                  hart_halted,
        output logic                  hart_running,
        output logic                  hart_resumed,   // a pulse
        input  logic                  reg_req,        // a pulse
        input  logic                  reg_wr,
        input  logic [15:0]           reg_regno,
        input  logic                  reg_size64,
        input  logic [63:0]           reg_wdata,
        output logic                  reg_ack,        // a pulse
        output logic [63:0]           reg_rdata,
        output logic                  reg_err,

        // OOO_TRAP
        input  logic                  dmode,
        input  logic                  d_take,         // an exception taken in debug mode (not a resume)
        input  logic [VA-1:1]         d_take_pc,
        input  logic [4:0]            d_take_cause,
        input  logic                  d_resumed,
        output logic                  d_resume,

        // the CSR unit's debugger port
        output logic                  c_access,
        output logic                  c_wr,
        output logic [11:0]           c_addr,
        output logic [63:0]           c_wdata,
        input  logic [63:0]           c_rdata,
        input  logic                  c_exists,

        // OOO_ICACHE: DBG_PC's block in debug mode
        output logic [255:0]          words,

        // a debugger's write to memory done (the bus master's)
        input  logic                  mem_wr
    );

    localparam logic [31:0] NOP    = 32'h0000_0013;
    localparam logic [31:0] EBREAK = 32'h0010_0073;
    localparam logic [31:0] FENCEI = 32'h0000_100f;
    localparam logic [11:0] DS0 = 12'h7B2, DS1 = 12'h7B3;

    function automatic logic [31:0] csrw(input logic [11:0] c, input logic [4:0] r);   // csrrw x0, c, xr
        return {c, r, 3'b001, 5'd0, 7'h73};
    endfunction
    function automatic logic [31:0] csrr(input logic [4:0] r, input logic [11:0] c);   // csrrs xr, c, x0
        return {c, 5'd0, 3'b010, r, 7'h73};
    endfunction
    function automatic logic [31:0] fmvxd(input logic [4:0] r, input logic [4:0] f);   // fmv.x.d xr, ff
        return {7'h71, 5'd0, f, 3'b000, r, 7'h53};
    endfunction
    function automatic logic [31:0] fmvdx(input logic [4:0] f, input logic [4:0] r);   // fmv.d.x ff, xr
        return {7'h79, 5'd0, r, 3'b000, f, 7'h53};
    endfunction

    typedef enum logic [3:0] {
        S_IDLE, S_CSR, S_RSEQ, S_RGET, S_WPUT, S_WSEQ, S_FENCE, S_RES, S_ACK
    } st_t;
    st_t             st;
    logic            q_wr, q_s64, q_fp, q_err;
    logic [4:0]      q_n;
    logic [63:0]     q_d;           // the data to write (merged), or the data read
    logic            armed;         // `words` is a sequence
    logic [3:0]      seq;           // which: 0 read, 1 write, 2 fence.i
    logic            mw;            // memory written since the last resume
    logic            done_seq;      // the armed sequence has ended
    logic            seq_ok;        // ... by its EBREAK

    assign done_seq = armed && d_take && d_take_pc != DBG_PC;
    assign seq_ok   = d_take_cause == 5'd3;

    // the block at DBG_PC
    always @(*) begin
        logic [31:0] w [8];
        for (int k = 0; k < 8; k++) w[k] = EBREAK;
        if (armed) begin
            w[0] = NOP;
            case (seq)
                4'd0: if (!q_fp) w[1] = csrw(DS0, q_n);
                      else begin
                          w[1] = csrw(DS1, 5'd1);
                          w[2] = fmvxd(5'd1, q_n);
                          w[3] = csrw(DS0, 5'd1);
                          w[4] = csrr(5'd1, DS1);
                      end
                4'd1: if (!q_fp) w[1] = csrr(q_n, DS0);
                      else begin
                          w[1] = csrw(DS1, 5'd1);
                          w[2] = csrr(5'd1, DS0);
                          w[3] = fmvdx(q_n, 5'd1);
                          w[4] = csrr(5'd1, DS1);
                      end
                default: w[1] = FENCEI;
            endcase
        end
        for (int k = 0; k < 8; k++) words[32*k +: 32] = w[k];
    end

    // the CSR port: a CSR access (S_CSR), dscratch0 read (S_RGET) or written (S_WPUT)
    logic [11:0] reg_regno_q;
    always @(*) begin
        c_access = st == S_CSR || st == S_RGET || st == S_WPUT;
        c_addr   = st == S_CSR ? reg_regno_q : DS0;
        c_wr     = (st == S_CSR && q_wr && c_exists && c_addr[11:10] != 2'b11) || st == S_WPUT;
        c_wdata  = st == S_WPUT ? q_d : q_s64 ? q_d : {c_rdata[63:32], q_d[31:0]};
    end

    assign hart_halted  = dmode;
    assign hart_running = !dmode;
    assign hart_resumed = d_resumed;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            armed    <= 1'b0;
            mw       <= 1'b0;
            d_resume <= 1'b0;
            reg_ack  <= 1'b0;
        end else begin
            reg_ack <= 1'b0;
            if (mem_wr) mw <= 1'b1;
            case (st)
                S_IDLE: begin
                    if (reg_req) begin
                        if (!dmode || (reg_regno >= 16'h1040)) begin
                            st    <= S_ACK;
                        end else if (reg_regno < 16'h1000) begin
                            st    <= S_CSR;
                        end else begin
                            // a GPR / FPR: a read first unless a 64-bit write
                            st    <= (reg_wr && reg_size64) ? S_WPUT : S_RSEQ;
                            armed <= !(reg_wr && reg_size64);
                            seq   <= 4'd0;
                        end
                    end else if (hart_resumereq && dmode) begin
                        if (mw) begin
                            st    <= S_FENCE;
                            armed <= 1'b1;
                            seq   <= 4'd2;
                        end else begin
                            st       <= S_RES;
                            d_resume <= 1'b1;
                        end
                    end
                end
                S_CSR:  st <= S_ACK;
                S_RSEQ: if (done_seq) begin
                    armed <= 1'b0;
                    st    <= seq_ok ? S_RGET : S_ACK;
                end
                S_RGET: st <= q_wr ? S_WPUT : S_ACK;    // a 32-bit write: the upper half kept (below)
                S_WPUT: begin
                    armed <= 1'b1;
                    seq   <= 4'd1;
                    st    <= S_WSEQ;
                end
                S_WSEQ: if (done_seq) begin
                    armed <= 1'b0;
                    st    <= S_ACK;
                end
                S_FENCE: if (done_seq) begin
                    armed    <= 1'b0;
                    mw       <= mem_wr;
                    st       <= S_RES;
                    d_resume <= 1'b1;
                end
                S_RES: if (d_resumed) begin
                    d_resume <= 1'b0;
                    st       <= S_IDLE;
                end
                default: begin              // S_ACK
                    reg_ack <= 1'b1;
                    st      <= S_IDLE;
                end
            endcase
        end
    end

    // the access: its request, then the data read (or merged) and the error
    always_ff @(posedge clk) begin
        case (st)
            S_IDLE: if (reg_req) begin
                q_wr        <= reg_wr;
                q_s64       <= reg_size64;
                q_fp        <= reg_regno[5];
                q_n         <= reg_regno[4:0];
                q_d         <= reg_wdata;
                q_err       <= !dmode || reg_regno >= 16'h1040;
                reg_regno_q <= reg_regno[11:0];
            end
            S_CSR: begin
                q_err <= !c_exists || (q_wr && c_addr[11:10] == 2'b11);
                q_d   <= c_rdata;
            end
            S_RSEQ, S_WSEQ: if (done_seq) q_err <= !seq_ok;
            S_RGET: q_d <= q_wr ? {c_rdata[63:32], q_d[31:0]} : c_rdata;
            default: ;
        endcase
    end

    assign reg_rdata = q_d;
    assign reg_err   = q_err;

endmodule : OOO_DBG
