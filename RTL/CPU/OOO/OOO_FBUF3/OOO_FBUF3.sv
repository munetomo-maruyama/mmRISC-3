//---------------------------------------------------------------------------
// OOO_FBUF3.sv
//
// The fetch buffer of the 4-wide core at 50 MHz (Doc/STRATEGY.md 4.3 D1, 4.5 loop 5,
// Plan/OOC.md 29.11): blocks of 32 bytes in, 6 instructions a cycle out, from 2 blocks.
// OOO_FBUF2, which has the reasons for a table of a block's instructions, with a second
// block read beside the first:
//
//   F2  in_st, in_first: a table of the block's instructions, as OOO_FBUF2
//   D1  the block being read (cur) gives what it has left, and the next one (nxt, also in
//       flip-flops) the rest of 6
//
// Against one block a cycle +2.1 % in the model (Plan/model: dec_block). A third block in a
// cycle waits: 2 are all of the gain (dec_block 2 and 3 give the same).
//
// A rare class (OOO_RARE: decoded in slot 0 alone): a block with one anywhere gives one
// instruction a cycle, and no block goes beside it. FP code pays for that; its unit is
// not in CoreMark.
//
// One block a cycle comes from the RAM or straight in, to cur or nxt, whichever is free
// next cycle. So short blocks that cur finishes each cycle leave nxt empty, with blocks
// waiting: one block a cycle then, which is as fast as fetch gives them (Plan/OOC.md 29.11).
//
// NO: how many it gives a cycle at most (6; 4 in OOO_FRONT, whose decode is 4 wide: step 1.5,
// Plan/OOC.md 29.37, 29.39). Slots NO and above are then never valid.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_FBUF3
    #(
        parameter int NB   = 8,         // blocks waiting (a power of two)
        parameter int FTQW = 5,
        parameter int NO   = 6          // given a cycle at most (1 .. 6)
    )
    (
        input  logic                     clk,
        input  logic                     rst_n,
        input  logic                     flush,

        // F4: from fetch's registers
        output logic                     in_ready,
        output logic [$clog2(NB):0]      free_n,     // blocks it can take (fetch's credit)
        input  logic                     in_valid,
        input  logic [255:0]             in_data,    // parcel k in bits 16k+15 .. 16k
        input  logic [15:0]              in_st,      // an instruction starts at this parcel (past a taken transfer too)
        input  logic [15:0]              in_first,   // the predicted-taken transfer that ends it, by its last parcel
        input  logic [FTQW-1:0]          in_ftq,

        // D1: to decode's registers
        input  logic                     out_ready,
        output logic [5:0]               out_valid,
        output logic [5:0][31:0]         out_inst,
        output logic [5:0]               out_rvc,
        output logic [5:0][3:0]          out_off,    // the parcel of its first half
        output logic [5:0][FTQW-1:0]     out_ftq,    // ... and its block
        output logic [5:0]               out_taken,
        output logic                     out_rare    // slot 0 is of a rare class
    );

    localparam int BW = $clog2(NB);
    // what waits: parcels, the table, the count, rare, rp, taken, ftq, cftq
    localparam int EW = 17 * 16 + 16 * 5 + 5 + 1 + 17 + 1 + FTQW + FTQW;

    // ---- F4: the block's place 0, and its table
    logic            c_v;                    // a first half waits for this block
    logic [15:0]     c_p;
    logic [FTQW-1:0] c_ftq;
    logic [15:0]     w_in [17];              // place 0: the first half; k + 1: parcel k
    logic            strad;                  // its last instruction starts here, ends in the next
    logic [15:0]     su;                     // the starts that are this block's
    logic [16:0]     rp_in;
    assign w_in[0] = c_p;
    for (genvar k = 0; k < 16; k++) begin : g_w
        assign w_in[k+1] = in_data[16*k +: 16];
    end
    for (genvar k = 0; k < 17; k++) begin : g_rare
        OOO_RARE u_rare (.p(w_in[k]), .rare(rp_in[k]));
    end

    logic [4:0]  n_in;
    logic [4:0]  p_in [16];
    logic        rb_in, in_taken, any_in;
    logic [4:0]  cum [16];                   // how many start up to this parcel
    always @(*) begin
        automatic logic [4:0] c = 5'(c_v);   // how many before this parcel
        strad = in_st[15] && in_data[241:240] == 2'b11;
        su    = in_st;
        su[15] = in_st[15] && !strad;
        for (int j = 0; j < 16; j++) p_in[j] = 5'd0;   // (with c_v, the first is place 0)
        for (int k = 0; k < 16; k++) begin
            for (int j = 0; j < 16; j++)
                if (su[k] && c == 5'(j)) p_in[j] = p_in[j] | 5'(k + 1);
            if (su[k]) c = c + 5'd1;
            cum[k] = c;
        end
        in_taken = in_first != 16'd0;
        n_in = in_taken ? 5'd0 : c;
        for (int k = 0; k < 16; k++) if (in_first[k]) n_in = n_in | cum[k];
        any_in = c != 5'd0;
        rb_in = (c_v && rp_in[0]) || ({su} & rp_in[16:1]) != 16'd0;
    end

    logic take_in;                           // a block comes in now
    logic keep_in;                           // ... and it has instructions
    assign take_in = in_valid && in_ready && !flush;
    assign keep_in = take_in && any_in;      // (a taken transfer ends an instruction, so with one n_in is not 0)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)        c_v <= 1'b0;
        else if (flush)    c_v <= 1'b0;
        else if (take_in)  c_v <= strad && !in_taken;
    end
    always_ff @(posedge clk) begin
        if (take_in) begin
            c_p   <= in_data[255:240];
            c_ftq <= in_ftq;
        end
    end

    logic [EW-1:0] e_in;
    always @(*) begin
        e_in = '0;
        for (int k = 0; k < 17; k++) e_in[16*k +: 16] = w_in[k];
        for (int j = 0; j < 16; j++) e_in[17*16 + 5*j +: 5] = p_in[j];
        e_in[17*16 + 80 +: 5]  = n_in;
        e_in[17*16 + 85]       = rb_in;
        e_in[17*16 + 86 +: 17] = rp_in;
        e_in[17*16 + 103]      = in_taken;
        e_in[17*16 + 104 +: FTQW] = in_ftq;
        e_in[17*16 + 104 + FTQW +: FTQW] = c_ftq;
    end

    // ---- the blocks that wait
    (* ram_style = "distributed" *) logic [EW-1:0] mem [NB];
    logic [BW-1:0] hb, tb;
    logic [BW:0]   cnt;
    logic [EW-1:0] e_q;
    assign e_q      = mem[hb];
    assign free_n   = (BW + 1)'(NB) - cnt;
    assign in_ready = cnt != (BW + 1)'(NB);

    logic e_use, e_by, e_v;                  // a block to take: from the RAM, or straight in
    assign e_use = cnt != '0;
    assign e_by  = !e_use && keep_in;
    assign e_v   = e_use || e_by;
    logic [EW-1:0] e_n;
    assign e_n = e_use ? e_q : e_in;

    // ---- D1: the blocks being read; [0] cur, [1] nxt
    logic [1:0]      bv;                     // cv, nv
    logic [15:0]     w  [2][17];
    logic [4:0]      p  [2][16];
    logic [4:0]      n1;                     // nxt: how many it has
    logic [4:0]      rem;                    // cur: how many it has left
    logic [1:0]      rb, tk;
    logic [16:0]     rp;                     // cur's
    logic [16:0]     rp1;
    logic [FTQW-1:0] ftq [2], cftq [2];
    logic [3:0]      hj [6];                 // the instruction in slot j, in its block
    logic [5:0]      sn;                     // slot j is from nxt

    // how many go now
    logic       cr;                          // nxt goes beside cur
    logic [2:0] take;
    logic [5:0] all;                         // what they have together
    logic [4:0] over;                        // of them from nxt
    logic       go, d0, d1;                  // cur is done, nxt is done
    always @(*) begin
        cr   = bv[1] && !rb[0] && !rb[1];
        all  = 6'(rem) + (cr ? 6'(n1) : 6'd0);
        take = rb[0] ? 3'd1 : all >= 6'(NO) ? 3'(NO) : 3'(all);
        go   = bv[0] && out_ready;
        d0   = go && 5'(take) >= rem;
        over = 5'(take) - rem;
        d1   = d0 && over == n1;             // (over is 0 unless cr, and a block has an instruction)
    end

    // the moves: from nxt to cur, and one block from outside
    logic ld0, ld0_n, ld1;                   // cur takes nxt, cur takes outside, nxt takes outside
    always @(*) begin
        ld0   = d0 && bv[1] && !d1;
        ld0_n = (!bv[0] || d1 || (d0 && !bv[1])) && e_v;
        ld1   = e_v && !ld0_n && (ld0 || !bv[1]);
    end

    // what cur has left next, and where its head is
    logic [4:0] rem_n;
    logic [3:0] h_n;                         // the head in the block that is cur next
    logic [3:0] h_q;
    always @(*) begin
        if (ld0) begin
            h_n   = 4'(over);
            rem_n = n1 - over;
        end else if (ld0_n) begin
            h_n   = 4'd0;
            rem_n = e_n[17*16 + 80 +: 5];
        end else if (go) begin
            h_n   = h_q + 4'(take);
            rem_n = rem - 5'(take);
        end else begin
            h_n   = h_q;
            rem_n = rem;
        end
    end

    for (genvar i = 0; i < 17; i++) begin : g_cw
        always_ff @(posedge clk) begin
            if (ld0)        w[0][i] <= w[1][i];
            else if (ld0_n) w[0][i] <= e_n[16*i +: 16];
            if (ld1)        w[1][i] <= e_n[16*i +: 16];
        end
    end
    always_ff @(posedge clk) begin
        if (ld0) begin
            for (int j = 0; j < 16; j++) p[0][j] <= p[1][j];
            rb[0] <= rb[1]; rp <= rp1; tk[0] <= tk[1]; ftq[0] <= ftq[1]; cftq[0] <= cftq[1];
        end else if (ld0_n) begin
            for (int j = 0; j < 16; j++) p[0][j] <= e_n[17*16 + 5*j +: 5];
            rb[0]   <= e_n[17*16 + 85];
            rp      <= e_n[17*16 + 86 +: 17];
            tk[0]   <= e_n[17*16 + 103];
            ftq[0]  <= e_n[17*16 + 104 +: FTQW];
            cftq[0] <= e_n[17*16 + 104 + FTQW +: FTQW];
        end
        if (ld1) begin
            for (int j = 0; j < 16; j++) p[1][j] <= e_n[17*16 + 5*j +: 5];
            n1      <= e_n[17*16 + 80 +: 5];
            rb[1]   <= e_n[17*16 + 85];
            rp1     <= e_n[17*16 + 86 +: 17];
            tk[1]   <= e_n[17*16 + 103];
            ftq[1]  <= e_n[17*16 + 104 +: FTQW];
            cftq[1] <= e_n[17*16 + 104 + FTQW +: FTQW];
        end
        rem <= rem_n;
        h_q <= h_n;
        for (int j = 0; j < 6; j++) begin
            sn[j] <= 5'(j) >= rem_n;
            hj[j] <= 5'(j) >= rem_n ? 4'(5'(j) - rem_n) : h_n + 4'(j);
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bv  <= '0;
            hb  <= '0;
            tb  <= '0;
            cnt <= '0;
        end else if (flush) begin
            bv  <= '0;
            hb  <= '0;
            tb  <= '0;
            cnt <= '0;
        end else begin
            if (ld0 || ld0_n)       bv[0] <= 1'b1;
            else if (d0 || !bv[0])  bv[0] <= 1'b0;
            if (ld1)                bv[1] <= 1'b1;
            else if (ld0 || d1)     bv[1] <= 1'b0;
            if ((ld0_n || ld1) && e_use) hb <= hb + 1'b1;
            if (keep_in && !(e_by && (ld0_n || ld1))) tb <= tb + 1'b1;
            cnt <= cnt + (BW + 1)'(keep_in && !(e_by && (ld0_n || ld1))) - (BW + 1)'((ld0_n || ld1) && e_use);
        end
    end
    always_ff @(posedge clk) begin
        if (keep_in && !(e_by && (ld0_n || ld1))) mem[tb] <= e_in;
    end

    // ---- the slots: where each one is, then its parcels
    logic [4:0]  pos [6];
    always @(*) begin
        for (int j = 0; j < 6; j++) begin
            automatic logic        s = sn[j];
            automatic logic [15:0] lo, hi;
            automatic logic [4:0]  q;
            pos[j]       = s ? p[1][hj[j]] : p[0][hj[j]];
            q            = pos[j];
            lo           = s ? w[1][q] : w[0][q];
            hi           = q == 5'd16 ? 16'd0 : s ? w[1][q + 5'd1] : w[0][q + 5'd1];
            out_valid[j] = bv[0] && 3'(j) < take;
            out_rvc[j]   = lo[1:0] != 2'b11;
            out_inst[j]  = {out_rvc[j] ? 16'd0 : hi, lo};
            out_off[j]   = q[3:0] - 4'd1;        // (place 0: parcel 15)
            out_ftq[j]   = q == 5'd0 ? cftq[s] : ftq[s];
            out_taken[j] = s ? tk[1] && 6'(rem) + 6'(n1) == 6'(j + 1) : tk[0] && rem == 5'(j + 1);
        end
        out_rare = rb[0] && rp[pos[0]];
    end

endmodule : OOO_FBUF3
