//---------------------------------------------------------------------------
// OOO_CORE.sv
//
// The out-of-order integer core of mmRISC-3 (Plan/CORE.md 1), brought up
// step by step (Plan/CORE.md 5). This is B4: ALU µops (B2), loads and
// stores (B3), port 0's CSR, system, multiply and MDU units and traps (B4).
//
//   front end  OOO_FRONT (fetch, FTQ, restore, fetch buffer, D1a / D1b,
//              the group register; the target array and the pc array)
//   D2         the group rotated to its oldest valid slot (the group
//              register keeps what D2 left in its place): up to 4 µops, one
//              instruction each (step 1.2 C, Plan/OOC.md 29.19: no pairing,
//              OOO_FUSE is gone), OOO_RENAME2's R1, OOO_CTRL's r_go (a
//              prefix, at most 2 checkpoints); g_take back to the front end
//   DS         OOO_RENAME2's R2 (tags, 4 slots), OOO_BUSY for the ready bits,
//              and the µop's payload: the record of OOO_IQPL2, pc, ...;
//              OOO_CTRL's d_go writes OOO_ROB, OOO_IQ3, OOO_IQPL2 and the LSU
//   IS         OOO_IQ3 (24 entries; stores split, step 1.5b G3, Plan/OOC.md 29.53): port 0 (ALU0, OOO_ALU2 full; OOO_CSRU, OOO_SYS,
//              OOO_PMUL, OOO_MDUP), port 1 (ALU1, FULL 0), port 2 (OOO_LSU)
//   RR         OOO_STAGE; OOO_PRF (2 reads a port), OOO_IQPL2's record, the
//              pc array and the target array (OOO_FRONT)
//   EX         OOO_STAGE; the operands from the RR read or the 3 write-back
//              registers (the bypass), OOO_ALU2, branch resolution (the
//              direction against the prediction, a jalr's target against
//              the target array) to OOO_CTRL, OOO_ROB and OOO_FRONT (FERS,
//              the TAGE outcomes, the BTB); the register file written at
//              the edge the result enters its write-back register (Plan/
//              CORE.md 4.2); completion to the ROB
//   WB         OOO_STAGE: the bypass source of the cycle after
//   commit     OOO_ROB 4 a cycle: renaming's committed state, OOO_CTRL
//              (free list, LQ / SQ, FTQ pops), OOO_TRAP (exceptions, the
//              interrupt, the vector, the replay pc), the commit trace
//
// B4: an illegal instruction (and an FP instruction with mstatus.FS off or a
// reserved rounding mode, step 1.8 U2), ECALL and EBREAK trap at decode (to the ROB at dispatch, never issued; tval
// through OOO_TRAP's ports 0 .. 3, one a dispatch slot). Port 0's CSR and system µops are
// non-speculative and read their instruction bits from rob_insn (per ROB
// entry, written at dispatch). A result for x0 (tag 0) of the LSU, the
// multiplier or the MDU is neither written nor forwarded (Plan/CORE.md
// 5.7). Left out: the fusion kinds but ALU + branch. The interrupt lines come in
// since step 1.8 I1 (Plan/OOC.md 29.78), into OOO_CSRU.
//
// B5a (Plan/CORE.md 5.19; turned off in 5.21, KINDS 0: the fused compare
// after the ALU does not fit in a cycle, Plan/OOC.md 27.5, and D1b's refill
// keeps its gain small; the pairing in D2 taken out at step 1.2 C, the
// fields kept, FUSE_AB 0, Plan/OOC.md 29.19): an ALU operation and the conditional branch
// after it that reads its rd are one µop: the ALU's fields, rd and
// sources, the branch's comparison in OOO_ALU2 (res1 against the other
// operand: s1, s2 or zero; on s2 when the ALU operation does not read
// rs2), the branch's offset in joff, prediction, last parcel, block and
// checkpoint. A pair whose halves are in two blocks reads the pc array at
// the branch's block less one (xline; an ALU half across two lines is in
// its second line's block, as is the branch right after it). Not paired:
// either half with an exception at decode, either reading one register
// twice (beq rd, rd; or rd, rs, rs: the branch's other operand would need
// a third place). The ROB counts the pair as two instructions; an
// exception at a pair cannot happen (OOO_TRAP's refetch unfused stays for
// the kinds to come).
//
// The µop's fields from decode (Plan/CORE.md 2.1):
//   - jal / jalr: the link (pc + length) is computed by the ALU (pc +
//     imm, the immediate replaced by the length); a jalr's own offset goes
//     in the record apart (joff). A jal is never resolved: its target was
//     right at F2 (predecode).
//   - a conditional branch and a jalr take a checkpoint; resolved in EX:
//     a branch by its direction against pred_taken (a taken one's target
//     pc + imm was right at F2), a jalr by its target against the one
//     predicted (the block's next address from the target array if it
//     ended a taken block, else the next instruction).
//   - call / ret as predecode tells them (link registers x1 / x5).
//   - the pc in EX: the pc array's line of the first half's block (the
//     µop's block, of its last half, less one when it crosses a line) and
//     the first half's parcel.
//
// The atomics (step 1.4 E1c, Plan/OOC.md 29.74), non-speculative, slot 0
// only: LR a load (an LQ entry, woken as a load), SC a store (an SQ entry,
// its data split on port 1 as a store's), an AMO both; the µop of port 2
// carries CORE_DEC's command in xop. SC and an AMO are answered from outside:
// OOO_LSU4 writes the result through its port 0 and wakes the issue queue
// (ext port 1, at_wk_*); its access fault (5 LR, 7 SC / AMO) and tval.
//
// The renamed FPU (step 1.8 U2, Plan/OOC.md 29.80 to 29.83): FP decoded in every slot
// (since U2b; a rare class in slot 0 at U2a). OOO_FREN renames the FP
// registers beside OOO_RENAME2 (its r1_adv, checkpoint ids; ready joins renaming's);
// busy bits of the FP file (OOO_BUSY, twice for 3 sources). An FP operation (and an
// FP -> integer one) goes to OOO_FIQ alone; an FP store's address to OOO_IQ3 (an
// integer store whose data is not its: disp_nd) and its data to OOO_FIQ's port B
// (2 stages, the FP file's 4th read with the FP result's bypass, then OOO_LSU4's
// second data port); an FP load to OOO_IQ3 as a load whose destination is FP (the
// LSU's tag carries {box, fp}: written into the FP file, NaN boxed if flw, the FP
// side woken in its RR, as the queue wakes for an integer load); an int -> FP µop
// to OOO_IQ3's port 0 (its operand in EX into OOO_FPUW's buffer; xf_ok). OOO_FPUW
// with mmRISC-2's FPU_PIPE; the FP file (OOO_PRF, 64, 3 writes: the FPU, the 2
// loads; 4 reads). FP -> integer results write through port 0's slot when the MDU
// and a latency-1 writer leave it (its wakeup on the MDU's external bus, its own
// completion port). Per ROB entry: the FP destination (OOO_FREN's commit), the
// flags (fflags at commit), mstatus.FS made dirty at the commit of an FP write or
// of nonzero flags (Spike's rule).
//
// Translation of loads and stores (step 1.8 V1, Plan/OOC.md 29.87): the effective
// privilege (MPRV with MPP in M) and tr_on (satp's MODE 8, not M) registered into
// OOO_LSU4's DTLBs (OOO_DTLB3: the permissions checked at the lookup); OOO_PTW on
// the LSU's walk port, its entries read through the D$'s miss handler (dc_pt_*);
// the DTLBs flushed (and a walk cancelled) by SFENCE.VMA or a change of satp (no
// ASID); a walk cancelled by a flush of everything too. The LSU's exceptions with
// their cause (misaligned, access fault, page fault: 4 / 5 / 13 a load, 6 / 7 / 15 a
// store or AMO) and their tval from its W. The fetch's translation (step 1.8 V2,
// Plan/OOC.md 29.88): OOO_FRONT's ITLB on the same walker (the LSU's ask first; bit 5
// of the id the fetch's), its privilege the current one's; the fetch's faults at D2
// first (12, 1; tval the pc, + 2 for an instruction across into the faulting page).
//
// The commit trace (OOO_TRACE, simulation only): per ROB entry the
// instruction bits (written at dispatch) and the value written (at
// completion); at commit with the ROB's pc and destination.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_CORE
    #(
        parameter int VA  = 39,
        parameter int PAW = 40,         // physical address bits (Phase 1: the address as it is)
        parameter int DWAYS = 8         // the D$'s ways (256 sets: 8 since step 1.7c C5, Plan/OOC.md 29.72)
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,
        input  logic                        boot,       // fetch from boot_pc (a cycle after reset)
        // the interrupt lines (step 1.8 I1, Plan/OOC.md 29.78: the CLINT's and the PLIC's in OOO_CPU) and mtime
        input  logic                        irq_m_soft,
        input  logic                        irq_m_timer,
        input  logic                        irq_m_ext,
        input  logic                        irq_s_ext,
        input  logic [63:0]                 mtime,
        // the memory side's events for the PMU (step 1.8 K1, Plan/OOC.md 29.97: OOO_CPU's): an I$ line fill asked
        // for, a D$ line fill asked for, an L2 read, an L2 miss
        input  logic [3:0]                  ev_mem,
        input  logic [VA-1:1]               boot_pc,
        // I$
        output logic                        ic_req_valid,
        output logic [VA-1:1]               ic_req_pc,
        output logic [PAW-1:12]             ic_req_ptag,    // its physical page (the ITLB, step 1.8 V2)
        output logic                        ic_req_tok,     // ... it may be fetched (else answered with zeros)
        input  logic                        ic_req_ready,
        input  logic                        ic_resp_valid,
        input  logic [255:0]                ic_resp_data,
        // the D$ (OOO_LSU's abstract port: OOO_DCAD and the D$, or a model)
        // the D$'s miss handler (OOO_LSU3's arrays are inside; step 1.3 E1, Plan/OOC.md 29.32)
        output logic                        dc_miss_valid,
        output logic [PAW-1:6]              dc_miss_line,
        output logic [1:0]                  dc_miss_vx,     // the virtual 13:12 (the D$ at 256 sets, step 1.7c C2)
        output logic [4:0]                  dc_miss_id,
        output logic                        dc_st_miss_valid,
        output logic [PAW-1:6]              dc_st_miss_line,
        output logic [1:0]                  dc_st_miss_vx,
        input  logic                        dc_fill_done,
        input  logic                        dc_done_v,
        input  logic [4:0]                  dc_done_id,
        input  logic                        dc_tw_en,
        input  logic [$clog2(DWAYS)-1:0]   dc_tw_way,
        input  logic [7:0]                  dc_tw_set,
        input  logic [PAW-12:0]             dc_tw_tag,
        input  logic                        dc_rf_en,
        input  logic [$clog2(DWAYS)-1:0]   dc_rf_way,
        input  logic [10:0]                 dc_rf_addr,
        input  logic [63:0]                 dc_rf_data,
        output logic                        dc_dirty_set,
        output logic [$clog2(DWAYS)-1:0]   dc_dirty_way,
        output logic [7:0]                  dc_dirty_idx,
        input  logic [10:0]                 dc_vr_addr,     // the D$'s victim's copy (written back, step 1.7b W2)
        input  logic [$clog2(DWAYS)-1:0]   dc_vr_way,
        output logic [63:0]                 dc_vr_data,
        output logic                        dc_sq_drained,
        output logic                        dc_pt_req,      // a page table's entry (OOO_PTW, step 1.8 V1), read through the miss handler
        output logic [PAW-1:3]              dc_pt_addr,
        input  logic                        dc_pt_done,
        input  logic [63:0]                 dc_pt_data,
        // what is not cacheable (step 1.3 E1b, Plan/OOC.md 29.33): one access to a device at a time
        input  logic                        dc_uc_line_v,   // a line not cached (simulation: the bench's tohost)
        input  logic [PAW-1:6]              dc_uc_line,
        output logic                        dc_uc_req,
        output logic                        dc_uc_we,
        output logic [PAW-1:0]              dc_uc_addr,
        output logic [1:0]                  dc_uc_size,
        output logic [63:0]                 dc_uc_wdata,
        output logic [7:0]                  dc_uc_wmask,
        input  logic                        dc_uc_done,
        input  logic [63:0]                 dc_uc_rdata,
        // the stores written into the D$, told (the D$ written back since step 1.7b W2: tb_core's model keeps its
        // memory with them; OOO_CPU leaves them open)
        output logic                        dc_wt_valid,
        output logic [PAW-1:0]              dc_wt_addr,
        output logic [63:0]                 dc_wt_data,
        output logic [7:0]                  dc_wt_mask,
        output logic                        fl_req,     // FENCE.I: FLUSH of the D$ (OOO_DCAD)
        input  logic                        fl_take,
        input  logic                        fl_done,
        output logic                        ic_flush,   // FENCE.I: invalidate the I$ (until ic_done)
        input  logic                        ic_done
`ifdef OOO_TRACE
        ,
        // the commit trace: up to 2 µops a cycle, slot 0 the older
        output logic [3:0]                  tr_valid,
        output logic [3:0][VA-1:1]          tr_pc,
        output logic [3:0][31:0]            tr_insn,
        output logic [3:0]                  tr_pair,    // a fused pair: its second instruction
        output logic [3:0][31:0]            tr_insn2,
        output logic [3:0]                  tr_wr,
        output logic [3:0]                  tr_fwr,     // ... an FP register (step 1.8 U2)
        output logic [3:0][4:0]             tr_rd,
        output logic [3:0][63:0]            tr_val,
        output logic                        tr_trap,
        output logic                        tr_int,     // an interrupt (taken before the head)
        output logic [4:0]                  tr_cause,
        output logic [VA-1:1]               tr_trap_pc,
        output logic [3:0]                  tr_st,      // a store: its address, data and size
        output logic [3:0][63:0]            tr_st_addr,
        output logic [3:0][63:0]            tr_st_data,
        output logic [3:0][1:0]             tr_st_size
`endif
    );

    localparam int NFTQ  = 32, FTQW = 5;        // D-18 (16 until ROB 48 and short blocks kept it full, Plan/OOC.md 29.45)
    localparam int NCKPT = 12, CW   = 4;        // step 1.2 A (Plan/OOC.md 29.16): the frozen sizes first
    localparam int TAGW  = 7;                   // 80 physical registers
    localparam int NROB  = 48, ROBW = 6;
    localparam int NIQ   = 24, IQW  = 5;
    localparam int ND    = 4;                   // renamed, dispatched and committed a cycle (step 1.2 C, Plan/OOC.md 29.19)
    localparam int NAP   = 4;                   // ALU ports (step 1.2 D, Plan/OOC.md 29.27); the LSU's is port NAP
    // the fusion kinds (OOO_FUSE's KINDS): ALU + branch (B5a, 8'h80) is off (5.21). FUSE_AB gates the pair's
    // uses after D2 as well: the record goes through OOO_IQPL2's LUT RAM, where synthesis cannot see `fused` as a
    // constant, and the compare after the ALU would stay in EX (Plan/OOC.md 27.7)
    localparam logic [7:0] FUSE_KINDS = 8'h00;
    localparam bit         FUSE_AB    = FUSE_KINDS[7];
    localparam int NWK   = 9;                   // wakeup buses (OOO_IQ3: 7 + NEXT)
    // the renamed FPU (step 1.8 U2, Plan/OOC.md 29.80)
    localparam int NFREG = 80, FTAGW = 7;       // FP physical registers (80 since step 1.8 U2b, Plan/OOC.md 29.83)
    localparam int FXW   = 1 + 5 + 2 * FTAGW;   // the FP destination in OOO_ROB's extra payload: {wr, arch, new, old}
    localparam int FPLW  = 32;                  // OOO_FIQ's payload: op [4:0], fmt [5], rm [8:6], int_signed [9], int_w [10],
                                                // the ROB index [11 +: ROBW], the integer destination [17 +: TAGW]; a store's
                                                // data: its SQ entry [27:24], double [28]
    localparam logic [4:0] FOP_DIV = 5'd3, FOP_SQRT = 5'd4, FOP_EQ = 5'd14, FOP_MV_X_F = 5'd18, FOP_MV_F_X = 5'd19,
                           FOP_CVT_F_I = 5'd22, FOP_CVT_I_F = 5'd23;

    logic [1:0]          priv;                  // the privilege level (CORE_CSR): ECALL's cause at decode

    // the payload record (OOO_IQPL2, 102 bits; the fields of B2 to B4)
    localparam logic [1:0] K_ALU = 2'd0, K_MDU = 2'd1, K_CSR = 2'd2, K_SYS = 2'd3;
    typedef struct packed {
        logic            fpd;                   // a load to an FP register (step 1.8 U2)
        logic            fx;                    // an int -> FP µop (port 0; OOO_FPUW's payload in imm [10:0])
        logic [1:0]      kind;                  // port 0's units: K_ALU (and branches, jumps), K_MDU, K_CSR, K_SYS
        logic [3:0]      xop;                   // an MDU µop's CORE_MDU op (0: mul / mulw, OOO_PMUL); a system µop's OOO_SYS op;
                                                // a µop of port 2: 0 a load or store, else an atomic's CORE_DEC command
                                                // (2 LR, 3 SC, 4..12 the AMOs; step 1.4 E1c, Plan/OOC.md 29.74)
        logic [3:0]      lq;                    // a load's LQ entry, a store's SQ entry (OOO_LSU)
        logic [3:0]      sq;
        logic [4:0]      st;                    // a load's: the SQ's tail at its dispatch (OOO_LSU3 rr_st)
        logic [1:0]      msize;                 // 0 byte .. 3 double
        logic            uns;                   // a load zero extended
        logic            is_ld;                 // (a µop of port 2: a load, else a store)
        logic            pred_taken;            // it ends a block predicted taken
        logic            ret;
        logic            call;
        logic            is_jalr;
        logic            is_jal;
        logic [2:0]      br_op;
        logic            is_br;
        logic            fused;                 // ALU + branch (B5a): the branch compares the ALU's result
        logic            b_res1a;               // the result is the comparison's first operand
        logic [1:0]      b_osel;                // the other operand: 0 s1, 1 s2, 2 zero
        logic            len4b;                 // the branch half is 32-bit
        logic            word_op;
        logic            b_sel;                 // imm
        logic [1:0]      a_sel;                 // 0 rs1, 1 pc, 2 zero
        logic [1:0]      a_shift;
        logic            a_uw;
        logic [5:0]      alu_op;
        logic [31:0]     imm;                   // sign extended at its use
        logic [11:0]     joff;                  // a jalr's offset; a fused branch's offset (halfwords)
        logic            len4;                  // 32-bit (else RVC)
        logic            xline;                 // its first half in the block before
        logic [3:0]      off;                   // the first half's parcel (blocks of 32 bytes)
        logic [3:0]      e;                     // the last half's parcel
        logic [CW-1:0]   ckpt;
        logic [FTQW-1:0] ftq;                   // the block of its last half
        logic [ROBW-1:0] rob;
    } rec_t;

    // what the DS register keeps besides the tags
    typedef struct packed {
        rec_t            rec;
        logic [VA-1:1]   pc;
        logic            wr;
        logic [4:0]      arch;
        logic [TAGW-1:0] dst;
        logic [TAGW-1:0] old;
        logic            exc;
        logic [4:0]      cause;                 // an exception at decode: illegal, ECALL, EBREAK
        logic [63:0]     tval;
        logic            ld, st;
        logic            ns;                    // non-speculative: issued at the ROB head
        logic            md;                    // answered from outside (OOO_MDUP): the issue queue does not wake for it
        logic [1:0]      port;
        logic            lat2;
        logic            wt;                    // the wait table's bit: a load waits for older stores' data too
        logic [31:0]     insn;
        // the FP side (step 1.8 U2)
        logic            fq;                    // to OOO_FIQ's port A (an FP operation, an FP -> integer one)
        logic            fsd;                   // an FP store (its data to OOO_FIQ's port B)
        logic            fwr;                   // writes an FP register
        logic            f2i;                   // its result is an integer register's
        logic            fdv;                   // a divide or square root
        logic            fpld;                  // an FP load
        logic            i2f;                   // an int -> FP µop
        logic [2:0]      fuse;                  // the FP sources it reads (a store: source 0, its fs2)
        logic [4:0]      farch;
        logic [10:0]     fpl;                   // OOO_FPUW's: int_w, int_signed, rm, fmt, op
`ifdef OOO_TRACE
        logic [31:0]     insn2;                 // a pair's second instruction (the trace only)
`endif
    } dsp_t;

    // ---- recovery and the front end
    logic                fe_redirect, fe_flush, flush_all, restore_port;
    logic                restore /*verilator public_flat_rd*/;     // (counted by SIM/CORE/tb_core)
    logic                restore_k;               // the kill's: not held off by a trap or replay (the LSU's)
    logic [VA-1:1]       fe_pc;
    logic [FTQW-1:0]     restore_ftq, rcv_ftq;
    logic [3:0]          rcv_end;
    logic [CW-1:0]       restore_id;
    logic [NCKPT-1:0]    kill, clr;
    logic [1:0]          ftq_pop;
    logic [1:0][3:0]     br_e     /*verilator public_flat_rd*/;
    // (the resolution's fields are read by SIM/CORE/tb_core, which checks them against the instruction)
    logic [1:0]          br_taken /*verilator public_flat_rd*/;
    logic [1:0]          br_call  /*verilator public_flat_rd*/;
    logic [1:0]          br_ret   /*verilator public_flat_rd*/;
    logic [1:0]          rs_valid /*verilator public_flat_rd*/;
    logic [1:0]          rs_taken /*verilator public_flat_rd*/;
    logic [1:0][FTQW-1:0] rs_ftq;
    logic [1:0][3:0]     rs_e     /*verilator public_flat_rd*/;
    logic                bt_valid /*verilator public_flat_rd*/;
    logic [VA-1:1]       bt_pc    /*verilator public_flat_rd*/;
    logic [VA-1:1]       bt_tgt;
    logic [1:0][FTQW-1:0] ta_idx, pa_idx;
    logic [1:0][VA-1:1]  ta_tgt;
    logic [1:0][VA-1:5]  pa_line;
    logic [2:0]          g_take;

    logic [3:0]          g_valid, g_rvc, g_taken;
    logic [3:0][VA-1:1]  g_pc;
    logic [3:0][31:0]    g_insn;
    logic [3:0][FTQW-1:0] g_ftq;
    logic [3:0][3:0]     g_end;
    logic [3:0]          g_illegal;
    logic [3:0][2:0]     g_cls;
    logic [3:0][4:0]     g_rd, g_rs1, g_rs2;
    logic [3:0]          g_use_rs1, g_use_rs2;
    logic [3:0][31:0]    g_imm;
    logic [3:0][1:0]     g_port;
    logic [3:0]          g_lat2;
    logic [3:0][5:0]     g_alu_op;
    logic [3:0]          g_a_uw;
    logic [3:0][1:0]     g_a_shift, g_a_sel;
    logic [3:0]          g_b_sel, g_word_op, g_is_branch, g_is_jal, g_is_jalr;
    logic [3:0][2:0]     g_br_op;
    logic [3:0][1:0]     g_mem_size;
    /* verilator lint_off UNUSEDSIGNAL */      // (decode's fields B2 does not use: MDU, memory, system, CSR, FP)
    logic [3:0]          g_seq;                 // (a pair's second half follows the first: no pairs now)
    logic [3:0][2:0]     g_op;
    logic [3:0]          g_mem_signed, g_ext_ans, g_nonspec, g_is_sfence, g_is_csr;
    logic [3:0][3:0]     g_mdu_op;
    logic [3:0][7:0]     g_sys;
    logic [3:0]          g_csr_imm_sel, g_csr_wr, g_csr_rd;     // (the CSR unit decodes the instruction itself)
    logic [3:0][4:0]     g_mem_cmd;
    logic [3:0][11:0]    g_csr_addr;
    logic [3:0][1:0]     g_csr_op;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [3:0]          g_is_fp, g_fp_fmt, g_fp_we_rd, g_fp_int_signed, g_fp_int_w;
    logic [3:0][4:0]     g_fp_op, g_rs3, g_frd;
    logic [3:0][2:0]     g_fp_rm, g_use_fs;
    // the FP CSR state decode reads (OOO_CSRU's; a CSR write replays what follows it)
    logic [1:0]          fs;
    logic [2:0]          frm;

    // the fetch's translation (step 1.8 V2): the current privilege (not MPRV), from CORE_CSR's registers (a trap or a
    // return redirects fetch as they change); the walker shared with the LSU (below)
    logic [3:0][1:0]     g_ifault;              // an instruction's fetch faulted (1 page, 2 access)
    logic [3:0]          g_ifx;                 // ... in its last half: tval pc + 2
    logic                it_on, it_au, it_as;
    logic                iw_req;
    logic [VA-1:12]      iw_vpn;
    logic                it_we;
    // PMP (step 1.8 P1): CORE_CSR's 8 entries; the walker's entry checked by OOO_FRONT's checker
    logic [63:0]         pmpcfg;
    logic [511:0]        pmpaddr, pmpmask;
    logic                pw_chk, pw_fail;
    logic            w_req, w_done, w_we, w_u, w_r, w_w, w_x, w_af;
    logic [VA-1:12]  w_vpn, w_tvpn;
    logic [4:0]      w_rid;
    logic [5:0]      w_did;                             // {the fetch's, the LSU's asker}
    logic [PAW-1:12] w_ptag;
    assign it_we = w_we && w_did[5];
    OOO_FRONT #(.VA(VA), .PAW(PAW), .NFTQ(NFTQ), .FTQW(FTQW)) u_front
        (.clk(clk), .rst_n(rst_n),
         .fe_redirect(fe_redirect || boot), .fe_flush(fe_flush || boot), .fe_pc(boot ? boot_pc : fe_pc),
         .restore_ftq(restore_ftq), .restore_port(restore_port), .br_e(br_e), .br_taken(br_taken),
         .br_call(br_call), .br_ret(br_ret), .rcv_ftq(rcv_ftq), .rcv_end(rcv_end),
         .rs_valid(rs_valid), .rs_ftq(rs_ftq), .rs_e(rs_e), .rs_taken(rs_taken),
         .bt_valid(bt_valid), .bt_pc(bt_pc), .bt_tgt(bt_tgt), .ftq_pop(ftq_pop),
         .ta_idx(ta_idx), .ta_tgt(ta_tgt), .pa_idx(pa_idx), .pa_line(pa_line),
         .ic_req_valid(ic_req_valid), .ic_req_pc(ic_req_pc), .ic_req_ptag(ic_req_ptag), .ic_req_tok(ic_req_tok),
         .ic_req_ready(ic_req_ready), .ic_resp_valid(ic_resp_valid), .ic_resp_data(ic_resp_data),
         .g_valid(g_valid), .g_pc(g_pc), .g_insn(g_insn), .g_rvc(g_rvc), .g_ftq(g_ftq), .g_end(g_end),
         .g_taken(g_taken), .g_seq(g_seq), .g_illegal(g_illegal), .g_cls(g_cls), .g_op(g_op), .g_rd(g_rd),
         .g_rs1(g_rs1), .g_rs2(g_rs2), .g_use_rs1(g_use_rs1), .g_use_rs2(g_use_rs2), .g_imm(g_imm),
         .g_port(g_port), .g_lat2(g_lat2), .g_ext_ans(g_ext_ans), .g_nonspec(g_nonspec), .g_alu_op(g_alu_op),
         .g_a_uw(g_a_uw), .g_a_shift(g_a_shift), .g_a_sel(g_a_sel), .g_b_sel(g_b_sel), .g_word_op(g_word_op),
         .g_is_branch(g_is_branch), .g_is_jal(g_is_jal), .g_is_jalr(g_is_jalr), .g_br_op(g_br_op),
         .g_mdu_op(g_mdu_op), .g_mem_cmd(g_mem_cmd), .g_mem_size(g_mem_size), .g_mem_signed(g_mem_signed),
         .g_sys(g_sys), .g_is_sfence(g_is_sfence), .g_is_csr(g_is_csr), .g_csr_addr(g_csr_addr),
         .g_csr_op(g_csr_op), .g_csr_imm_sel(g_csr_imm_sel), .g_csr_wr(g_csr_wr), .g_csr_rd(g_csr_rd),
         .g_is_fp(g_is_fp), .g_fp_op(g_fp_op), .g_fp_fmt(g_fp_fmt), .g_fp_rm(g_fp_rm), .g_use_fs(g_use_fs),
         .g_rs3(g_rs3), .g_frd(g_frd), .g_fp_we_rd(g_fp_we_rd), .g_fp_int_signed(g_fp_int_signed),
         .g_fp_int_w(g_fp_int_w), .g_ifault(g_ifault), .g_ifx(g_ifx), .g_take(g_take),
         .it_on(it_on), .it_au(it_au), .it_as(it_as), .it_flush(tlb_flush_all), .iw_req(iw_req), .iw_vpn(iw_vpn),
         .it_we(it_we), .it_vpn(w_tvpn), .it_ptag(w_ptag), .it_u(w_u), .it_x(w_x), .it_af(w_af),
         .it_priv(priv), .pmp_cfg(pmpcfg), .pmp_addr(pmpaddr), .pmp_mask(pmpmask),
         .pw_chk(pw_chk), .pw_addr(dc_pt_addr), .pw_fail(pw_fail));

    // ---- D2: the group from its oldest valid slot. The valid slots run from
    // hd to the last one given (D2 takes from the oldest, and the register
    // takes a new group only when empty), so the slots that wrap round past
    // slot 3 are below hd and never valid
    logic [1:0]          hd;                    // the oldest valid slot
    logic [3:0][1:0]     rs;                    // rotated slot k is group slot rs[k]
    logic [3:0]          r_v;
    always @(*) begin
        hd = g_valid[0] ? 2'd0 : g_valid[1] ? 2'd1 : g_valid[2] ? 2'd2 : 2'd3;
        for (int k = 0; k < 4; k++) begin
            rs[k]  = hd + 2'(k);
            r_v[k] = g_valid[rs[k]];
        end
    end

    // ---- the wait table (step 1.5b G3, Plan/OOC.md 29.50, 29.53): a bit by pc[8:1], set at the commit of a load
    // that waited for a store's data (OOO_LSU4's cmp_ld_sd, replayed); a load with its bit waits in OOO_IQ3 for
    // the older stores' data too, so that it is not replayed again. Never cleared (there are a few such loads
    // in a program). A copy of 256 x 1 in LUT RAM for each slot of the group register, written alike
    logic [3:0]      wt_g;                      // the group's slots' bits
    logic            wt_we;
    logic [7:0]      wt_wa;
    for (genvar k = 0; k < 4; k++) begin : g_wt
        (* ram_style = "distributed" *) logic wt_ram [256];
        initial for (int i = 0; i < 256; i++) wt_ram[i] = 1'b0;
        always_ff @(posedge clk) if (wt_we) wt_ram[wt_wa] <= 1'b1;
        assign wt_g[k] = wt_ram[g_pc[k][8:1]];
    end

    // the µops: one instruction each, ND of them (Plan/OOC.md 29.19: OOO_FUSE pairs 2 µops out of 4 slots, and
    // with 4 µops a group no pairing is left; ALU + branch has been off since 5.21)
    /* verilator lint_off UNUSEDSIGNAL */
    logic                no_fuse;               // OOO_TRAP: a pair being fetched again (no pairs now)
    /* verilator lint_on UNUSEDSIGNAL */
    logic [ND-1:0]       r_valid, r_ckpt, r_go, ren_wr;
    logic [ND-1:0][1:0]  ren_use;
    logic [ND-1:0][1:0][4:0] ren_src;
    logic [ND-1:0][4:0]  ren_dst;
    logic [ND-1:0][CW-1:0] ren_ckpt_id;
    logic                ren_ready;
    dsp_t [ND-1:0]       d2;
    // FP at D2 (step 1.8 U2): its classes, and an FP instruction that traps (mstatus.FS off; a reserved rounding mode,
    // in the instruction or, dynamic, in frm: mmRISC-2's CPU_CORE)
    logic [ND-1:0]       f_ok, fexc, fpar, fpld, fpst, fi2f, ff2i, fwr_d;
    logic [ND-1:0][2:0][4:0] fren_src;
    logic [ND-1:0][4:0]  fren_dst;
    always @(*) begin
        for (int j = 0; j < ND; j++) begin
            automatic logic [1:0] s  = rs[j];
            automatic logic [2:0] rm = g_fp_rm[s];
            f_ok[j]  = g_is_fp[s] && !g_illegal[s];
            fpar[j]  = f_ok[j] && g_port[s] == 2'd3;
            fpld[j]  = f_ok[j] && g_port[s] == 2'd2 && g_fp_we_rd[s];
            fpst[j]  = f_ok[j] && g_port[s] == 2'd2 && !g_fp_we_rd[s];
            fi2f[j]  = fpar[j] && (g_fp_op[s] == FOP_MV_F_X || g_fp_op[s] == FOP_CVT_F_I);
            ff2i[j]  = fpar[j] && ((g_fp_op[s] >= FOP_EQ && g_fp_op[s] <= FOP_MV_X_F) || g_fp_op[s] == FOP_CVT_I_F);
            fexc[j]  = f_ok[j] && (fs == 2'b00 || (fpar[j] && (rm == 3'd5 || rm == 3'd6 || (rm == 3'd7 && frm >= 3'd5))));
            fwr_d[j] = f_ok[j] && g_fp_we_rd[s] && !fexc[j];
            fren_src[j] = {g_rs3[s], g_rs2[s], g_rs1[s]};
            fren_dst[j] = g_frd[s];
        end
    end
    always @(*) begin
        for (int j = 0; j < ND; j++) begin
            r_valid[j] = r_v[j];
            ren_use[j] = {g_use_rs2[rs[j]], g_use_rs1[rs[j]]};
            ren_src[j] = {g_rs2[rs[j]], g_rs1[rs[j]]};
            ren_wr[j]  = r_valid[j] && g_rd[rs[j]] != 5'd0 && !fexc[j];   // (renaming's ready counts the destinations offered)
            ren_dst[j] = g_rd[rs[j]];
            r_ckpt[j]  = g_is_branch[rs[j]] || g_is_jalr[rs[j]];
        end
    end
    always @(*) begin
        logic [1:0] s;
        logic       jmp, link_rd, link_rs1, sysop_v, at, ifl;
        logic [2:0] sysop;
        logic [VA-1:1] ipc;
        for (int j = 0; j < ND; j++) begin
            s        = rs[j];
            // OOO_SYS's operations: 0 FENCE, 1 FENCE.I, 2 SFENCE.VMA, 3 MRET, 4 WFI, 5 SRET (decode's sys:
            // wfi, sret, mret, ebreak, ecall, cbo, fence.i, fence)
            sysop_v  = g_sys[s][0] || g_sys[s][1] || g_is_sfence[s] || g_sys[s][5] || g_sys[s][7] || g_sys[s][6];
            sysop    = g_sys[s][1] ? 3'd1 : g_is_sfence[s] ? 3'd2 : g_sys[s][5] ? 3'd3 : g_sys[s][7] ? 3'd4 :
                       g_sys[s][6] ? 3'd5 : 3'd0;
            jmp      = g_is_jal[s] || g_is_jalr[s];
            link_rd  = g_rd[s] == 5'd1 || g_rd[s] == 5'd5;
            link_rs1 = g_rs1[s] == 5'd1 || g_rs1[s] == 5'd5;
            // an atomic (step 1.4 E1c, slot 0 only): LR a load, SC a store, an AMO both (an LQ entry and an SQ entry)
            at       = g_port[s] == 2'd2 && g_mem_cmd[s] >= 5'd2 && g_mem_cmd[s] <= 5'd12 && !g_is_fp[s] && !g_illegal[s];
            d2[j]                = '0;
            d2[j].rec.pred_taken = g_taken[s];
            d2[j].rec.call       = g_is_jalr[s] && link_rd;
            d2[j].rec.ret        = g_is_jalr[s] && link_rs1 && !link_rd;
            d2[j].rec.is_jalr    = g_is_jalr[s];
            d2[j].rec.is_jal     = g_is_jal[s];
            d2[j].rec.br_op      = g_br_op[s];
            d2[j].rec.is_br      = g_is_branch[s];
            d2[j].rec.len4b      = !g_rvc[s];
            d2[j].rec.word_op    = jmp ? 1'b0 : g_word_op[s];
            d2[j].rec.b_sel      = jmp ? 1'b1 : g_b_sel[s];
            d2[j].rec.a_sel      = jmp ? 2'd1 : g_a_sel[s];             // the link: pc + length
            d2[j].rec.a_shift    = jmp ? 2'd0 : g_a_shift[s];
            d2[j].rec.a_uw       = jmp ? 1'b0 : g_a_uw[s];
            d2[j].rec.alu_op     = jmp ? 6'd0 : g_alu_op[s];            // (ADD)
            d2[j].rec.imm        = jmp ? (g_rvc[s] ? 32'd2 : 32'd4) :
                                   fi2f[j] ? {21'd0, g_fp_int_w[s], g_fp_int_signed[s], g_fp_rm[s], g_fp_fmt[s], g_fp_op[s]} : g_imm[s];
            d2[j].rec.joff       = g_imm[s][11:0];
            d2[j].rec.len4       = !g_rvc[s];
            d2[j].rec.xline      = !g_rvc[s] && g_pc[s][4:1] == 4'd15;
            d2[j].rec.off        = g_pc[s][4:1];
            d2[j].rec.e          = g_end[s];
            d2[j].rec.ckpt       = ren_ckpt_id[j];
            d2[j].rec.ftq        = g_ftq[s];
            d2[j].rec.msize      = g_mem_size[s];
            d2[j].rec.uns        = !g_mem_signed[s];
            d2[j].rec.is_ld      = g_cls[s] == 3'd4 || (at && g_mem_cmd[s] != 5'd3) || fpld[j];
            d2[j].ld             = g_cls[s] == 3'd4 || (at && g_mem_cmd[s] != 5'd3) || fpld[j];
            d2[j].st             = g_cls[s] == 3'd5 || (at && g_mem_cmd[s] != 5'd2) || fpst[j];
            d2[j].rec.fpd        = fpld[j];
            d2[j].rec.fx         = fi2f[j];
            d2[j].fq             = fpar[j] && !fi2f[j];
            d2[j].fsd            = fpst[j];
            d2[j].fwr            = fwr_d[j];
            d2[j].f2i            = ff2i[j];
            d2[j].fdv            = fpar[j] && (g_fp_op[s] == FOP_DIV || g_fp_op[s] == FOP_SQRT);
            d2[j].fpld           = fpld[j];
            d2[j].i2f            = fi2f[j];
            d2[j].fuse           = fpst[j] ? 3'b001 : g_use_fs[s];
            d2[j].farch          = g_frd[s];
            d2[j].fpl            = {g_fp_int_w[s], g_fp_int_signed[s], g_fp_rm[s], g_fp_fmt[s], g_fp_op[s]};
            d2[j].pc             = g_pc[s];
            d2[j].wr             = ren_wr[j];
            d2[j].arch           = g_rd[s];
            d2[j].rec.kind       = g_cls[s] == 3'd6 ? K_MDU : g_is_csr[s] ? K_CSR : sysop_v ? K_SYS : K_ALU;
            d2[j].rec.xop        = g_cls[s] == 3'd6 ? g_mdu_op[s] : at ? g_mem_cmd[s][3:0] : {1'b0, sysop};
            // a fetch fault (step 1.8 V2: 12 a page fault, 1 an access fault; tval its pc, + 2 if in its last half), illegal
            // (an FP instruction with FS off or a reserved rounding mode too), EBREAK, ECALL
            ifl                  = g_ifault[s] != 2'd0;
            ipc                  = g_pc[s] + (VA - 1)'(g_ifx[s]);
            d2[j].exc            = ifl || g_illegal[s] || fexc[j] || g_sys[s][4] || g_sys[s][3];
            d2[j].cause          = ifl ? (g_ifault[s] == 2'd1 ? 5'd12 : 5'd1) :
                                   (g_illegal[s] || fexc[j]) ? 5'd2 : g_sys[s][4] ? 5'd3 : (5'd8 | 5'(priv));
            d2[j].tval           = ifl ? {{(64 - VA){ipc[VA-1]}}, ipc, 1'b0}
                                 : (g_illegal[s] || fexc[j]) ? {32'd0, g_insn[s]}     // (an RVC one: the upper half 0, OOO_FBUF)
                                 : g_sys[s][4] ? {{(64 - VA){g_pc[s][VA-1]}}, g_pc[s], 1'b0} : 64'd0;
            d2[j].ns             = g_nonspec[s];
            d2[j].md             = g_ext_ans[s];
            d2[j].port           = fi2f[j] ? 2'd1 : g_port[s];          // (an int -> FP µop: port 0, its operand there)
            d2[j].lat2           = g_lat2[s];
            d2[j].wt             = wt_g[s];
            d2[j].insn           = g_insn[s];
`ifdef OOO_TRACE
            d2[j].insn2          = g_insn[s];
`endif
        end
    end
    // instructions taken: r_go is a prefix
    assign g_take = r_go[3] ? 3'd4 : r_go[2] ? 3'd3 : r_go[1] ? 3'd2 : r_go[0] ? 3'd1 : 3'd0;

    // ---- the wakeups, commit, the ROB, the issue queue (declared for renaming and CTRL)
    logic [NWK-1:0]            wk_valid;
    logic [NWK-1:0][TAGW-1:0]  wk_tag;
    logic [ND-1:0]             free_valid, cmt_valid, cmt_wr;
    logic [2:0]                cmt_ld_n, cmt_st_n;
    logic [ND-1:0][TAGW-1:0]   free_tag, cmt_new, cmt_old;
    logic [ND-1:0][4:0]        cmt_arch;
    logic [ND-1:0][VA-1:1]     cmt_pc;
    logic [ND-1:0][FTQW-1:0]   cmt_ftq;
    logic [ND-1:0][FXW-1:0]    dv_fx, cmt_fx;                 // the FP destination through OOO_ROB (step 1.8 U3b)

    // ---- renaming: 4 slots
    logic [ND-1:0]             d_go;
    logic [3:0]                r1_wr, r2_wr_all;
    logic [3:0][TAGW-1:0]      r1_tag, r2_dst_all, r2_old_all;
    logic [3:0][1:0][TAGW-1:0] r2_src_all;
    logic [3:0][CW-1:0]        r1_ckid;
    /* verilator lint_off UNUSEDSIGNAL */      // (R2's valid and checkpoint: the DS register has them from D2)
    logic [3:0]                r2_v_all, r2_ck_all;
    logic [3:0][CW-1:0]        r2_ckid_all;
    logic                      r1_adv;
    logic [2:0]                r1_take;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [3:0][1:0]           ren_rdy;
    OOO_RENAME2 #(.NREG(80), .TAGW(TAGW), .NCK(NCKPT)) u_rename
        (.clk(clk), .rst_n(rst_n), .in_valid(r_go), .in_src(ren_src),
         .in_wr(ren_wr), .in_dst(ren_dst), .in_ckpt(r_ckpt), .in_take(r1_take),
         .r1_adv(r1_adv), .r1_wr(r1_wr), .r1_tag(r1_tag), .r1_ready(ren_ready), .r1_ckid(r1_ckid),
         .r2_valid(r2_v_all), .r2_src(r2_src_all), .r2_wr(r2_wr_all), .r2_dst(r2_dst_all), .r2_old(r2_old_all),
         .r2_ck(r2_ck_all), .r2_ckid(r2_ckid_all), .disp_go(d_go),
         .cmt_wr(free_valid), .cmt_arch(cmt_arch), .cmt_new(cmt_new),
         .cmt_old(free_tag), .restore(restore), .restore_id(restore_id), .flush_all(flush_all));
    assign ren_ckpt_id = r1_ckid;
    OOO_BUSY #(.NREG(80), .TAGW(TAGW), .NWK(NWK)) u_busy
        (.clk(clk), .rst_n(rst_n), .set_v(r1_wr), .set_t(r1_tag), .wk_valid(wk_valid), .wk_tag(wk_tag),
         .rd_t(r2_src_all), .rd_rdy(ren_rdy));

    // ---- the FP side's declarations (step 1.8 U2; the blocks below)
    logic                      fren_ready;
    logic [3:0]                f1_wr;
    logic [3:0][FTAGW-1:0]     f1_tag;
    logic [3:0][2:0][FTAGW-1:0] f2_src;
    /* verilator lint_off UNUSEDSIGNAL */      // (R2's write bit: the DS register has it from D2)
    logic [3:0]                f2_wr;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [3:0][FTAGW-1:0]     f2_dst, f2_old;
    logic [ND-1:0]             fcmt_wr;
    logic [ND-1:0][4:0]        fcmt_arch;
    logic [ND-1:0][FTAGW-1:0]  fcmt_new, fcmt_old;
    logic [3:0]                fwk_v;                   // the FP wakeups: the FPU's, the 2 load ports' (in their RR), none
    logic [3:0][FTAGW-1:0]     fwk_t;
    logic [3:0][1:0]           fbsy_a, fbsy_b;
    logic [ND-1:0][2:0]        frdy;
    logic [2:0]                fq_ready;
    logic                      x_ready, xf_ok, f2i_wr, f2i_hold, iw_ack, fw_valid, iw_valid;
    logic [TAGW-1:0]           iw_tag;
    logic [63:0]               iw_data, fw_data;
    logic [ROBW-1:0]           iw_rob, fw_rob;
    logic [4:0]                iw_flags, fw_flags;
    logic [FTAGW-1:0]          fw_tag;
    logic [4:0]                f_fl_set;
    logic [ND-1:0]             fq_disp, fq_cand;        // to OOO_FIQ (below)
    logic                      f_dirty;

    // ---- the FP registers' renaming (OOO_FREN, beside OOO_RENAME2 and in step with it: its r1_adv, the checkpoints'
    // ids; the group goes when both are ready, OOO_CTRL's r_ren_ready) and the FP file's busy bits
    OOO_FREN #(.NREG(NFREG), .TAGW(FTAGW), .NCK(NCKPT)) u_fren
        (.clk(clk), .rst_n(rst_n), .in_valid(r_go), .in_src(fren_src), .in_wr(fwr_d), .in_dst(fren_dst),
         .in_ckpt(r_ckpt), .in_ckid(r1_ckid), .adv(r1_adv), .ready(fren_ready),
         .r1_wr(f1_wr), .r1_tag(f1_tag), .r2_src(f2_src), .r2_wr(f2_wr), .r2_dst(f2_dst), .r2_old(f2_old),
         .cmt_wr(fcmt_wr), .cmt_arch(fcmt_arch), .cmt_new(fcmt_new), .cmt_old(fcmt_old),
         .restore(restore), .restore_id(restore_id), .flush_all(flush_all));
    logic [3:0][1:0][FTAGW-1:0] fb_ta, fb_tb;
    always @(*)
        for (int j = 0; j < ND; j++) begin
            fb_ta[j] = {f2_src[j][1], f2_src[j][0]};
            fb_tb[j] = {f2_src[j][2], f2_src[j][2]};
            frdy[j]  = {fbsy_b[j][0], fbsy_a[j][1], fbsy_a[j][0]};
        end
    OOO_BUSY #(.NREG(NFREG), .TAGW(FTAGW), .NWK(4)) u_fbusy_a
        (.clk(clk), .rst_n(rst_n), .set_v(f1_wr), .set_t(f1_tag), .wk_valid(fwk_v), .wk_tag(fwk_t),
         .rd_t(fb_ta), .rd_rdy(fbsy_a));
    OOO_BUSY #(.NREG(NFREG), .TAGW(FTAGW), .NWK(4)) u_fbusy_b      // (the third source: fs3)
        (.clk(clk), .rst_n(rst_n), .set_v(f1_wr), .set_t(f1_tag), .wk_valid(fwk_v), .wk_tag(fwk_t),
         .rd_t(fb_tb), .rd_rdy(fbsy_b));

    // ---- DS
    logic [2:0]                rob_avail, iq_ready;
    /* verilator lint_off UNUSEDSIGNAL */      // (d_go says what dispatches)
    logic [ND-1:0]             ds_valid;
    /* verilator lint_on UNUSEDSIGNAL */
    logic                      ds_load;
    logic [ND-1:0][NCKPT-1:0]  d_bmask;
    logic [ND-1:0][1:0][TAGW-1:0] ds_src;
    logic [ND-1:0][1:0]        ds_use, ds_rdy;
    dsp_t [ND-1:0]             ds;
    logic [ND-1:0][ROBW-1:0]   disp_rob;
    logic [ND-1:0][IQW-1:0]    disp_entry;
    // the DS µops' fields by slot, for the units' ports
    logic [ND-1:0]             dv_ld, dv_st, dv_wr, dv_ns, dv_exc, dv_iqwr, dv_lat2, dv_md, dv_wt;
    logic [ND-1:0][FTQW-1:0]   dv_ftq;
    logic [ND-1:0][VA-1:1]     dv_pc;
    logic [ND-1:0][4:0]        dv_arch, dv_cause;
    logic [ND-1:0][TAGW-1:0]   dv_dst, dv_old;
    logic [ND-1:0][1:0]        dv_port;

    // the DS register: the tags are R2's, the ready bits from the busy bits as of now
    // (OOO_BUSY: no snoop is needed), and the rest of the µop travels beside them
    dsp_t [ND-1:0]             ds_q;
    logic [ND-1:0][1:0]        ds_use_q;
    always_ff @(posedge clk) begin
        if (ds_load) begin
            ds_q     <= d2;
            ds_use_q <= ren_use;
        end
    end
    always @(*) begin
        ds     = ds_q;
        ds_use = ds_use_q;
        for (int j = 0; j < ND; j++) begin
            ds[j].dst = r2_wr_all[j] ? r2_dst_all[j] : '0;   // (tag 0: a result for x0 is not written, 5.7)
            ds[j].old = r2_old_all[j];
            ds_src[j] = r2_src_all[j];
            ds_rdy[j] = ren_rdy[j];
        end
        for (int j = 0; j < ND; j++) begin
            dv_ld[j]    = ds[j].ld;
            dv_st[j]    = ds[j].st;
            dv_wr[j]    = ds[j].wr;
            dv_ns[j]    = ds[j].ns;
            dv_exc[j]   = ds[j].exc;
            dv_iqwr[j]  = ds[j].wr && !ds[j].md;
            dv_lat2[j]  = ds[j].lat2;
            dv_md[j]    = ds[j].md && ds[j].rec.kind == K_MDU;
            dv_wt[j]    = ds[j].wt;
            dv_ftq[j]   = ds[j].rec.ftq;
            dv_pc[j]    = ds[j].pc;
            dv_arch[j]  = ds[j].arch;
            dv_cause[j] = ds[j].cause;
            dv_dst[j]   = ds[j].dst;
            dv_old[j]   = ds[j].old;
            dv_port[j]  = ds[j].port;
        end
    end

    // the resolution (registered: e_* as EX makes it, Plan/CORE.md 5.20)
    logic [1:0]                br_valid /*verilator public_flat_rd*/;
    logic [1:0]                br_mispred;
    logic [1:0][CW-1:0]        br_ckpt;
    logic [1:0][VA-1:1]        br_next;
    logic [1:0][ROBW-1:0]      br_rob   /*verilator public_flat_rd*/;
    logic [1:0][VA-1:1]        br_pc    /*verilator public_flat_rd*/;     // (tb_core: the pc it resolved at)
    logic [1:0]                e_br_valid, e_br_mispred, e_br_taken, e_br_call, e_br_ret, e_rs_valid, e_rs_taken;
    logic [1:0][CW-1:0]        e_br_ckpt;
    logic [1:0][VA-1:1]        e_br_next;
    logic [1:0][ROBW-1:0]      e_br_rob;
    logic [1:0][3:0]           e_br_e, e_rs_e;
    logic [1:0][FTQW-1:0]      e_rs_ftq;
    logic                      e_bt_valid;
    logic [VA-1:1]             e_bt_pc, e_bt_tgt;
    logic                      rob_restore, rob_trap, trap, head_ns, iss_ns, ns_ok, ns_busy, irq;
    logic                      k_v;                     // the kill's misprediction, chosen at EX's end (step 1.8 V3d, below)
    logic [CW-1:0]             k_ckpt;
    logic                      replay /*verilator public_flat_rd*/;      // (counted by SIM/CORE/tb_core)
    logic [VA-1:1]             rob_replay_pc, replay_pc, trap_vec;
    logic [ROBW-1:0]           head_rob;
    logic [4:0]                trap_cause;
    logic [VA-1:1]             trap_pc;

    // the LSU's side of dispatch, commit and recovery
    logic [2:0]                lq_avail, sq_avail, lq_commit, sq_commit;
    logic [ND-1:0][4:0]        ck_lq_tail, ck_sq_tail;
    logic [4:0]                restore_lq_tail, restore_sq_tail;
    logic [ND-1:0][3:0]        disp_lq, disp_sq;
    logic [ND-1:0][4:0]        disp_st;

    logic [2:0]                ev_dwait;                // what dispatch and renaming wait for (the PMU's events)
    logic                      ev_rreg, ev_rckpt;
    /* verilator lint_off PINCONNECTEMPTY */   // (what OOO_TRAP and interrupts take: not yet)
    OOO_CTRL #(.NCKPT(NCKPT), .CW(CW), .VA(VA), .FTQW(FTQW), .LW(4), .TAGW(TAGW), .ND(ND)) u_ctrl
        (.clk(clk), .rst_n(rst_n),
         .r_valid(r_valid), .r_ckpt(r_ckpt), .r_ckpt_id(ren_ckpt_id), .r_ren_ready(ren_ready && fren_ready), .r_go(r_go),
         .ds_valid(ds_valid), .ds_load(ds_load), .ds_ld(dv_ld), .ds_st(dv_st),
         .ds_ftq(dv_ftq), .rob_avail(rob_avail), .iq_avail(iq_ready),
         .lq_avail(lq_avail), .sq_avail(sq_avail), .ck_lq_tail(ck_lq_tail), .ck_sq_tail(ck_sq_tail), .d_go(d_go), .d_bmask(d_bmask),
         .br_valid(br_valid), .br_mispred(br_mispred), .br_ckpt(br_ckpt), .br_next(br_next),
         .cl_valid(br_valid & ~br_mispred), .cl_ckpt(br_ckpt),
         .rob_restore(rob_restore), .rob_restore_k(k_v), .rob_restore_ckpt(k_ckpt), .trap(trap), .replay(replay),
         .replay_pc(replay_pc), .trap_vec(trap_vec), .head_ns(head_ns),     // (trap, trap_vec, replay_pc: OOO_TRAP)
         .cmt_valid(cmt_valid), .cmt_wr(cmt_wr), .cmt_old(cmt_old), .cmt_ld_n(cmt_ld_n), .cmt_st_n(cmt_st_n),
         .cmt_ftq(cmt_ftq), .iss_ns(iss_ns), .ns_ok(ns_ok), .ns_busy(ns_busy),
         .fe_flush(fe_flush), .flush_all(flush_all), .restore(restore), .restore_k(restore_k), .restore_id(restore_id),
         .restore_port(restore_port), .restore_lq_tail(restore_lq_tail), .restore_sq_tail(restore_sq_tail), .restore_ftq(restore_ftq),
         .kill(kill), .clr(clr), .fe_redirect(fe_redirect), .fe_pc(fe_pc), .live(),
         .free_valid(free_valid), .free_tag(free_tag), .lq_commit(lq_commit), .sq_commit(sq_commit), .ftq_pop(ftq_pop),
         .ev_dwait(ev_dwait), .ev_rreg(ev_rreg), .ev_rckpt(ev_rckpt));

    // the ROB
    // completion: 0 port 0's EX, 1 port 1's EX, 2 the LSU's loads, 3 its stores, 4 port 0's multiplier and
    // MDU (their results), 5 the system unit, 6 / 7 the mispredicted branches of ports 0 / 1 with their restore,
    // (after the ALU ports) 8 the CSR unit, 9 an FP -> integer result, 10 an FP result (step 1.8 U2)
    localparam int NCMP = NAP + 10;
    logic [NCMP-1:0]           cmp_valid, cmp_exc, cmp_rp;
    logic [NCMP-1:0][ROBW-1:0] cmp_rob;
    logic [NCMP-1:0][4:0]      cmp_cause;
    logic [ND-1:0]             disp_go;
    assign disp_go = d_go;
    logic                      head_valid, head_fused, head_mem;
    logic [ROBW-1:0]           rob_restore_rob;
    logic [3:0]                cmt_instret;
    logic [ND-1:0][2:0]        disp_len;                    // halfwords
    logic [ND-1:0]             disp_fused;
    always @(*)
        for (int j = 0; j < ND; j++) begin
            disp_len[j]   = (ds[j].rec.len4 ? 3'd2 : 3'd1) + ((FUSE_AB && ds[j].rec.fused) ? (ds[j].rec.len4b ? 3'd2 : 3'd1) : 3'd0);
            disp_fused[j] = FUSE_AB && ds[j].rec.fused;
        end
    OOO_ROB #(.NROB(NROB), .ROBW(ROBW), .VA(VA), .TAGW(TAGW), .CW(CW), .NCMP(NCMP), .FTQW(FTQW), .ND(ND), .PB(4), .XW(FXW)) u_rob
        (.clk(clk), .rst_n(rst_n), .rob_avail(rob_avail), .disp_valid(disp_go),
         .disp_pc(dv_pc), .disp_wr(dv_wr), .disp_arch(dv_arch),
         .disp_new(dv_dst), .disp_old(dv_old), .disp_ld(dv_ld), .disp_st(dv_st),
         .disp_fused(disp_fused), .disp_ns(dv_ns), .disp_len(disp_len),
         .disp_ftq(dv_ftq), .disp_exc(dv_exc), .disp_cause(dv_cause), .disp_x(dv_fx),
         .disp_rob(disp_rob),
         .cmp_valid(cmp_valid), .cmp_rob(cmp_rob), .cmp_exc(cmp_exc), .cmp_cause(cmp_cause), .cmp_rp(cmp_rp),
         .br_valid(br_valid), .br_rob(br_rob), .br_mispred(br_mispred), .br_ckpt(br_ckpt),
         .restore(rob_restore), .restore_k(), .restore_rob(rob_restore_rob), .restore_ckpt(),
         .head_rob(head_rob), .head_ns(head_ns), .head_valid(head_valid), .head_fused(head_fused), .head_mem(head_mem), .irq(irq),
         .cmt_valid(cmt_valid), .cmt_wr(cmt_wr), .cmt_arch(cmt_arch), .cmt_new(cmt_new), .cmt_old(cmt_old),
         .cmt_pc(cmt_pc), .cmt_ftq(cmt_ftq), .cmt_x(cmt_fx), .cmt_ld_n(cmt_ld_n), .cmt_st_n(cmt_st_n), .cmt_instret(cmt_instret),
         .trap(rob_trap), .trap_cause(trap_cause), .trap_pc(trap_pc), .replay(replay), .replay_pc(rob_replay_pc),
         .rcv_ftq(rcv_ftq), .rcv_end(rcv_end));

    // ---- the instructions by ROB entry (what a CSR or system µop reads in EX: its fields, its tval)
    logic [31:0]               rob_insn [NROB];
    always_ff @(posedge clk)
        for (int j = 0; j < ND; j++) if (disp_go[j]) rob_insn[disp_rob[j]] <= ds[j].insn;

    // ---- OOO_TRAP: exceptions and interrupts at the head; the CSRs' trap side
    localparam int NTV = ND + 3;                // tval: the dispatch slots, LSU0 (misaligned), port 0 (CSR / system), LSU1
    logic [NTV-1:0]            tv_valid;
    logic [NTV-1:0][ROBW-1:0]  tv_rob;
    logic [NTV-1:0][63:0]      tv_val;
    logic                      irq_pend, x_ret, x_sret, csr_trap, csr_int, csr_mret, csr_sret, wfi_wake;
    logic [30:0][3:0]          hpm_ev /*verilator public_flat_rd*/;    // the PMU's events, registered (below; checked by SIM/CORE/tb_core)
    logic [4:0]                irq_cause, csr_cause;
    logic [VA-1:1]             tvec, mepc, sepc, csr_epc;
    logic [63:0]               csr_tval;
    /* verilator lint_off UNUSEDSIGNAL */      // (fusion is off until B5)
    /* verilator lint_on UNUSEDSIGNAL */
    OOO_TRAP #(.VA(VA), .NROB(NROB), .ROBW(ROBW), .NTV(NTV)) u_trap
        (.clk(clk), .rst_n(rst_n),
         .rob_trap(rob_trap), .rob_cause(trap_cause), .rob_pc(trap_pc), .head_valid(head_valid), .head_fused(head_fused),
         .head_rob(head_rob), .rob_replay(replay), .rob_replay_pc(rob_replay_pc), .cmt_instret(cmt_instret),
         .restore(rob_restore), .restore_rob(rob_restore_rob), .irq(irq),
         .ns_busy(ns_busy), .flush_all(flush_all), .take(trap), .vec(trap_vec), .rp_pc(replay_pc),
         .x_ret(x_ret), .x_sret(x_sret), .tv_valid(tv_valid), .tv_rob(tv_rob), .tv_val(tv_val),
         .irq_pend(irq_pend), .irq_cause(irq_cause), .tvec(tvec), .mepc(mepc), .sepc(sepc),
         .csr_trap(csr_trap), .csr_epc(csr_epc), .csr_int(csr_int), .csr_cause(csr_cause), .csr_tval(csr_tval),
         .csr_mret(csr_mret), .csr_sret(csr_sret), .no_fuse(no_fuse));
    always @(*) begin
        for (int j = 0; j < ND; j++) begin                        // an exception at decode
            tv_valid[j] = disp_go[j] && ds[j].exc;
            tv_rob[j]   = disp_rob[j];
            tv_val[j]   = ds[j].tval;
        end
    end

    // the issue queue and its payload (an exception at decode is never issued)
    /* verilator lint_off UNUSEDSIGNAL */      // (port NAP, the LSU's: not in B2)
    logic [ND-1:0]             iq_disp, iq_cand;
    logic [NAP+1:0]            iss_valid, iss_wr;
    logic [NAP+1:0][IQW-1:0]   iss_entry;
    logic [NAP+1:0][1:0][TAGW-1:0] iss_src;
    logic [NAP+1:0][TAGW-1:0]  iss_dst;
    logic [NAP+1:0][NCKPT-1:0] iss_bm;
    /* verilator lint_off UNUSEDSIGNAL */
    rec_t [NAP+1:0]            rr_rec;
    /* verilator lint_on UNUSEDSIGNAL */
    logic                      iss_md, iss_sd, mdu_ok, p0_hold, md_ext_v;
    logic [TAGW-1:0]           md_ext_t;
    logic                      at_wk_v;                 // an AMO's or SC's result written (OOO_LSU4, step 1.4 E1c): its wakeup
    logic [TAGW-1:0]           at_wk_t;
    // (an FP operation goes to OOO_FIQ alone; an FP store's address, an FP load and an int -> FP µop to this queue)
    logic [ND-1:0]             dv_fq, dv_fsd, dv_i2f;
    logic [ND-1:0][TAGW-1:0]   iq_dst;                  // an FP load's, an int -> FP µop's: the FP tag (not woken here: wr 0)
    always @(*)
        for (int j = 0; j < ND; j++) begin
            dv_fq[j]  = ds[j].fq;
            dv_fsd[j] = ds[j].fsd;
            dv_i2f[j] = ds[j].i2f;
            iq_dst[j] = (ds[j].fpld || ds[j].i2f) ? TAGW'(f2_dst[j]) : dv_dst[j];
        end
    assign iq_disp = d_go & ~dv_exc & ~dv_fq;
    assign iq_cand = ds_valid & ~dv_exc & ~dv_fq;      // (iq_disp is these or none: the banks need not wait for the go)
    // OOO_IQ3: ALU ports 0..3 (port 1 also a store's data, iss_sd), LSU0 (port 4: loads, stores' addresses) and
    // LSU1 (port 5, step 1.3 E1)
    logic [2:0]                q_ready;
    logic [3:0][IQW-1:0]       q_entry;
    logic [5:0]                q_valid, q_wr;
    logic [5:0][IQW-1:0]       q_ientry;
    logic [5:0][1:0][TAGW-1:0] q_src;
    logic [5:0][TAGW-1:0]      q_dst;
    logic [5:0][NCKPT-1:0]     q_bm;
    OOO_IQ3 #(.N(NIQ), .TAGW(TAGW), .NEXT(2), .NCK(NCKPT)) u_iq
        (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr), .ns_ok(ns_ok), .mdu_ok(mdu_ok),
         .p0_hold(p0_hold || f2i_hold), .xf_ok(xf_ok), .disp_ready(q_ready), .disp_entry(q_entry), .disp_valid(iq_disp), .disp_cand(iq_cand),
         .disp_port(dv_port), .disp_use(ds_use), .disp_src(ds_src), .disp_rdy(ds_rdy),
         .disp_wr(dv_iqwr), .disp_dst(iq_dst), .disp_lat2(dv_lat2), .disp_bm(d_bmask), .disp_ns(dv_ns),
         .disp_md(dv_md), .disp_st(dv_st), .disp_wt(dv_wt), .disp_nd(dv_fsd), .disp_xf(dv_i2f),
         // (an FP -> integer result is written through port 0's slot when the MDU leaves it: its wakeup on the MDU's bus)
         .ext_valid({at_wk_v, md_ext_v || f2i_wr}), .ext_tag({at_wk_t, md_ext_v ? md_ext_t : iw_tag}),
         .iss_valid(q_valid), .iss_entry(q_ientry), .iss_src(q_src), .iss_wr(q_wr), .iss_dst(q_dst),
         .iss_bm(q_bm), .iss_ns(iss_ns), .iss_md(iss_md), .iss_sd(iss_sd), .wk_valid(wk_valid), .wk_tag(wk_tag));
    // each queue's room against its own µops of the group (step 1.8 U2b): OOO_CTRL compares iq_avail with all the group's
    logic [2:0]                n_iq, n_fq;
    always @(*) begin
        n_iq = '0;
        n_fq = '0;
        for (int j = 0; j < ND; j++) begin
            n_iq = n_iq + 3'(iq_cand[j]);
            n_fq = n_fq + 3'(fq_cand[j]);
        end
    end
    assign iq_ready   = (q_ready >= n_iq && fq_ready >= n_fq) ? 3'd4 : 3'd0;
    assign disp_entry = q_entry;
    always @(*) begin
        for (int p = 0; p <= NAP + 1; p++) begin
            automatic int q = p >= NAP ? 4 + p - NAP : p;       // (the queue's LSU0, LSU1 are its ports 4, 5 whatever NA is)
            iss_valid[p] = q_valid[q];
            iss_entry[p] = q_ientry[q];
            iss_src[p]   = q_src[q];
            iss_wr[p]    = q_wr[q];
            iss_dst[p]   = q_dst[q];
            iss_bm[p]    = q_bm[q];
        end
    end

    rec_t [ND-1:0]             wrec;
    always @(*) begin
        for (int j = 0; j < ND; j++) begin
            wrec[j]     = ds[j].rec;
            wrec[j].rob = disp_rob[j];
            wrec[j].lq  = disp_lq[j];
            wrec[j].sq  = disp_sq[j];
            wrec[j].st  = disp_st[j];
        end
    end
    OOO_IQPL2 #(.N(NIQ), .NBANK(4), .W($bits(rec_t)), .NR(NAP + 2)) u_iqpl
        (.clk(clk), .wr_valid(iq_disp), .wr_cand(iq_cand), .wr_entry(disp_entry), .wr_data(wrec),
         .iss_entry(iss_entry), .rr_data(rr_rec));
    /* verilator lint_on PINCONNECTEMPTY */

    // ---- the ports: RR, EX (and WB for the ALU ports; the LSU has its own M and WB)
    localparam int RRW = 3 * TAGW + 1;                          // sources, destination, writes
    typedef struct packed {
        logic [63:0]     v1, v2;                                // the sources as read in RR
        logic [TAGW-1:0] t1, t2;
        logic [TAGW-1:0] dst;
        logic            wr;
        rec_t            rec;
        logic [VA-1:5]   line;                                  // the pc array's line of its first half
        logic [VA-1:1]   ta;                                    // the target array: its block's predicted next
        logic            sd;                                    // port 1: a store's data (source 2), for OOO_LSU4
    } ex_t;
    localparam int WBW = TAGW + 64;

    logic [2*NAP+1:0][TAGW-1:0] prf_ra;                // (LSU0's and LSU1's one source each: 2 * NAP, 2 * NAP + 1)
    logic [2*NAP+1:0][63:0]    prf_rd;
    logic [NAP+1:0]            prf_we;
    logic [NAP+1:0][TAGW-1:0]  prf_wa;
    logic [NAP+1:0][63:0]      prf_wd;
    logic [NAP-1:0]            wb_v;
    logic [NAP-1:0][WBW-1:0]   wb_d;
    // the bypass sources: the ALU ports' WB registers and the loads' (OOO_LSU3's results in M, through a
    // register here: a wrong value of a miss replays what used it at the load's commit, D-12)
    logic [1:0]                lw_v;
    logic [1:0][63:0]          lw_d;
    logic [NAP+1:0]            byp_v;
    logic [NAP+1:0][63:0]      byp_d;
    // (step 1.8 V3b's next, V3c, Plan/OOC.md 29.93) each source's tag of the next cycle, as its register takes it now
    // (the WB stages' input, the loads' in M): RR compares its sources with them into a register, which EX takes in
    // place of the compare it made (the same to the bit: these registers and RR -> EX always take their inputs)
    logic [NAP+1:0][TAGW-1:0]  byp_nt;
    always @(*) begin
        for (int q = 0; q < NAP; q++) begin
            byp_v[q] = wb_v[q];
            byp_d[q] = wb_d[q][63:0];
        end
        for (int m = 0; m < 2; m++) begin
            byp_v[NAP + m] = lw_v[m];                   // (a load to x0 has tag 0: never forwarded, the PRF reads it as 0)
            byp_d[NAP + m] = lw_d[m];
        end
    end
    logic [NAP-1:0]            ex_v;
    logic                      pm_w, md_w;     // port 0's multiplier / MDU result written (below)
    logic                      md_wr, wbw0;    // the MDU's register-file write (also when killed now), port 0's
    logic                      pm_wr, wbw1;    // the multiplier's, port 1's (Plan/OOC.md 29.42)
    ex_t  [NAP-1:0]            ex;
    logic [NAP-1:0][63:0]      ex_res;
    /* verilator lint_off UNUSEDSIGNAL */      // (ALU1..3: no branch; port 0's units read port 0's operands)
    logic [NAP-1:0]            ex_tk;
    logic [1:0][VA-1:1]        ex_pc /*verilator public_flat_rd*/;      // (ports 0, 1: the resolution's)
    logic [NAP-1:0][63:0]      ex_a, ex_b;              // the sources after the bypass
    logic [NAP-1:0][NCKPT-1:0] ex_bms;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [NAP-1:0]            wbi_v;                   // into the WB register (and the register file) at the end of the cycle
    logic [NAP-1:0][TAGW-1:0]  wbi_t;
    logic [NAP-1:0][63:0]      wbi_d;

    for (genvar p = 0; p < NAP; p++) begin : g_alu
        // RR
        logic            rr_v;
        logic [NCKPT-1:0] rr_bm, ex_bm;
        /* verilator lint_off UNUSEDSIGNAL */
        logic [NCKPT-1:0] wb_bm;
        /* verilator lint_on UNUSEDSIGNAL */
        logic [RRW:0]    rr_d;
        logic [TAGW-1:0] rr_t1, rr_t2, rr_dst;
        logic            rr_wr, rr_sd;
        logic [VA-1:5]   p_line;                                // the pc array's line, the target array's next
        logic [VA-1:1]   p_ta;                                  // (ports 0, 1: the arrays' 2 read ports)
        ex_t             rx;
        OOO_STAGE #(.W(RRW + 1), .NCK(NCKPT)) u_rr
            (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr), .en(1'b1),
             .in_valid(iss_valid[p]), .in_bm(iss_bm[p]),
             .in_data({p == 1 && iss_sd, iss_src[p][1], iss_src[p][0], iss_dst[p], iss_wr[p]}),
             .out_valid(rr_v), .out_bm(rr_bm), .out_data(rr_d));
        assign {rr_sd, rr_t2, rr_t1, rr_dst, rr_wr} = rr_d;
        assign prf_ra[2*p]   = rr_t1;
        assign prf_ra[2*p+1] = rr_t2;
        if (p < 2) begin : g_pa
            assign pa_idx[p] = rr_rec[p].ftq - FTQW'(rr_rec[p].xline);
            assign ta_idx[p] = rr_rec[p].ftq;
            assign p_line    = pa_line[p];
            assign p_ta      = ta_tgt[p];
        end else begin : g_npa                                  // (ports 2, 3: nothing that needs the pc)
            assign p_line    = '0;
            assign p_ta      = '0;
        end
        always @(*) begin
            rx      = '0;
            rx.v1   = prf_rd[2*p];
            rx.v2   = prf_rd[2*p+1];
            rx.t1   = rr_t1;
            rx.t2   = rr_t2;
            rx.dst  = rr_dst;
            rx.wr   = rr_wr;
            rx.rec  = rr_rec[p];
            rx.line = p_line;
            rx.ta   = p_ta;
            rx.sd   = rr_sd;
        end
        // EX
        OOO_STAGE #(.W($bits(ex_t)), .NCK(NCKPT)) u_ex
            (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr), .en(1'b1),
             .in_valid(rr_v), .in_bm(rr_bm), .in_data(rx), .out_valid(ex_v[p]), .out_bm(ex_bm), .out_data(ex[p]));

        // the bypass's compare at RR, registered (V3c)
        logic [NAP+1:0]  ex_m1, ex_m2;
        always_ff @(posedge clk) begin
            for (int q = 0; q < NAP + 2; q++) begin
                ex_m1[q] <= byp_nt[q] == rr_t1;
                ex_m2[q] <= byp_nt[q] == rr_t2;
            end
        end
        logic [63:0]     a, b, pc64, imm64;
        logic [VA-1:1]   pc;
        always @(*) begin
            // the bypass: the write-back registers (the results of the cycle before), else the RR read; which
            // source holds each operand's tag compared at RR (ex_m1, ex_m2: its WB or load register's tag == ex[p].t1, t2)
            a = ex[p].v1;
            b = ex[p].v2;
            for (int q = 0; q < NAP + 2; q++) begin
                if (byp_v[q] && ex_m1[q]) a = byp_d[q];
                if (byp_v[q] && ex_m2[q]) b = byp_d[q];
            end
            ex_a[p] = a;
            ex_b[p] = b;
            pc    = {ex[p].line, ex[p].rec.off};
            pc64  = {{(64 - VA){pc[VA-1]}}, pc, 1'b0};
            imm64 = {{32{ex[p].rec.imm[31]}}, ex[p].rec.imm};
        end
        // ALU0 is the full ALU (and the only one with branches, jumps and the pc: OOO_DEC gives
        // them to it, Plan/OOC.md 29.27); ALU1..3 the middle set (OOO_ALU MID)
        OOO_ALU2 #(.FULL(p == 0), .MID(p != 0)) u_alu
            (.s1(a), .s2(b), .imm1(imm64), .pc(pc64), .op1(ex[p].rec.alu_op), .uw1(ex[p].rec.a_uw),
             .shift1(ex[p].rec.a_shift), .word1(ex[p].rec.word_op), .a1_sel(ex[p].rec.a_sel), .b1_imm(ex[p].rec.b_sel),
             .is_br(p < 2 && ex[p].rec.is_br), .br_op(ex[p].rec.br_op), .br_fused(FUSE_AB && ex[p].rec.fused), .br_res1_a(ex[p].rec.b_res1a),
             .br_o_sel(ex[p].rec.b_osel),
             .res1(ex_res[p]), .take_branch(ex_tk[p]));
        logic isbr;                                             // a branch or jalr: resolved, and completed, a cycle later
        if (p < 2) begin : g_br
            logic [VA-1:1] pc_b, pc_nx, b_tgt, j_tgt, nxt, pnx;
            logic          mis;
            always @(*) begin
                /* verilator lint_off UNUSEDSIGNAL */
                logic [63:0] jt;
                /* verilator lint_on UNUSEDSIGNAL */
                ex_pc[p] = pc;
                // (a pair: the branch at pc + the ALU half's length, its offset in joff)
                pc_b  = pc + (ex[p].rec.len4 ? (VA - 1)'(2) : (VA - 1)'(1));
                pc_nx = (FUSE_AB && ex[p].rec.fused) ? pc_b + (ex[p].rec.len4b ? (VA - 1)'(2) : (VA - 1)'(1)) : pc_b;
                b_tgt = (FUSE_AB && ex[p].rec.fused) ? pc_b + (VA - 1)'({{52{ex[p].rec.joff[11]}}, ex[p].rec.joff})
                                        : pc + (VA - 1)'({{32{ex[p].rec.imm[31]}}, ex[p].rec.imm} >> 1);
                jt    = a + {{52{ex[p].rec.joff[11]}}, ex[p].rec.joff};
                j_tgt = jt[VA-1:1];
                nxt   = ex[p].rec.is_jalr ? j_tgt : ex_tk[p] ? b_tgt : pc_nx;
                pnx   = ex[p].rec.pred_taken ? (ex[p].rec.is_jalr ? ex[p].ta : b_tgt) : pc_nx;
                mis   = ex[p].rec.is_jalr ? nxt != pnx : ex_tk[p] != ex[p].rec.pred_taken;
                // resolution: OOO_CTRL, OOO_ROB, OOO_FRONT (FERS, TAGE), through the register below
                e_br_valid[p]   = ex_v[p] && (ex[p].rec.is_br || ex[p].rec.is_jalr);
                e_br_mispred[p] = mis;
                e_br_ckpt[p]    = ex[p].rec.ckpt;
                e_br_next[p]    = nxt;
                e_br_rob[p]     = ex[p].rec.rob;
                e_br_e[p]       = ex[p].rec.e;
                e_br_taken[p]   = ex[p].rec.is_jalr || ex_tk[p];
                e_br_call[p]    = ex[p].rec.call;
                e_br_ret[p]     = ex[p].rec.ret;
                e_rs_valid[p]   = ex_v[p] && ex[p].rec.is_br;
                e_rs_ftq[p]     = ex[p].rec.ftq;
                e_rs_e[p]       = ex[p].rec.e;
                e_rs_taken[p]   = ex_tk[p];
            end
            assign isbr = e_br_valid[p];
        end else begin : g_nbr
            assign isbr = 1'b0;
        end
        always @(*) begin
            // the register file at the edge the result enters the write-back register (port 0: also the
            // multiplier's and the MDU's results, below); completion in EX, but of what an MDU or the system
            // unit completes later, and of a branch or jalr: through the resolution's register, a cycle later
            // (below, Plan/OOC.md 29.25)
            prf_we[p]     = p == 0 ? wbw0 : p == 1 ? wbw1 : wbi_v[p];
            prf_wa[p]     = wbi_t[p];
            prf_wd[p]     = wbi_d[p];
            // (a store's data on port 1 completes nothing: the store completes in OOO_LSU4 with both)
            // (an int -> FP µop completes with its FP result, OOO_FPUW's)
            cmp_valid[p]  = ex_v[p] && ex[p].rec.kind != K_MDU && ex[p].rec.kind != K_SYS && ex[p].rec.kind != K_CSR && !isbr &&
                            !ex[p].sd && !ex[p].rec.fx;
            cmp_rob[p]    = ex[p].rec.rob;
        end
        assign ex_bms[p] = ex_bm;
        // WB's mask: EX's µop's, but not for the MDU's result on port 0 or the multiplier's on port 1 (they checked it
        // against kill with their own masks this cycle; a later kill can only be of a branch older than the
        // result, whose takers are younger and killed too, and its tag is not given out again in a cycle)
        logic [NCKPT-1:0] wb_in_bm;
        assign wb_in_bm = ((p == 0 && (md_w || f2i_wr)) || (p == 1 && pm_w)) ? '0 : ex_bm;     // (an FP -> integer result: the MDU's case)
        // WB
        OOO_STAGE #(.W(WBW), .NCK(NCKPT)) u_wb
            (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr), .en(1'b1),
             .in_valid(wbi_v[p]), .in_bm(wb_in_bm), .in_data({wbi_t[p], wbi_d[p]}),
             .out_valid(wb_v[p]), .out_bm(wb_bm), .out_data(wb_d[p]));
    end

    // ---- port 0's units beside ALU0: the CSRs, the system µops, the multiplier, the MDU
    logic [31:0]     x_ins;                                     // the instruction of port 0's EX
    logic            x_csr, x_sys, x_mul, x_mdu, x_wv;
    // (read in RR, from a register in EX: the choice of 48 lay on the CSRs' paths, Plan/OOC.md 29.35; written at
    // dispatch, a cycle at least before the µop's issue)
    always_ff @(posedge clk) x_ins <= rob_insn[rr_rec[0].rob];
    assign x_csr = ex_v[0] && ex[0].rec.kind == K_CSR;
    assign x_sys = ex_v[0] && ex[0].rec.kind == K_SYS;
    assign x_mul = ex_v[0] && ex[0].rec.kind == K_MDU && ex[0].rec.xop == 4'd0;
    assign x_mdu = ex_v[0] && ex[0].rec.kind == K_MDU && ex[0].rec.xop != 4'd0;
    assign x_wv  = ex_v[0] && ex[0].wr && ex[0].rec.kind != K_MDU;        // a latency-1 writer (ALU, CSR)

    logic [63:0]     csr_res, csr_tv;
    logic            csr_exc, csr_rp, csr_tv_v;
    logic [ROBW-1:0] csr_tv_rob;
    logic            m_tw, m_tsr, m_tvm;
    logic            m_sum, m_mxr, m_mprv;
    logic [1:0]      m_mpp;
    /* verilator lint_off UNUSEDSIGNAL */      // (satp's ASID; debug, triggers: Phase 2)
    logic [63:0]     satp;
    logic            menv_cbze, senv_cbze, dcsr_step, dcsr_ebm, dcsr_ebs, dcsr_ebu, tctl_mte;
    logic [63:0]     dbg_rdata, dpc;
    logic [31:0]     trig_cfg;
    logic [255:0]    trig_addr;
    /* verilator lint_on UNUSEDSIGNAL */
    logic            tlb_flush;
    // misa as mmRISC-2's (and the reference's): RV64 IMAFDC, S, U
    OOO_CSRU #(.VA(VA), .ROBW(ROBW), .MISA(64'h8000_0000_0014_112F)) u_csr
        (.clk(clk), .rst_n(rst_n),
         .ex_valid(x_csr), .ex_op(x_ins[14:12]), .ex_addr(x_ins[31:20]), .ex_rs1(x_ins[19:15]), .ex_src(ex_a[0]),
         .ex_rob(ex[0].rec.rob), .ex_inst(x_ins), .ex_res(csr_res), .ex_exc(csr_exc), .ex_rp(csr_rp),
         .tv_valid(csr_tv_v), .tv_rob(csr_tv_rob), .tv_val(csr_tv),
         .trap_en(csr_trap), .trap_int(csr_int), .trap_cause(csr_cause), .trap_epc(csr_epc), .trap_tval(csr_tval),
         .mret_en(csr_mret), .sret_en(csr_sret), .tvec(tvec), .mepc(mepc), .sepc(sepc),
         .irq_pend(irq_pend), .irq_cause(irq_cause), .wfi_wake(wfi_wake),
         .irq_m_soft(irq_m_soft), .irq_m_timer(irq_m_timer), .irq_m_ext(irq_m_ext), .irq_s_ext(irq_s_ext), .mtime(mtime),
         .instret_inc(cmt_instret), .hpm_ev(hpm_ev),
         .priv(priv), .satp(satp), .mstatus_sum(m_sum), .mstatus_mxr(m_mxr), .mstatus_mprv(m_mprv),
         .mstatus_mpp(m_mpp), .mstatus_tvm(m_tvm), .mstatus_tw(m_tw), .mstatus_tsr(m_tsr),
         .menvcfg_cbze(menv_cbze), .senvcfg_cbze(senv_cbze), .pmpcfg(pmpcfg), .pmpaddr(pmpaddr), .pmpmask(pmpmask),
         .fflags_we(f_fl_set != 5'd0), .fflags_set(f_fl_set), .fs_dirty(f_dirty), .frm(frm), .fs(fs),
         .dbg_access(1'b0), .dbg_addr(12'd0), .dbg_enter(1'b0), .dbg_cause(3'd0), .dbg_pc(64'd0), .dbg_resume(1'b0),
         .dbg_rdata(dbg_rdata), .dcsr_step(dcsr_step), .dcsr_ebreakm(dcsr_ebm), .dcsr_ebreaks(dcsr_ebs),
         .dcsr_ebreaku(dcsr_ebu), .dpc(dpc), .trig_cfg(trig_cfg), .trig_addr(trig_addr), .tcontrol_mte(tctl_mte),
         .trig_fired(4'd0));

    logic            sys_cv, sys_rp, sys_exc, sys_tv_v;
    logic [ROBW-1:0] sys_rob, sys_tv_rob;
    logic [63:0]     sys_tv;
    OOO_SYS #(.ROBW(ROBW)) u_sys
        (.clk(clk), .rst_n(rst_n), .flush(flush_all),
         .sys_valid(x_sys), .sys_op(ex[0].rec.xop[2:0]), .sys_rob(ex[0].rec.rob), .sys_inst(x_ins), .priv(priv),
         .tw(m_tw), .tsr(m_tsr), .tvm(m_tvm), .sq_drained(sq_drained), .fl_req(fl_req), .fl_take(fl_take),
         .fl_done(fl_done), .ic_flush(ic_flush), .ic_done(ic_done), .tlb_flush(tlb_flush), .x_ret(x_ret),
         .x_sret(x_sret), .wfi_wake(wfi_wake), .cmp_valid(sys_cv), .cmp_rob(sys_rob), .cmp_rp(sys_rp),
         .cmp_exc(sys_exc), .tv_valid(sys_tv_v), .tv_rob(sys_tv_rob), .tv_val(sys_tv));

    logic            pm_v, pm_we, md_v, md_we;
    logic [TAGW-1:0] pm_t, md_t;
    logic [63:0]     pm_d, md_d;
    logic [ROBW-1:0] pm_rob, md_rob;
    OOO_PMUL #(.ROBW(ROBW), .TAGW(TAGW), .NCK(NCKPT)) u_pmul
        (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill),
         .ex_valid(x_mul), .ex_word(ex[0].rec.word_op), .ex_a(ex_a[0]), .ex_b(ex_b[0]), .ex_rob(ex[0].rec.rob),
         .ex_dst(ex[0].dst), .ex_bm(ex_bms[0]),
         .res_valid(pm_v), .res_we(pm_we), .res_tag(pm_t), .res_data(pm_d), .res_rob(pm_rob));
    OOO_MDUP #(.ROBW(ROBW), .TAGW(TAGW), .NCK(NCKPT)) u_mdup
        (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr),
         .iss_md(iss_md), .iss_bm(iss_bm[0]), .mdu_ok(mdu_ok), .p0_hold(p0_hold), .res_we(md_we),
         .ex_valid(x_mdu), .ex_op(ex[0].rec.xop), .ex_word(ex[0].rec.word_op), .ex_a(ex_a[0]), .ex_b(ex_b[0]),
         .ex_rob(ex[0].rec.rob), .ex_dst(ex[0].dst), .ex_bm(ex_bms[0]), .slot_busy(x_wv || pm_we),   // (pm: the completion port they share; not waiting on the kill)
         .res_valid(md_v), .res_tag(md_t), .res_data(md_d), .res_rob(md_rob), .ext_valid(md_ext_v), .ext_tag(md_ext_t));

    // the write-back registers: port 0 takes the MDU's result, else its EX's; port 1 the multiplier's, else
    // its EX's (Plan/CORE.md 5.13; the issue queue and OOO_MDUP keep them to one a cycle). A result for x0
    // (tag 0: the issue queue keeps no slot for a multiply without a destination) is neither written nor
    // forwarded
    assign pm_w = pm_v && pm_t != '0;
    assign md_w = md_v && md_t != '0;
    // the register file's write from port 0 does not wait on the kill (Plan/OOC.md 29.28): the MDU's raw
    // write, which implies no latency-1 writer (slot_busy), so the choice below can take it too
    assign md_wr = md_we && md_t != '0;
    // an FP -> integer result (step 1.8 U2) takes the slot when the MDU and a latency-1 writer leave it (f2i_wr, below)
    assign wbw0  = md_wr || x_wv || f2i_wr;
    // port 1 the same: a multiply in its write slot (also one killed now) implies no latency-1 writer there, the
    // queue having kept the slot (blk1), but for one to x0, which keeps none
    assign pm_wr = pm_we && pm_t != '0;
    assign wbw1  = pm_wr || (ex_v[1] && ex[1].wr);
    always @(*) begin
        wbi_v[0] = md_w || x_wv || f2i_wr;
        wbi_t[0] = md_wr ? md_t : f2i_wr ? iw_tag : ex[0].dst;
        wbi_d[0] = md_wr ? md_d : f2i_wr ? iw_data : (ex[0].rec.kind == K_CSR ? csr_res : ex_res[0]);
        wbi_v[1] = pm_w || (ex_v[1] && ex[1].wr);
        wbi_t[1] = pm_wr ? pm_t : ex[1].dst;
        wbi_d[1] = pm_wr ? pm_d : ex_res[1];
        for (int p = 2; p < NAP; p++) begin                     // ALU2, ALU3: their own results only
            wbi_v[p] = ex_v[p] && ex[p].wr;
            wbi_t[p] = ex[p].dst;
            wbi_d[p] = ex_res[p];
        end
    end

    // ---- the LSU's ports (step 1.3 E1, Plan/OOC.md 29.32): LSU0 (issue port NAP: loads, stores' addresses, and
    // OOO_LSU4's tries of what had to wait) and LSU1 (NAP + 1: loads), one source each: a store's data comes on
    // port 1 (step 1.5b G3, Plan/OOC.md 29.53). RR and EX here; OOO_LSU4 follows them with its E (the address of
    // EX), M (the D$'s arrays inside it) and W
    logic [1:0]              m_rr_v;
    /* verilator lint_off UNUSEDSIGNAL */      // (the commit trace's: a store's address in EX)
    logic [1:0]              m_ex_v;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [1:0][NCKPT-1:0]   m_rr_bm;
    /* verilator lint_off UNUSEDSIGNAL */      // (the address and the store's data only, and the trace)
    logic [1:0][NCKPT-1:0]   m_ex_bm;
    ex_t  [1:0]              m_ex;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [1:0][TAGW-1:0]    m_rr_dst;
    logic [1:0][TAGW+1:0]    l_rr_dst;                  // OOO_LSU4's: {flw: NaN box it, an FP register, the tag} (step 1.8 U2)
    logic [1:0][63:0]        m_a, m_ea;
    for (genvar m = 0; m < 2; m++) begin : g_mem
        logic [RRW-1:0]  rr_d;
        logic [TAGW-1:0] t1;
        /* verilator lint_off UNUSEDSIGNAL */
        logic [TAGW-1:0] t2;                                    // (a store's data: port 1's)
        logic            wr;
        /* verilator lint_on UNUSEDSIGNAL */
        ex_t             rx;
        OOO_STAGE #(.W(RRW), .NCK(NCKPT)) u_rr
            (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr), .en(1'b1),
             .in_valid(iss_valid[NAP+m]), .in_bm(iss_bm[NAP+m]),
             .in_data({iss_src[NAP+m][1], iss_src[NAP+m][0], iss_dst[NAP+m], iss_wr[NAP+m]}),
             .out_valid(m_rr_v[m]), .out_bm(m_rr_bm[m]), .out_data(rr_d));
        assign {t2, t1, m_rr_dst[m], wr} = rr_d;
        assign l_rr_dst[m] = {rr_rec[NAP+m].fpd && rr_rec[NAP+m].msize == 2'd2, rr_rec[NAP+m].fpd, m_rr_dst[m]};
        assign prf_ra[2*NAP + m] = t1;                          // the base
        always @(*) begin
            rx     = '0;
            rx.v1  = prf_rd[2*NAP + m];
            rx.t1  = t1;
            rx.dst = m_rr_dst[m];
            rx.rec = rr_rec[NAP+m];
        end
        OOO_STAGE #(.W($bits(ex_t)), .NCK(NCKPT)) u_ex
            (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr), .en(1'b1),
             .in_valid(m_rr_v[m]), .in_bm(m_rr_bm[m]), .in_data(rx), .out_valid(m_ex_v[m]), .out_bm(m_ex_bm[m]),
             .out_data(m_ex[m]));
        logic [NAP+1:0]  m_m1;                                  // the bypass's compare at RR, registered (V3c)
        always_ff @(posedge clk) for (int q = 0; q < NAP + 2; q++) m_m1[q] <= byp_nt[q] == t1;
        always @(*) begin
            m_a[m] = m_ex[m].v1;
            for (int q = 0; q < NAP + 2; q++)
                if (byp_v[q] && m_m1[q]) m_a[m] = byp_d[q];
            m_ea[m] = m_a[m] + {{52{m_ex[m].rec.imm[11]}}, m_ex[m].rec.imm[11:0]};
        end
    end

    // a store's data: port 1's EX after the bypass, through a register into OOO_LSU4 (sd_lag 1 of the model).
    // Not dropped by a kill or a flush, nor by EX's valid bit (ex[1].sd without ex_v[1] is a store's data killed
    // in RR or EX; iss_sd is 1 only with an issue): the data of a store killed meanwhile writes an SQ entry that is
    // free then (behind the restored tail), cleared as it is given out again, and nothing is given out in a
    // recovery's cycle (OOO_LSU4)
    logic            sd_v;
    logic [3:0]      sd_sq;
    logic [1:0]      sd_size;
    logic [63:0]     sd_data;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sd_v <= 1'b0;
        else        sd_v <= ex[1].sd;
    end
    always_ff @(posedge clk) begin
        sd_sq   <= ex[1].rec.sq;
        sd_size <= ex[1].rec.msize;
        sd_data <= ex_b[1];
    end

    // a try of OOO_LSU4 takes LSU0's RR when the queue leaves it: in EX its address is rt_base, offset 0
    logic            rt_v, rt_q;
    logic [PAW-1:0]  rt_base, rt_bq;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) rt_q <= 1'b0;
        else        rt_q <= rt_v;
    end
    always_ff @(posedge clk) rt_bq <= rt_base;

    // dispatch: OOO_LSU4 takes counts and gives its tails; the slots' entries, a load's older stores (rr_st),
    // and the tails after each slot (the checkpoint table's) are counted here
    logic [4:0]      l3_lq_tail, l3_sq_tail, l3_lq_free, l3_sq_free;
    logic [2:0]      lq_alloc, sq_alloc;
    always @(*) begin
        automatic logic [4:0] lt = l3_lq_tail, st = l3_sq_tail;
        lq_alloc = '0;
        sq_alloc = '0;
        for (int k = 0; k < ND; k++) begin
            disp_lq[k] = lt[3:0];
            disp_sq[k] = st[3:0];
            disp_st[k] = st;
            if (ds_valid[k] && dv_ld[k]) lt = lt + 5'd1;
            if (ds_valid[k] && dv_st[k]) st = st + 5'd1;
            ck_lq_tail[k] = lt;
            ck_sq_tail[k] = st;
            lq_alloc = lq_alloc + 3'(d_go[k] && dv_ld[k]);
            sq_alloc = sq_alloc + 3'(d_go[k] && dv_st[k]);
        end
        lq_avail = l3_lq_free >= 5'd4 ? 3'd4 : l3_lq_free[2:0];
        sq_avail = l3_sq_free >= 5'd4 ? 3'd4 : l3_sq_free[2:0];
    end

    logic            sq_drained;
    logic [1:0]      ld_nv;
    logic [1:0][TAGW+1:0] ld_nt;                        // {box, fp, tag}
    logic [1:0][63:0] ld_d, ld_db;                      // (ld_db: NaN boxed for flw)
    logic [1:0]      ld_fp;
    logic            sd2_v;                             // an FP store's data (OOO_FIQ's port B), into OOO_LSU4's second port
    logic [3:0]      sd2_sq;
    logic [1:0]      sd2_size;
    logic [63:0]     sd2_data;
    /* verilator lint_off UNUSEDSIGNAL */      // (an atomic's destination: integer, its {box, fp} 0)
    logic [TAGW+1:0] at_wk_tl;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [1:0]      cmp_ld_v, cmp_ld_e, cmp_ld_rp, cmp_ld_sd;
    logic [1:0][ROBW-1:0] cmp_ld_rob;
    logic            cmp_st_v, cmp_st_e;
    logic [1:0][1:0] cmp_ld_cause;                      // an exception's: 0 misaligned, 1 an access fault, 2 a page fault
    logic [1:0]      cmp_st_cause;
    logic [1:0]      l_tv_v;                            // its tval, from the LSU's W (a port each)
    logic [1:0][ROBW-1:0] l_tv_rob;
    logic [1:0][63:0] l_tv_va;
    // ---- translation (step 1.8 V1, Plan/OOC.md 29.87): the effective privilege of loads and stores (MPRV with MPP in M),
    // registered: it changes only at a trap, a return or a CSR write, each with nothing younger in flight after it
    logic            tr_on, tr_au, tr_as, tr_mxr;
    logic [1:0]      tr_ep;                             // ... the privilege itself (PMP's, step 1.8 P1)
    logic [1:0]      tr_eff;
    logic [63:0]     satp_q;
    logic            tlb_flush_all;                     // SFENCE.VMA, or satp changed (no ASID in the DTLBs)
    assign tr_eff = (m_mprv && priv == 2'd3) ? m_mpp : priv;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tr_on <= 1'b0; tr_au <= 1'b0; tr_as <= 1'b0; tr_mxr <= 1'b0; tr_ep <= 2'd3; satp_q <= '0;
        end else begin
            tr_on  <= satp[63:60] == 4'd8 && tr_eff != 2'd3;
            tr_au  <= tr_eff == 2'd0 || (tr_eff == 2'd1 && m_sum);
            tr_as  <= tr_eff == 2'd1;
            tr_mxr <= m_mxr;
            tr_ep  <= tr_eff;
            satp_q <= satp;
        end
    end
    assign tlb_flush_all = tlb_flush || satp_q != satp;
    assign it_on = satp[63:60] == 4'd8 && priv != 2'd3;
    assign it_au = priv == 2'd0;
    assign it_as = priv == 2'd1;
    // the walker (its signals declared above, with the fetch's)
    logic            w_busy;                            // (the PMU's events 9, 10, 27, 28)
    // one walker for both sides (step 1.8 V2): the LSU's ask (one cycle, dropped if the walker is busy) first, else the
    // fetch's (held until its entry is in); bit 5 of the id says the fetch's. Every walk's end is an event for the LSU;
    // the DTLBs are written by the LSU's walks, the ITLB by the fetch's
    OOO_PTW #(.PAW(PAW), .VA(VA), .IW(6)) u_ptw
        (.clk(clk), .rst_n(rst_n), .req(w_req || iw_req), .req_vpn(w_req ? w_vpn : iw_vpn),
         .req_id(w_req ? {1'b0, w_rid} : 6'b100000), .satp_ppn(satp[43:0]),
         .cancel(tlb_flush_all || flush_all), .busy(w_busy),
         .pt_req(dc_pt_req), .pt_addr(dc_pt_addr), .pt_chk(pw_chk), .pmp_fail(pw_fail),
         .pt_done(dc_pt_done), .pt_data(dc_pt_data),
         .hold(dc_fill_done), .tlb_done(w_done), .done_id(w_did), .tlb_we(w_we), .tlb_vpn(w_tvpn), .tlb_ptag(w_ptag),
         .tlb_u(w_u), .tlb_r(w_r), .tlb_w(w_w), .tlb_x(w_x), .tlb_af(w_af));
    /* verilator lint_off UNUSEDSIGNAL */      // (the commit trace's)
    logic [ROBW-1:0] at_wk_rob;
    logic [63:0]     at_wk_d, at_nd;
    logic            at_st, at_amo;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [ROBW-1:0] cmp_st_rob;
    OOO_LSU4 #(.NLQ(16), .NSQ(16), .PAW(PAW), .VA(VA), .TAGW(TAGW + 2), .ROBW(ROBW), .NCK(NCKPT), .DWAYS(DWAYS)) u_lsu
        (.clk(clk), .rst_n(rst_n), .tr_on(tr_on), .allow_u(tr_au), .allow_s(tr_as), .mxr(tr_mxr),
         .pmp_priv(tr_ep), .pmp_cfg(pmpcfg), .pmp_addr(pmpaddr), .pmp_mask(pmpmask),
         .lq_alloc(lq_alloc), .sq_alloc(sq_alloc), .lq_tail(l3_lq_tail), .sq_tail(l3_sq_tail),
         .lq_free(l3_lq_free), .sq_free(l3_sq_free),
         .rr_valid(m_rr_v), .rr_ld(rr_rec[NAP].is_ld), .rr_lq({rr_rec[NAP+1].lq, rr_rec[NAP].lq}), .rr_sq(rr_rec[NAP].sq),
         .rr_st({rr_rec[NAP+1].st, rr_rec[NAP].st}), .rr_size({rr_rec[NAP+1].msize, rr_rec[NAP].msize}),
         .rr_uns({rr_rec[NAP+1].uns, rr_rec[NAP].uns}), .rr_dst(l_rr_dst), .rr_rob({rr_rec[NAP+1].rob, rr_rec[NAP].rob}),
         .rr_bm(m_rr_bm), .rr_at(rr_rec[NAP].xop), .rt_v(rt_v), .rt_base(rt_base),
         .e_addr({m_ea[1], rt_q ? {{(64 - PAW){rt_bq[PAW-1]}}, rt_bq} : m_ea[0]}),     // (a try: sign extended, step 1.8 V2)
         .sd_v(sd_v), .sd_sq(sd_sq), .sd_size(sd_size), .sd_data(sd_data),
         .sd2_v(sd2_v), .sd2_sq(sd2_sq), .sd2_size(sd2_size), .sd2_data(sd2_data),
         .ld_nv(ld_nv), .ld_nt(ld_nt), .ld_d(ld_d),
         .cmp_ld_valid(cmp_ld_v), .cmp_ld_rob(cmp_ld_rob), .cmp_ld_exc(cmp_ld_e), .cmp_ld_rp(cmp_ld_rp), .cmp_ld_sd(cmp_ld_sd),
         .cmp_st_valid(cmp_st_v), .cmp_st_rob(cmp_st_rob), .cmp_st_exc(cmp_st_e),
         .cmp_ld_cause(cmp_ld_cause), .cmp_st_cause(cmp_st_cause), .tv_v(l_tv_v), .tv_rob(l_tv_rob), .tv_va(l_tv_va),
         .at_wk_v(at_wk_v), .at_wk_t(at_wk_tl), .at_wk_rob(at_wk_rob), .at_wk_d(at_wk_d), .at_st(at_st), .at_amo(at_amo),
         .at_nd(at_nd),
         .lq_commit(lq_commit), .sq_commit(sq_commit), .restore(restore_k), .kill(kill),
         .restore_lq_tail(restore_lq_tail), .restore_sq_tail(restore_sq_tail), .flush_all(flush_all),
         .sq_drained(sq_drained),
         .miss_valid(dc_miss_valid), .miss_line(dc_miss_line), .miss_vx(dc_miss_vx), .miss_id(dc_miss_id),
         .st_miss_valid(dc_st_miss_valid), .st_miss_line(dc_st_miss_line), .st_miss_vx(dc_st_miss_vx), .fill_done(dc_fill_done),
         .done_v(dc_done_v || (w_done && !w_did[5])), .done_id((w_done && !w_did[5]) ? w_did[4:0] : dc_done_id), .tw_en(dc_tw_en), .tw_way(dc_tw_way), .tw_set(dc_tw_set),
         .tw_tag(dc_tw_tag), .rf_en(dc_rf_en), .rf_way(dc_rf_way), .rf_addr(dc_rf_addr), .rf_data(dc_rf_data),
         .dirty_set(dc_dirty_set), .dirty_way(dc_dirty_way), .dirty_idx(dc_dirty_idx),
         .tlb_miss(w_req), .tlb_miss_vpn(w_vpn), .walk_id(w_rid), .tlb_done(w_done), .tlb_we(w_we && !w_did[5]), .tlb_vpn(w_tvpn),
         .tlb_ptag(w_ptag), .tlb_u(w_u), .tlb_r(w_r), .tlb_w(w_w), .tlb_x(w_x), .tlb_af(w_af), .tlb_flush(tlb_flush_all),
         .uc_line_v(dc_uc_line_v), .uc_line(dc_uc_line), .head_rob(head_rob),
         .uc_req(dc_uc_req), .uc_we(dc_uc_we), .uc_addr(dc_uc_addr), .uc_size(dc_uc_size), .uc_wdata(dc_uc_wdata),
         .uc_wmask(dc_uc_wmask), .uc_done(dc_uc_done), .uc_rdata(dc_uc_rdata),
         .wt_valid(dc_wt_valid), .wt_addr(dc_wt_addr), .wt_data(dc_wt_data), .wt_mask(dc_wt_mask),
         .vr_addr(dc_vr_addr), .vr_way(dc_vr_way), .vr_data(dc_vr_data));
    assign dc_sq_drained = sq_drained;
    assign at_wk_t = at_wk_tl[TAGW-1:0];
    always @(*)
        for (int m = 0; m < 2; m++) begin
            ld_fp[m] = ld_nt[m][TAGW];
            ld_db[m] = ld_nt[m][TAGW+1] ? {32'hFFFF_FFFF, ld_d[m][31:0]} : ld_d[m];
        end
    // the loads' results: the register file at the end of M (whatever the value: a miss's is replaced by its fill, and
    // what read it replays), the bypass from a register a cycle later
    always @(*) begin
        for (int m = 0; m < 2; m++) begin
            prf_we[NAP + m] = ld_nv[m] && !ld_fp[m];        // (an FP load's: the FP file, below)
            prf_wa[NAP + m] = ld_nt[m][TAGW-1:0];
            prf_wd[NAP + m] = ld_d[m];
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) lw_v <= '0;
        else for (int m = 0; m < 2; m++) lw_v[m] <= ld_nv[m] && !ld_fp[m] && ld_nt[m][TAGW-1:0] != '0 && !flush_all;
    end
    always @(*) begin
        for (int q = 0; q < NAP; q++) byp_nt[q] = wbi_t[q];
        for (int m = 0; m < 2; m++) byp_nt[NAP + m] = ld_nt[m][TAGW-1:0];
    end
    always_ff @(posedge clk) begin
        lw_d <= ld_db;                                  // (boxed: the trace's value of an FP load; an integer one is not)
    end


    // ==== the renamed FPU (step 1.8 U2, Plan/OOC.md 29.80 to 29.82) ====
    // ---- dispatch to OOO_FIQ: an FP operation (port A), an FP store's data (port B: its fs2 as source 0)
    logic [ND-1:0][2:0]        fq_use, fq_rdy;
    logic [ND-1:0][2:0][FTAGW-1:0] fq_src;
    logic [ND-1:0]             fq_wr, fq_sd, fq_dv, fq_f2i;
    logic [ND-1:0][FTAGW-1:0]  fq_dst;
    logic [ND-1:0][FPLW-1:0]   fq_pl;
    always @(*) begin
        for (int j = 0; j < ND; j++) begin
            fq_cand[j] = ds_valid[j] && !ds[j].exc && (ds[j].fq || ds[j].fsd);
            fq_use[j]  = ds[j].fuse;
            fq_src[j]  = ds[j].fsd ? {f2_src[j][2], f2_src[j][0], f2_src[j][1]} : f2_src[j];
            fq_rdy[j]  = ds[j].fsd ? {frdy[j][2], frdy[j][0], frdy[j][1]} : frdy[j];
            fq_wr[j]   = ds[j].fwr;
            fq_dst[j]  = f2_dst[j];
            fq_sd[j]   = ds[j].fsd;
            fq_dv[j]   = ds[j].fdv;
            fq_f2i[j]  = ds[j].f2i;
            fq_pl[j]   = '0;
            fq_pl[j][10:0]           = ds[j].fpl;
            fq_pl[j][11 +: ROBW]     = disp_rob[j];
            fq_pl[j][17 +: TAGW]     = ds[j].dst;           // (an FP -> integer µop's integer destination: 0 for x0)
            fq_pl[j][27:24]          = disp_sq[j];
            fq_pl[j][28]             = ds[j].rec.msize[0];  // (a store's data: fsd)
        end
    end
    assign fq_disp = d_go & fq_cand;                    // (apart: fq_cand feeds the dispatch room, d_go comes of it)
    logic                      fpu_ok, f2i_ok;
    logic                      ia_v, ia_wr, ia_dv, ia_f2i, ib_v;
    logic [2:0][FTAGW-1:0]     ia_src;
    logic [FTAGW-1:0]          ia_dst, ib_src;
    logic [NCKPT-1:0]          ia_bm, ib_bm;
    logic [FPLW-1:0]           ia_pl, ib_pl;
    OOO_FIQ #(.N(16), .TAGW(FTAGW), .NEXT(4), .NCK(NCKPT), .NBANK(4), .PLW(FPLW)) u_fiq
        (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr), .fpu_ok(fpu_ok), .f2i_ok(f2i_ok),
         .disp_ready(fq_ready), .disp_valid(fq_disp), .disp_cand(fq_cand), .disp_use(fq_use), .disp_src(fq_src),
         .disp_rdy(fq_rdy), .disp_wr(fq_wr), .disp_dst(fq_dst), .disp_bm(d_bmask), .disp_sd(fq_sd), .disp_dv(fq_dv),
         .disp_f2i(fq_f2i), .disp_pl(fq_pl), .ext_valid(fwk_v), .ext_tag(fwk_t),
         .ia_valid(ia_v), .ia_src(ia_src), .ia_wr(ia_wr), .ia_dst(ia_dst), .ia_bm(ia_bm), .ia_dv(ia_dv), .ia_f2i(ia_f2i),
         .ia_pl(ia_pl), .ib_valid(ib_v), .ib_src(ib_src), .ib_bm(ib_bm), .ib_pl(ib_pl));

    // ---- the FP file: written by the FPU and the 2 load ports, read by the FPU (3) and a store's data (1)
    logic [3:0][FTAGW-1:0]     fp_ra;
    logic [3:0][63:0]          fp_rd;
    logic [2:0]                fp_we;
    logic [2:0][FTAGW-1:0]     fp_wa;
    logic [2:0][63:0]          fp_wd;
    /* verilator lint_off PINCONNECTEMPTY */
    OOO_PRF #(.NREG(NFREG), .NW(3), .NR(4), .ZERO(1'b0)) u_fprf
        (.clk(clk), .ra(fp_ra), .rd(fp_rd), .we(fp_we), .wa(fp_wa), .wd(fp_wd));
    /* verilator lint_on PINCONNECTEMPTY */
    logic [1:0]                fld_w;                   // an FP load's write of this cycle (its M)
    logic [1:0][FTAGW-1:0]     fld_t;
    always @(*) begin
        for (int m = 0; m < 2; m++) begin
            fld_w[m]      = ld_nv[m] && ld_fp[m];
            fld_t[m]      = ld_nt[m][FTAGW-1:0];
            fp_we[1 + m]  = fld_w[m];
            fp_wa[1 + m]  = fld_t[m];
            fp_wd[1 + m]  = ld_db[m];
        end
        fp_we[0] = fw_valid;
        fp_wa[0] = fw_tag;
        fp_wd[0] = fw_data;
    end

    // ---- the FPU (OOO_FPUW around FPU_PIPE): port A; an int -> FP µop from port 0's EX (its operand after the bypass)
    logic                      x_i2f;
    logic [FPLW-1:0]           x_pl;
    logic                      fpu_wk_v;
    logic [FTAGW-1:0]          fpu_wk_t;
    always @(*) begin
        x_i2f = ex_v[0] && ex[0].rec.fx;
        x_pl  = '0;
        x_pl[10:0]       = ex[0].rec.imm[10:0];
        x_pl[11 +: ROBW] = ex[0].rec.rob;
    end
    OOO_FPUW #(.TAGW(FTAGW), .ITAGW(TAGW), .ROBW(ROBW), .NCK(NCKPT), .PLW(FPLW), .FD(4)) u_fpuw
        (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr), .frm(frm),
         .a_valid(ia_v), .a_src(ia_src), .a_wr(ia_wr), .a_dst(ia_dst), .a_bm(ia_bm), .a_dv(ia_dv), .a_f2i(ia_f2i),
         .a_pl(ia_pl), .fpu_ok(fpu_ok), .f2i_ok(f2i_ok), .rf_addr(fp_ra[2:0]), .rf_data(fp_rd[2:0]),
         .ld_valid(fld_w), .ld_tag(fld_t), .ld_data(ld_db),
         .x_valid(x_i2f), .x_data(ex_a[0]), .x_dst(ex[0].dst[FTAGW-1:0]), .x_bm(ex_bms[0]), .x_pl(x_pl), .x_ready(x_ready),
         .fw_valid(fw_valid), .fw_tag(fw_tag), .fw_data(fw_data), .fw_rob(fw_rob), .fw_flags(fw_flags),
         .iw_valid(iw_valid), .iw_tag(iw_tag), .iw_data(iw_data), .iw_rob(iw_rob), .iw_flags(iw_flags), .iw_ack(iw_ack),
         .wk_valid(fpu_wk_v), .wk_tag(fpu_wk_t));
    // an int -> FP µop issues when OOO_FPUW's buffer is empty and none is in port 0's RR or EX (one at a time: rare)
    assign xf_ok = x_ready && !(g_alu[0].rr_v && rr_rec[0].fx) && !(ex_v[0] && ex[0].rec.fx);
    // an FP -> integer result: written through port 0's slot when the MDU and a latency-1 writer leave it; while one
    // waits, port 0's latency-1 writers are held a cycle later (OOO_MDUP's p0_hold), so the slot comes
    assign iw_ack = iw_valid && !x_wv && !md_we;
    assign f2i_wr = iw_ack && iw_tag != '0;                 // (x0: completed, not written)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) f2i_hold <= 1'b0;
        else        f2i_hold <= iw_valid && !iw_ack;
    end

    // ---- the FP wakeups: the FPU's (OOO_FPUW: its dependents issue the cycle after), an FP load's in its RR (as OOO_IQ3
    // wakes for an integer load: its dependents issue the cycle after, their S1 meets its write in M)
    always @(*) begin
        fwk_v[0] = fpu_wk_v;
        fwk_t[0] = fpu_wk_t;
        for (int m = 0; m < 2; m++) begin
            fwk_v[1 + m] = m_rr_v[m] && rr_rec[NAP+m].fpd && !flush_all && (m_rr_bm[m] & kill) == '0;
            fwk_t[1 + m] = m_rr_dst[m][FTAGW-1:0];
        end
        fwk_v[3] = 1'b0;
        fwk_t[3] = '0;
    end

    // ---- an FP store's data (OOO_FIQ's port B): 2 stages, the FP file read in the second (with the FP result of that
    // cycle: a store issued the cycle after its producer's wakeup meets the result there), then into OOO_LSU4's second
    // data port through a register (as port 1's data)
    logic                      b1_v, b2_v;
    logic [NCKPT-1:0]          b1_bm, b2_bm;
    logic [FTAGW+FPLW-1:0]     b1_d, b2_d;
    logic [FTAGW-1:0]          b2_src;
    /* verilator lint_off UNUSEDSIGNAL */      // (a store's data: its SQ entry, size and ROB index)
    logic [FPLW-1:0]           b2_pl;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [63:0]               b2_dat;
    OOO_STAGE #(.W(FTAGW + FPLW), .NCK(NCKPT)) u_fb1
        (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr), .en(1'b1),
         .in_valid(ib_v), .in_bm(ib_bm), .in_data({ib_src, ib_pl}), .out_valid(b1_v), .out_bm(b1_bm), .out_data(b1_d));
    OOO_STAGE #(.W(FTAGW + FPLW), .NCK(NCKPT)) u_fb2
        (.clk(clk), .rst_n(rst_n), .flush(flush_all), .kill(kill), .clr(clr), .en(1'b1),
         .in_valid(b1_v), .in_bm(b1_bm), .in_data(b1_d), .out_valid(b2_v), .out_bm(b2_bm), .out_data(b2_d));
    assign {b2_src, b2_pl} = b2_d;
    assign fp_ra[3] = b2_src;
    assign b2_dat   = (fw_valid && fw_tag == b2_src) ? fw_data : fp_rd[3];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sd2_v <= 1'b0;
        else        sd2_v <= b2_v && !flush_all && (b2_bm & kill) == '0;
    end
    always_ff @(posedge clk) begin
        sd2_sq   <= b2_pl[27:24];
        sd2_size <= {1'b1, b2_pl[28]};
        sd2_data <= b2_dat;
    end

    // ---- per ROB entry: the FP destination (OOO_FREN's commit) in OOO_ROB's extra payload, LUT RAM (step 1.8
    // U3b, Plan/OOC.md 29.85: as flip-flops written by 4 slots and read by 4, about 2 to 3k LUTs), and the flags
    // here (written at completion); at commit fflags and mstatus.FS
    logic [4:0]                fr_fl   [NROB];
    always_ff @(posedge clk) begin
        if (fw_valid) fr_fl[fw_rob] <= fw_flags;
        if (iw_ack)   fr_fl[iw_rob] <= iw_flags;
        for (int j = 0; j < ND; j++) if (disp_go[j])            // (an entry given out again takes its new state first)
            fr_fl[disp_rob[j]]   <= 5'd0;
    end
    always @(*) begin
        for (int j = 0; j < ND; j++) dv_fx[j] = {ds[j].fwr && !ds[j].exc, ds[j].farch, f2_dst[j], f2_old[j]};
    end
    always @(*) begin
        automatic logic [ROBW-1:0] ik = head_rob;
        f_fl_set = '0;
        f_dirty  = 1'b0;
        for (int k = 0; k < ND; k++) begin
            fcmt_wr[k]   = cmt_valid[k] && cmt_fx[k][FXW-1];
            fcmt_arch[k] = cmt_fx[k][2*FTAGW +: 5];
            fcmt_new[k]  = cmt_fx[k][FTAGW +: FTAGW];
            fcmt_old[k]  = cmt_fx[k][0 +: FTAGW];
            if (cmt_valid[k]) begin
                f_fl_set = f_fl_set | fr_fl[ik];
                if (cmt_fx[k][FXW-1] || fr_fl[ik] != 5'd0) f_dirty = 1'b1;    // (Spike dirties FS on an FP write or new flags)
            end
            ik = (ik == ROBW'(NROB - 1)) ? '0 : ik + ROBW'(1);
        end
    end

    // completion: port 0 (a CSR µop: illegal, replay after a write), port 1, the LSU's loads and stores
    // (misaligned), port 0's multiplier and MDU, the system unit (illegal, replay), the branches and jalrs
    // of ports 0 and 1 (all of them through the resolution's register: completed in EX, as predicted, the
    // misprediction's compare lay on the 4-wide core's paths, Plan/OOC.md 29.25). A load completes into
    // the ROB a cycle after its W, through a register for the same reason (the D$'s hit and fill). A late
    // completion of a µop killed or flushed meanwhile is harmless: its entry is out of the ROB, and an
    // entry given out again in that cycle takes its new state first (OOO_ROB's status writes)
    logic [1:0]      ld_cv, ld_ce, ld_crp;
    logic [1:0][4:0] ld_ccause;                         // the cause of an exception (4, 5 or 13)
    logic [1:0][ROBW-1:0] ld_crob;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ld_cv <= '0;
        else        ld_cv <= cmp_ld_v;
    end
    always_ff @(posedge clk) begin
        ld_crob <= cmp_ld_rob;
        ld_ce   <= cmp_ld_e;
        ld_crp  <= cmp_ld_rp;
        for (int m = 0; m < 2; m++) ld_ccause[m] <= cmp_ld_cause[m] == 2'd2 ? 5'd13 : cmp_ld_cause[m] == 2'd1 ? 5'd5 : 5'd4;
    end
    // the wait table's write: a load that waited for a store's data is marked by its ROB entry when it completes
    // (cmp_ld_sd comes with its replay), and its pc goes to the table at its commit, as the last µop of the cycle
    // (a replay commits nothing younger with it); through a register
    logic [NROB-1:0] rob_sd;
    always_ff @(posedge clk) begin
        for (int j = 0; j < ND; j++) if (disp_go[j]) rob_sd[disp_rob[j]] <= 1'b0;
        for (int m = 0; m < 2; m++) if (cmp_ld_v[m] && cmp_ld_sd[m]) rob_sd[cmp_ld_rob[m]] <= 1'b1;
    end
    logic            wt_we_n;
    logic [7:0]      wt_wa_n;
    always @(*) begin
        automatic logic [ROBW-1:0] ik = head_rob;
        wt_we_n = 1'b0;
        wt_wa_n = '0;
        for (int k = 0; k < ND; k++) begin
            if (cmt_valid[k] && rob_sd[ik]) begin
                wt_we_n = 1'b1;
                wt_wa_n = cmt_pc[k][8:1];
            end
            ik = (ik == ROBW'(NROB - 1)) ? '0 : ik + ROBW'(1);
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) wt_we <= 1'b0;
        else        wt_we <= wt_we_n;
    end
    always_ff @(posedge clk) wt_wa <= wt_wa_n;

    // A CSR µop completes, and reports its tval, a cycle after EX too: its illegal check lay on the 4-wide core's
    // paths (Plan/OOC.md 29.28). It runs at the ROB head alone, so this costs a cycle a CSR instruction
    logic            csr_cv, csr_ce, csr_crp, csr_tvq;
    logic [ROBW-1:0] csr_crob, csr_tvq_rob;
    logic [63:0]     csr_tvq_val;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            csr_cv  <= 1'b0;
            csr_tvq <= 1'b0;
        end else begin
            csr_cv  <= x_csr;
            csr_tvq <= csr_tv_v;
        end
    end
    always_ff @(posedge clk) begin
        csr_crob    <= ex[0].rec.rob;
        csr_ce      <= csr_exc;
        csr_crp     <= csr_rp;
        csr_tvq_rob <= csr_tv_rob;
        csr_tvq_val <= csr_tv;
    end
    always @(*) begin
        cmp_exc   = {2'b00, csr_ce, 2'b00, sys_exc, 1'b0, cmp_st_e, ld_ce, (NAP)'(0)};
        cmp_rp    = {2'b00, csr_crp, 2'b00, sys_rp, 1'b0, 1'b0, ld_crp, (NAP)'(0)};
        // the LSU's: misaligned (4 a load, 6 a store or AMO), an access fault (5, 7), a page fault (13, 15; step 1.8 V1)
        cmp_cause = {5'd0, 5'd0, 5'd2, 5'd0, 5'd0, 5'd2, 5'd0,
                     cmp_st_cause == 2'd2 ? 5'd15 : cmp_st_cause == 2'd1 ? 5'd7 : 5'd6, ld_ccause[1], ld_ccause[0], (5 * NAP)'(0)};
    end
    assign cmp_valid[NCMP-1:NAP] = {fw_valid, iw_ack, csr_cv, br_valid, sys_cv, pm_v || md_v, cmp_st_v, ld_cv};
    assign cmp_rob[NCMP-1:NAP]   = {fw_rob, iw_rob, csr_crob, br_rob, sys_rob, pm_v ? pm_rob : md_rob, cmp_st_rob, ld_crob};

    // tval: an exception of LSU0 or LSU1 (OOO_LSU4's W: misaligned, an access fault, a page fault; its virtual address;
    // step 1.8 V1), the CSR unit or the system unit (one at a time at the head)
    always @(*) begin
        tv_valid[ND]     = l_tv_v[0];
        tv_rob[ND]       = l_tv_rob[0];
        tv_val[ND]       = l_tv_va[0];
        tv_valid[ND + 1] = csr_tvq || sys_tv_v;                // (the CSR's a cycle late: never with the system unit's,
        tv_rob[ND + 1]   = sys_tv_v ? sys_tv_rob : csr_tvq_rob;  //  as both run at the ROB head and complete first)
        tv_val[ND + 1]   = sys_tv_v ? sys_tv : csr_tvq_val;
        tv_valid[ND + 2] = l_tv_v[1];
        tv_rob[ND + 2]   = l_tv_rob[1];
        tv_val[ND + 2]   = l_tv_va[1];
    end

    // an indirect jump (a jalr not a return) writes the BTB: port 0's first
    always @(*) begin
        logic [1:0] ij;
        for (int p = 0; p < 2; p++) ij[p] = ex_v[p] && ex[p].rec.is_jalr && !ex[p].rec.ret;
        e_bt_valid = ij != 2'b00;
        e_bt_pc    = ij[0] ? ex_pc[0] + (VA - 1)'(ex[0].rec.len4) : ex_pc[1] + (VA - 1)'(ex[1].rec.len4);   // its last parcel
        e_bt_tgt   = ij[0] ? e_br_next[0] : e_br_next[1];
    end

    // ---- the resolution through a register (Plan/CORE.md 5.20, Plan/OOC.md 27.3): what EX resolves acts a
    // cycle later (the restore, the kill, the redirect, the predictors' training, the BTB, every branch's
    // completion), so that no block uses EX's comparison in the cycle it is made. Dropped when the branch is
    // killed or flushed as it leaves EX. In the cycle between, the branch is not complete (it cannot commit,
    // nor anything younger), and the younger µops move a stage on, killed there by their masks if it was
    // mispredicted. A branch resolved as predicted completed in EX until Plan/OOC.md 29.25 (the misprediction's
    // compare gated it). Its checkpoint is cleared from this register too (OOO_CTRL's cl_*), not by its
    // commit: from EX, it lay on the 4-wide core's paths (29.21; a checkpoint held a cycle longer cost 2 % with
    // 6 of them).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            br_valid <= '0;
            rs_valid <= '0;
            bt_valid <= 1'b0;
        end else begin
            for (int p = 0; p < 2; p++) begin
                br_valid[p] <= e_br_valid[p] && !flush_all && (ex_bms[p] & kill) == '0;
                rs_valid[p] <= e_rs_valid[p] && !flush_all && (ex_bms[p] & kill) == '0;
            end
            bt_valid <= e_bt_valid && !flush_all &&
                        ((ex_v[0] && ex[0].rec.is_jalr && !ex[0].rec.ret) ? (ex_bms[0] & kill) == '0 : (ex_bms[1] & kill) == '0);
        end
    end
    // the kill's choice, made here at EX's end and registered (step 1.8 V3d, Plan/OOC.md 29.94 / 29.95): OOO_ROB
    // chooses the oldest live misprediction of this register in the next cycle (restore_k, restore_ckpt), and
    // OOO_CTRL's kill, the LSU's restore and the restore's checkpoint (its id, the LQ / SQ / FTQ tails) came
    // from that choice, behind OOO_ROB's live check and age compare. A branch here is in the ROB in the next
    // cycle but after a trap or replay of this cycle (one killed or flushed now is dropped, as br_valid), and in
    // that cycle OOO_CTRL holds the kill and the restore off (flush_q); of two live ones the older is the same
    // against any head. So the same choice is made now, against this cycle's head, without the live check:
    // the same to the bit wherever it is used. OOO_ROB keeps its own (restore, restore_rob: its tail, the front end)
    logic [1:0]                k_m;                     // a misprediction leaving EX into br_* (as br_valid && br_mispred)
    logic [1:0][ROBW-1:0]      k_d;                     // its distance from the head
    always @(*) begin
        for (int p = 0; p < 2; p++) begin
            k_m[p] = e_br_valid[p] && e_br_mispred[p] && !flush_all && (ex_bms[p] & kill) == '0;
            k_d[p] = (e_br_rob[p] >= head_rob) ? ROBW'(e_br_rob[p] - head_rob) : ROBW'(e_br_rob[p] + ROBW'(NROB) - head_rob);
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) k_v <= 1'b0;
        else        k_v <= k_m != 2'b00;
    end
    always_ff @(posedge clk) k_ckpt <= (k_m[0] && (!k_m[1] || k_d[0] <= k_d[1])) ? e_br_ckpt[0] : e_br_ckpt[1];
    always_ff @(posedge clk) begin
        br_mispred <= e_br_mispred;
        br_ckpt    <= e_br_ckpt;
        br_next    <= e_br_next;
        br_rob     <= e_br_rob;
        br_pc      <= ex_pc;
        br_e       <= e_br_e;
        br_taken   <= e_br_taken;
        br_call    <= e_br_call;
        br_ret     <= e_br_ret;
        rs_ftq     <= e_rs_ftq;
        rs_e       <= e_rs_e;
        rs_taken   <= e_rs_taken;
        bt_pc      <= e_bt_pc;
        bt_tgt     <= e_bt_tgt;
    end

    // ---- the PMU's events (step 1.8 K1, Plan/OOC.md 29.97): each made here and registered into hpm_ev, a count
    // each, which CORE_CSR registers again (hpm_ev_q): counted two cycles after they happen (a CSR instruction
    // runs at the ROB's head, so the difference of two reads is exact). The 4 slots a cycle at renaming go to
    // one class each: used (r_go); in recovery (from a restore or a trap / replay until renaming takes µops
    // again) the rest; else the µops offered and not renamed to the back end, the slots with none to the front
    // end. So 12 + 17 + 20 + 21 = 4 a cycle.
    function automatic logic [2:0] pop4(input logic [3:0] v);
        return 3'(v[0]) + 3'(v[1]) + 3'(v[2]) + 3'(v[3]);
    endfunction
    logic       ev_rec;                         // renaming in recovery
    logic       w_own_f;                        // the walk on is the fetch's
    logic [2:0] ev_used, ev_offer;
    logic       ev_recn, w_start;
    always @(*) begin
        ev_used  = pop4(r_go);
        ev_offer = pop4(r_valid);
        ev_recn  = ev_rec || flush_all || restore_k;
        w_start  = !w_busy && (w_req || iw_req) && !(tlb_flush_all || flush_all);   // (OOO_PTW leaves S_IDLE)
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ev_rec  <= 1'b0;
            w_own_f <= 1'b0;
            hpm_ev  <= '0;
        end else begin
            ev_rec <= fe_flush || restore_k || (ev_rec && r_go == '0);
            if (w_start) w_own_f <= !w_req;
            hpm_ev[0]  <= 4'd0;                                         // nothing
            hpm_ev[1]  <= 4'd1;                                         // cycles
            hpm_ev[2]  <= cmt_instret;                                  // instructions retired
            hpm_ev[3]  <= 4'(cmt_ld_n);                                 // loads retired
            hpm_ev[4]  <= 4'(cmt_st_n);                                 // stores retired
            hpm_ev[5]  <= 4'(rs_valid[0]);                              // conditional branches resolved (port 0's)
            hpm_ev[6]  <= 4'(restore);                                  // mispredictions (restores)
            hpm_ev[7]  <= 4'(ev_mem[0]);                                // I$ line fills
            hpm_ev[8]  <= 4'(ev_mem[1]);                                // D$ line fills
            hpm_ev[9]  <= 4'(w_start && !w_req);                        // walks for the fetch
            hpm_ev[10] <= 4'(w_start && w_req);                         // walks for the LSU
            hpm_ev[11] <= 4'(head_valid && cmt_valid == '0 && head_mem);    // the head waits on a load or store
            hpm_ev[12] <= ev_recn ? 4'd0 : 4'(3'(ND) - ev_offer);      // slots: the front end
            hpm_ev[13] <= 4'(replay);                                   // replays
            hpm_ev[14] <= 4'(head_valid && cmt_valid == '0 && !head_mem);   // the head waits, not on memory
            hpm_ev[15] <= 4'(csr_trap && !csr_int);                     // exceptions
            hpm_ev[16] <= 4'(csr_trap && csr_int);                      // interrupts
            hpm_ev[17] <= ev_recn ? 4'd0 : 4'(ev_offer - ev_used);     // slots: the back end
            hpm_ev[18] <= 4'(ev_mem[2]);                                // L2 reads
            hpm_ev[19] <= 4'(ev_mem[3]);                                // L2 misses
            hpm_ev[20] <= 4'(ev_used);                                  // slots: used
            hpm_ev[21] <= ev_recn ? 4'(3'(ND) - ev_used) : 4'd0;       // slots: recovery
            hpm_ev[22] <= 4'(pop4(cmt_valid));                          // µops retired
            hpm_ev[23] <= 4'(ev_dwait[0]);                              // dispatch waits for the ROB
            hpm_ev[24] <= 4'(ev_dwait[1]);                              // ... an issue queue
            hpm_ev[25] <= 4'(ev_dwait[2]);                              // ... the LQ or the SQ
            hpm_ev[26] <= 4'(ev_rreg);                                  // renaming waits for physical registers
            hpm_ev[27] <= 4'(w_busy && !w_own_f);                       // the walker works for the LSU
            hpm_ev[28] <= 4'(w_busy && w_own_f);                        // ... for the fetch
            hpm_ev[29] <= 4'(ev_rckpt);                                 // renaming waits for a checkpoint
            hpm_ev[30] <= 4'(!head_valid);                              // the ROB empty
        end
    end

    /* verilator lint_off PINCONNECTEMPTY */
    OOO_PRF #(.NREG(80), .NW(NAP + 2), .NR(2 * NAP + 2)) u_prf
        (.clk(clk), .ra(prf_ra), .rd(prf_rd), .we(prf_we), .wa(prf_wa), .wd(prf_wd));
    /* verilator lint_on PINCONNECTEMPTY */

`ifdef OOO_TRACE
    // ---- the commit trace
    logic [31:0]     sh_insn [NROB] /*verilator public_flat_rd*/;
    logic [31:0]     sh_insn2 [NROB] /*verilator public_flat_rd*/;  // a pair's branch (tb_core checks its resolution)
    logic            sh_pair [NROB] /*verilator public_flat_rd*/;
    logic [VA-1:1]   sh_pc [NROB] /*verilator public_flat_rd*/;     // (tb_core checks the pc a branch resolves at)
    logic [63:0]     sh_val  [NROB];
    logic            sh_st   [NROB];
    logic [63:0]     sh_sa   [NROB];
    logic [63:0]     sh_sd   [NROB];
    logic [1:0]      sh_ss   [NROB];
    always_ff @(posedge clk) begin
        for (int j = 0; j < ND; j++) if (disp_go[j]) begin
            sh_insn[disp_rob[j]]  <= ds[j].insn;
            sh_insn2[disp_rob[j]] <= ds[j].insn2;
            sh_pair[disp_rob[j]]  <= FUSE_AB && ds[j].rec.fused;
            sh_pc[disp_rob[j]]    <= ds[j].pc;
            sh_st[disp_rob[j]]    <= 1'b0;
        end
        for (int p = 0; p < NAP; p++) if (ex_v[p] && ex[p].wr) sh_val[ex[p].rec.rob] <= ex_res[p];
        for (int m = 0; m < 2; m++)                                               // a load's value of its last M, with its W
            if (cmp_ld_v[m] && !cmp_ld_e[m]) sh_val[cmp_ld_rob[m]] <= lw_d[m];
        if (pm_v) sh_val[pm_rob] <= pm_d;                                         // the multiplier's and the MDU's
        if (md_v) sh_val[md_rob] <= md_d;
        if (x_csr) sh_val[ex[0].rec.rob] <= csr_res;                              // a CSR µop's old value
        if (fw_valid) sh_val[fw_rob] <= fw_data;                                  // an FP result (step 1.8 U2)
        if (iw_ack) sh_val[iw_rob] <= iw_data;                                    // an FP -> integer one
        // a store's address in EX (OOO_LSU4's E), an AMO's too
        if (m_ex_v[0] && (!m_ex[0].rec.is_ld || m_ex[0].rec.xop[3:2] != 2'd0)) begin
            sh_st[m_ex[0].rec.rob] <= 1'b1;
            sh_sa[m_ex[0].rec.rob] <= m_ea[0];
            sh_ss[m_ex[0].rec.rob] <= m_ex[0].rec.msize;
        end
        if (ex_v[1] && ex[1].sd) sh_sd[ex[1].rec.rob] <= ex_b[1];                  // its data in port 1's EX
        if (b2_v) sh_sd[b2_pl[11 +: ROBW]] <= b2_dat;                             // an FP store's, in port B's second stage
        if (at_wk_v) begin                                                        // an AMO's or SC's result (step 1.4 E1c):
            sh_val[at_wk_rob] <= at_wk_d;                                         // its value; a store if an AMO or an SC
            sh_st[at_wk_rob]  <= at_st;                                           // that succeeds, with an AMO's new data
            if (at_amo) sh_sd[at_wk_rob] <= at_nd;
        end
    end
    always @(*) begin
        logic [ROBW-1:0] ik;
        tr_valid   = cmt_valid;
        tr_pc      = cmt_pc;
        tr_wr      = cmt_wr | fcmt_wr;
        tr_fwr     = fcmt_wr;
        for (int k = 0; k < ND; k++) tr_rd[k] = fcmt_wr[k] ? fcmt_arch[k] : cmt_arch[k];
        tr_trap    = rob_trap || irq;
        tr_int     = irq;
        tr_cause   = csr_cause;              // (OOO_TRAP's: irq_cause a cycle late)
        tr_trap_pc = trap_pc;
        ik = head_rob;
        for (int k = 0; k < ND; k++) begin
            tr_insn[k]    = sh_insn[ik];
            tr_pair[k]    = sh_pair[ik];
            tr_insn2[k]   = sh_insn2[ik];
            tr_val[k]     = sh_val[ik];
            tr_st[k]      = sh_st[ik];
            tr_st_addr[k] = sh_sa[ik];
            tr_st_data[k] = sh_sd[ik];
            tr_st_size[k] = sh_ss[ik];
            ik = (ik == ROBW'(NROB - 1)) ? '0 : ik + ROBW'(1);
        end
    end
`endif

endmodule : OOO_CORE
