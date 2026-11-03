//---------------------------------------------------------------------------
// OOO_EXU.sv
//
// Stages RR2, EX and the results of the 4-issue core at 100 MHz (Doc/STRATEGY.md
// 4.3, 4.5 loop 2, Plan/OOC.md 28.6): NA ports with an ALU and the memory port,
// which adds an address. 1 cycle from a result to the next result is the loop:
//
//   r_ex -> EX's mux (sa, sb) -> OOO_ALUF -> r_ex
//
// A result has 4 + 1 sources' worth of sinks, so it is kept 3 times: r_ex for
// EX's muxes, r_sn for RR2's, r_wr for the register file and whoever is outside.
//
// How a source gets its value, with T the cycle a result is in r_*:
//   a consumer in RR2 at T - 1   sa / sb choose r_ex in its EX
//   a consumer in RR2 at T       its operand register takes r_sn
//   later                        the register file (OOO_PRF2, written at the end of T)
// What is compared, in RR2: the sources' tags with the results in r_* (rv, rt)
// and those going there at the end of this cycle (ev, et). So EX's mux has its
// selection from a register and 5 sources; an immediate, the pc, a zero are
// already in the operand register (rr_use = 0, rr_const).
//
// Each ALU port has one write, and so does the memory port (s = NA, the load's).
// Port 0's write is shared, by the scheduler's write slots (OOO_SCHED rs), with:
//   - the operations not in OOO_ALUF, on queue 0 alone (rr_slow): latency 2, in
//     OOO_ALU from registers (p0_a, p0_b, for the multiplier and MDU too);
//   - x_*: what comes from outside (multiplier, MDU, system), x_d 0 without x_nv;
//   - a jalr's link. A jalr is on queue 0 alone, its target is the adder's sum.
// A µop that writes nothing, or that a flush took in RR2, leaves all the g_* of
// OOO_ALUF at 0, so that it does not disturb one of those on port 0.
//
// A branch compares on the adder (a - b) and a comparator; the flags are
// kept in a register, the decision (br_take) and misprediction follow in EX + 1.
//
// Not here: branch masks (OOO_STAGE around the control, Plan/CORE.md); kill and
// mispredictions reach only valid bits outside. flush empties everything.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_EXU
    #(
        parameter int NA   = 3,      // ALU ports (the muxes below name 3)
        parameter int TAGW = 7,
        parameter int VA   = 39
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,
        input  logic                  flush,

        // ---- RR2, from RR1's registers; port NA is the memory port
        input  logic [NA:0]           rr_v,
        input  logic [NA:0][1:0]      rr_use,     // the source is a register
        input  logic [NA:0][1:0][TAGW-1:0] rr_src,
        input  logic [NA:0][1:0][63:0] rr_prf,    // the register file's read
        input  logic [NA:0][1:0][63:0] rr_const,  // what a source not in use takes
        input  logic [NA-1:0]         rr_wr,
        input  logic [NA-1:0][TAGW-1:0] rr_dst,
        input  logic [NA-1:0][5:0]    rr_op,      // OOO_ALU's encoding
        input  logic [NA-1:0]         rr_uw,
        input  logic [NA-1:0][1:0]    rr_shift,
        input  logic [NA-1:0]         rr_word,
        input  logic [NA-1:0]         rr_br,
        input  logic [NA-1:0][2:0]    rr_brop,    // funct3 of the branch
        input  logic                  rr_slow,    // port 0
        input  logic                  rr_jalr,    // port 0
        input  logic [63:0]           rr_link,    // port 0
        input  logic [11:0]           rr_agi,     // the memory port's offset

        // ---- results from outside: *_nv, *_nt the cycle before they are in r_*
        input  logic                  ld_nv,
        input  logic [TAGW-1:0]       ld_nt,
        input  logic [63:0]           ld_d,
        input  logic                  x_nv,
        input  logic [TAGW-1:0]       x_nt,
        input  logic [63:0]           x_d,

        // ---- the results: into the register file
        output logic [NA:0]           wb_v,
        output logic [NA:0][TAGW-1:0] wb_t,
        output logic [NA:0][63:0]     wb_d,

        // ---- EX + 1
        output logic [NA-1:0]         br_v,
        output logic [NA-1:0]         br_take,
        output logic                  jr_v,
        output logic [VA-1:1]         jr_tgt,
        output logic                  ag_v,
        output logic [63:0]           ag,         // the memory port's address
        output logic [63:0]           sd,         // ... and its second source (a store's data)
        output logic [63:0]           p0_a,       // port 0's sources after the bypass
        output logic [63:0]           p0_b
    );

    localparam logic [5:0] ALU_ADD  = 6'd0;
    localparam logic [5:0] ALU_SUB  = 6'd1;
    localparam logic [5:0] ALU_SLL  = 6'd2;
    localparam logic [5:0] ALU_SLT  = 6'd3;
    localparam logic [5:0] ALU_SLTU = 6'd4;
    localparam logic [5:0] ALU_XOR  = 6'd5;
    localparam logic [5:0] ALU_SRL  = 6'd6;
    localparam logic [5:0] ALU_SRA  = 6'd7;
    localparam logic [5:0] ALU_OR   = 6'd8;
    localparam logic [5:0] ALU_AND  = 6'd9;
    localparam logic [5:0] ALU_ANDN = 6'd10;
    localparam logic [5:0] ALU_ORN  = 6'd11;
    localparam logic [5:0] ALU_XNOR = 6'd12;
    localparam logic [5:0] ALU_SEXTB= 6'd22;
    localparam logic [5:0] ALU_SEXTH= 6'd23;
    localparam logic [5:0] ALU_ZEXTH= 6'd24;
    localparam logic [5:0] ALU_CZEQZ= 6'd27;
    localparam logic [5:0] ALU_CZNEZ= 6'd28;
    localparam logic [5:0] ALU_BEXT = 6'd32;

    // ---- the results, 3 times each; s = NA is the load
    (* keep = "true" *) logic [63:0] r_ex [NA+1];
    (* keep = "true" *) logic [63:0] r_sn [NA+1];
    (* keep = "true" *) logic [63:0] r_wr [NA+1];
    logic [63:0]         r_d  [NA+1];
    logic [NA:0]         rv, ev;
    logic [TAGW-1:0]     rt [NA+1];
    logic [TAGW-1:0]     et [NA+1];

    assign r_d[NA] = ld_d;
    assign ev[NA]  = ld_nv;
    assign et[NA]  = ld_nt;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) rv <= '0;
        else        rv <= flush ? '0 : ev;
    end
    for (genvar s = 0; s <= NA; s++) begin : g_res
        always_ff @(posedge clk) begin
            r_ex[s] <= r_d[s];
            r_sn[s] <= r_d[s];
            r_wr[s] <= r_d[s];
            rt[s]   <= et[s];
        end
        assign wb_d[s] = r_wr[s];
        assign wb_t[s] = rt[s];
    end
    assign wb_v = rv;

    // ---- every port: RR2's operands and EX's mux
    logic [63:0] a [NA+1];
    logic [63:0] b [NA+1];
    for (genvar p = 0; p <= NA; p++) begin : g_p
        logic [63:0] op_n [2];
        logic [2:0]  sx_n [2];
        always @(*) begin
            for (int x = 0; x < 2; x++) begin
                automatic logic [NA:0] hr = '0;
                automatic logic [NA:0] he = '0;
                automatic logic [2:0]  k;
                for (int s = 0; s <= NA; s++) begin
                    hr[s] = rr_use[p][x] && rv[s] && rt[s] == rr_src[p][x];
                    he[s] = rr_use[p][x] && ev[s] && et[s] == rr_src[p][x];
                end
                // RR2's mux: 0 the register file, 1 the constant, 2 + s r_sn[s]
                k = rr_use[p][x] ? 3'd0 : 3'd1;
                sx_n[x] = 3'd0;
                for (int s = 0; s <= NA; s++) begin
                    if (hr[s]) k = 3'(2 + s);
                    if (he[s]) sx_n[x] = 3'(1 + s);
                end
                case (k)
                    3'd0:    op_n[x] = rr_prf[p][x];
                    3'd1:    op_n[x] = rr_const[p][x];
                    3'd2:    op_n[x] = r_sn[0];
                    3'd3:    op_n[x] = r_sn[1];
                    3'd4:    op_n[x] = r_sn[2];
                    default: op_n[x] = r_sn[NA];
                endcase
            end
        end
        logic [63:0] oa, ob;
        (* max_fanout = 16 *) logic [2:0] sa, sb;
        always_ff @(posedge clk) begin
            oa <= op_n[0];
            ob <= op_n[1];
            sa <= sx_n[0];
            sb <= sx_n[1];
        end
        always @(*) begin
            case (sa)
                3'd1:    a[p] = r_ex[0];
                3'd2:    a[p] = r_ex[1];
                3'd3:    a[p] = r_ex[2];
                3'd4:    a[p] = r_ex[NA];
                default: a[p] = oa;
            endcase
            case (sb)
                3'd1:    b[p] = r_ex[0];
                3'd2:    b[p] = r_ex[1];
                3'd3:    b[p] = r_ex[2];
                3'd4:    b[p] = r_ex[NA];
                default: b[p] = ob;
            endcase
        end
    end

    // ---- the ALU ports
    for (genvar p = 0; p < NA; p++) begin : g_alu
        // RR2: the operation, decoded
        logic        wn;
        logic [5:0]  op, nsh;
        logic        left_n;
        always @(*) begin
            op     = rr_op[p];
            wn     = rr_v[p] && !flush && rr_wr[p] && !(p == 0 && (rr_slow || rr_jalr));
            nsh    = rr_word[p] ? {1'b0, rr_const[p][1][4:0]} : rr_const[p][1][5:0];
            left_n = op == ALU_SLL && nsh != 6'd0;
        end
        (* max_fanout = 16 *) logic c_inv, c_uw, c_gadd, c_glog, c_gsh, c_shl, c_sra, c_shw, c_gcz, c_word;
        (* max_fanout = 16 *) logic [1:0] c_ash;
        (* max_fanout = 16 *) logic [2:0] c_lop;
        (* max_fanout = 16 *) logic [5:0] c_amt;
        logic c_gbx, c_gslt, c_gsltu, c_gzh, c_gsb, c_gsxh, c_czn;
        logic ex_v, ex_wr, ex_br;
        logic [TAGW-1:0] ex_dst;
        logic [2:0]      ex_brop;
        always_ff @(posedge clk) begin
            c_inv   <= rr_br[p] || op == ALU_SUB || op == ALU_SLT || op == ALU_SLTU;
            c_uw    <= rr_uw[p];
            c_ash   <= rr_shift[p];
            c_gadd  <= wn && (op == ALU_ADD || op == ALU_SUB);
            c_glog  <= wn && (op == ALU_XOR || op == ALU_OR || op == ALU_AND || op == ALU_ANDN || op == ALU_ORN || op == ALU_XNOR);
            c_lop   <= op == ALU_XOR ? 3'd0 : op == ALU_OR ? 3'd1 : op == ALU_AND ? 3'd2 :
                       op == ALU_ANDN ? 3'd3 : op == ALU_ORN ? 3'd4 : 3'd5;
            c_gsh   <= wn && (op == ALU_SLL || op == ALU_SRL || op == ALU_SRA);
            c_shl   <= left_n;
            c_sra   <= op == ALU_SRA;
            c_shw   <= rr_word[p] && op != ALU_SLL;
            c_amt   <= left_n ? 6'd0 - nsh : nsh;
            c_gbx   <= wn && op == ALU_BEXT;
            c_gslt  <= wn && op == ALU_SLT;
            c_gsltu <= wn && op == ALU_SLTU;
            c_gzh   <= wn && op == ALU_ZEXTH;
            c_gsb   <= wn && op == ALU_SEXTB;
            c_gsxh  <= wn && op == ALU_SEXTH;
            c_gcz   <= wn && (op == ALU_CZEQZ || op == ALU_CZNEZ);
            c_czn   <= op == ALU_CZNEZ;
            c_word  <= rr_word[p];
            ex_wr   <= rr_wr[p];
            ex_dst  <= rr_dst[p];
            ex_br   <= rr_br[p];
            ex_brop <= rr_brop[p];
        end
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) ex_v <= 1'b0;
            else        ex_v <= rr_v[p] && !flush;
        end

        // EX
        logic [63:0] res;
        /* verilator lint_off UNUSEDSIGNAL */      // (jalr's target only, port 0 only)
        logic [63:0] sum;
        /* verilator lint_on UNUSEDSIGNAL */
        logic        c_eq, c_lt, c_ltu;
        OOO_ALUF u_alu
            (.a(a[p]), .b(b[p]), .inv(c_inv), .a_uw(c_uw), .a_shift(c_ash),
             .g_add(c_gadd), .g_log(c_glog), .lop(c_lop), .g_sh(c_gsh), .sh_left(c_shl), .sh_sra(c_sra),
             .sh_w(c_shw), .amt(c_amt), .g_bx(c_gbx), .g_slt(c_gslt), .g_sltu(c_gsltu), .g_zh(c_gzh),
             .g_sb(c_gsb), .g_sxh(c_gsxh), .g_cz(c_gcz), .cz_n(c_czn), .word(c_word),
             .result(res), .sum(sum), .c_eq(c_eq), .c_lt(c_lt), .c_ltu(c_ltu));

        // EX + 1: a branch
        logic       fl_v, fl_eq, fl_lt, fl_ltu;
        logic [2:0] fl_op;
        always_ff @(posedge clk) begin
            fl_eq  <= c_eq;
            fl_lt  <= c_lt;
            fl_ltu <= c_ltu;
            fl_op  <= ex_brop;
        end
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) fl_v <= 1'b0;
            else        fl_v <= ex_v && ex_br && !flush;
        end
        assign br_v[p] = fl_v;
        always @(*) begin
            case (fl_op)
                3'b000:  br_take[p] = fl_eq;
                3'b001:  br_take[p] = !fl_eq;
                3'b100:  br_take[p] = fl_lt;
                3'b101:  br_take[p] = !fl_lt;
                3'b110:  br_take[p] = fl_ltu;
                3'b111:  br_take[p] = !fl_ltu;
                default: br_take[p] = 1'b0;
            endcase
        end

        // the result, and what port 0 shares its write with
        if (p == 0) begin : g_p0
            logic            s_ex, j_ex, rare_v;
            logic [5:0]      op_q, rop;
            logic            ruw, rword;
            logic [1:0]      rsh;
            logic [TAGW-1:0] rare_t;
            logic [63:0]     ra_q, rb_q, lk_q, rare;
            always_ff @(posedge clk) begin
                s_ex   <= rr_slow;
                j_ex   <= rr_jalr;
                lk_q   <= (rr_v[0] && !flush && rr_jalr && rr_wr[0]) ? rr_link : 64'd0;
                ra_q   <= a[0];
                rb_q   <= b[0];
                op_q   <= rr_op[0];
                rop    <= op_q;
                ruw    <= c_uw;
                rsh    <= c_ash;
                rword  <= c_word;
                rare_t <= ex_dst;
            end
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) rare_v <= 1'b0;
                else        rare_v <= ex_v && s_ex && ex_wr && !flush;
            end
            OOO_ALU #(.FULL(1'b1)) u_rare
                (.op_a(ra_q), .op_b(rb_q), .alu_op(rop), .a_uw(ruw), .a_shift(rsh), .word_op(rword), .result(rare));
            assign r_d[0] = res | lk_q | x_d | ({64{rare_v}} & rare);
            assign ev[0]  = (ex_v && ex_wr && !s_ex) || rare_v || x_nv;
            assign et[0]  = ({TAGW{ex_v && ex_wr && !s_ex}} & ex_dst) | ({TAGW{rare_v}} & rare_t) | ({TAGW{x_nv}} & x_nt);
            assign p0_a   = ra_q;
            assign p0_b   = rb_q;
            logic            jq;
            logic [VA-1:1]   jt;
            always_ff @(posedge clk) jt <= sum[VA-1:1];
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) jq <= 1'b0;
                else        jq <= ex_v && j_ex && !flush;
            end
            assign jr_v   = jq;
            assign jr_tgt = jt;
        end else begin : g_pn
            assign r_d[p] = res;
            assign ev[p]  = ex_v && ex_wr;
            assign et[p]  = ex_dst;
        end
    end

    // ---- the memory port
    logic        m_v;
    logic [11:0] m_i;
    logic [63:0] m_ag, m_sd;
    always_ff @(posedge clk) begin
        m_i  <= rr_agi;
        m_ag <= a[NA] + {{52{m_i[11]}}, m_i};
        m_sd <= b[NA];
    end
    logic m_ex;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin m_ex <= 1'b0; m_v <= 1'b0; end
        else        begin m_ex <= rr_v[NA] && !flush; m_v <= m_ex && !flush; end
    end
    assign ag_v = m_v;
    assign ag   = m_ag;
    assign sd   = m_sd;

endmodule : OOO_EXU
