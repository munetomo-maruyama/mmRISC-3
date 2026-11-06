//---------------------------------------------------------------------------
// OOO_TRAP.sv
//
// Exceptions and interrupts of mmRISC-3 (Doc/UARCH.md 3.8, Plan/OOC.md 22):
// what happens at the ROB head, between the ROB, the CSRs (mmRISC-2's
// CORE_CSR inside OOO_CSRU: csr_* below) and OOO_CTRL (take / vec / rp_pc
// are its trap / trap_vec / replay_pc). Taken at the head, between µops:
//
//   interrupt   irq_pend (a pending interrupt enabled, the CSRs' choice of
//               cause) with a µop at the head: irq empties the ROB before
//               it (nothing commits), mepc = its pc, mcause = the
//               interrupt, mtval = 0, fetch from mtvec (+ 4 x cause when
//               vectored). Not while the head is a non-speculative µop
//               that has issued (ns_busy): its effect (a CSR write, an MMIO
//               load, WFI) has happened or is happening, so it must
//               commit. The vector is the CSRs' (tvec: mtvec or stvec when
//               the trap is delegated, + 4 x cause when vectored), which
//               they give for the cause on csr_*. A pair is one µop, so an interrupt never splits
//               one. An interrupt wins over the head's exception (taken
//               before the instruction, which faults again after mret).
//   exception   the head µop has one (OOO_ROB trap): mepc = its pc,
//               mcause, mtval = the tval of the oldest exception reported
//               (tv_*), fetch from mtvec
//   ... in a pair  the pair's two instructions are not told apart (one
//               write per pair: the first one's result may never have been
//               written), so the pair is fetched again from its pc with
//               fusion off (no_fuse) and no CSR written: one at a time,
//               the faulting instruction traps with its own pc, tval and
//               registers. no_fuse holds until two instructions have
//               committed (the pair's) or the next trap or interrupt
//   MRET, SRET  executed at the head by OOO_SYS (x_ret, x_sret for SRET):
//               it completes marked for replay, and that replay fetches
//               from mepc / sepc (not pc + length) and tells the CSRs
//               (csr_mret / csr_sret: the mstatus bits and the level)
//
// tval: every unit that reports an exception reports its tval with it
// (address, instruction bits, or 0) on a tv_* port; the oldest one by ROB
// position is kept until it traps or is flushed (flush_all, or a restore
// before it), so a trap at the head finds its own: the head is the oldest
// µop, and it reported. Reports of flushed µops
// still on their way are not taken: none in the cycle of flush_all, none
// younger than the restored branch in the cycle of a restore (a stale one
// kept would look older than the next real one and hide it).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_TRAP
    #(
        parameter int VA   = 39,
        parameter int NROB = 24,
        parameter int ROBW = 5,
        parameter int NTV  = 3          // tval ports (the dispatch slots, the LSU, ...)
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,

        // OOO_ROB
        input  logic                        rob_trap,       // the head has an exception
        input  logic [4:0]                  rob_cause,
        input  logic [VA-1:1]               rob_pc,         // the head's pc
        input  logic                        head_valid,
        input  logic                        head_fused,
        input  logic [ROBW-1:0]             head_rob,
        input  logic                        rob_replay,
        input  logic [VA-1:1]               rob_replay_pc,
        input  logic [3:0]                  cmt_instret,
        input  logic                        restore,
        input  logic [ROBW-1:0]             restore_rob,
        output logic                        irq,            // OOO_ROB irq: take the interrupt now

        // OOO_CTRL
        input  logic                        ns_busy,
        input  logic                        flush_all,
        output logic                        take,           // OOO_CTRL trap
        output logic [VA-1:1]               vec,            // OOO_CTRL trap_vec
        output logic [VA-1:1]               rp_pc,          // OOO_CTRL replay_pc

        // OOO_SYS
        input  logic                        x_ret,          // an MRET / SRET ran at the head
        input  logic                        x_sret,         //   (SRET)

        // tval of the exceptions reported (with cmp_exc / disp_exc)
        input  logic [NTV-1:0]              tv_valid,
        input  logic [NTV-1:0][ROBW-1:0]    tv_rob,
        input  logic [NTV-1:0][63:0]        tv_val,

        // the CSRs
        input  logic                        irq_pend,
        input  logic [4:0]                  irq_cause,
        input  logic [VA-1:1]               tvec,           // the trap vector for csr_int / csr_cause
        input  logic [VA-1:1]               mepc,
        input  logic [VA-1:1]               sepc,
        output logic                        csr_trap,       // write mepc, mcause, mtval, mstatus (trap entry)
        output logic [VA-1:1]               csr_epc,
        output logic                        csr_int,        // mcause's interrupt bit
        output logic [4:0]                  csr_cause,
        output logic [63:0]                 csr_tval,
        output logic                        csr_mret,       // mstatus and the level for MRET
        output logic                        csr_sret,       //   ... for SRET

        // OOO_FUSE
        output logic                        no_fuse
    );

    function automatic logic [ROBW-1:0] rdist(input logic [ROBW-1:0] i, input logic [ROBW-1:0] h);
        return (i >= h) ? ROBW'(i - h) : ROBW'(i + ROBW'(NROB) - h);
    endfunction

    logic            tv_v;              // the oldest exception's tval
    logic [ROBW-1:0] tv_r;
    logic [63:0]     tv_d;
    logic            x_pend, x_s;       // an MRET (SRET: x_s) at the head has run
    logic [1:0]      nf_cnt;            // instructions committed since the refetch

    logic exc, refetch;
    always @(*) begin
        irq     = irq_pend && head_valid && !ns_busy;
        exc     = rob_trap && !irq;
        refetch = exc && head_fused;
        take    = irq || exc;
        vec     = refetch ? rob_pc : tvec;
        rp_pc     = !x_pend ? rob_replay_pc : x_s ? sepc : mepc;
        csr_trap  = irq || (exc && !head_fused);
        csr_epc   = rob_pc;
        csr_int   = irq;
        csr_cause = irq ? irq_cause : rob_cause;
        csr_tval  = irq ? 64'd0 : tv_d;     // the head is the oldest, and it reported (bug injection: no check needed)
        csr_mret  = rob_replay && x_pend && !x_s;
        csr_sret  = rob_replay && x_pend && x_s;
    end

    // the oldest tval: a report older than (or at) the one kept replaces it;
    // of one cycle's reports, the oldest (the later port at the same place).
    // All distances from the head at once and the reports compared in pairs:
    // taken one port after another, the 6 ports of C made a chain of 44 logic
    // levels (Plan/OOC.md 29.20)
    logic [ROBW-1:0] dk [NTV];          // each report's distance from the head
    logic [NTV-1:0]  ok;                // a report that counts
    logic [NTV-1:0]  win;               // ... and is the one kept next
    logic            kv;                // the one kept stays
    always @(*) begin
        automatic logic [ROBW-1:0] dr  = rdist(tv_r, head_rob);
        automatic logic [ROBW-1:0] drs = rdist(restore_rob, head_rob);
        kv = tv_v;
        if (flush_all || take) kv = 1'b0;
        else if (restore && kv && dr > drs) kv = 1'b0;
        for (int k = 0; k < NTV; k++) begin
            dk[k] = rdist(tv_rob[k], head_rob);
            ok[k] = tv_valid[k] && !flush_all && !(restore && dk[k] > drs);
        end
        for (int k = 0; k < NTV; k++) begin
            win[k] = ok[k] && (!kv || dk[k] <= dr);
            for (int j = 0; j < k; j++)
                if (ok[j] && dk[j] < dk[k]) win[k] = 1'b0;
            for (int j = k + 1; j < NTV; j++)
                if (ok[j] && dk[j] <= dk[k]) win[k] = 1'b0;
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) tv_v <= 1'b0;
        else        tv_v <= kv || ok != '0;
    end
    always_ff @(posedge clk) begin
        for (int k = 0; k < NTV; k++)
            if (win[k]) begin
                tv_r <= tv_rob[k];
                tv_d <= tv_val[k];
            end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_pend  <= 1'b0;
            x_s     <= 1'b0;
            no_fuse <= 1'b0;
            nf_cnt  <= '0;
        end else begin
            if (x_ret)                          begin x_pend <= 1'b1; x_s <= x_sret; end
            else if (rob_replay || flush_all)   x_pend <= 1'b0;
            if (refetch) begin
                no_fuse <= 1'b1;
                nf_cnt  <= '0;
            end else if (take) begin
                no_fuse <= 1'b0;
            end else if (no_fuse) begin
                if (4'(nf_cnt) + cmt_instret >= 4'd2) no_fuse <= 1'b0;
                nf_cnt <= nf_cnt + 2'(cmt_instret);
            end
        end
    end

endmodule : OOO_TRAP
