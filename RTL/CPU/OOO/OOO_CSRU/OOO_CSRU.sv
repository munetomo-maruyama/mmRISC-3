//---------------------------------------------------------------------------
// OOO_CSRU.sv
//
// The CSR unit of mmRISC-3 (Plan/OOC.md 23): mmRISC-2's CORE_CSR (RTL/CPU/
// CORE, HPM_COUNTERS = 2: G0b L1) behind issue port 0, and its trap side for
// OOO_TRAP / OOO_SYS.
//
//   CSR µops  csrrw / csrrs / csrrc and the immediate forms are
//             non-speculative: issued only at the ROB head (OOO_IQ ns_ok),
//             so in EX nothing older is left and the µop commits (no
//             interrupt while the head's non-speculative µop has issued).
//             EX reads the CSR (the result, port 0's like an ALU µop's),
//             checks it (not implemented, not allowed at this level, a
//             write to a read-only one, or an FP CSR with mstatus.FS off,
//             as mmRISC-2's CPU_CORE did: an illegal instruction, with the
//             instruction bits as tval) and writes it in the same cycle
//             (mmRISC-2 wrote at commit; here EX at the head is as late as
//             it gets). csrrs / csrrc with x0 (or a zero immediate) do not
//             write. A µop that writes completes marked for replay after
//             commit: what follows is fetched again under the new state
//             (satp, mstatus, the counters' enables, ...).
//   trap      OOO_TRAP's csr_* go to CORE_CSR's trap entry, MRET and SRET;
//             CORE_CSR gives back the vector (mtvec or stvec, + 4 x cause
//             when vectored), mepc / sepc for the returns, and the
//             interrupt to take (irq_req, its cause) and WFI's wakeup
//   counters  minstret counts the instructions retired a cycle, 0 .. 4
//             (instret_inc: the copy of CORE_CSR here has that one change).
//             An instruction that writes minstret does not count itself (as
//             Spike): written in EX, it commits next, alone (a CSR µop at the
//             head, marked for replay), and that commit is not counted.
//             A write to mcountinhibit reaches CORE_CSR at that commit, so
//             the instruction counts under the old IR bit (as Spike, Sail)
//
// The rest of CORE_CSR's outputs (the level, satp, mstatus bits, PMP, the
// FP state, debug and triggers) go out as they are, for the MMU, the FPU
// and debug at the assembly.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_CSRU
    #(
        parameter int          VA           = 39,
        parameter int          ROBW         = 5,
        parameter logic [63:0] HART_ID      = 64'd0,
        parameter logic [63:0] MISA         = (64'd2 << 62) | (64'd1 << 8),
        parameter int          PMP_ENTRIES  = 8,
        parameter int          PMP_CSRS     = 16,
        parameter int          TRIGGERS     = 4,
        parameter int          HPM_COUNTERS = 2,    // G0b L1 (Doc/UARCH.md 6.3): 4 -> 2
        parameter int          HPM_EVENTS   = 20
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,

        // EX of port 0: a CSR µop at the ROB head
        input  logic                        ex_valid,
        input  logic [2:0]                  ex_op,      // funct3: 1 rw, 2 rs, 3 rc, 5 / 6 / 7 the immediate forms
        input  logic [11:0]                 ex_addr,
        input  logic [4:0]                  ex_rs1,     // the rs1 field: x0, or the immediate
        input  logic [63:0]                 ex_src,     // rs1's value
        input  logic [ROBW-1:0]             ex_rob,
        input  logic [31:0]                 ex_inst,
        output logic [63:0]                 ex_res,     // the old value, into rd
        output logic                        ex_exc,     // an illegal instruction (cause 2)
        output logic                        ex_rp,      // it wrote: replay after commit
        output logic                        tv_valid,   // OOO_TRAP: the tval of the exception
        output logic [ROBW-1:0]             tv_rob,
        output logic [63:0]                 tv_val,

        // OOO_TRAP
        input  logic                        trap_en,
        input  logic                        trap_int,
        input  logic [4:0]                  trap_cause,
        input  logic [VA-1:1]               trap_epc,
        input  logic [63:0]                 trap_tval,
        input  logic                        mret_en,
        input  logic                        sret_en,
        output logic [VA-1:1]               tvec,
        output logic [VA-1:1]               mepc,
        output logic [VA-1:1]               sepc,
        output logic                        irq_pend,   // an interrupt to take
        output logic [4:0]                  irq_cause,
        output logic                        wfi_wake,   // OOO_SYS

        // interrupts, counters
        input  logic                        irq_m_soft,
        input  logic                        irq_m_timer,
        input  logic                        irq_m_ext,
        input  logic                        irq_s_ext,
        input  logic [63:0]                 mtime,
        input  logic [2:0]                  instret_inc,    // OOO_ROB cmt_instret
        input  logic [HPM_EVENTS-1:0]       hpm_ev,

        // the rest of CORE_CSR, as it is
        output logic [1:0]                  priv,
        output logic [63:0]                 satp,
        output logic                        mstatus_sum,
        output logic                        mstatus_mxr,
        output logic                        mstatus_mprv,
        output logic [1:0]                  mstatus_mpp,
        output logic                        mstatus_tvm,
        output logic                        mstatus_tw,
        output logic                        mstatus_tsr,
        output logic                        menvcfg_cbze,
        output logic                        senvcfg_cbze,
        output logic [8*PMP_ENTRIES-1:0]    pmpcfg,
        output logic [64*PMP_ENTRIES-1:0]   pmpaddr,
        output logic [64*PMP_ENTRIES-1:0]   pmpmask,
        input  logic                        fflags_we,
        input  logic [4:0]                  fflags_set,
        input  logic                        fs_dirty,
        output logic [2:0]                  frm,
        output logic [1:0]                  fs,
        input  logic                        dbg_access,
        input  logic [11:0]                 dbg_addr,
        input  logic                        dbg_enter,
        input  logic [2:0]                  dbg_cause,
        input  logic [63:0]                 dbg_pc,
        input  logic                        dbg_resume,
        output logic [63:0]                 dbg_rdata,
        output logic                        dcsr_step,
        output logic                        dcsr_ebreakm,
        output logic                        dcsr_ebreaks,
        output logic                        dcsr_ebreaku,
        output logic [63:0]                 dpc,
        output logic [8*TRIGGERS-1:0]       trig_cfg,
        output logic [64*TRIGGERS-1:0]      trig_addr,
        output logic                        tcontrol_mte,
        input  logic [TRIGGERS-1:0]         trig_fired
    );

    logic [63:0] rd_data, rmw_data, src, wdata;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] tvec64, mret64, sret64;        // (VA bits of them: the core's addresses)
    /* verilator lint_on UNUSEDSIGNAL */
    logic        ex_exists, ex_readonly, ex_denied, wants_write, ill, wr_en;

    always @(*) begin
        src         = ex_op[2] ? {59'd0, ex_rs1} : ex_src;
        wants_write = ex_op[1:0] == 2'b01 || ex_rs1 != 5'd0;
        // (with mstatus.FS off fflags / frm / fcsr are not there: mmRISC-2's CPU_CORE checked it)
        ill         = !ex_exists || ex_denied || (wants_write && ex_readonly) ||
                      (fs == 2'b00 && (ex_addr == 12'h001 || ex_addr == 12'h002 || ex_addr == 12'h003));
        wr_en       = ex_valid && wants_write && !ill;
        case (ex_op[1:0])
            2'b10:   wdata = rmw_data | src;
            2'b11:   wdata = rmw_data & ~src;
            default: wdata = src;
        endcase
        ex_res   = rd_data;
        ex_exc   = ill;
        ex_rp    = wants_write && !ill;
        tv_valid = ex_valid && ill;
        tv_rob   = ex_rob;
        tv_val   = {32'd0, ex_inst};
        tvec     = tvec64[VA-1:1];
        mepc     = mret64[VA-1:1];
        sepc     = sret64[VA-1:1];
    end

    // the commit of an instruction that wrote minstret is not counted
    logic       ir_skip;
    logic [2:0] ir_inc;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                                ir_skip <= 1'b0;
        else if (wr_en && ex_addr == 12'hB02)      ir_skip <= 1'b1;
        else if (instret_inc != 3'd0)              ir_skip <= 1'b0;
    end
    assign ir_inc = (ir_skip && instret_inc != 3'd0) ? instret_inc - 3'd1 : instret_inc;

    // a write to mcountinhibit waits for its commit (nothing reads it before)
    logic        ih_pend, c_wr_en;
    logic [63:0] ih_data;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                                ih_pend <= 1'b0;
        else if (wr_en && ex_addr == 12'h320)      ih_pend <= 1'b1;
        else if (instret_inc != 3'd0)              ih_pend <= 1'b0;
    end
    always_ff @(posedge clk) if (wr_en && ex_addr == 12'h320) ih_data <= wdata;
    assign c_wr_en = (wr_en && ex_addr != 12'h320) || (ih_pend && instret_inc != 3'd0);

    // (rd_exists / rd_readonly are the debugger's, trap_to_s is in the vector already)
    /* verilator lint_off PINCONNECTEMPTY */
    CORE_CSR #(.HART_ID(HART_ID), .MISA(MISA), .PMP_ENTRIES(PMP_ENTRIES), .PMP_CSRS(PMP_CSRS),
               .TRIGGERS(TRIGGERS), .HPM_COUNTERS(HPM_COUNTERS), .HPM_EVENTS(HPM_EVENTS)) u_csr
        (.clk(clk), .rst_n(rst_n),
         .rd_addr(dbg_access ? dbg_addr : ex_addr), .rd_data(rd_data), .rmw_data(rmw_data),
         .rd_exists(), .rd_readonly(),
         .ex_addr(ex_addr), .ex_exists(ex_exists), .ex_readonly(ex_readonly), .ex_denied(ex_denied),
         .wr_en(c_wr_en), .wr_addr(ih_pend ? 12'h320 : ex_addr), .wr_data(ih_pend ? ih_data : wdata),
         .trap_en(trap_en), .trap_int(trap_int), .trap_cause(trap_cause),
         .trap_epc({{(65 - VA){trap_epc[VA-1]}}, trap_epc[VA-2:1], 1'b0}), .trap_tval(trap_tval),
         .trap_vector(tvec64), .trap_to_s(),
         .mret_en(mret_en), .sret_en(sret_en), .mret_target(mret64), .sret_target(sret64),
         .irq_m_soft(irq_m_soft), .irq_m_timer(irq_m_timer), .irq_m_ext(irq_m_ext), .irq_s_ext(irq_s_ext),
         .mtime(mtime), .irq_req(irq_pend), .irq_cause(irq_cause), .irq_any(wfi_wake),
         .priv(priv), .satp_out(satp), .mstatus_sum_out(mstatus_sum), .mstatus_mxr_out(mstatus_mxr),
         .mstatus_mprv_out(mstatus_mprv), .mstatus_mpp_out(mstatus_mpp), .mstatus_tvm_out(mstatus_tvm),
         .mstatus_tw_out(mstatus_tw), .mstatus_tsr_out(mstatus_tsr),
         .menvcfg_cbze_out(menvcfg_cbze), .senvcfg_cbze_out(senvcfg_cbze),
         .pmpcfg_out(pmpcfg), .pmpaddr_out(pmpaddr), .pmpmask_out(pmpmask),
         .instret_inc(ir_inc), .hpm_ev(hpm_ev),
         .fflags_we(fflags_we), .fflags_set(fflags_set), .fs_dirty(fs_dirty), .frm_out(frm), .fs_out(fs),
         .dbg_access(dbg_access), .dbg_enter(dbg_enter), .dbg_cause(dbg_cause), .dbg_pc(dbg_pc),
         .dbg_resume(dbg_resume), .dcsr_step(dcsr_step), .dcsr_ebreakm(dcsr_ebreakm),
         .dcsr_ebreaks(dcsr_ebreaks), .dcsr_ebreaku(dcsr_ebreaku), .dpc_out(dpc),
         .trig_cfg(trig_cfg), .trig_addr(trig_addr), .tcontrol_mte(tcontrol_mte), .trig_fired(trig_fired));
    /* verilator lint_on PINCONNECTEMPTY */
    assign dbg_rdata = rd_data;

endmodule : OOO_CSRU
