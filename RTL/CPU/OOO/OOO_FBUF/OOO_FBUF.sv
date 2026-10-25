//---------------------------------------------------------------------------
// OOO_FBUF.sv
//
// The fetch buffer of mmRISC-3 (Doc/UARCH.md 3.2): between fetch (F2) and
// decode (D1). It takes one 16-byte fetch block a cycle and gives up to 4
// instructions a cycle, RVC (one 16-bit parcel) or 32-bit (two parcels,
// possibly across two blocks).
//
// A queue of NB whole blocks, not of parcels: a block goes into a slot as
// it is (no select in front of every parcel of the buffer), with
//   start   the first parcel to use (fetch may start in the middle of a
//           block, after a taken transfer)
//   end     the last parcel to use (a block ends at the last half of a
//           predicted-taken transfer, else at parcel 7)
//   taken   the block ends with a predicted-taken transfer
//   ftq     its entry in the fetch target queue (where its pc and its
//           predictions are)
// Decode sees a window of 8 parcels: the rest of the head block from the
// current parcel, followed by the used part of the next block (so the
// parcels after a taken transfer and before its target are skipped). Up to
// 4 instructions come out of the window, as far as they are complete in
// it; a 32-bit instruction whose second half is not there yet waits.
//
// For each instruction: its bits (an RVC one in the low 16), whether it is
// RVC, the block (ftq) and parcel (off) of its first half, whether it is a
// predicted-taken transfer (its last half is the end of a taken block), and
// whether it follows the one before it directly (seq, for fusion). Decode
// takes the first `consume` of them; flush (a redirect) empties the buffer.
//
// Only two blocks feed the window, so a window that would need a third (the
// head block and the next one both nearly empty) gives fewer instructions
// that cycle; the cycle model counts the buffer in instructions, and its
// size hardly matters (Plan/MODEL.md 6: 16 → 8 is −0.3 %).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_FBUF
    #(
        parameter int NB   = 4,         // blocks (a power of two)
        parameter int FTQW = 3
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,
        input  logic                        flush,

        // from fetch: one block a cycle
        output logic                        in_ready,
        input  logic                        in_valid,
        input  logic [127:0]                in_data,    // parcel k in bits 16k+15 .. 16k
        input  logic [2:0]                  in_start,
        input  logic [2:0]                  in_end,
        input  logic                        in_taken,
        input  logic [FTQW-1:0]             in_ftq,

        // to decode: up to 4 instructions
        output logic [3:0]                  out_valid,
        output logic [3:0][31:0]            out_inst,
        output logic [3:0]                  out_rvc,
        output logic [3:0][2:0]             out_off,
        output logic [3:0][FTQW-1:0]        out_ftq,
        output logic [3:0]                  out_taken,
        output logic [3:0]                  out_seq,
        input  logic [2:0]                  consume     // instructions taken, at most the valid ones
    );

    localparam int BW = $clog2(NB);

    // ---- the blocks
    logic [127:0]    bdata [NB];
    logic [2:0]      bs    [NB];
    logic [2:0]      be    [NB];
    logic [NB-1:0]   btk;
    logic [FTQW-1:0] bftq  [NB];
    logic [BW-1:0]   hb, tb;                   // head block, next free slot
    logic [BW:0]     nblk;                     // blocks in the queue
    logic [2:0]      hoff;                     // the head block's next parcel

    assign in_ready = nblk != (BW + 1)'(NB);

    // ---- the window: the head block A from hoff, then the next block B
    logic [BW-1:0] ib;
    logic          av, bv;
    logic [3:0]    na;                         // parcels left in A (1 .. 8)
    logic [15:0]   w    [8];
    logic [7:0]    wv, wb, wend;               // valid, from B, a taken block's last parcel
    logic [2:0]    woff [8];
    always @(*) begin
        ib = hb + BW'(1);
        av = nblk != '0;
        bv = nblk >= (BW + 1)'(2);
        na = 4'(be[hb]) - 4'(hoff) + 4'd1;
        for (int k = 0; k < 8; k++) begin
            logic [2:0] ja;                    // parcel index in A (k < na keeps it below 8)
            logic [3:0] jb;                    // parcel index in B
            ja = hoff + 3'(k);
            jb = 4'(bs[ib]) + 4'(k) - na;
            if (av && 4'(k) < na) begin
                w[k]    = bdata[hb][16*ja +: 16];
                wv[k]   = 1'b1;
                wb[k]   = 1'b0;
                woff[k] = ja;
                wend[k] = btk[hb] && ja == be[hb];
            end else begin
                w[k]    = bdata[ib][16*jb[2:0] +: 16];
                wv[k]   = av && bv && jb <= 4'(be[ib]) && !jb[3];
                wb[k]   = 1'b1;
                woff[k] = jb[2:0];
                wend[k] = btk[ib] && jb[2:0] == be[ib];
            end
        end
    end

    // ---- up to 4 instructions out of the window
    logic [3:0] st [5];                        // where instruction i starts (st[4]: past the last)
    always @(*) begin
        logic run;
        run = 1'b1;
        st[0] = 4'd0;
        for (int i = 0; i < 4; i++) begin
            logic [3:0] s;
            logic       len2, ok;
            s    = st[i];
            len2 = s < 4'd8 && w[s[2:0]][1:0] == 2'b11;
            ok   = run && s < 4'd8 && wv[s[2:0]] && (!len2 || (s < 4'd7 && wv[s[2:0] + 3'd1]));
            out_valid[i] = ok;
            out_rvc[i]   = !len2;
            out_inst[i]  = {len2 ? w[s[2:0] + 3'd1] : 16'd0, w[s[2:0]]};
            out_off[i]   = woff[s[2:0]];
            out_ftq[i]   = wb[s[2:0]] ? bftq[ib] : bftq[hb];
            out_taken[i] = len2 ? wend[s[2:0] + 3'd1] : wend[s[2:0]];
            st[i+1] = s + (len2 ? 4'd2 : 4'd1);
            run = ok;
        end
        out_seq[0] = 1'b1;
        for (int i = 1; i < 4; i++) out_seq[i] = !out_taken[i-1];
    end

    // ---- taking instructions out, and new blocks in
    logic [3:0]  used;                         // parcels consumed
    logic [1:0]  npop;                         // blocks emptied
    logic [2:0]  hoff_n;
    always @(*) begin
        used = st[consume];
        if (!av || used < na) begin            // (an empty queue: nothing to pop, whatever the stale block says)
            npop   = 2'd0;
            hoff_n = hoff + 3'(used);
        end else if (used - na < 4'(be[ib]) - 4'(bs[ib]) + 4'd1 || !bv) begin
            npop   = 2'd1;                     // A gone; B (if any) partly used
            hoff_n = bs[ib] + 3'(used - na);
        end else begin
            npop   = 2'd2;                     // A and B gone
            hoff_n = 3'd0;
        end
    end

    logic push;
    assign push = in_valid && in_ready;        // (during a flush into a slot left free: harmless)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hb   <= '0;
            tb   <= '0;
            nblk <= '0;
            hoff <= '0;
        end else if (flush) begin
            hb   <= '0;
            tb   <= '0;
            nblk <= '0;
        end else begin
            logic [BW:0] left;                 // blocks after the pops
            left = nblk - (BW + 1)'(npop);
            hb   <= hb + BW'(npop);
            tb   <= tb + BW'(push);
            nblk <= left + (BW + 1)'(push);
            // the head's parcel: into B, or the start of whatever is head next
            if (!av)                           hoff <= in_start;   // empty: the block coming in
            else if (npop == 2'd0)             hoff <= hoff_n;
            else if (npop == 2'd1 && bv && used - na < 4'(be[ib]) - 4'(bs[ib]) + 4'd1)
                                               hoff <= hoff_n;
            else if (left != '0)               hoff <= bs[hb + BW'(npop)];
            else                               hoff <= in_start;   // empty: the block coming in
        end
    end
    always_ff @(posedge clk) begin
        if (push) begin
            bdata[tb] <= in_data;
            bs[tb]    <= in_start;
            be[tb]    <= in_end;
            btk[tb]   <= in_taken;
            bftq[tb]  <= in_ftq;
        end
    end

endmodule : OOO_FBUF
