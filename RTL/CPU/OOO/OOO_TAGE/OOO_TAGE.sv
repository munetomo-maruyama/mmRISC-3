//---------------------------------------------------------------------------
// OOO_TAGE.sv
//
// TAGE-S of mmRISC-3 (Doc/UARCH.md 3.2), per fetch block, in block RAM.
// The tables are read in F1 with the fetch address only, before the
// instructions of the block are known, so the predictor works per block
// (Plan/model/tageblk.h; Plan/OOC.md 14.1 measured the choices on CoreMark):
//
//   tagged tables  4 x 1024 rows, histories 5 / 12 / 30 / 70, tags 8 / 8 /
//                  9 / 9 bits; a row is indexed and tagged by the block's
//                  fetch address and the global history, and holds one
//                  tag, a valid bit, one 2-bit useful counter and 3-bit
//                  direction counters for 3 slots: the first, second and
//                  third conditional branch of the block in program order
//   base table     512 rows x 8 parcels of 2-bit counters, indexed by the
//                  line; a branch uses the counter of its last parcel
//   history        one bit per slot branch (taken / not taken), at most 3
//                  a block; the folded histories are XORs of the last L
//                  bits, computed directly from a shift register (no
//                  folded registers to save and restore)
//
// The history a block is read with lacks the 2 blocks before it, always
// (D-17, Plan/CORE.md 5.3, 5.11): F0 reads with the history shifted past
// those of the 2 blocks before that are already in it, by the bit counts
// of the last 2 blocks pushed (c1, c2): none when both are still in flight
// (f0_live, from fetch), c1 when one is, c1 + c2 when neither. The lag no
// longer changes with fetch's stalls (a full FTQ or fetch buffer, an I$
// miss, an override, a restore), so a branch reads one row. The register
// keeps 76 bits (70 and the 6 a shift can take); a restore puts back 70
// from the metadata (the 6 above as 0) and c2 from the block's cprev (the
// bit count of the block pushed before it).
//
// The pipeline follows the I$ (OOO_FETCH): F0 f0_valid (the fetch
// accepted) reads the rows; F1 compares the tags and keeps the results for
// F2, where predecode gives the parcels of the slot branches (f2_sv,
// f2_par) and the predictions come out (f2_pred). The F1 results are held
// until the next f0_valid's F1, so F2 of a block may come late (an I$
// miss) as long as the next fetch is not accepted before it, as the I$
// does. F2 pushes the first f2_n slot predictions into the history; a
// misprediction restores it (rs_*: the history before the block, from
// f2_meta in the FTQ, and the right outcomes of its slots).
//
// The update comes at commit, one block at a time (up_*: its f2_meta from
// the FTQ, the slots that ran and their outcomes). It recomputes provider
// and alternate from the rows as read at prediction (f2_meta carries them),
// and follows Seznec's TAGE (Plan/model/tage.h) slot by slot: the
// use-alt-on-new-allocation counter, one allocation on a misprediction
// (a row with useful 0 in a longer table, else the useful counters of
// those rows go down), the provider's counter and useful counter, the base
// counter. Each table is written at most once (provider, allocation and
// decrement are in different tables). Fields that were not updated are
// written back as read, so an update can undo one made between this
// block's prediction and its commit; that only costs accuracy. The
// periodic halving of the useful counters is left out (no effect on
// CoreMark, 14.1).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_TAGE
    #(
        parameter int VA = 39,
        parameter int MW = 272          // f2_meta / up_meta (see the packing below)
    )
    (
        input  logic                clk,
        input  logic                rst_n,

        // F0: read
        input  logic                f0_valid,
        input  logic [VA-1:1]       f0_pc,
        input  logic [1:0]          f0_live,    // blocks read before this one not pushed yet (2: 2 or more)

        // F2: the block read last
        input  logic [2:0]          f2_sv,      // slots that hold a branch (a prefix)
        input  logic [2:0][2:0]     f2_par,     // the parcel of each (its last half)
        output logic [2:0]          f2_pred,
        input  logic                f2_push,    // push the first f2_n slot predictions
        input  logic [1:0]          f2_n,
        output logic [MW-1:0]       f2_meta,

        // recovery
        input  logic                rs_valid,
        input  logic [71:0]         rs_hist,    // the block's metadata: {cprev, hist}
        input  logic [1:0]          rs_n,
        input  logic [2:0]          rs_bits,    // slot 0 first

        // update (commit)
        input  logic                up_valid,
        input  logic [MW-1:0]       up_meta,
        input  logic [2:0]          up_ex,      // slots that ran (a prefix)
        input  logic [2:0]          up_tk
    );

    localparam int NT = 4, NLOG = 10, NROW = 1 << NLOG, HMAX = 70, HREG = 76;
    localparam int RW = 21;             // row: v, tag[8:0], u[1:0], ctr[2:0] x 3
    localparam int BLOG = 9;

    function automatic int tw(input int j);     // tag bits
        return (j < 2) ? 8 : 9;
    endfunction
    function automatic int hl(input int j);     // history length
        case (j)
            0: return 5;
            1: return 12;
            2: return 30;
            default: return 70;
        endcase
    endfunction

    // the last L history bits folded to c bits (bit k ago goes to k mod c)
    function automatic logic [NLOG-1:0] fold(input logic [HMAX-1:0] h, input int L, input int c);
        logic [NLOG-1:0] v;
        v = '0;
        for (int k = 0; k < HMAX; k++) if (k < L) v[k % c] = v[k % c] ^ h[k];
        return v;
    endfunction

    function automatic logic [HREG-1:0] hpush(input logic [HREG-1:0] h, input logic [1:0] n, input logic [2:0] b);
        case (n)
            2'd0:    return h;
            2'd1:    return {h[HREG-2:0], b[0]};
            2'd2:    return {h[HREG-3:0], b[0], b[1]};
            default: return {h[HREG-4:0], b[0], b[1], b[2]};
        endcase
    endfunction

    function automatic logic [2:0] sat3(input logic [2:0] c, input logic t);
        if (t) return (c == 3'd7) ? c : c + 3'd1;
        else   return (c == 3'd0) ? c : c - 3'd1;
    endfunction
    function automatic logic [1:0] sat2(input logic [1:0] c, input logic t);
        if (t) return (c == 2'd3) ? c : c + 2'd1;
        else   return (c == 2'd0) ? c : c - 2'd1;
    endfunction

    // ---- the metadata kept per block in the FTQ
    typedef struct packed {
        logic [1:0]                cprev;   // the bit count of the block pushed before this one
        logic [HMAX-1:0]           hist;    // the history before the block's push
        logic [2:0]                pred;
        logic [2:0]                sv;
        logic [2:0][2:0]           par;
        logic [BLOG-1:0]           bidx;
        logic [15:0]               base;    // the base row as read
        logic [NT-1:0][RW-1:0]     row;     // the tagged rows as read
        logic [NT-1:0][8:0]        tag;     // the tags of this block
        logic [NT-1:0][NLOG-1:0]   idx;
    } meta_t;

    logic [HREG-1:0] h;                 // the speculative global history (h[0] newest)
    logic [1:0]      c1, c2;            // the bit counts of the last block pushed and the one before
    logic [3:0]      use_alt;
    logic            tick;

    // ---- F0: index and tag of each table, from the history lagging 2 blocks
    logic [NT-1:0][NLOG-1:0] idx0;
    logic [NT-1:0][8:0]      tag0;
    logic [2:0]              hs;        // the bits of the blocks before that are in h already
    logic [HMAX-1:0]         hr;        // the history read with
    assign hs = (f0_live == 2'd2 || f0_live == 2'd3) ? 3'd0 : (f0_live == 2'd1) ? {1'b0, c1} : 3'(c1) + 3'(c2);
    assign hr = HMAX'(h >> hs);
    /* verilator lint_off UNUSEDSIGNAL */     // (the folds to fewer than 10 bits, the top bit of tt)
    always @(*) begin
        for (int j = 0; j < NT; j++) begin
            logic [NLOG-1:0] fi, f1, f2;
            logic [9:0]      tt;
            fi = fold(hr, hl(j), NLOG);
            f1 = fold(hr, hl(j), tw(j));
            f2 = fold(hr, hl(j), tw(j) - 1);
            idx0[j] = f0_pc[NLOG:1] ^ f0_pc[NLOG - j + 1 +: NLOG] ^ fi;
            tt      = {1'b0, f0_pc[9:1]} ^ {1'b0, f1[8:0]} ^ {f2[8:0], 1'b0};
            tag0[j] = (j < 2) ? {1'b0, tt[7:0]} : tt[8:0];
        end
    end
    /* verilator lint_on UNUSEDSIGNAL */

    // ---- the tables (one read port at F0, one write port for the update)
    logic [NT-1:0]           we;
    logic [NT-1:0][NLOG-1:0] wa;
    logic [NT-1:0][RW-1:0]   wd;
    logic [NT-1:0][RW-1:0]   rd1;
    for (genvar j = 0; j < NT; j++) begin : g_tbl
        (* ram_style = "block" *) logic [RW-1:0] tbl [NROW];
        initial for (int r = 0; r < NROW; r++) tbl[r] = '0;
        always_ff @(posedge clk) if (we[j]) tbl[wa[j]] <= wd[j];
        always_ff @(posedge clk) if (f0_valid) rd1[j] <= tbl[idx0[j]];
    end
    logic            bwe;
    logic [BLOG-1:0] bwa;
    logic [15:0]     bwd, brd1;
    (* ram_style = "block" *) logic [15:0] btbl [1 << BLOG];
    initial for (int r = 0; r < (1 << BLOG); r++) btbl[r] = 16'haaaa;   // every counter weakly taken
    always_ff @(posedge clk) if (bwe) btbl[bwa] <= bwd;
    always_ff @(posedge clk) if (f0_valid) brd1 <= btbl[f0_pc[4 +: BLOG]];

    logic                    v1;
    logic [NT-1:0][NLOG-1:0] idx1;
    logic [NT-1:0][8:0]      tag1;
    logic [BLOG-1:0]         bidx1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) v1 <= 1'b0;
        else        v1 <= f0_valid;
    end
    always_ff @(posedge clk) if (f0_valid) begin
        idx1  <= idx0;
        tag1  <= tag0;
        bidx1 <= f0_pc[4 +: BLOG];
    end

    // ---- F1: provider and alternate, kept for F2
    logic       pv1, av1;
    logic [2:0] ptk1, pweak1, atk1;
    always @(*) begin
        logic [NT-1:0] hit;
        logic [RW-1:0] pr, ar;
        for (int j = 0; j < NT; j++) hit[j] = rd1[j][20] && rd1[j][19:11] == tag1[j];
        pv1 = 1'b0; av1 = 1'b0; pr = '0; ar = '0;
        for (int j = 0; j < NT; j++) begin     // the highest hit, then the next
            if (hit[j]) begin
                av1 = pv1; ar = pr;
                pv1 = 1'b1; pr = rd1[j];
            end
        end
        for (int s = 0; s < 3; s++) begin
            logic [2:0] c;
            c = pr[3*s +: 3];
            ptk1[s]   = c[2];
            pweak1[s] = (c == 3'd3 || c == 3'd4) && pr[10:9] == 2'd0;
            atk1[s]   = ar[3*s + 2];
        end
    end

    logic                    pv2, av2;
    logic [2:0]              ptk2, pweak2, atk2;
    logic [NT-1:0][RW-1:0]   row2;
    logic [NT-1:0][NLOG-1:0] idx2;
    logic [NT-1:0][8:0]      tag2;
    logic [BLOG-1:0]         bidx2;
    logic [15:0]             base2;
    always_ff @(posedge clk) if (v1) begin
        pv2 <= pv1; av2 <= av1; ptk2 <= ptk1; pweak2 <= pweak1; atk2 <= atk1;
        row2 <= rd1; idx2 <= idx1; tag2 <= tag1; bidx2 <= bidx1; base2 <= brd1;
    end

    // ---- F2: the predictions
    meta_t m2;
    always @(*) begin
        for (int s = 0; s < 3; s++) begin
            logic bp, ap;
            bp = base2[{f2_par[s], 1'b1}];
            ap = av2 ? atk2[s] : bp;
            f2_pred[s] = pv2 ? ((pweak2[s] && use_alt[3]) ? ap : ptk2[s]) : bp;
        end
        m2.cprev = c1;
        m2.hist = h[HMAX-1:0];
        m2.pred = f2_pred;
        m2.sv   = f2_sv;
        m2.par  = f2_par;
        m2.bidx = bidx2;
        m2.base = base2;
        m2.row  = row2;
        m2.tag  = tag2;
        m2.idx  = idx2;
    end
    assign f2_meta = m2;

    // ---- the update
    /* verilator lint_off UNUSEDSIGNAL */     // (the update needs neither the history nor the slot valid bits)
    meta_t um;
    /* verilator lint_on UNUSEDSIGNAL */
    assign um = up_meta;
    logic [3:0] use_alt_n;
    logic       tick_n;
    always @(*) begin
        logic [NT-1:0] hit;
        logic          pv, av, alloc, dec;
        logic [1:0]    pj, aj, ja;
        logic [RW-1:0] pr, ar;
        logic [1:0]    u;
        logic [2:0][2:0] c;
        logic [7:0][1:0] b;
        logic [3:0]    ua;
        logic [2:0]    init;            // the counters of an allocated row: taken or not
        logic          tk, bp, ap, pp, wk, n2;
        logic [NT-1:0] fr;
        logic [1:0]    f0, f1;
        for (int j = 0; j < NT; j++) hit[j] = um.row[j][20] && um.row[j][19:11] == um.tag[j];
        pv = 1'b0; av = 1'b0; pj = '0; aj = '0;
        for (int j = 0; j < NT; j++) if (hit[j]) begin av = pv; aj = pj; pv = 1'b1; pj = 2'(j); end
        pr = um.row[pj];
        ar = um.row[aj];
        u  = pr[10:9];
        for (int s = 0; s < 3; s++) c[s] = pr[3*s +: 3];
        for (int e = 0; e < 8; e++) b[e] = um.base[2*e +: 2];
        ua = use_alt;
        alloc = 1'b0; dec = 1'b0; ja = '0; init = '0;
        for (int s = 0; s < 3; s++) begin
            tk = up_tk[s];
            bp = b[um.par[s]][1];
            ap = av ? ar[3*s + 2] : bp;
            pp = pv ? c[s][2] : bp;
            wk = pv && (c[s] == 3'd3 || c[s] == 3'd4) && u == 2'd0;
            fr = '0; f0 = '0; f1 = '0; n2 = 1'b0;
            if (up_ex[s]) begin
                if (wk && pp != ap) begin
                    if (ap == tk) ua = (ua == 4'd15) ? ua : ua + 4'd1;
                    else          ua = (ua == 4'd0)  ? ua : ua - 4'd1;
                end
                // a misprediction allocates in a longer table (at most one a block)
                if (um.pred[s] != tk && !(pv && pj == 2'd3) && !alloc && !dec) begin
                    for (int j = 0; j < NT; j++) fr[j] = (!pv || 2'(j) > pj) && um.row[j][10:9] == 2'd0;
                    for (int j = NT - 1; j >= 0; j--) if (fr[j]) begin f1 = f0; f0 = 2'(j); end
                    n2 = $countones(fr) >= 2;
                    if (fr != '0) begin
                        alloc = 1'b1;
                        ja    = (n2 && !(tick ^ s[0])) ? f1 : f0;
                        for (int q = 0; q < 3; q++)
                            init[q] = (q == s) ? tk : (av ? ar[3*q + 2] : b[um.par[q]][1]);
                    end else begin
                        dec = 1'b1;
                    end
                end
                if (pv) begin
                    c[s] = sat3(c[s], tk);
                    if (pp != ap) u = sat2(u, pp == tk);
                    if (!av && u == 2'd0) b[um.par[s]] = sat2(b[um.par[s]], tk);
                end else begin
                    b[um.par[s]] = sat2(b[um.par[s]], tk);
                end
            end
        end
        use_alt_n = ua;
        tick_n    = tick ^ (^up_ex);
        // the writes: the provider's row, the allocated row, the useful counters gone down
        for (int j = 0; j < NT; j++) begin
            wa[j] = um.idx[j];
            we[j] = 1'b0;
            wd[j] = um.row[j];
            if (pv && pj == 2'(j)) begin
                we[j] = 1'b1;
                wd[j] = {pr[20:11], u, c[2], c[1], c[0]};
            end else if (alloc && ja == 2'(j)) begin
                we[j] = 1'b1;
                wd[j] = {1'b1, um.tag[j], 2'd0, init[2] ? 3'd4 : 3'd3, init[1] ? 3'd4 : 3'd3, init[0] ? 3'd4 : 3'd3};
            end else if (dec && (!pv || 2'(j) > pj) && um.row[j][10:9] != 2'd0) begin
                we[j] = 1'b1;
                wd[j][10:9] = um.row[j][10:9] - 2'd1;
            end
            we[j] = we[j] && up_valid && up_ex != '0;
        end
        bwe = up_valid && up_ex != '0;
        bwa = um.bidx;
        bwd = b;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h       <= '0;
            c1      <= '0;
            c2      <= '0;
            use_alt <= 4'd8;
            tick    <= 1'b0;
        end else begin
            if (rs_valid) begin
                h  <= hpush({(HREG - HMAX)'(0), rs_hist[HMAX-1:0]}, rs_n, rs_bits);
                c1 <= rs_n;
                c2 <= rs_hist[HMAX+1:HMAX];
            end else if (f2_push) begin
                h  <= hpush(h, f2_n, f2_pred);
                c1 <= f2_n;
                c2 <= c1;
            end
            if (up_valid) begin
                use_alt <= use_alt_n;
                tick    <= tick_n;
            end
        end
    end

endmodule : OOO_TAGE
