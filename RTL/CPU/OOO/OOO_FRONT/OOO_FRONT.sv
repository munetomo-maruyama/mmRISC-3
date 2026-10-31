//---------------------------------------------------------------------------
// OOO_FRONT.sv
//
// The front end of mmRISC-3 put together (Plan/CORE.md 3.8 and 5.2, B1):
// from the fetch address to the D1 / D2 register, the group of up to 4
// decoded instructions that fusion and renaming take from in D2.
//
//   F0-F2  OOO_FETCH (uBTB, predecode, TAGE-S, BTB, RAS) on the I$ port.
//          Each block it gives goes into the FTQ (pc, next address, end,
//          taken, 314 bits of predictor state: TAGE's 272 and the RAS
//          snapshot's 42) and into the fetch buffer with its FTQ index.
//   D1a    OOO_FBUF gives up to 4 instructions, kept raw.
//   D1b    OOO_DEC decodes them; the pc of each is its block's line (two
//          FTQ reads: the group's two blocks) and its parcel.
//   D2     the group register (g_*): what fusion and renaming read.
//
// Credit: fetch asks only while the fetch buffer and the FTQ (16 blocks,
// D-18) have room
// (free_n of both, from their pointers).
//
// D1a / D1b / D2, under the contract of Plan/OOC.md 13.6 (what the fetch
// buffer gives must not depend on what D2 computes in the same cycle):
//   D1a  the fetch buffer's group goes raw (4 x 41 bits: bits, rvc, parcel,
//        block, taken, seq) into the raw register R, or into the skid S
//        when R is not freed this cycle.
//   D1b  R is decoded (and its two lines read from the FTQ) into the group
//        register, which takes a new group only when D2 empties it (g_take:
//        how many of its instructions D2 took this cycle, oldest first); R
//        is then freed and takes S's group, else the fetch buffer's.
// The read of the buffer and decode each have a cycle: in one cycle they
// closed by 0.03 ns only (Plan/OOC.md 26.6, 26.7). The fetch buffer's
// consume comes from its own valid instructions, up to the first of a rare
// class in slot 1 to 3 (the buffer's out_rare: OOO_RARE on its window's
// parcels, a few gates beside the chain of lengths; decode's cut in that
// loop missed 50 MHz by 2.2 ns, Plan/OOC.md 26, and OOO_RARE on the slots'
// bits left 0.6 ns, 26.10), and S's occupancy, a register: the buffer gives while S is empty.
// R's freeing (late: it waits for g_take) only enables R and S; the select
// in front of R is S's occupancy. So a group of 4 follows one D2 takes in
// 2 cycles without a bubble.
//
// Recovery (cycle R: fe_redirect from OOO_CTRL): fetch stops at once
// (be_stop), the fetch buffer, R, S and the group register are
// emptied, the FTQ drops the blocks after the mispredicted branch's
// (restore) or all of them (fe_flush: a trap or a replay); at R + 1
// OOO_FERS reads the block's FTQ entry and restarts fetch with the history
// and the RAS put back.
//
// The TAGE update: OOO_CTRL pops the FTQ one block a cycle (ftq_pop); the
// popped block's metadata (the FTQ's head read) goes to TAGE with the
// outcomes of its slot branches. Those are kept here by parcel (8 + 8
// flip-flops a block: the resolution may write two a cycle): cleared when
// the block is pushed, written when a conditional branch resolves (rs_*:
// its block and last parcel), cleared again after the point of a restore
// (a younger branch of the same block may have resolved before the older
// one was found mispredicted), and turned into slots at the pop with the
// slots' parcels in the metadata. The update goes to TAGE a cycle after
// the pop, from a register (up_*_q): the FTQ's read and TAGE's update
// logic in one cycle closed by 0.87 ns only (Plan/OOC.md 26.13, 26.14 A).
//
// The target array (Plan/CORE.md 4.5): each FTQ block's predicted next
// address, written at the push, read by the resolution of a jalr (ta_*, one
// read per ALU port). The pc array (4.1): each FTQ block's line, written at
// the push, read in RR for the µops' pc (pa_*, one read per ALU port).
//
// Phase 1 keeps decode's FP fields out of the group register (no FPU;
// is_fp only), and the instruction bits go with each instruction for the
// commit trace (simulation; synthesis drops them when nothing reads them).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_FRONT
    #(
        parameter int VA   = 39,
        parameter int NFTQ = 16,
        parameter int FTQW = 4,
        parameter int MW   = 272        // OOO_TAGE's metadata (the field positions below are its layout)
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,

        // recovery (cycle R): OOO_CTRL, OOO_ROB, the ALU ports
        input  logic                        fe_redirect,
        input  logic                        fe_flush,   // a trap or a replay (else a restore)
        input  logic [VA-1:1]               fe_pc,
        input  logic [FTQW-1:0]             restore_ftq,
        input  logic                        restore_port,
        input  logic [1:0][2:0]             br_e,
        input  logic [1:0]                  br_taken,
        input  logic [1:0]                  br_call,
        input  logic [1:0]                  br_ret,
        input  logic [FTQW-1:0]             rcv_ftq,
        input  logic [2:0]                  rcv_end,

        // conditional branches resolved: their outcomes for the TAGE update
        input  logic [1:0]                  rs_valid,
        input  logic [1:0][FTQW-1:0]        rs_ftq,     // the branch's block (of its last half)
        input  logic [1:0][2:0]             rs_e,       // its last parcel
        input  logic [1:0]                  rs_taken,

        // an indirect jump resolved (the BTB)
        input  logic                        bt_valid,
        input  logic [VA-1:1]               bt_pc,
        input  logic [VA-1:1]               bt_tgt,

        // commit: OOO_CTRL's pops, at most one a cycle
        input  logic [1:0]                  ftq_pop,

        // the target array and the pc array (one read per ALU port)
        input  logic [1:0][FTQW-1:0]        ta_idx,
        output logic [1:0][VA-1:1]          ta_tgt,
        input  logic [1:0][FTQW-1:0]        pa_idx,
        output logic [1:0][VA-1:4]          pa_line,

        // I$
        output logic                        ic_req_valid,
        output logic [VA-1:1]               ic_req_pc,
        input  logic                        ic_req_ready,
        input  logic                        ic_resp_valid,
        input  logic [127:0]                ic_resp_data,

        // the D2 group (slot 0 the oldest; the valid slots are contiguous)
        output logic [3:0]                  g_valid,
        output logic [3:0][VA-1:1]          g_pc,
        output logic [3:0][31:0]            g_insn,     // an RVC one in the low 16 bits
        output logic [3:0]                  g_rvc,
        output logic [3:0][FTQW-1:0]        g_ftq,      // the block of its last half
        output logic [3:0][2:0]             g_end,      // its last parcel
        output logic [3:0]                  g_taken,    // predicted taken: it ends a taken block
        output logic [3:0]                  g_seq,      // follows the slot before directly
        output logic [3:0]        g_illegal,
        output logic [3:0][2:0]   g_cls,
        output logic [3:0][2:0]   g_op,
        output logic [3:0][4:0]   g_rd,
        output logic [3:0][4:0]   g_rs1,
        output logic [3:0][4:0]   g_rs2,
        output logic [3:0]        g_use_rs1,
        output logic [3:0]        g_use_rs2,
        output logic [3:0][31:0]  g_imm,
        output logic [3:0][1:0]   g_port,
        output logic [3:0]        g_lat2,
        output logic [3:0]        g_ext_ans,
        output logic [3:0]        g_nonspec,
        output logic [3:0][5:0]   g_alu_op,
        output logic [3:0]        g_a_uw,
        output logic [3:0][1:0]   g_a_shift,
        output logic [3:0][1:0]   g_a_sel,
        output logic [3:0]        g_b_sel,
        output logic [3:0]        g_word_op,
        output logic [3:0]        g_is_branch,
        output logic [3:0]        g_is_jal,
        output logic [3:0]        g_is_jalr,
        output logic [3:0][2:0]   g_br_op,
        output logic [3:0][3:0]   g_mdu_op,
        output logic [3:0][4:0]   g_mem_cmd,
        output logic [3:0][1:0]   g_mem_size,
        output logic [3:0]        g_mem_signed,
        output logic [3:0][7:0]   g_sys,
        output logic [3:0]        g_is_sfence,
        output logic [3:0]        g_is_csr,
        output logic [3:0][11:0]  g_csr_addr,
        output logic [3:0][1:0]   g_csr_op,
        output logic [3:0]        g_csr_imm_sel,
        output logic [3:0]        g_csr_wr,
        output logic [3:0]        g_csr_rd,
        output logic [3:0]        g_is_fp,
        input  logic [2:0]                  g_take      // instructions D2 takes this cycle
    );

    localparam int TM = 4 + VA - 1;     // where TAGE's metadata starts in the FTQ's (above the RAS's)
    localparam int FW = MW + TM;

    // ---- fetch, the FTQ, the restore
    logic                be_redirect /*verilator public_flat_rd*/;
    logic                be_ras_push, be_ras_pop;
    logic [VA-1:1]       be_pc, be_ras_val, be_ras_addr;
    logic [71:0]         be_hist;      // {cprev, history}
    logic [1:0]          be_hist_n;
    logic [2:0]          be_hist_bits;
    logic [3:0]          be_ras_ptr;
    logic [3:0]          credit;
    // (the block pushed, the restore's view of a block and the update's metadata are read by
    // SIM/CORE/tb_front, which checks that the restore and the update get what the push wrote)
    logic                out_valid   /*verilator public_flat_rd*/;
    logic                out_taken;
    logic [VA-1:1]       out_pc      /*verilator public_flat_rd*/;
    logic [VA-1:1]       out_next;
    logic [VA-1:1]       out_ras_val /*verilator public_flat_rd*/;
    logic [127:0]        out_data;
    logic [2:0]          out_end;
    logic [MW-1:0]       out_tmeta   /*verilator public_flat_rd*/;
    logic [3:0]          out_ras_ptr /*verilator public_flat_rd*/;
    logic                up_valid /*verilator public_flat_rd*/;     // (read by SIM/CORE/tb_front)
    logic [2:0]          up_ex    /*verilator public_flat_rd*/;
    logic [2:0]          up_tk    /*verilator public_flat_rd*/;
    logic                up_valid_q /*verilator public_flat_rd*/;   // the same a cycle later, to TAGE
    logic [2:0]          up_ex_q    /*verilator public_flat_rd*/;
    logic [2:0]          up_tk_q    /*verilator public_flat_rd*/;
    logic [MW-1:0]       up_meta_q  /*verilator public_flat_rd*/;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [FW-1:0]       hd_meta /*verilator public_flat_rd*/;
    logic [FW-1:0]       ft_meta;           // (the fields the update and the restore do not read)
    logic [VA-1:1]       ft_pc;             // (its line only)
    /* verilator lint_on UNUSEDSIGNAL */
    logic [FTQW-1:0]     push_idx /*verilator public_flat_rd*/;
    logic [FTQW-1:0]     rs_idx   /*verilator public_flat_rd*/;
    logic [FTQW-1:0]     hd_idx   /*verilator public_flat_rd*/;
    logic [FTQW:0]       ftq_free /*verilator public_flat_rd*/;
    logic [1:0][FTQW-1:0] rd_idx;
    logic [1:0][VA-1:1]  rd_pc;
    logic [2:0]          fb_free;

    // the smaller of the two (at most the fetch buffer's 4 blocks)
    assign credit = (FTQW + 1)'(fb_free) < ftq_free ? 4'(fb_free) : 4'(ftq_free);

    OOO_FETCH #(.VA(VA), .MW(MW)) u_fetch
        (.clk(clk), .rst_n(rst_n),
         .be_stop(fe_redirect), .be_redirect(be_redirect), .be_pc(be_pc), .be_hist(be_hist), .be_hist_n(be_hist_n),
         .be_hist_bits(be_hist_bits), .be_ras_ptr(be_ras_ptr), .be_ras_val(be_ras_val), .be_ras_push(be_ras_push),
         .be_ras_addr(be_ras_addr), .be_ras_pop(be_ras_pop), .credit(credit),
         .ic_req_valid(ic_req_valid), .ic_req_pc(ic_req_pc), .ic_req_ready(ic_req_ready),
         .ic_resp_valid(ic_resp_valid), .ic_resp_data(ic_resp_data),
         .out_valid(out_valid), .out_pc(out_pc), .out_data(out_data), .out_end(out_end), .out_taken(out_taken),
         .out_next(out_next), .out_tmeta(out_tmeta), .out_ras_ptr(out_ras_ptr), .out_ras_val(out_ras_val),
         .up_valid(up_valid_q), .up_meta(up_meta_q), .up_ex(up_ex_q), .up_tk(up_tk_q),
         .bt_valid(bt_valid), .bt_pc(bt_pc), .bt_tgt(bt_tgt));

    OOO_FTQ #(.NFTQ(NFTQ), .FTQW(FTQW), .VA(VA), .MW(FW)) u_ftq
        (.clk(clk), .rst_n(rst_n),
         .push_ready(), .push_valid(out_valid), .push_pc(out_pc), .push_target(out_next), .push_taken(out_taken),
         .push_end(out_end), .push_meta({out_tmeta, out_ras_ptr, out_ras_val}), .push_idx(push_idx),
         .rd_idx(rd_idx), .rd_pc(rd_pc),
         .br_idx(rs_idx), .br_pc(ft_pc), .br_target(), .br_taken(), .br_end(), .br_meta(ft_meta),
         .hd_idx(hd_idx), .hd_meta(hd_meta), .free_n(ftq_free),
         .pop(ftq_pop), .restore(fe_redirect && !fe_flush), .restore_idx(restore_ftq), .flush_all(fe_redirect && fe_flush));

    // the FTQ entry's fields: TAGE's metadata (OOO_TAGE meta_t, MSB first: hist 70, pred 3,
    // sv 3, par 3 x 3, ...) above the RAS snapshot (pointer 4, value VA - 1)
    logic [MW-1:0]       up_meta    /*verilator public_flat_rd*/;
    logic [VA-1:4]       ft_line    /*verilator public_flat_rd*/;
    logic [71:0]         ft_hist    /*verilator public_flat_rd*/;
    logic [2:0]          ft_sv      /*verilator public_flat_rd*/;
    logic [2:0][2:0]     ft_par     /*verilator public_flat_rd*/;
    logic [3:0]          ft_ras_ptr /*verilator public_flat_rd*/;
    logic [VA-1:1]       ft_ras_val /*verilator public_flat_rd*/;
    assign up_meta    = hd_meta[FW-1:TM];
    assign ft_line    = ft_pc[VA-1:4];
    assign ft_hist    = ft_meta[TM+271:TM+200];    // with cprev (D-17)
    assign ft_sv      = ft_meta[TM+196:TM+194];
    assign ft_par     = ft_meta[TM+193:TM+185];
    assign ft_ras_ptr = ft_meta[TM-1:TM-4];
    assign ft_ras_val = ft_meta[VA-2:0];

    OOO_FERS #(.VA(VA), .FTQW(FTQW), .HL(72), .RW(4)) u_fers
        (.clk(clk), .rst_n(rst_n),
         .fe_redirect(fe_redirect), .fe_flush(fe_flush), .fe_pc(fe_pc), .restore_ftq(restore_ftq),
         .restore_port(restore_port), .br_e(br_e), .br_taken(br_taken), .br_call(br_call), .br_ret(br_ret),
         .rcv_ftq(rcv_ftq), .rcv_end(rcv_end),
         .rs_idx(rs_idx), .ft_line(ft_line), .ft_hist(ft_hist), .ft_sv(ft_sv),
         .ft_par(ft_par), .ft_ras_ptr(ft_ras_ptr), .ft_ras_val(ft_ras_val),
         .be_redirect(be_redirect), .be_pc(be_pc), .be_hist(be_hist), .be_hist_n(be_hist_n),
         .be_hist_bits(be_hist_bits), .be_ras_ptr(be_ras_ptr), .be_ras_val(be_ras_val),
         .be_ras_push(be_ras_push), .be_ras_addr(be_ras_addr), .be_ras_pop(be_ras_pop));

    // ---- the outcomes of the slot branches, by block and parcel
    logic [NFTQ-1:0][7:0] oc_ex, oc_tk;
    always_ff @(posedge clk) begin
        for (int f = 0; f < NFTQ; f++)
            for (int p = 0; p < 8; p++) begin
                if (out_valid && push_idx == FTQW'(f)) oc_ex[f][p] <= 1'b0;
                for (int k = 0; k < 2; k++)
                    if (rs_valid[k] && rs_ftq[k] == FTQW'(f) && rs_e[k] == 3'(p)) begin
                        oc_ex[f][p] <= 1'b1;
                        oc_tk[f][p] <= rs_taken[k];
                    end
                if (fe_redirect && !fe_flush && restore_ftq == FTQW'(f) && 3'(p) > br_e[restore_port]) oc_ex[f][p] <= 1'b0;
            end
    end

    // the update of the popped block (the head)
    always @(*) begin
        logic [2:0]      sv;
        logic [2:0][2:0] par;
        sv  = hd_meta[TM+196:TM+194];
        par = hd_meta[TM+193:TM+185];
        up_valid = ftq_pop != 2'd0;
        for (int s = 0; s < 3; s++) begin
            up_ex[s] = sv[s] && oc_ex[hd_idx][par[s]];
            up_tk[s] = oc_tk[hd_idx][par[s]];
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) up_valid_q <= 1'b0;
        else        up_valid_q <= up_valid;
    end
    always_ff @(posedge clk) begin
        up_meta_q <= up_meta;
        up_ex_q   <= up_ex;
        up_tk_q   <= up_tk;
    end

    // ---- the target array and the pc array
    (* ram_style = "distributed" *) logic [VA-1:1] ta_mem [NFTQ];
    (* ram_style = "distributed" *) logic [VA-1:4] pa_mem [NFTQ];
    always_ff @(posedge clk) if (out_valid) ta_mem[push_idx] <= out_next;
    always_ff @(posedge clk) if (out_valid) pa_mem[push_idx] <= out_pc[VA-1:4];
    for (genvar k = 0; k < 2; k++) begin : g_arr
        assign ta_tgt[k]  = ta_mem[ta_idx[k]];
        assign pa_line[k] = pa_mem[pa_idx[k]];
    end

    // ---- D1a: the fetch buffer's group into R (or the skid S)
    logic [3:0]            fb_v, fb_rvc, fb_tk, fb_seq, fb_rare;
    logic [3:0][31:0]      fb_inst;
    logic [3:0][2:0]       fb_off;
    logic [3:0][FTQW-1:0]  fb_ftq;
    logic [2:0]            consume;

    OOO_FBUF #(.NB(4), .FTQW(FTQW)) u_fbuf
        (.clk(clk), .rst_n(rst_n), .flush(fe_redirect),
         .in_ready(), .free_n(fb_free), .in_valid(out_valid), .in_data(out_data), .in_start(out_pc[3:1]),
         .in_end(out_end), .in_taken(out_taken), .in_ftq(push_idx),
         .out_valid(fb_v), .out_inst(fb_inst), .out_rvc(fb_rvc), .out_off(fb_off), .out_ftq(fb_ftq),
         .out_taken(fb_tk), .out_seq(fb_seq), .out_rare(fb_rare), .consume(consume));

    // the skid S and the raw register R
    logic [3:0]            s_m /*verilator public_flat_rd*/;
    logic [3:0]            s_rvc, s_tk, s_seq;
    logic [3:0][31:0]      s_inst;
    logic [3:0][2:0]       s_off;
    logic [3:0][FTQW-1:0]  s_ftq;
    logic                  s_v;
    assign s_v = s_m != 4'd0;
    logic [3:0]            r_m /*verilator public_flat_rd*/;
    logic [3:0]            r_rvc, r_tk, r_seq;
    logic [3:0][31:0]      r_inst;
    logic [3:0][2:0]       r_off;
    logic [3:0][FTQW-1:0]  r_ftq;

    logic [3:0] d_illegal;
    logic [3:0][2:0] d_cls;
    logic [3:0][2:0] d_op;
    logic [3:0][4:0] d_rd;
    logic [3:0][4:0] d_rs1;
    logic [3:0][4:0] d_rs2;
    logic [3:0] d_use_rs1;
    logic [3:0] d_use_rs2;
    logic [3:0][31:0] d_imm;
    logic [3:0][1:0] d_port;
    logic [3:0] d_lat2;
    logic [3:0] d_ext_ans;
    logic [3:0] d_nonspec;
    logic [3:0][5:0] d_alu_op;
    logic [3:0] d_a_uw;
    logic [3:0][1:0] d_a_shift;
    logic [3:0][1:0] d_a_sel;
    logic [3:0] d_b_sel;
    logic [3:0] d_word_op;
    logic [3:0] d_is_branch;
    logic [3:0] d_is_jal;
    logic [3:0] d_is_jalr;
    logic [3:0][2:0] d_br_op;
    logic [3:0][3:0] d_mdu_op;
    logic [3:0][4:0] d_mem_cmd;
    logic [3:0][1:0] d_mem_size;
    logic [3:0] d_mem_signed;
    logic [3:0][7:0] d_sys;
    logic [3:0] d_is_sfence;
    logic [3:0] d_is_csr;
    logic [3:0][11:0] d_csr_addr;
    logic [3:0][1:0] d_csr_op;
    logic [3:0] d_csr_imm_sel;
    logic [3:0] d_csr_wr;
    logic [3:0] d_csr_rd;
    logic [3:0] d_is_fp;
    /* verilator lint_off UNUSEDSIGNAL */          // the FP fields: not kept in Phase 1
    logic [3:0][4:0] d_fp_op;
    logic [3:0] d_fp_fmt;
    logic [3:0][2:0] d_fp_rm;
    logic [3:0][2:0] d_use_fs;
    logic [3:0][4:0] d_rs3;
    logic [3:0] d_fp_we_rd;
    logic [3:0] d_fp_int_signed;
    logic [3:0] d_fp_int_w;
    /* verilator lint_on UNUSEDSIGNAL */
    // ---- D1b: decode of R
    /* verilator lint_off PINCONNECTEMPTY */    // (decode's cut: the fetch buffer's group is cut below, as it is given)
    OOO_DEC u_dec
        (.in_inst(r_inst), .in_rvc(r_rvc), .cut(),
         .illegal(d_illegal), .cls(d_cls), .op(d_op), .rd(d_rd), .rs1(d_rs1), .rs2(d_rs2), .use_rs1(d_use_rs1), .use_rs2(d_use_rs2), .imm(d_imm), .port(d_port), .lat2(d_lat2), .ext_ans(d_ext_ans), .nonspec(d_nonspec), .alu_op(d_alu_op), .a_uw(d_a_uw), .a_shift(d_a_shift), .a_sel(d_a_sel), .b_sel(d_b_sel), .word_op(d_word_op), .is_branch(d_is_branch), .is_jal(d_is_jal), .is_jalr(d_is_jalr), .br_op(d_br_op), .mdu_op(d_mdu_op), .mem_cmd(d_mem_cmd), .mem_size(d_mem_size), .mem_signed(d_mem_signed), .sys(d_sys), .is_sfence(d_is_sfence), .is_csr(d_is_csr), .csr_addr(d_csr_addr), .csr_op(d_csr_op), .csr_imm_sel(d_csr_imm_sel), .csr_wr(d_csr_wr), .csr_rd(d_csr_rd), .is_fp(d_is_fp), .fp_op(d_fp_op), .fp_fmt(d_fp_fmt), .fp_rm(d_fp_rm), .use_fs(d_use_fs), .rs3(d_rs3), .fp_we_rd(d_fp_we_rd), .fp_int_signed(d_fp_int_signed), .fp_int_w(d_fp_int_w));
    /* verilator lint_on PINCONNECTEMPTY */

    // the fetch buffer's group: its valid instructions up to the first of a
    // rare class in slot 1 to 3 (out_rare)
    logic [3:0] fb_m;
    always @(*) begin
        logic run;
        run = 1'b1;
        for (int k = 0; k < 4; k++) begin
            run     = run && fb_v[k] && (k == 0 || !fb_rare[k]);
            fb_m[k] = run;
        end
        consume = s_v ? 3'd0 : 3'(fb_m[0]) + 3'(fb_m[1]) + 3'(fb_m[2]) + 3'(fb_m[3]);
    end

    // R's two blocks: their lines
    assign rd_idx[0] = r_ftq[0];
    assign rd_idx[1] = r_ftq[0] + FTQW'(1);

    // ---- D2: the group register
    typedef struct packed {
        logic  illegal;
        logic [2:0] cls;
        logic [2:0] op;
        logic [4:0] rd;
        logic [4:0] rs1;
        logic [4:0] rs2;
        logic  use_rs1;
        logic  use_rs2;
        logic [31:0] imm;
        logic [1:0] port;
        logic  lat2;
        logic  ext_ans;
        logic  nonspec;
        logic [5:0] alu_op;
        logic  a_uw;
        logic [1:0] a_shift;
        logic [1:0] a_sel;
        logic  b_sel;
        logic  word_op;
        logic  is_branch;
        logic  is_jal;
        logic  is_jalr;
        logic [2:0] br_op;
        logic [3:0] mdu_op;
        logic [4:0] mem_cmd;
        logic [1:0] mem_size;
        logic  mem_signed;
        logic [7:0] sys;
        logic  is_sfence;
        logic  is_csr;
        logic [11:0] csr_addr;
        logic [1:0] csr_op;
        logic  csr_imm_sel;
        logic  csr_wr;
        logic  csr_rd;
        logic  is_fp;
    } dec_t;
    dec_t [3:0]            gd, g_d;
    always @(*) begin
        for (int k = 0; k < 4; k++) begin
            gd[k].illegal = d_illegal[k];
            gd[k].cls = d_cls[k];
            gd[k].op = d_op[k];
            gd[k].rd = d_rd[k];
            gd[k].rs1 = d_rs1[k];
            gd[k].rs2 = d_rs2[k];
            gd[k].use_rs1 = d_use_rs1[k];
            gd[k].use_rs2 = d_use_rs2[k];
            gd[k].imm = d_imm[k];
            gd[k].port = d_port[k];
            gd[k].lat2 = d_lat2[k];
            gd[k].ext_ans = d_ext_ans[k];
            gd[k].nonspec = d_nonspec[k];
            gd[k].alu_op = d_alu_op[k];
            gd[k].a_uw = d_a_uw[k];
            gd[k].a_shift = d_a_shift[k];
            gd[k].a_sel = d_a_sel[k];
            gd[k].b_sel = d_b_sel[k];
            gd[k].word_op = d_word_op[k];
            gd[k].is_branch = d_is_branch[k];
            gd[k].is_jal = d_is_jal[k];
            gd[k].is_jalr = d_is_jalr[k];
            gd[k].br_op = d_br_op[k];
            gd[k].mdu_op = d_mdu_op[k];
            gd[k].mem_cmd = d_mem_cmd[k];
            gd[k].mem_size = d_mem_size[k];
            gd[k].mem_signed = d_mem_signed[k];
            gd[k].sys = d_sys[k];
            gd[k].is_sfence = d_is_sfence[k];
            gd[k].is_csr = d_is_csr[k];
            gd[k].csr_addr = d_csr_addr[k];
            gd[k].csr_op = d_csr_op[k];
            gd[k].csr_imm_sel = d_csr_imm_sel[k];
            gd[k].csr_wr = d_csr_wr[k];
            gd[k].csr_rd = d_csr_rd[k];
            gd[k].is_fp = d_is_fp[k];
        end
    end

    logic [3:0]            g_v, tm, g_left, g_bsel, g_rvc_q, g_tk_q, g_seq_q;
    logic [3:0][2:0]       g_off;
    logic [3:0][FTQW-1:0]  g_ftq_q;
    logic [3:0][31:0]      g_insn_q;
    logic [VA-1:4]         g_line0, g_line1;
    logic                  g_load, r_free;
    always @(*) begin
        logic [2:0] n;
        n = '0;
        for (int k = 0; k < 4; k++) begin
            tm[k] = g_v[k] && n < g_take;
            n = n + 3'(g_v[k]);
        end
        g_left = g_v & ~tm;
        g_load = g_left == 4'd0 && r_m != 4'd0;
        r_free = r_m == 4'd0 || g_left == 4'd0;     // R empty, or moving into the group register
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g_v <= '0;
            r_m <= '0;
            s_m <= '0;
        end else if (fe_redirect) begin
            g_v <= '0;
            r_m <= '0;
            s_m <= '0;
        end else begin
            g_v <= g_load ? r_m : g_left;
            if (r_free)         r_m <= s_v ? s_m : fb_m;        // S's group, else the fetch buffer's (or none)
            if (s_v)            s_m <= r_free ? 4'd0 : s_m;     // taken by R, or still waiting
            else if (!r_free)   s_m <= fb_m;                    // the fetch buffer's group waits (or none)
        end
    end
    always_ff @(posedge clk) begin
        if (!s_v && !r_free) begin
            s_inst <= fb_inst;
            s_rvc  <= fb_rvc;
            s_off  <= fb_off;
            s_ftq  <= fb_ftq;
            s_tk   <= fb_tk;
            s_seq  <= fb_seq;
        end
        if (r_free) begin
            r_inst <= s_v ? s_inst : fb_inst;
            r_rvc  <= s_v ? s_rvc  : fb_rvc;
            r_off  <= s_v ? s_off  : fb_off;
            r_ftq  <= s_v ? s_ftq  : fb_ftq;
            r_tk   <= s_v ? s_tk   : fb_tk;
            r_seq  <= s_v ? s_seq  : fb_seq;
        end
        if (g_load) begin
            g_d      <= gd;
            g_line0  <= rd_pc[0][VA-1:4];
            g_line1  <= rd_pc[1][VA-1:4];
            for (int k = 0; k < 4; k++) begin
                g_bsel[k]   <= r_ftq[k] != r_ftq[0];
                g_ftq_q[k]  <= r_ftq[k] + FTQW'(r_off[k] == 3'd7 && !r_rvc[k]);   // across two lines: the next block
            end
            g_off    <= r_off;
            g_rvc_q  <= r_rvc;
            g_tk_q   <= r_tk;
            g_seq_q  <= r_seq;
            g_insn_q <= r_inst;
        end
    end

    assign g_valid = g_v;
    assign g_insn  = g_insn_q;
    assign g_rvc   = g_rvc_q;
    assign g_ftq   = g_ftq_q;
    assign g_taken = g_tk_q;
    assign g_seq   = g_seq_q;
    for (genvar k = 0; k < 4; k++) begin : g_out
        assign g_pc[k]  = {g_bsel[k] ? g_line1 : g_line0, g_off[k]};
        assign g_end[k] = g_off[k] + 3'(!g_rvc_q[k]);
        assign g_illegal[k] = g_d[k].illegal;
        assign g_cls[k] = g_d[k].cls;
        assign g_op[k] = g_d[k].op;
        assign g_rd[k] = g_d[k].rd;
        assign g_rs1[k] = g_d[k].rs1;
        assign g_rs2[k] = g_d[k].rs2;
        assign g_use_rs1[k] = g_d[k].use_rs1;
        assign g_use_rs2[k] = g_d[k].use_rs2;
        assign g_imm[k] = g_d[k].imm;
        assign g_port[k] = g_d[k].port;
        assign g_lat2[k] = g_d[k].lat2;
        assign g_ext_ans[k] = g_d[k].ext_ans;
        assign g_nonspec[k] = g_d[k].nonspec;
        assign g_alu_op[k] = g_d[k].alu_op;
        assign g_a_uw[k] = g_d[k].a_uw;
        assign g_a_shift[k] = g_d[k].a_shift;
        assign g_a_sel[k] = g_d[k].a_sel;
        assign g_b_sel[k] = g_d[k].b_sel;
        assign g_word_op[k] = g_d[k].word_op;
        assign g_is_branch[k] = g_d[k].is_branch;
        assign g_is_jal[k] = g_d[k].is_jal;
        assign g_is_jalr[k] = g_d[k].is_jalr;
        assign g_br_op[k] = g_d[k].br_op;
        assign g_mdu_op[k] = g_d[k].mdu_op;
        assign g_mem_cmd[k] = g_d[k].mem_cmd;
        assign g_mem_size[k] = g_d[k].mem_size;
        assign g_mem_signed[k] = g_d[k].mem_signed;
        assign g_sys[k] = g_d[k].sys;
        assign g_is_sfence[k] = g_d[k].is_sfence;
        assign g_is_csr[k] = g_d[k].is_csr;
        assign g_csr_addr[k] = g_d[k].csr_addr;
        assign g_csr_op[k] = g_d[k].csr_op;
        assign g_csr_imm_sel[k] = g_d[k].csr_imm_sel;
        assign g_csr_wr[k] = g_d[k].csr_wr;
        assign g_csr_rd[k] = g_d[k].csr_rd;
        assign g_is_fp[k] = g_d[k].is_fp;
    end

endmodule : OOO_FRONT
