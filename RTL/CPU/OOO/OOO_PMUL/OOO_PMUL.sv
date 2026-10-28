//---------------------------------------------------------------------------
// OOO_PMUL.sv
//
// Port 0's pipelined multiplier of mmRISC-3 for mul / mulw (Doc/UARCH.md
// D-16, variant A; Plan/OOC.md 24): beside CORE_MDU, which keeps mulh*,
// clmul* and the divides (OOO_MDUP). One mul a cycle, latency 2 for the
// issue queue:
//
//   t      issued (OOO_IQ wakes its dependents with the delayed wakeup)
//   t + 2  EX: the operands go into the DSP blocks (registered there)
//   t + 3  the three products are summed: res_* goes into port 0's
//          write-back register at the end of the cycle (the register
//          file and the bypass in t + 4). That is the slot of a latency-1
//          µop issued on port 0 in t + 1, which the issue queue does not
//          give port 0 then; OOO_MDUP does not write in it either
//
// Only the low 64 bits of the product: a_lo x b_lo in full and the two
// cross products to 32 bits (the high ones never reach the low half), so
// signs do not matter. mulw: the low 32 bits sign extended. Three 32 x 32
// products: 10 DSP48E1 in Yosys (Plan/OOC.md 23.4).
//
// A µop is not taken when it is killed in EX (its branch mask has the
// killed bit) or flushed, and writes nothing when killed or flushed in the
// cycle after (the mask keeps that cycle's clears: one cycle, as the LSU's
// M, OOO_LSU).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_PMUL
    #(
        parameter int ROBW = 5,
        parameter int TAGW = 6,
        parameter int NCK  = 6
    )
    (
        input  logic                clk,
        input  logic                rst_n,
        input  logic                flush,      // OOO_CTRL flush_all
        input  logic [NCK-1:0]      kill,

        // port 0's EX: a mul / mulw
        input  logic                ex_valid,
        input  logic                ex_word,
        input  logic [63:0]         ex_a,
        input  logic [63:0]         ex_b,
        input  logic [ROBW-1:0]     ex_rob,
        input  logic [TAGW-1:0]     ex_dst,
        input  logic [NCK-1:0]      ex_bm,

        // into port 0's write-back register at the end of this cycle
        output logic                res_valid,
        output logic [TAGW-1:0]     res_tag,
        output logic [63:0]         res_data,
        output logic [ROBW-1:0]     res_rob
    );

    logic            m_v, m_w;
    logic [ROBW-1:0] m_rob;
    logic [TAGW-1:0] m_dst;
    logic [NCK-1:0]  m_bm;
    logic [63:0]     p_ll;              // a_lo x b_lo
    logic [31:0]     p_lh, p_hl;        // the cross products, their low halves

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) m_v <= 1'b0;
        else        m_v <= ex_valid && !flush && (ex_bm & kill) == '0;
    end
    always_ff @(posedge clk) begin
        p_ll  <= ex_a[31:0]  * ex_b[31:0];
        p_lh  <= ex_a[31:0]  * ex_b[63:32];
        p_hl  <= ex_a[63:32] * ex_b[31:0];
        m_w   <= ex_word;
        m_rob <= ex_rob;
        m_dst <= ex_dst;
        m_bm  <= ex_bm;
    end

    always @(*) begin
        logic [63:0] s;
        s         = p_ll + {p_lh + p_hl, 32'd0};
        res_valid = m_v && !flush && (m_bm & kill) == '0;
        res_tag   = m_dst;
        res_data  = m_w ? {{32{s[31]}}, s[31:0]} : s;
        res_rob   = m_rob;
    end

endmodule : OOO_PMUL
