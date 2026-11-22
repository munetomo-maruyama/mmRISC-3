//---------------------------------------------------------------------------
// OOO_TRAP.sv
//
// Exceptions and interrupts of mmRISC-3 (Doc/UARCH.md 3.8, Plan/OOC.md 22):
// what happens at the ROB head, between the ROB, the CSRs (mmRISC-2's
// CORE_CSR inside OOO_CSRU: csr_* below) and OOO_CTRL (take / vec / rp_pc
// are its trap / trap_vec / replay_pc). Taken at the head, between µops:
//
//   interrupt   irq_pend (a pending interrupt enabled, the CSRs' choice of
//               cause; through a register, see below) with a µop at the head: irq empties the ROB before
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
// Debug mode (step 1.8 J1, Plan/OOC.md 29.101; RISC-V Debug Spec 1.0, 4.1):
//   halt        a halt request (resethaltreq once after the reset: dcsr.cause
//               5; the DM's haltreq: 3; a step done: 4) is taken at the head
//               as an interrupt is (hlt, on irq: nothing commits, not while
//               an issued non-speculative µop is at the head), before any
//               interrupt; d_enter: dpc = the head's pc, dcsr.cause, dcsr.prv
//               (CORE_CSR, which sets the level to M), and fetch from DBG_PC
//   EBREAK      an exception at the head of cause 3 (EBREAK, C.EBREAK: no
//               other µop raises 3) with dcsr.ebreakm / s / u set for the
//               level enters debug mode in place of the trap (cause 1)
//   in debug    dmode: OOO_ICACHE answers any fetch in physical page 0 with
//               OOO_DBG's words, DBG_PC's block a sequence of its own or
//               EBREAKs (the park), the rest EBREAKs. Every exception at the
//               head is taken without the CSRs (no trap entry) and fetches
//               DBG_PC again (d_take: a park EBREAK, a sequence's last
//               EBREAK, or an exception in a sequence, by its pc and cause),
//               or, with d_resume, fetches from dpc and leaves debug mode
//               (d_resumed: the CSRs' dbg_resume, the level dcsr.prv). The
//               park keeps a µop coming to the head, so a resume always finds
//               one. No interrupt and no halt is taken in debug mode
//   step        a resume with dcsr.step: one instruction commits (one: the
//               head alone, fusion off, no interrupt), or traps, then the
//               next µop at the head halts (cause 4). WFI wakes for it
//               (d_wake: also for a halt request)
//   triggers    (Sdtrig) a µop that matched one at decode (an execute
//               trigger, cause 24) or in the LSU (a data trigger, 26) has
//               that exception; at the head the triggers it matched are
//               found again (their address against its tval, the pc or the
//               virtual address; the enables cannot have changed since):
//               one of action 1 halts (dcsr.cause 2), else a breakpoint
//               (cause 3, tval the address); trig_fired sets their hit
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
        parameter int NTV  = 3,         // tval ports (the dispatch slots, the LSU, ...)
        parameter logic [VA-1:1] DBG_PC = (VA-1)'(64'h800 >> 1)   // debug mode's fetch (step 1.8 J1)
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
        output logic                        no_fuse,

        // debug (step 1.8 J1): the DM's requests, OOO_DBG, the CSRs' dcsr / dpc
        input  logic                        d_haltreq,      // the DM's haltreq (a level)
        input  logic                        d_resethalt,    // the DM's resethaltreq: looked at once after the reset
        input  logic                        d_resume,       // OOO_DBG: resume at the next take in debug mode (until d_resumed)
        input  logic                        d_step,         // dcsr.step
        input  logic                        d_ebm,          // dcsr.ebreakm / s / u
        input  logic                        d_ebs,
        input  logic                        d_ebu,
        input  logic [1:0]                  priv,
        input  logic [VA-1:1]               dpc,
        output logic                        dmode,          // in debug mode (halted)
        output logic                        d_enter,        // the CSRs' dbg_enter (dpc = csr_epc)
        output logic [2:0]                  d_cause,
        output logic                        d_resumed,      // the CSRs' dbg_resume; the DM's resumeack
        output logic                        d_take,         // an exception taken in debug mode, not resuming (OOO_DBG)
        output logic                        one,            // OOO_ROB: the head alone commits (a step)
        output logic                        d_wake,         // OOO_SYS: WFI wakes (a halt request, a step)
        input  logic [3:0]                  t_ex,           // the triggers enabled for execute (OOO_CORE's registers)
        input  logic [3:0]                  t_dat,          // ... for loads or stores
        input  logic [3:0]                  t_act,          // their action (1: debug mode)
        input  logic [3:0][63:0]            t_a,            // their address
        output logic [3:0]                  trig_fired      // the CSRs: hit
    );

    function automatic logic [ROBW-1:0] rdist(input logic [ROBW-1:0] i, input logic [ROBW-1:0] h);
        return (i >= h) ? ROBW'(i - h) : ROBW'(i + ROBW'(NROB) - h);
    endfunction

    // irq_pend and its cause a cycle late: from the CSRs' state (the level,
    // mstatus, mie, mip) they lay at the start of most of the 4-wide core's
    // paths (Plan/OOC.md 29.22). The state changes only by a CSR write (a
    // non-speculative µop: ns_busy holds off interrupts from its issue to the
    // cycle after its commit, and it writes in EX, before), by a trap or by
    // MRET / SRET (both empty the ROB); the core has no interrupt source
    // outside the CSRs yet, and one would only be seen a cycle later
    logic            irq_q;
    logic [4:0]      irq_cause_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) irq_q <= 1'b0;
        else        irq_q <= irq_pend;
    end
    always_ff @(posedge clk) irq_cause_q <= irq_cause;

    logic            tv_v;              // the oldest exception's tval
    logic [ROBW-1:0] tv_r;
    logic [63:0]     tv_d;
    logic            x_pend, x_s;       // an MRET (SRET: x_s) at the head has run
    logic [1:0]      nf_cnt;            // instructions committed since the refetch

    // debug
    logic            rh_first, rh_pend;  // the first cycle after the reset; resethaltreq seen then
    logic            step_pend;          // a step: from its resume to its halt
    logic            step_done;          // ... its instruction committed or trapped
    logic            nf_r;               // no_fuse for a pair fetched again
    logic            hreq, hlt, irq_t, ebk, dexc, trg, tdbg, tbrk;
    logic [3:0]      tm;                 // the triggers the head's µop matched
    logic [2:0]      hcause;

    logic exc, refetch;
    always @(*) begin
        hreq    = !dmode && (rh_pend || d_haltreq || step_done);
        hcause  = rh_pend ? 3'd5 : d_haltreq ? 3'd3 : 3'd4;
        hlt     = hreq && head_valid && !ns_busy;
        irq_t   = irq_q && head_valid && !ns_busy && !dmode && !step_pend && !hreq;
        irq     = irq_t || hlt;
        exc     = rob_trap && !irq;
        ebk     = exc && !dmode && rob_cause == 5'd3 &&
                  (priv == 2'b11 ? d_ebm : priv == 2'b01 ? d_ebs : priv == 2'b00 && d_ebu);
        dexc    = exc && dmode;
        trg     = exc && !dmode && (rob_cause == 5'd24 || rob_cause == 5'd26);
        for (int i = 0; i < 4; i++) tm[i] = (rob_cause == 5'd24 ? t_ex[i] : t_dat[i]) && t_a[i] == tv_d;
        tdbg    = trg && (tm & t_act) != '0;
        tbrk    = trg && !tdbg;
        trig_fired = tdbg ? (tm & t_act) : tbrk ? (tm & ~t_act) : '0;
        d_enter   = hlt || ebk || tdbg;
        d_cause   = hlt ? hcause : ebk ? 3'd1 : 3'd2;
        d_resumed = dexc && d_resume;
        d_take    = dexc && !d_resume;
        refetch = exc && head_fused && !dmode && !ebk && !tdbg;
        take    = irq || exc;
        vec     = d_resumed ? dpc : (d_enter || dexc) ? DBG_PC : refetch ? rob_pc : tvec;
        rp_pc     = !x_pend ? rob_replay_pc : x_s ? sepc : mepc;
        csr_trap  = irq_t || (exc && !head_fused && !ebk && !tdbg && !dmode);
        csr_epc   = rob_pc;
        csr_int   = irq_t;
        csr_cause = irq_t ? irq_cause_q : tbrk ? 5'd3 : rob_cause;
        csr_tval  = irq_t ? 64'd0 : tv_d;   // the head is the oldest, and it reported (bug injection: no check needed)
        csr_mret  = rob_replay && x_pend && !x_s;
        csr_sret  = rob_replay && x_pend && x_s;
        one       = step_pend;
        no_fuse   = nf_r || step_pend;
        d_wake    = d_haltreq || rh_pend || step_pend;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dmode     <= 1'b0;
            rh_first  <= 1'b1;
            rh_pend   <= 1'b0;
            step_pend <= 1'b0;
            step_done <= 1'b0;
        end else begin
            rh_first <= 1'b0;
            if (rh_first) rh_pend <= d_resethalt;
            if (d_enter) begin
                dmode     <= 1'b1;
                rh_pend   <= 1'b0;
                step_pend <= 1'b0;
                step_done <= 1'b0;
            end else if (d_resumed) begin
                dmode     <= 1'b0;
                step_pend <= d_step;
            end else if (step_pend && !dmode && (cmt_instret != 4'd0 || take)) begin
                step_done <= 1'b1;
            end
        end
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
            nf_r    <= 1'b0;
            nf_cnt  <= '0;
        end else begin
            if (x_ret)                          begin x_pend <= 1'b1; x_s <= x_sret; end
            else if (rob_replay || flush_all)   x_pend <= 1'b0;
            if (refetch) begin
                nf_r    <= 1'b1;
                nf_cnt  <= '0;
            end else if (take) begin
                nf_r    <= 1'b0;
            end else if (nf_r) begin
                if (4'(nf_cnt) + cmt_instret >= 4'd2) nf_r <= 1'b0;
                nf_cnt <= nf_cnt + 2'(cmt_instret);
            end
        end
    end

endmodule : OOO_TRAP
