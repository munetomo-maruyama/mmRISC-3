//---------------------------------------------------------------------------
// OOO_RENAME2.sv
//
// Register renaming of the 4-issue core at 100 MHz (Doc/STRATEGY.md 4.3, 4.5 loop
// 4, Plan/OOC.md 28.16): 4 µops a cycle, 2 stages.
//
//   R1  the RAT read, the dependences among the 4, a new register for each that
//       writes: all of it into R2's registers, and the RAT written, at the end
//   R2  those registers are what OOO_SDISP's S1 compares (disp_src, disp_dst). What
//       S1 does not take this cycle (disp_go) stays, in its slot; R1 moves on when
//       none is left
//
// Nothing needs the free list's count in the path, and no busy bits: OOO_SDISP
// compares a source with what is pending.
//
//   RAT         32 x TAGW in flip-flops: 12 reads, 4 writes
//   free list   a ring of 64 places for NREG - 32 tags, 4 banks of distributed RAM,
//               place p in bank p % 4. So n places in a row touch n banks once, a
//               group's reads and a group's writes need one port a bank. A bank
//               is read from a register of its own row (rb), with no adder
//   commit      the old mappings back at the tail; the committed RAT (arat, in flip-
//               flops) and head (chead) for flush_all, which comes in a cycle
//               without a commit
//   checkpoints in distributed RAM, one write, one read: a RAT is 224 bits but one
//               address, against 12 copies in flip-flops with a mux of 12. 2 a
//               group: ids in a ring, so 2 in a row are one even, one odd, each with
//               its bank. A third, and what follows it, waits for the next cycle
//
// A checkpoint is written a cycle after its group left R1: the RAT as it is then,
// after the whole group, and what undoes the younger µops of the group: their
// architectural register and old mapping, up to 3, oldest last. A restore takes 2
// cycles, the front end is many behind it: the RAT from the checkpoint, then the
// undoes through the RAT's write ports, where the higher port wins. A checkpoint is
// not restored in the cycle right after its µop left R2, which the pipeline
// guarantees. Nothing is renamed in a restore's cycles. The block gives out ids and
// no more: OOO_CTRL keeps the unresolved ones to at most NCK. A restore gives its own
// id out next, its branch being resolved and all with its bit gone, so the open
// ones are always in a row of the ring.
//
// The registers are never short while the ROB holds all that write, as there are
// as many as ROB entries; but up to 8 are between R1 and the ROB, so a group waits
// if fewer than 8 were free in the last cycle (free_ok). A register too few for a
// cycle costs nothing else.
//
// The table is not valid after a reset until init has written it: 12 cycles.
// x0 maps to register 0 forever.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_RENAME2
    #(
        parameter int NREG = 80,
        parameter int TAGW = 7,
        parameter int NCK  = 12
    )
    (
        input  logic                      clk,
        input  logic                      rst_n,

        // ---- R1: from the decoded queue's registers, valid as a prefix
        input  logic [3:0]                in_valid,
        input  logic [3:0][1:0][4:0]      in_src,      // architectural
        input  logic [3:0]                in_wr,       // the destination is written (x0 too, then nothing happens)
        input  logic [3:0][4:0]           in_dst,
        input  logic [3:0]                in_ckpt,     // a checkpoint after this µop
        output logic [2:0]                in_take,     // how many it takes this cycle, 0 .. 4

        // ---- R1: what goes on at this edge (OOO_BUSY, and what travels with R2 outside)
        output logic                      r1_adv,
        output logic [3:0]                r1_wr,
        output logic [3:0][TAGW-1:0]      r1_tag,
        output logic                      r1_ready,    // registers are there, no restore is going on
        output logic [3:0][$clog2(NCK)-1:0] r1_ckid,   // the id a slot takes if it goes with those before

        // ---- R2
        output logic [3:0]                r2_valid,
        output logic [3:0][1:0][TAGW-1:0] r2_src,
        output logic [3:0]                r2_wr,       // a register is written: r2_dst
        output logic [3:0][TAGW-1:0]      r2_dst,
        output logic [3:0][TAGW-1:0]      r2_old,      // for the ROB: back to the free list at its commit
        output logic [3:0]                r2_ck,       // it took a checkpoint: r2_ckid
        output logic [3:0][$clog2(NCK)-1:0] r2_ckid,
        input  logic [3:0]                disp_go,     // S1: late in the cycle

        // ---- commit: any of the 4, in order
        input  logic [3:0]                cmt_wr,
        input  logic [3:0][4:0]           cmt_arch,
        input  logic [3:0][TAGW-1:0]      cmt_new,
        input  logic [3:0][TAGW-1:0]      cmt_old,

        // ---- recovery
        input  logic                      restore,
        input  logic [$clog2(NCK)-1:0]    restore_id,
        input  logic                      flush_all
    );

    localparam int NF = NREG - 32;
    localparam int CW = $clog2(NCK);
    localparam int CKW = 32 * TAGW + 6 + 3 * (1 + 5 + TAGW);
    localparam int NCKB = NCK / 2 + NCK % 2;      // places in a bank

    function automatic logic [CW-1:0] cinc(input logic [CW-1:0] a);
        return a == CW'(NCK - 1) ? '0 : a + 1'b1;
    endfunction

    // ---- init
    logic [3:0] init;
    logic       init_b;
    assign init_b = init != 4'd12;

    // ---- the state
    logic [TAGW-1:0] rat  [32];
    logic [TAGW-1:0] arat [32];
    logic [5:0]      head, tail, chead;
    logic [3:0]      rb [4];                  // the row of a bank's next place
    logic [CW-1:0]   ck_next;
    logic            free_ok;
    logic            u_v;                     // the undoes go now
    logic [2:0]      u_w;
    logic [4:0]      u_a [3];
    logic [TAGW-1:0] u_t [3];

    // ---- how far this group goes: to the second checkpoint at most
    logic [3:0] take, wr;
    logic [1:0] nck;                          // checkpoints before the slot
    always @(*) begin
        nck = 2'd0;
        for (int k = 0; k < 4; k++) begin
            take[k] = in_valid[k] && nck != 2'd2;
            if (in_valid[k] && in_ckpt[k] && nck != 2'd2) nck = nck + 2'd1;
            wr[k]   = take[k] && in_wr[k] && in_dst[k] != 5'd0;
        end
        in_take = 3'(take[0]) + 3'(take[1]) + 3'(take[2]) + 3'(take[3]);
    end

    // ---- the free list: slot k takes place head + (writers before it)
    (* ram_style = "distributed" *) logic [TAGW-1:0] fl0 [16];
    (* ram_style = "distributed" *) logic [TAGW-1:0] fl1 [16];
    (* ram_style = "distributed" *) logic [TAGW-1:0] fl2 [16];
    (* ram_style = "distributed" *) logic [TAGW-1:0] fl3 [16];
    logic [TAGW-1:0] top [4];
    assign top[0] = fl0[rb[0]];
    assign top[1] = fl1[rb[1]];
    assign top[2] = fl2[rb[2]];
    assign top[3] = fl3[rb[3]];

    logic [1:0]      pos [4];                 // the bank of a slot's place
    logic [TAGW-1:0] tag [4];
    logic [2:0]      n;                       // places taken
    logic [3:0]      pre;                     // a bank gives its place, if the group goes
    always @(*) begin
        pos[0] = head[1:0];
        pos[1] = head[1:0] + 2'(wr[0]);
        pos[2] = head[1:0] + 2'(wr[0]) + 2'(wr[1]);
        pos[3] = head[1:0] + 2'(wr[0]) + 2'(wr[1]) + 2'(wr[2]);
        n      = 3'(wr[0]) + 3'(wr[1]) + 3'(wr[2]) + 3'(wr[3]);
        pre    = 4'd0;
        for (int k = 0; k < 4; k++) begin
            tag[k] = top[pos[k]];
            if (wr[k]) pre[pos[k]] = 1'b1;
        end
    end

    // ---- R1's reads, with the dependences among the 4
    logic [TAGW-1:0] src_n [4][2];
    logic [TAGW-1:0] old_n [4];
    always @(*) begin
        for (int k = 0; k < 4; k++) begin
            for (int s = 0; s < 2; s++) begin
                src_n[k][s] = rat[in_src[k][s]];
                for (int m = 0; m < k; m++)
                    if (wr[m] && in_dst[m] == in_src[k][s]) src_n[k][s] = tag[m];
            end
            old_n[k] = rat[in_dst[k]];
            for (int m = 0; m < k; m++)
                if (wr[m] && in_dst[m] == in_dst[k]) old_n[k] = tag[m];
        end
    end

    logic [CW-1:0] id_n [4];
    // ---- R1 moves on when R2 has nothing left
    logic adv;
    assign adv = (r2_valid & ~disp_go) == 4'd0 && free_ok && !init_b && !u_v && !restore && !flush_all;
    assign r1_adv = adv;
    assign r1_ready = free_ok && !init_b && !u_v;
    always @(*) begin
        for (int k = 0; k < 4; k++) begin
            r1_wr[k]  = adv && wr[k];
            r1_tag[k] = tag[k];
            r1_ckid[k] = id_n[k];
        end
    end

    // ---- R2
    (* max_fanout = 32 *) logic adv_d;
    assign adv_d = adv;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                       r2_valid <= 4'd0;
        else if (restore || flush_all)    r2_valid <= 4'd0;
        else if (adv)                     r2_valid <= take;
        else                              r2_valid <= r2_valid & ~disp_go;
    end
    always @(*) begin
        automatic logic [CW-1:0] c = ck_next;
        for (int k = 0; k < 4; k++) begin
            id_n[k] = c;
            if (in_ckpt[k]) c = cinc(c);        // (not by take: what asks for an id cannot wait for what goes)
        end
    end
    always_ff @(posedge clk) begin
        if (adv_d) begin
            for (int k = 0; k < 4; k++) begin
                r2_src[k][0] <= src_n[k][0];
                r2_src[k][1] <= src_n[k][1];
                r2_wr[k]     <= wr[k];
                r2_dst[k]    <= tag[k];
                r2_old[k]    <= old_n[k];
                r2_ck[k]     <= take[k] && in_ckpt[k];
                r2_ckid[k]   <= id_n[k];
            end
        end
    end

    // ---- the RAT's write ports: the higher port wins
    logic [3:0]      pv;
    logic [4:0]      pa [4];
    logic [TAGW-1:0] pt [4];
    always @(*) begin
        for (int j = 0; j < 4; j++) begin
            pv[j] = wr[j] && adv;
            pa[j] = in_dst[j];
            pt[j] = tag[j];
        end
        if (u_v) begin
            pv[3] = 1'b0;
            for (int j = 0; j < 3; j++) begin
                pv[j] = u_w[j];
                pa[j] = u_a[j];
                pt[j] = u_t[j];
            end
        end
    end

    // ---- the checkpoints: a write a cycle after the group, in the bank of its id
    logic          pk_any;
    logic [5:0]    pk_head;                  // the head before the group
    logic [4:0]    pk_ad [4];                // the group's destinations
    (* ram_style = "distributed" *) logic [CKW-1:0] ck0 [NCKB];
    (* ram_style = "distributed" *) logic [CKW-1:0] ck1 [NCKB];
    logic [31*TAGW-1:0] rat_v;                // (register 0 is not kept: always 0)
    always @(*) for (int a = 1; a < 32; a++) rat_v[(a - 1) * TAGW +: TAGW] = rat[a];

    // what a checkpoint at slot k writes
    logic [CKW-1:0] ckw [4];
    always @(*) begin
        for (int k = 0; k < 4; k++) begin
            automatic logic [5:0] h = pk_head;
            for (int m = 0; m <= k; m++) if (r2_wr[m]) h = h + 6'd1;
            ckw[k] = '0;
            ckw[k][32*TAGW-1:0] = {{TAGW{1'b0}}, rat_v};
            ckw[k][32*TAGW +: 6] = h;
            // the undoes, the oldest at the highest port
            for (int j = 0; j < 3; j++) begin
                automatic int y = k + 3 - j;
                if (y < 4) ckw[k][32*TAGW + 6 + j * (6 + TAGW) +: 6 + TAGW] = {r2_wr[y], pk_ad[y], r2_old[y]};
            end
        end
    end
    logic [1:0] sel0, sel1;                   // which slot writes each bank
    logic       we0, we1;
    logic [CKW-1:0] wd0, wd1;
    logic [$clog2(NCKB)-1:0] wa0, wa1;
    always @(*) begin
        we0 = 1'b0; we1 = 1'b0; sel0 = 2'd0; sel1 = 2'd0; wa0 = '0; wa1 = '0;
        for (int k = 3; k >= 0; k--)
            if (pk_any && r2_ck[k]) begin
                if (r2_ckid[k][0]) begin we1 = 1'b1; sel1 = 2'(k); wa1 = r2_ckid[k][CW-1:1]; end
                else               begin we0 = 1'b1; sel0 = 2'(k); wa0 = r2_ckid[k][CW-1:1]; end
            end
        wd0 = ckw[sel0];
        wd1 = ckw[sel1];
    end
    always_ff @(posedge clk) begin
        if (we0) ck0[wa0] <= wd0;
        if (we1) ck1[wa1] <= wd1;
    end
    logic [CKW-1:0] rd;
    assign rd = restore_id[0] ? ck1[restore_id[CW-1:1]] : ck0[restore_id[CW-1:1]];

    // ---- the free list: the commits' old mappings, at the tail
    logic [3:0]      f_w;                     // a bank is written
    logic [3:0]      f_r [4];
    logic [TAGW-1:0] f_d [4];
    logic [2:0]      f_n;
    always @(*) begin
        automatic logic [5:0] t = tail;
        f_w = 4'd0;
        for (int b = 0; b < 4; b++) begin f_r[b] = '0; f_d[b] = '0; end
        for (int k = 0; k < 4; k++) begin
            if (cmt_wr[k]) begin
                f_w[t[1:0]] = 1'b1;
                f_r[t[1:0]] = t[5:2];
                f_d[t[1:0]] = cmt_old[k];
                t = t + 6'd1;
            end
        end
        f_n = 3'(cmt_wr[0]) + 3'(cmt_wr[1]) + 3'(cmt_wr[2]) + 3'(cmt_wr[3]);
        if (init_b) begin
            for (int b = 0; b < 4; b++) begin
                f_w[b] = 1'b1;
                f_r[b] = init;
                f_d[b] = TAGW'(32) + TAGW'(int'(init) * 4 + b);
            end
        end
    end
    always_ff @(posedge clk) begin
        if (f_w[0]) fl0[f_r[0]] <= f_d[0];
        if (f_w[1]) fl1[f_r[1]] <= f_d[1];
        if (f_w[2]) fl2[f_r[2]] <= f_d[2];
        if (f_w[3]) fl3[f_r[3]] <= f_d[3];
    end

    // the rows of a head
    function automatic logic [3:0] row_of(input logic [5:0] h, input int b);
        return h[5:2] + 4'(b < int'(h[1:0]));
    endfunction

    // ---- the clocked state
    logic [5:0] h_new;
    assign h_new = flush_all ? chead : rd[32*TAGW +: 6];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            init    <= 4'd0;
            head    <= 6'd0;
            tail    <= 6'(NF);
            chead   <= 6'd0;
            ck_next <= '0;
            free_ok <= 1'b0;
            u_v     <= 1'b0;
            pk_any  <= 1'b0;
            for (int b = 0; b < 4; b++) rb[b] <= 4'd0;
            for (int a = 0; a < 32; a++) begin
                rat[a]  <= TAGW'(a);
                arat[a] <= TAGW'(a);
            end
        end else begin
            if (init_b) init <= init + 4'd1;
            free_ok <= !init_b && 6'(tail - head) >= 6'd8;
            u_v     <= restore && !flush_all;
            pk_any  <= adv;
            tail    <= init_b ? tail : tail + 6'(f_n);
            // the committed state
            for (int k = 0; k < 4; k++) if (cmt_wr[k]) arat[cmt_arch[k]] <= cmt_new[k];
            chead   <= chead + 6'(f_n);
            // the head
            if (flush_all || restore) begin
                head <= h_new;
                for (int b = 0; b < 4; b++) rb[b] <= row_of(h_new, b);
            end else if (adv) begin
                head <= head + 6'(n);
                for (int b = 0; b < 4; b++) if (pre[b]) rb[b] <= rb[b] + 4'd1;
            end
            // the ids
            if (restore && !flush_all) ck_next <= restore_id;
            else if (adv) begin
                for (int k = 0; k < 4; k++) if (take[k] && in_ckpt[k]) ck_next <= cinc(id_n[k]);
            end
            // the RAT
            if (flush_all) begin
                for (int a = 1; a < 32; a++) rat[a] <= arat[a];
            end else if (restore) begin
                for (int a = 1; a < 32; a++) rat[a] <= rd[(a - 1) * TAGW +: TAGW];
            end else begin
                for (int j = 0; j < 4; j++) if (pv[j] && pa[j] != 5'd0) rat[pa[j]] <= pt[j];
            end
        end
    end
    always_ff @(posedge clk) begin
        pk_head <= head;
        for (int k = 0; k < 4; k++) pk_ad[k] <= in_dst[k];
        for (int j = 0; j < 3; j++)
            {u_w[j], u_a[j], u_t[j]} <= rd[32*TAGW + 6 + j * (6 + TAGW) +: 6 + TAGW];
    end

endmodule : OOO_RENAME2
