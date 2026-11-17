//---------------------------------------------------------------------------
// OOO_FREN.sv
//
// The FP registers' renaming of the renamed FPU (step 1.8 U1, Plan/OOC.md 29.80,
// 29.81): OOO_RENAME2's structure for the 32 FP registers, beside it and in step
// with it.
//
//   R1  the FP map read for up to 3 sources a µop (FMA's rs3), the dependences
//       among the 4, a new register for each that writes an FP register: into
//       R2's registers, and the map written, at the edge OOO_RENAME2's R1 moves on
//   R2  those registers, held until the next move, as OOO_RENAME2's R2 is
//
// What it shares with OOO_RENAME2 rather than repeats: when the group moves
// (adv: OOO_RENAME2's r1_adv, which in the core also waits for this block's
// ready), how far a group goes (the same rule: to the second checkpoint, from the
// same in_valid and in_ckpt), and the checkpoint ids (in_ckid: OOO_RENAME2's
// r1_ckid). The rest is OOO_RENAME2's, but that f0 is a register like any other
// (no fixed zero: the map's 32 entries are all renamed and all kept):
//
//   map         32 x TAGW in flip-flops: 12 reads, 4 writes
//   free list   a ring of 64 places for NREG - 32 tags, 4 banks of distributed RAM
//   commit      the old mappings back at the tail; the committed map (amap) and head
//               (chead) for flush_all
//   checkpoints in distributed RAM, 2 banks by the id's parity; each the map after the
//               whole group and up to 3 undoes for the younger µops of the group,
//               written a cycle after the group; a restore takes 2 cycles (the map
//               from the checkpoint, then the undoes), and adv must be low in the
//               second (OOO_RENAME2's u_v does the same there)
//
// ready: the registers are there (at least 8 were free in the last cycle: up to 8
// are between R1 and the ROB) and the init is over (NREG - 32 places: (NREG - 32) / 4
// cycles). The integrator keeps adv low while ready is not.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_FREN
    #(
        parameter int NREG = 64,
        parameter int TAGW = 6,
        parameter int NCK  = 12
    )
    (
        input  logic                      clk,
        input  logic                      rst_n,

        // ---- R1: OOO_RENAME2's inputs, with the FP fields
        input  logic [3:0]                in_valid,
        input  logic [3:0][2:0][4:0]      in_src,      // f registers: fs1, fs2, fs3
        input  logic [3:0]                in_wr,       // an FP register is written
        input  logic [3:0][4:0]           in_dst,
        input  logic [3:0]                in_ckpt,
        input  logic [3:0][$clog2(NCK)-1:0] in_ckid,   // OOO_RENAME2's r1_ckid
        input  logic                      adv,         // OOO_RENAME2's r1_adv
        output logic                      ready,

        // ---- R1: what is set at the edge (the FP busy bits)
        output logic [3:0]                r1_wr,
        output logic [3:0][TAGW-1:0]      r1_tag,

        // ---- R2
        output logic [3:0][2:0][TAGW-1:0] r2_src,
        output logic [3:0]                r2_wr,
        output logic [3:0][TAGW-1:0]      r2_dst,
        output logic [3:0][TAGW-1:0]      r2_old,      // for the ROB: back to the free list at its commit

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

    localparam int NF  = NREG - 32;
    localparam int NI  = NF / 4;                   // init cycles
    localparam int CW  = $clog2(NCK);
    localparam int CKW = 32 * TAGW + 6 + 3 * (1 + 5 + TAGW);
    localparam int NCKB = NCK / 2 + NCK % 2;

    // ---- init
    logic [3:0] init;
    logic       init_b;
    assign init_b = init != 4'(NI);

    // ---- the state
    logic [TAGW-1:0] rat  [32];
    logic [TAGW-1:0] arat [32];
    logic [5:0]      head, tail, chead;
    logic [3:0]      rb [4];
    logic            free_ok;
    logic            u_v;
    logic [2:0]      u_w;
    logic [4:0]      u_a [3];
    logic [TAGW-1:0] u_t [3];
    assign ready = free_ok && !init_b;

    // ---- how far this group goes (OOO_RENAME2's rule)
    logic [3:0] take, wr;
    logic [1:0] nck;
    always @(*) begin
        nck = 2'd0;
        for (int k = 0; k < 4; k++) begin
            take[k] = in_valid[k] && nck != 2'd2;
            if (in_valid[k] && in_ckpt[k] && nck != 2'd2) nck = nck + 2'd1;
            wr[k]   = take[k] && in_wr[k];
        end
    end

    // ---- the free list
    (* ram_style = "distributed" *) logic [TAGW-1:0] fl0 [16];
    (* ram_style = "distributed" *) logic [TAGW-1:0] fl1 [16];
    (* ram_style = "distributed" *) logic [TAGW-1:0] fl2 [16];
    (* ram_style = "distributed" *) logic [TAGW-1:0] fl3 [16];
    logic [TAGW-1:0] top [4];
    assign top[0] = fl0[rb[0]];
    assign top[1] = fl1[rb[1]];
    assign top[2] = fl2[rb[2]];
    assign top[3] = fl3[rb[3]];

    logic [1:0]      pos [4];
    logic [TAGW-1:0] tag [4];
    logic [2:0]      n;
    logic [3:0]      pre;
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
    logic [TAGW-1:0] src_n [4][3];
    logic [TAGW-1:0] old_n [4];
    always @(*) begin
        for (int k = 0; k < 4; k++) begin
            for (int s = 0; s < 3; s++) begin
                src_n[k][s] = rat[in_src[k][s]];
                for (int m = 0; m < k; m++)
                    if (wr[m] && in_dst[m] == in_src[k][s]) src_n[k][s] = tag[m];
            end
            old_n[k] = rat[in_dst[k]];
            for (int m = 0; m < k; m++)
                if (wr[m] && in_dst[m] == in_dst[k]) old_n[k] = tag[m];
        end
    end

    always @(*) begin
        for (int k = 0; k < 4; k++) begin
            r1_wr[k]  = adv && wr[k];
            r1_tag[k] = tag[k];
        end
    end

    // ---- R2
    logic [3:0]    r2_ck;
    logic [CW-1:0] r2_ckid [4];
    always_ff @(posedge clk) begin
        if (adv) begin
            for (int k = 0; k < 4; k++) begin
                for (int s = 0; s < 3; s++) r2_src[k][s] <= src_n[k][s];
                r2_wr[k]   <= wr[k];
                r2_dst[k]  <= tag[k];
                r2_old[k]  <= old_n[k];
                r2_ck[k]   <= take[k] && in_ckpt[k];
                r2_ckid[k] <= in_ckid[k];
            end
        end
    end

    // ---- the map's write ports: the higher port wins
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
    logic [5:0]    pk_head;
    logic [4:0]    pk_ad [4];
    (* ram_style = "distributed" *) logic [CKW-1:0] ck0 [NCKB];
    (* ram_style = "distributed" *) logic [CKW-1:0] ck1 [NCKB];
    logic [32*TAGW-1:0] rat_v;
    always @(*) for (int a = 0; a < 32; a++) rat_v[a * TAGW +: TAGW] = rat[a];

    logic [CKW-1:0] ckw [4];
    always @(*) begin
        for (int k = 0; k < 4; k++) begin
            automatic logic [5:0] h = pk_head;
            for (int m = 0; m <= k; m++) if (r2_wr[m]) h = h + 6'd1;
            ckw[k] = '0;
            ckw[k][32*TAGW-1:0] = rat_v;
            ckw[k][32*TAGW +: 6] = h;
            for (int j = 0; j < 3; j++) begin
                automatic int y = k + 3 - j;
                if (y < 4) ckw[k][32*TAGW + 6 + j * (6 + TAGW) +: 6 + TAGW] = {r2_wr[y], pk_ad[y], r2_old[y]};
            end
        end
    end
    logic [1:0] sel0, sel1;
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
    logic [3:0]      f_w;
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
            for (int k = 0; k < 4; k++) if (cmt_wr[k]) arat[cmt_arch[k]] <= cmt_new[k];
            chead   <= chead + 6'(f_n);
            if (flush_all || restore) begin
                head <= h_new;
                for (int b = 0; b < 4; b++) rb[b] <= row_of(h_new, b);
            end else if (adv) begin
                head <= head + 6'(n);
                for (int b = 0; b < 4; b++) if (pre[b]) rb[b] <= rb[b] + 4'd1;
            end
            if (flush_all) begin
                for (int a = 0; a < 32; a++) rat[a] <= arat[a];
            end else if (restore) begin
                for (int a = 0; a < 32; a++) rat[a] <= rd[a * TAGW +: TAGW];
            end else begin
                for (int j = 0; j < 4; j++) if (pv[j]) rat[pa[j]] <= pt[j];
            end
        end
    end
    always_ff @(posedge clk) begin
        pk_head <= head;
        for (int k = 0; k < 4; k++) pk_ad[k] <= in_dst[k];
        for (int j = 0; j < 3; j++)
            {u_w[j], u_a[j], u_t[j]} <= rd[32*TAGW + 6 + j * (6 + TAGW) +: 6 + TAGW];
    end

endmodule : OOO_FREN
