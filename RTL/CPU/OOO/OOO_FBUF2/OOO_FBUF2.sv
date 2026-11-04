//---------------------------------------------------------------------------
// OOO_FBUF2.sv
//
// The fetch buffer of the 4-issue core at 100 MHz (Doc/STRATEGY.md 4.3 F4, D1, 4.5
// loop 5, Plan/OOC.md 28.19): blocks of 32 bytes in, 6 instructions a cycle out.
//
// What made today's OOO_FBUF slow is one loop: the head parcel, a window, the
// lengths one after another, the count taken, the head parcel. So the boundaries are
// not found here at all, and the head is an instruction, not a parcel:
//
//   F4  in_st, from the predecode of F3, says where instructions start. From it a
//       table of the block's instructions: where each one is (p), how many (n)
//   D1  the block being read (cur, flip-flops) gives its next instructions, by
//       the table; a count down of what is left, and 6 counters, are all the loop
//
// One block a cycle: what is left of a block goes alone. It costs 0.03 % in the model,
// as a block seldom has more than 6, and there is no second block in any path.
//
// A 32-bit instruction that starts at the last parcel is the next block's first: that
// block keeps the parcel (in its place 0), and the entry the first half came in
// (cftq). A block with nothing else, only such a first half, is not kept. The
// predecode knows that the next block's parcel 0 is no start.
//
// A rare class (OOO_RARE: decoded in slot 0 alone) has no part in the count: a block
// with one anywhere gives one instruction a cycle. FP code pays for that; its unit is
// half-rate in any case (Doc/STRATEGY.md 4.4).
//
// The blocks wait in distributed RAM, a wide word with one read and one write; a block
// goes straight to cur when nothing waits. Decode takes all it is given or nothing:
// out_ready comes from the decoded queue's room, in a register. flush empties it all.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_FBUF2
    #(
        parameter int NB   = 8,         // blocks waiting (a power of two)
        parameter int FTQW = 5
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
        input  logic [15:0]              in_st,      // an instruction starts at this parcel
        input  logic                     in_taken,   // its last instruction is a predicted-taken transfer
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
    logic        rb_in;
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
        end
        n_in  = c;
        rb_in = (c_v && rp_in[0]) || ({su} & rp_in[16:1]) != 16'd0;
    end

    logic take_in;                           // a block comes in now
    logic keep_in;                           // ... and it has instructions
    assign take_in = in_valid && in_ready && !flush;
    assign keep_in = take_in && n_in != 5'd0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)        c_v <= 1'b0;
        else if (flush)    c_v <= 1'b0;
        else if (take_in)  c_v <= strad;
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

    // ---- D1: the block being read
    logic            cv;
    logic [15:0]     w  [17];
    logic [15:0]     w1 [17];                // the place after
    logic [4:0]      p  [16];
    logic [4:0]      rem;
    logic            rb, tk;
    logic [16:0]     rp;
    logic [FTQW-1:0] ftq, cftq;
    (* max_fanout = 16 *) logic [3:0] hj [6];  // the instruction in slot j
    logic [2:0]      take;
    logic            go, done, load;
    assign go   = cv && out_ready;
    always @(*) begin
        take = rb ? 3'd1 : rem >= 5'd6 ? 3'd6 : 3'(rem);
        done = rem <= 5'(take);
    end
    assign load = !cv || (out_ready && done);

    logic e_use, e_by;                       // cur takes from the RAM, or straight in
    assign e_use = cnt != '0;
    assign e_by  = !e_use && keep_in;

    logic [EW-1:0] e_n;
    assign e_n = e_use ? e_q : e_in;
    (* max_fanout = 32 *) logic load_d;
    assign load_d = load;

    for (genvar i = 0; i < 17; i++) begin : g_cw
        always_ff @(posedge clk) if (load_d) w[i] <= e_n[16*i +: 16];
        if (i < 16) begin : g_n
            assign w1[i] = w[i+1];
        end else begin : g_l
            assign w1[i] = '0;
        end
    end
    always_ff @(posedge clk) begin
        if (load_d) begin
            for (int j = 0; j < 16; j++) p[j] <= e_n[17*16 + 5*j +: 5];
            rb   <= e_n[17*16 + 85];
            rp   <= e_n[17*16 + 86 +: 17];
            tk   <= e_n[17*16 + 103];
            ftq  <= e_n[17*16 + 104 +: FTQW];
            cftq <= e_n[17*16 + 104 + FTQW +: FTQW];
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cv  <= 1'b0;
            hb  <= '0;
            tb  <= '0;
            cnt <= '0;
        end else if (flush) begin
            cv  <= 1'b0;
            hb  <= '0;
            tb  <= '0;
            cnt <= '0;
        end else begin
            if (load) cv <= e_use || e_by;
            if (load && e_use) hb <= hb + 1'b1;
            if (keep_in && !(load && !e_use)) tb <= tb + 1'b1;
            cnt <= cnt + (BW + 1)'(keep_in && !(load && !e_use)) - (BW + 1)'(load && e_use);
        end
    end
    always_ff @(posedge clk) begin
        if (keep_in && !(load && !e_use)) mem[tb] <= e_in;
        if (load) begin
            rem <= e_n[17*16 + 80 +: 5];
            for (int j = 0; j < 6; j++) hj[j] <= 4'(j);
        end else if (go) begin
            rem <= rem - 5'(take);
            for (int j = 0; j < 6; j++) hj[j] <= hj[j] + 4'(take);
        end
    end

    // ---- the slots: where each one is, then its parcels
    logic [4:0] pos [6];
    always @(*) begin
        for (int j = 0; j < 6; j++) begin
            automatic logic [15:0] lo, hi;
            pos[j]       = p[hj[j]];
            lo           = w[pos[j]];
            hi           = w1[pos[j]];
            out_valid[j] = cv && 3'(j) < take;
            out_rvc[j]   = lo[1:0] != 2'b11;
            out_inst[j]  = {out_rvc[j] ? 16'd0 : hi, lo};
            out_off[j]   = pos[j][3:0] - 4'd1;   // (place 0: parcel 15)
            out_ftq[j]   = ftq;
            out_taken[j] = tk && rem == 5'(j + 1);
        end
        if (pos[0] == 5'd0) out_ftq[0] = cftq;
        out_rare = rb && rp[pos[0]];
    end

endmodule : OOO_FBUF2
