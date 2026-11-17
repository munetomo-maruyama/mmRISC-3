//---------------------------------------------------------------------------
// OOO_FPUW.sv
//
// The renamed FPU around mmRISC-2's FPU_PIPE (step 1.8 U1, Plan/OOC.md 29.80,
// 29.81). FPU_PIPE is used as it is: one operation a cycle, the result 9 cycles
// after the offer, in the order offered; a divide / square root holds it from its
// offer to its answer (in_ready low). Its hold and kill are not used: this block
// offers only what FPU_PIPE takes, and drops what is killed by itself.
//
//   issue (c)   OOO_FIQ's port A
//   S1   (c+1)  the FP file read at the sources (rf_addr / rf_data), with a bypass
//               of the FP results and the load ports' writes of this cycle; the
//               rounding mode resolved (7: frm, which only CSR µops at the ROB head
//               write, and they replay what follows)
//   S2   (c+2)  the offer, with a bypass of the FP result of this cycle: an operation
//               issued exactly at its producer's wakeup meets the result here
//   out  (c+11) the result: an FP one written into the FP file (fw_*: also the ROB's
//               completion, with the flags), an integer one (compares, fclass,
//               fmv.x.*, fcvt to integers) into a FIFO of FD toward the integer file
//               (iw_*, popped by iw_ack: port 0's write slot, shared with OOO_MDUP)
//
// The wakeup (wk_*): an FP result's tag at its offer + 6, so that a dependent
// issued the cycle after it is offered as the result comes out; a divide's or a
// square root's at its answer (its length is not known: special values do not
// iterate), dependents then reading the FP file. The two never meet: nothing is
// offered between a divide's offer and its answer. A broadcast is not made for a µop
// killed by then: its register may already be a younger µop's.
//
// fpu_ok (OOO_FIQ may issue to port A): no divide / square root in S1, S2 or the
// FPU, no int -> FP µop waiting. f2i_ok: the FP -> integer µops in S1, S2, the FPU
// and the FIFO are fewer than FD, so each finds a place.
//
// An int -> FP µop (fmv.*.x, fcvt from an integer) comes from OOO_IQ3's port 0 with
// its operand (x_*) into a buffer of one, and is offered in the first cycle S2 is
// empty and FPU_PIPE takes it (fpu_ok being low meanwhile, S2 empties in 2 cycles).
// x_ready: the buffer is empty.
//
// Kills: what is in flight carries its branch mask, cleared by clr: in S1, S2, the
// buffer (not offered when killed), the FPU (a ring of the offered µops in FPU order,
// popped at each answer: a killed one is neither written nor woken), the FIFO
// (skipped at its head). flush kills it all. A killed divide runs to its end
// (Plan/OOC.md 29.80).
//
// The payload (OOO_FIQ's, PLW bits): op [4:0] (FPU_PIPE's numbers), fmt [5],
// rm [8:6], int_signed [9], int_w [10], the ROB index [11 +: ROBW], the integer
// destination [11 + ROBW +: ITAGW].
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_FPUW
    #(
        parameter int TAGW  = 6,
        parameter int ITAGW = 7,
        parameter int ROBW  = 6,
        parameter int NCK   = 12,
        parameter int PLW   = 32,
        parameter int FD    = 4
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,
        input  logic                  flush,
        input  logic [NCK-1:0]        kill,
        input  logic [NCK-1:0]        clr,
        input  logic [2:0]            frm,

        // OOO_FIQ's port A
        input  logic                  a_valid,
        input  logic [2:0][TAGW-1:0]  a_src,
        input  logic                  a_wr,
        input  logic [TAGW-1:0]       a_dst,
        input  logic [NCK-1:0]        a_bm,
        input  logic                  a_dv,
        input  logic                  a_f2i,
        input  logic [PLW-1:0]        a_pl,
        output logic                  fpu_ok,
        output logic                  f2i_ok,

        // the FP file's 3 reads for S1
        output logic [2:0][TAGW-1:0]  rf_addr,
        input  logic [2:0][63:0]      rf_data,

        // the load ports' FP writes of this cycle (for S1's bypass)
        input  logic [1:0]            ld_valid,
        input  logic [1:0][TAGW-1:0]  ld_tag,
        input  logic [1:0][63:0]      ld_data,

        // an int -> FP µop from port 0
        input  logic                  x_valid,
        input  logic [63:0]           x_data,
        input  logic [TAGW-1:0]       x_dst,
        input  logic [NCK-1:0]        x_bm,
        input  logic [PLW-1:0]        x_pl,
        output logic                  x_ready,

        // an FP result
        output logic                  fw_valid,
        output logic [TAGW-1:0]       fw_tag,
        output logic [63:0]           fw_data,
        output logic [ROBW-1:0]       fw_rob,
        output logic [4:0]            fw_flags,

        // an integer result
        output logic                  iw_valid,
        output logic [ITAGW-1:0]      iw_tag,
        output logic [63:0]           iw_data,
        output logic [ROBW-1:0]       iw_rob,
        output logic [4:0]            iw_flags,
        input  logic                  iw_ack,

        // the wakeup
        output logic                  wk_valid,
        output logic [TAGW-1:0]       wk_tag
    );

    localparam int P_ROB  = 11;
    localparam int P_IDST = 11 + ROBW;
    localparam int RD     = 16;                      // the ring

    function automatic logic dead(input logic [NCK-1:0] bm);
        return flush || (bm & kill) != '0;
    endfunction

    // ---- S1
    logic                 s1_v, s1_wr, s1_dv, s1_f2i;
    logic [2:0][TAGW-1:0] s1_src;
    logic [TAGW-1:0]      s1_dst;
    logic [NCK-1:0]       s1_bm;
    logic [PLW-1:0]       s1_pl;
    // ---- S2
    logic                 s2_v, s2_wr, s2_dv, s2_f2i;
    logic [2:0][63:0]     s2_op;
    logic [2:0][TAGW-1:0] s2_src;
    logic [TAGW-1:0]      s2_dst;
    logic [NCK-1:0]       s2_bm;
    logic [PLW-1:0]       s2_pl;
    // ---- the buffer of an int -> FP µop
    logic                 xb_v;
    logic [63:0]          xb_d;
    logic [TAGW-1:0]      xb_dst;
    logic [NCK-1:0]       xb_bm;
    logic [PLW-1:0]       xb_pl;

    // ---- the FPU's answer and what the ring says of it
    logic                 o_valid, o_is_int;
    logic [63:0]          o_result;
    logic [4:0]           o_flags;
    logic [3:0]           o_tag;
    logic                 in_ready, busy_u;
    logic [3:0]           rh, rt;                    // the ring's head (oldest), tail
    logic                 r_v   [RD];
    logic                 r_wr  [RD], r_f2i [RD], r_dv [RD], r_k [RD];
    logic [TAGW-1:0]      r_dst [RD];
    logic [ITAGW-1:0]     r_idst [RD];
    logic [ROBW-1:0]      r_rob [RD];
    logic [NCK-1:0]       r_bm  [RD];

    // the answer of this cycle, alive
    logic o_live, o_fp;
    assign o_live = o_valid && !r_k[rh] && !dead(r_bm[rh]);
    assign o_fp   = o_live && r_wr[rh] && !r_f2i[rh];

    assign fw_valid = o_fp;
    assign fw_tag   = r_dst[rh];
    assign fw_data  = o_result;
    assign fw_rob   = r_rob[rh];
    assign fw_flags = o_flags;

    // ---- S1: the reads and their bypass
    assign rf_addr = s1_src;
    logic [2:0][63:0] s1_op;
    always @(*) begin
        for (int s = 0; s < 3; s++) begin
            s1_op[s] = rf_data[s];
            for (int l = 0; l < 2; l++) if (ld_valid[l] && ld_tag[l] == s1_src[s]) s1_op[s] = ld_data[l];
            if (o_fp && r_dst[rh] == s1_src[s]) s1_op[s] = o_result;
        end
    end
    logic [2:0] s1_rm;
    assign s1_rm = s1_pl[8:6] == 3'b111 ? frm : s1_pl[8:6];

    // ---- S2: the offer
    logic             s2_go, xb_go, offer;
    logic [2:0][63:0] in_op;
    logic [PLW-1:0]   in_pl;
    always @(*) begin
        for (int s = 0; s < 3; s++) begin
            in_op[s] = s2_op[s];
            if (o_fp && r_dst[rh] == s2_src[s]) in_op[s] = o_result;
        end
    end
    assign s2_go = s2_v && !dead(s2_bm);
    assign xb_go = !s2_go && xb_v && !dead(xb_bm) && in_ready;
    assign offer = s2_go || xb_go;
    assign in_pl = s2_go ? s2_pl : xb_pl;
    logic [2:0] x_rm;
    assign x_rm = xb_pl[8:6] == 3'b111 ? frm : xb_pl[8:6];

    FPU_PIPE #(.TAG_W(4)) u_fpu
        (.clk(clk), .rst_n(rst_n),
         .in_valid(offer), .in_ready(in_ready), .in_op(in_pl[4:0]), .in_fmt(in_pl[5]),
         .in_rm(s2_go ? s2_pl[8:6] : x_rm), .in_int_signed(in_pl[9]), .in_int_w(in_pl[10]),
         .in_a(s2_go ? in_op[0] : xb_d), .in_b(in_op[1]), .in_c(in_op[2]), .in_tag(rt),
         .hold0(1'b0), .hold1(1'b0), .kill0(1'b0), .kill1(1'b0),
         .out_valid(o_valid), .out_result(o_result), .out_is_int(o_is_int), .out_flags(o_flags),
         .out_tag(o_tag), .busy(busy_u));

    // ---- what the FIQ may issue
    logic [2:0] fcnt;                                // the FIFO's entries
    logic [4:0] f2n;                                 // FP -> integer µops in flight and waiting
    always @(*) begin
        f2n = 5'(s1_v && s1_f2i) + 5'(s2_v && s2_f2i) + 5'(fcnt);
        for (int i = 0; i < RD; i++) f2n = f2n + 5'(r_v[i] && r_f2i[i]);
    end
    assign fpu_ok  = !xb_v && !(s1_v && s1_dv) && !(s2_v && s2_dv) && in_ready;
    assign f2i_ok  = f2n < 5'(FD);
    assign x_ready = !xb_v;

    // ---- the wakeup: offer + 6, or a divide's answer
    logic [5:0]       w_v;
    logic [3:0]       w_i [6];
    logic             w_fix;
    assign w_fix = w_v[5] && !r_k[w_i[5]] && !dead(r_bm[w_i[5]]);
    always @(*) begin
        wk_valid = 1'b0;
        wk_tag   = r_dst[w_i[5]];
        if (w_fix) wk_valid = 1'b1;
        if (o_fp && r_dv[rh]) begin wk_valid = 1'b1; wk_tag = r_dst[rh]; end
    end

    // ---- the FIFO of integer results
    logic [ITAGW-1:0] f_tag  [FD];
    logic [63:0]      f_data [FD];
    logic [ROBW-1:0]  f_rob  [FD];
    logic [4:0]       f_fl   [FD];
    logic [NCK-1:0]   f_bm   [FD];
    logic             f_k    [FD];                   // killed while it waits
    logic [$clog2(FD)-1:0] fh, ft;
    logic             fhd;                           // the head is killed: dropped now
    assign fhd      = fcnt != 3'd0 && (f_k[fh] || dead(f_bm[fh]));
    assign iw_valid = fcnt != 3'd0 && !fhd;
    assign iw_tag   = f_tag[fh];
    assign iw_data  = f_data[fh];
    assign iw_rob   = f_rob[fh];
    assign iw_flags = f_fl[fh];
    logic f_push, f_pop;
    assign f_push = o_live && r_f2i[rh];
    assign f_pop  = fhd || (iw_valid && iw_ack);

    // ---- the clocked state
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_v <= 1'b0; s2_v <= 1'b0; xb_v <= 1'b0;
            rh <= '0; rt <= '0;
            for (int i = 0; i < RD; i++) r_v[i] <= 1'b0;
            w_v <= '0;
            fh <= '0; ft <= '0; fcnt <= '0;
        end else begin
            s1_v <= a_valid && !dead(a_bm);
            s2_v <= s1_v && !dead(s1_bm);
            if (xb_go || (xb_v && dead(xb_bm))) xb_v <= 1'b0;
            if (x_valid && !xb_v && !dead(x_bm)) xb_v <= 1'b1;
            if (offer) begin
                r_v[rt] <= 1'b1;
                rt <= rt + 4'd1;
            end
            if (o_valid) begin
                r_v[rh] <= 1'b0;
                rh <= rh + 4'd1;
            end
            w_v <= {w_v[4:0], offer && (s2_go ? s2_wr && !s2_f2i && !s2_dv : 1'b1)};
            if (flush) begin
                fcnt <= '0; fh <= ft;
            end else begin
                if (f_push) ft <= ft + 1'b1;
                if (f_pop)  fh <= fh + 1'b1;
                fcnt <= fcnt + 3'(f_push) - 3'(f_pop);
            end
        end
    end
    always_ff @(posedge clk) begin
        s1_src <= a_src; s1_wr <= a_wr; s1_dst <= a_dst; s1_bm <= a_bm & ~clr; s1_dv <= a_dv; s1_f2i <= a_f2i;
        s1_pl  <= a_pl;
        s2_op  <= s1_op; s2_src <= s1_src; s2_wr <= s1_wr; s2_dst <= s1_dst; s2_bm <= s1_bm & ~clr;
        s2_dv  <= s1_dv; s2_f2i <= s1_f2i;
        s2_pl  <= s1_pl; s2_pl[8:6] <= s1_rm;
        if (x_valid && !xb_v) begin
            xb_d <= x_data; xb_dst <= x_dst; xb_bm <= x_bm & ~clr; xb_pl <= x_pl;
        end else xb_bm <= xb_bm & ~clr;
        for (int i = 0; i < RD; i++) begin
            r_bm[i] <= r_bm[i] & ~clr;
            if (dead(r_bm[i])) r_k[i] <= 1'b1;
        end
        if (offer) begin
            r_wr[rt]   <= s2_go ? s2_wr : 1'b1;
            r_f2i[rt]  <= s2_go && s2_f2i;
            r_dv[rt]   <= s2_go && s2_dv;
            r_k[rt]    <= 1'b0;
            r_dst[rt]  <= s2_go ? s2_dst : xb_dst;
            r_idst[rt] <= in_pl[P_IDST +: ITAGW];
            r_rob[rt]  <= in_pl[P_ROB +: ROBW];
            r_bm[rt]   <= (s2_go ? s2_bm : xb_bm) & ~clr;
        end
        w_i[0] <= rt;
        for (int k = 1; k < 6; k++) w_i[k] <= w_i[k-1];
        if (f_push) begin
            f_tag[ft]  <= r_idst[rh];
            f_data[ft] <= o_result;
            f_rob[ft]  <= r_rob[rh];
            f_fl[ft]   <= o_flags;
            f_bm[ft]   <= r_bm[rh] & ~clr;
        end
        for (int i = 0; i < FD; i++)
            if (f_push && ft == ($clog2(FD))'(i)) f_k[i] <= 1'b0;
            else begin
                f_bm[i] <= f_bm[i] & ~clr;
                if (dead(f_bm[i])) f_k[i] <= 1'b1;
            end
    end

    // (o_tag is the ring's index of the answer, rh; o_is_int is r_f2i's; busy is not needed;
    //  the payload's bits above the integer destination are the integrator's, its rm went by s1_rm / x_rm)
    logic unused;
    assign unused = ^{o_tag, o_is_int, busy_u, in_pl[8:6]} ^ (PLW > P_IDST + ITAGW ? ^in_pl : 1'b0);

endmodule : OOO_FPUW
