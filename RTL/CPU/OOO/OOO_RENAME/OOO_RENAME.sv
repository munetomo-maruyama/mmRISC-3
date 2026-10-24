//---------------------------------------------------------------------------
// OOO_RENAME.sv
//
// Register renaming of mmRISC-3 in the fusion configuration (STRATEGY.md
// 4): 2 µops a cycle, each with up to 3 sources and 2 destinations (a fused
// pair; the decoder drops the first destination when both halves write the
// same register, so a µop never names one register twice).
//
//   RAT        32 x TAGW in flip-flops (6 source reads, 4 old-mapping reads
//              and 4 writes a cycle are too many ports for distributed RAM;
//              224 bits)
//   free list  a ring of NREG - 32 tags (a power of two): up to 4 taken a
//              cycle at rename, up to 4 given back a cycle at commit (the
//              old mappings). head / tail carry one wrap bit, so the number
//              of free registers is tail - head and stays right across a
//              restore
//   busy bits  NREG: set when a register is given out, cleared when its
//              value is written (wb_*); rename reads them to tell the issue
//              queue which sources are ready already
//   in-group   a source of µop 1 that is a destination of µop 0 takes µop
//              0's new tag (and is not ready)
//   checkpoints NCKPT copies of the RAT and of the free list's head, taken
//              after a µop with a control transfer; a misprediction restores
//              one (the registers given out after it come back by moving the
//              head back: the ring order makes them the right ones)
//
// x0 maps to physical register 0 forever, is never given out and is always
// ready. Rename stalls (ready = 0) when the free list cannot cover the
// destinations of both µops, and in the cycle of a restore.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_RENAME
    #(
        parameter int NREG  = 96,
        parameter int TAGW  = 7,
        parameter int NCKPT = 8,
        parameter int NWB   = 5      // write-back ports that clear busy bits
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,

        // the 2 µops of this cycle (0 the older)
        output logic                        ready,
        input  logic [1:0]                  in_valid,
        input  logic [1:0][2:0]             in_use,      // sources used
        input  logic [1:0][2:0][4:0]        in_src,      // architectural
        input  logic [1:0][1:0]             in_wr,       // destinations written
        input  logic [1:0][1:0][4:0]        in_dst,
        input  logic [1:0]                  in_ckpt,     // take a checkpoint after this µop
        output logic [1:0][$clog2(NCKPT)-1:0] out_ckpt_id,

        output logic [1:0][2:0][TAGW-1:0]   out_src,     // physical
        output logic [1:0][2:0]             out_rdy,
        output logic [1:0][1:0][TAGW-1:0]   out_dst,
        output logic [1:0][1:0][TAGW-1:0]   out_old,     // the previous mapping, freed at commit

        // write-back: the value of a register is there
        input  logic [NWB-1:0]              wb_valid,
        input  logic [NWB-1:0][TAGW-1:0]    wb_tag,

        // commit: old mappings back to the free list (up to 4 a cycle)
        input  logic [3:0]                  free_valid,
        input  logic [3:0][TAGW-1:0]        free_tag,

        // misprediction: back to a checkpoint
        input  logic                        restore,
        input  logic [$clog2(NCKPT)-1:0]    restore_id
    );

    localparam int NF = NREG - 32;
    localparam int FW = $clog2(NF);
    localparam int CW = $clog2(NCKPT);

    initial begin
        if ((1 << FW) != NF) $error("OOO_RENAME: NREG - 32 must be a power of two");
    end

    // arrays (not packed vectors) where an entry is chosen at run time
    logic [TAGW-1:0]         rat    [32];
    logic [TAGW-1:0]         fl     [NF]; // free list ring
    logic [FW:0]             head, tail;  // with a wrap bit
    logic [FW:0]             nfree;
    logic [NREG-1:0]         busy;
    logic [TAGW-1:0]         ck_rat [NCKPT][32];
    logic [FW:0]             ck_head[NCKPT];
    logic [CW-1:0]           ck_next;

    assign nfree = tail - head;

    // which of the next four free registers each destination takes
    logic [2:0] need;
    logic [1:0][1:0][2:0] nth;
    logic [1:0][1:0]      alloc;
    always @(*) begin
        logic [2:0] n;
        n = 3'd0;
        for (int u = 0; u < 2; u++)
            for (int k = 0; k < 2; k++) begin
                nth[u][k]   = n;
                alloc[u][k] = in_valid[u] && in_wr[u][k] && in_dst[u][k] != 5'd0;
                if (alloc[u][k]) n = n + 3'd1;
            end
        need = n;
    end
    assign ready = (nfree >= (FW + 1)'(need)) && !restore;

    // rename
    logic [1:0][1:0][TAGW-1:0] new_tag;
    logic [TAGW-1:0] ck_val [2][32];      // the RAT after µop 0, after µop 1
    always @(*) begin
        for (int u = 0; u < 2; u++)
            for (int k = 0; k < 2; k++)
                new_tag[u][k] = alloc[u][k] ? fl[FW'(head + (FW + 1)'(nth[u][k]))] : '0;
        for (int u = 0; u < 2; u++) begin
            for (int s = 0; s < 3; s++) begin
                out_src[u][s] = rat[in_src[u][s]];
                out_rdy[u][s] = !in_use[u][s] || in_src[u][s] == 5'd0 || !busy[out_src[u][s]];
                if (u == 1)
                    for (int k = 0; k < 2; k++)
                        if (alloc[0][k] && in_dst[0][k] == in_src[1][s]) begin
                            out_src[1][s] = new_tag[0][k];
                            out_rdy[1][s] = 1'b0;
                        end
            end
            for (int k = 0; k < 2; k++) begin
                out_dst[u][k] = new_tag[u][k];
                out_old[u][k] = rat[in_dst[u][k]];
            end
        end
        // µop 1's old mapping of a register µop 0 just renamed is µop 0's new one
        for (int k = 0; k < 2; k++)
            for (int j = 0; j < 2; j++)
                if (alloc[0][j] && in_dst[0][j] == in_dst[1][k])
                    out_old[1][k] = new_tag[0][j];
        // the RAT after each µop, for the checkpoints
        for (int a = 0; a < 32; a++) ck_val[0][a] = rat[a];
        for (int k = 0; k < 2; k++) if (alloc[0][k]) ck_val[0][in_dst[0][k]] = new_tag[0][k];
        for (int a = 0; a < 32; a++) ck_val[1][a] = ck_val[0][a];
        for (int k = 0; k < 2; k++) if (alloc[1][k]) ck_val[1][in_dst[1][k]] = new_tag[1][k];
        out_ckpt_id[0] = ck_next;
        out_ckpt_id[1] = ck_next + CW'(in_valid[0] && in_ckpt[0]);
    end

    logic go;
    assign go = ready && (in_valid != 2'b00);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int a = 0; a < 32; a++) rat[a] <= TAGW'(a);     // x_a in p_a at reset
            for (int f = 0; f < NF; f++) fl[f] <= TAGW'(32 + f);
            head    <= '0;
            tail    <= (FW + 1)'(NF);                          // all NF free
            busy    <= '0;
            ck_next <= '0;
        end else begin
            logic [FW:0] t;
            // write-back clears busy
            for (int w = 0; w < NWB; w++) if (wb_valid[w]) busy[wb_tag[w]] <= 1'b0;
            // commit returns registers at the tail
            t = tail;
            for (int k = 0; k < 4; k++)
                if (free_valid[k]) begin fl[t[FW-1:0]] <= free_tag[k]; t = t + (FW + 1)'(1); end
            tail <= t;
            if (restore) begin
                for (int a = 0; a < 32; a++) rat[a] <= ck_rat[restore_id][a];
                head    <= ck_head[restore_id];
                ck_next <= restore_id + CW'(1);
            end else if (go) begin
                for (int u = 0; u < 2; u++)
                    for (int k = 0; k < 2; k++)
                        if (alloc[u][k]) begin
                            rat[in_dst[u][k]]   <= new_tag[u][k];
                            busy[new_tag[u][k]] <= 1'b1;
                        end
                head <= head + (FW + 1)'(need);
                for (int u = 0; u < 2; u++)
                    if (in_valid[u] && in_ckpt[u]) begin
                        for (int a = 0; a < 32; a++) ck_rat[out_ckpt_id[u]][a] <= ck_val[u][a];
                        ck_head[out_ckpt_id[u]] <= head + ((u == 0) ? (FW + 1)'(nth[1][0]) : (FW + 1)'(need));
                    end
                ck_next <= ck_next + CW'(in_valid[0] && in_ckpt[0]) + CW'(in_valid[1] && in_ckpt[1]);
            end
        end
    end

endmodule : OOO_RENAME
