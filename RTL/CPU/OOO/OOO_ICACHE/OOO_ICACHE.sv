//---------------------------------------------------------------------------
// OOO_ICACHE.sv
//
// The I$ of the 4-wide core (step 1.7 H1, Plan/OOC.md 29.55): 32 bytes a cycle to
// OOO_FETCH2 on its port (ic_*), with the timing tb_core's ICacheModel gave it:
//
//   F0  a request taken (ic_req_valid && ic_req_ready): the tags (LUT RAM) read by its
//       address and compared at once, the hit way kept in a register; the data
//       arrays (block RAM) read by the same address
//   F1  a hit: the ways' 32 bytes (zeros but the hit's) ORed into the answer's
//       register; a miss: the line asked for, and no request taken from this cycle
//       until the line is in and the request looked up again
//   F2  the answer (ic_resp_valid, ic_resp_data) from flip-flops
//
// A request every cycle while they hit; every request taken is answered, in order
// (OOO_FETCH2 throws away what it no longer wants). SETS x WAYS lines of 64 bytes:
// 128 KB at 256 x 8 (step 1.7c C1, Plan/OOC.md 29.64-29.66; 32 KB at 64 x 8 before).
// Each column of a way is SETS*2 x 64 bits: at 256 sets 512 x 64 in one RAMB36
// (512 x 72), the same 32 tiles as at 64 sets; the tags' LUT RAM 4 times as deep.
// The index takes bits 13:12 of the fetch address, beyond a 4 KB page: with the ITLB
// (step 1.8) a physical line can sit in up to 4 sets. In an I$ that is harmless: no
// store writes it, and FENCE.I sweeps every set. Tagged by the fetch address (no
// translation yet). One miss at a time: a burst of 8 beats on AXI4 (m_axi4_ar*, r*), each word
// written into the arrays as it comes, the line's tag and valid bit at the last beat;
// the cycle after, the request is looked up again in F0 (rp) and answered as a hit,
// 3 cycles after the last beat (the answer has one source: answered from the beats,
// it took 1.5k LUTs more in Yosys). The way: one free in the set, else the next of a
// counter moved by each fill. A beat with an error answer leaves the way invalid; the
// request is answered all the same, with zeros (fetch faults come with the MMU, step
// 1.8). Everything fetched is cached (a boot ROM
// outside memory waits for the SoC, step 2).
//
// The valid bits are in the tags' LUT RAM ({valid, tag} a way and set), so they are
// cleared by a sweep, one set a cycle (SETS cycles: 256), in which no request is taken:
// after the reset, and for FENCE.I (ic_flush until ic_done; no request is taken
// while ic_flush is up). The sweep waits for a line asked for to be in, so a fill
// asked before the flush (the D$'s writes not yet in memory) is swept away; ic_done
// the cycle after the sweep, until ic_flush goes. A way that does not hit gives zeros
// from its block RAM (its output reset), so a hit's 32 bytes are the ways' OR.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_ICACHE
    #(
        parameter int VA   = 39,
        parameter int PAW  = 40,
        parameter int SETS = 256,
        parameter int WAYS = 8,
        parameter logic [3:0] AXI_ID = 4'd2
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,

        // ---- OOO_FETCH2
        input  logic                  ic_req_valid,
        input  logic [VA-1:1]         ic_req_pc,
        output logic                  ic_req_ready,
        output logic                  ic_resp_valid,
        output logic [255:0]          ic_resp_data,
        input  logic                  ic_flush,     // FENCE.I: invalidate (until ic_done)
        output logic                  ic_done,

        // ---- the fills (AXI4, reads only)
        output logic [3:0]            m_axi4_arid,
        output logic [PAW-1:0]        m_axi4_araddr,
        output logic [7:0]            m_axi4_arlen,
        output logic [2:0]            m_axi4_arsize,
        output logic [1:0]            m_axi4_arburst,
        output logic                  m_axi4_arvalid,
        input  logic                  m_axi4_arready,
        input  logic [63:0]           m_axi4_rdata,
        input  logic [1:0]            m_axi4_rresp,
        input  logic                  m_axi4_rlast,
        input  logic                  m_axi4_rvalid,
        output logic                  m_axi4_rready
    );

    localparam int SW = $clog2(SETS);
    localparam int WW = (WAYS > 1) ? $clog2(WAYS) : 1;
    localparam int TW = VA - 6 - SW;            // the tag: the address above the index

    // ---- F0: the tags compared
    logic [SW-1:0]   idx0;
    logic [TW-1:0]   tag0;
    logic            acc;
    logic [WAYS-1:0] hit0, vs0;                 // the ways that hit, the ways valid
    logic [TW:0]     tv [WAYS];                 // {valid, tag} read

    logic            hf0;                       // the half line
    logic            rp;                        // a miss's line is in: its request looked up again
    logic            busy;                      // a line asked for, until its request is looked up again
    logic            arv;
    logic [VA-1:6]   m_line;
    logic            m_half;

    assign idx0 = rp ? m_line[6+SW-1:6]  : ic_req_pc[6+SW-1:6];
    assign tag0 = rp ? m_line[VA-1:6+SW] : ic_req_pc[VA-1:6+SW];
    assign hf0  = rp ? m_half            : ic_req_pc[5];
    assign acc  = ic_req_valid && ic_req_ready;

    // ---- the miss
    logic [WW-1:0]   m_way;
    logic [2:0]      beat;
    logic            m_err;
    logic            fill_end;
    logic [WW-1:0]   rr;                        // the way of a set without a free one

    assign fill_end = busy && m_axi4_rvalid && m_axi4_rlast;

    // ---- the sweep: every set's {valid, tag} cleared, one set a cycle (after the reset, and for FENCE.I)
    logic            cl;
    logic [SW-1:0]   fc;

    // ---- the arrays
    logic            t_we;
    logic [SW-1:0]   t_wa;
    logic [TW:0]     t_wd;
    assign t_we = cl || fill_end;
    assign t_wa = cl ? fc : m_line[6+SW-1:6];
    assign t_wd = cl ? '0 : {!m_err && m_axi4_rresp == 2'b00, m_line[VA-1:6+SW]};   // (the way's old line is gone either way)

    logic [63:0]     dq [WAYS][4];              // each way's 32 bytes, read at F0 (zero if it does not hit), by columns
    for (genvar w = 0; w < WAYS; w++) begin : g_way
        (* ram_style = "distributed" *) logic [TW:0] tag_ram [SETS];
        always_ff @(posedge clk) if (t_we && (cl || m_way == WW'(w))) tag_ram[t_wa] <= t_wd;
        assign tv[w]   = tag_ram[idx0];
        assign vs0[w]  = tv[w][TW];
        assign hit0[w] = tv[w][TW] && tv[w][TW-1:0] == tag0;
        for (genvar c = 0; c < 4; c++) begin : g_col      // a column: the c-th 8 bytes of each half line
            (* ram_style = "block" *) logic [63:0] dat [SETS*2];
            always_ff @(posedge clk)
                if (busy && m_axi4_rvalid && m_way == WW'(w) && beat[1:0] == 2'(c))
                    dat[{m_line[6+SW-1:6], beat[2]}] <= m_axi4_rdata;
            always_ff @(posedge clk)                      // (the block RAM's output reset)
                if (!hit0[w]) dq[w][c] <= '0;
                else          dq[w][c] <= dat[{idx0, hf0}];
        end
    end

    // ---- F1
    logic            s1_v;
    logic            s1_rp;                     // a request looked up again: answered, hit or not (a fill with an error);
                                                // its words come by the block RAMs' output reset, s1_hit and s1_vs not needed
    logic            s1_hit;                    // a request that hit
    logic [WAYS-1:0] s1_vs;                     // its set's valid ways
    logic [VA-1:5]   s1_pc;
    logic            s1_miss;
    logic [255:0]    s1_data;

    assign s1_miss      = s1_v && !s1_rp && !s1_hit;
    assign ic_req_ready = !busy && !s1_miss && !cl && !ic_flush;

    always @(*) begin
        s1_data = '0;
        for (int w = 0; w < WAYS; w++) s1_data = s1_data | {dq[w][3], dq[w][2], dq[w][1], dq[w][0]};
    end

    // the way a miss fills: a free one in the set, else the counter's
    logic [WW-1:0]   vic;
    always @(*) begin
        vic = rr;
        for (int w = WAYS - 1; w >= 0; w--) if (!s1_vs[w]) vic = WW'(w);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_v          <= 1'b0;
            busy          <= 1'b0;
            arv           <= 1'b0;
            rr            <= '0;
            ic_resp_valid <= 1'b0;
            ic_done       <= 1'b0;
            rp            <= 1'b0;
            cl            <= 1'b1;
            fc            <= '0;
        end else begin
            s1_v          <= acc || rp;
            ic_resp_valid <= s1_v && !s1_miss;
            if (s1_miss) begin
                busy <= 1'b1;
                arv  <= 1'b1;
            end
            if (arv && m_axi4_arready) arv <= 1'b0;
            if (fill_end) begin
                rp   <= 1'b1;
                rr   <= rr + 1'b1;
            end
            if (rp) begin
                rp   <= 1'b0;
                busy <= 1'b0;
            end
            // FENCE.I: the sweep once no line is asked for (a fill asked before it is swept away)
            if (ic_flush && !ic_done && !cl && !busy && !s1_miss) cl <= 1'b1;
            if (cl) begin
                fc <= fc + 1'b1;
                if (fc == SW'(SETS - 1)) begin
                    cl      <= 1'b0;
                    ic_done <= 1'b1;            // (cleared below without ic_flush: after the reset's sweep)
                end
            end
            if (!ic_flush) ic_done <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        s1_rp <= rp;
        if (acc) begin
            s1_hit <= hit0 != '0;
            s1_vs  <= vs0;
            s1_pc  <= ic_req_pc[VA-1:5];
        end
        if (s1_v && !s1_miss) ic_resp_data <= s1_data;
        if (s1_miss) begin
            m_line <= s1_pc[VA-1:6];
            m_half <= s1_pc[5];
            m_way  <= vic;
            beat   <= 3'd0;
            m_err  <= 1'b0;
        end
        if (busy && m_axi4_rvalid) begin
            beat <= beat + 3'd1;
            if (m_axi4_rresp != 2'b00) m_err <= 1'b1;
        end
    end

    assign m_axi4_arid    = AXI_ID;
    assign m_axi4_araddr  = PAW'({m_line, 6'd0});
    assign m_axi4_arlen   = 8'd7;
    assign m_axi4_arsize  = 3'd3;
    assign m_axi4_arburst = 2'b01;
    assign m_axi4_arvalid = arv;
    assign m_axi4_rready  = 1'b1;

    /* verilator lint_off UNUSEDSIGNAL */
    logic unused;
    assign unused = ^ic_req_pc[4:1];
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
