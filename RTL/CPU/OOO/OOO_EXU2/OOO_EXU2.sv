//---------------------------------------------------------------------------
// OOO_EXU2.sv
//
// Stages RR, EX and the results of the 4-wide core at 50 MHz (Doc/STRATEGY.md 4.3,
// 4.5 loop 2): 4 ALU ports and 2 memory ports. 1 cycle from a result to the next
// result is the loop:
//
//   r_ex -> EX's mux (sa, sb) -> ALU -> r_ex
//
// A result goes into the register file at the same edge as into r_ex (wb_*, from EX
// itself), so there is one bypass and not two. How a source gets its value, with T
// the cycle a result is in r_ex:
//   a consumer in RR at T - 1    sa / sb choose r_ex in its EX
//   a consumer in RR at T, later the register file, read in RR
// What is compared, in RR: the sources' tags with the results going into r_ex at the
// end of this cycle (ev, et). So EX's mux has its selection from a register and 6
// sources; an immediate, the pc, a zero are already in the operand register (rr_use
// = 0, rr_const).
//
// Each ALU port has one write, and each memory port (s = 4, 5, a load's). The write of
// 2 ports is shared, by OOO_IQ2's write slots:
//   port 0  x0_*: what comes from outside (MDU, system), x0_d 0 without x0_nv;
//           a jalr's link
//   port 1  x1_*: the multiplier
// Port 0 has the operations not in OOO_ALUF too (rr_slow): OOO_ALUR, in the cycle
// of its operands, as a jalr, on port 0 alone.
// A µop that writes nothing, or that a flush took in RR, leaves all the g_* of
// OOO_ALUF at 0, so that it does not disturb what comes from outside.
//
// A branch compares on the adder (a - b) and a comparator; the flags are
// kept in a register, the decision (br_take) and misprediction follow in EX + 1.
//
// A memory port's address is the sum of its a and offset, out in EX, for the block RAM
// at the end of EX; port 4's b is a store's data. Port 5 has loads only: one source,
// so 11 reads of the register file, not 12.
//
// Not here: branch masks (OOO_STAGE around the control, Plan/CORE.md); kill and
// mispredictions reach only valid bits outside. flush empties everything.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_EXU2
    #(
        parameter int TAGW = 7,
        parameter int VA   = 39
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,
        input  logic                  flush,

        // ---- RR; ports 4, 5 are the memory ports
        input  logic [5:0]            rr_v,
        input  logic [5:0][1:0]       rr_use,     // the source is a register
        input  logic [5:0][1:0][TAGW-1:0] rr_src,
        input  logic [5:0][1:0][63:0] rr_prf,     // the register file's read (port 5's second: not used)
        input  logic [5:0][1:0][63:0] rr_const,   // what a source not in use takes
        input  logic [3:0]            rr_wr,
        input  logic [3:0][TAGW-1:0]  rr_dst,
        input  logic [3:0][5:0]       rr_op,      // OOO_ALU's encoding
        input  logic [3:0]            rr_uw,
        input  logic [3:0][1:0]       rr_shift,
        input  logic [3:0]            rr_word,
        input  logic [3:0]            rr_br,
        input  logic [3:0][2:0]       rr_brop,    // funct3 of the branch
        input  logic                  rr_slow,    // port 0
        input  logic                  rr_jalr,    // port 0
        input  logic [63:0]           rr_link,    // port 0
        input  logic [1:0][11:0]      rr_agi,     // the memory ports' offsets

        // ---- results from outside, the cycle before they are in r_ex
        input  logic [1:0]            ld_nv,
        input  logic [1:0][TAGW-1:0]  ld_nt,
        input  logic [1:0][63:0]      ld_d,
        input  logic                  x0_nv,
        input  logic [TAGW-1:0]       x0_nt,
        input  logic [63:0]           x0_d,
        input  logic                  x1_nv,
        input  logic [TAGW-1:0]       x1_nt,
        input  logic [63:0]           x1_d,

        // ---- the results: into the register file, at the end of this cycle
        output logic [5:0]            wb_v,
        output logic [5:0][TAGW-1:0]  wb_t,
        output logic [5:0][63:0]      wb_d,

        // ---- EX: the memory ports
        output logic [1:0]            ag_v,
        output logic [1:0][63:0]      ag,         // the address
        output logic [63:0]           sd,         // port 4's second source (a store's data)

        // ---- EX + 1
        output logic [3:0]            br_v,
        output logic [3:0]            br_take,
        output logic                  jr_v,
        output logic [VA-1:1]         jr_tgt,
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

    // ---- the results; s = 4, 5 are the loads
    logic [63:0]     r_ex [6];
    logic [63:0]     r_d  [6];
    logic [5:0]      ev;
    logic [TAGW-1:0] et [6];

    for (genvar s = 0; s < 2; s++) begin : g_ld
        assign r_d[4+s] = ld_d[s];
        assign ev[4+s]  = ld_nv[s];
        assign et[4+s]  = ld_nt[s];
    end
    for (genvar s = 0; s < 6; s++) begin : g_res
        always_ff @(posedge clk) r_ex[s] <= r_d[s];
        assign wb_d[s] = r_d[s];
        assign wb_t[s] = et[s];
    end
    assign wb_v = flush ? '0 : ev;

    // ---- every port: RR's operands and EX's mux
    logic [63:0] a [6];
    logic [63:0] b [6];
    for (genvar p = 0; p < 6; p++) begin : g_p
        logic [63:0] op_n [2];
        logic [2:0]  sx_n [2];
        always @(*) begin
            for (int x = 0; x < 2; x++) begin
                op_n[x] = rr_use[p][x] ? rr_prf[p][x] : rr_const[p][x];
                sx_n[x] = 3'd0;
                for (int s = 0; s < 6; s++)
                    if (rr_use[p][x] && ev[s] && et[s] == rr_src[p][x]) sx_n[x] = 3'(1 + s);
            end
        end
        logic [63:0] oa;
        logic [2:0]  sa;
        always_ff @(posedge clk) begin
            oa <= op_n[0];
            sa <= sx_n[0];
        end
        always @(*) begin
            case (sa)
                3'd1:    a[p] = r_ex[0];
                3'd2:    a[p] = r_ex[1];
                3'd3:    a[p] = r_ex[2];
                3'd4:    a[p] = r_ex[3];
                3'd5:    a[p] = r_ex[4];
                3'd6:    a[p] = r_ex[5];
                default: a[p] = oa;
            endcase
        end
        if (p < 5) begin : g_b
            logic [63:0] ob;
            logic [2:0]  sb;
            always_ff @(posedge clk) begin
                ob <= op_n[1];
                sb <= sx_n[1];
            end
            always @(*) begin
                case (sb)
                    3'd1:    b[p] = r_ex[0];
                    3'd2:    b[p] = r_ex[1];
                    3'd3:    b[p] = r_ex[2];
                    3'd4:    b[p] = r_ex[3];
                    3'd5:    b[p] = r_ex[4];
                    3'd6:    b[p] = r_ex[5];
                    default: b[p] = ob;
                endcase
            end
        end else begin : g_nb
            assign b[p] = 64'd0;
        end
    end

    // ---- the ALU ports
    for (genvar p = 0; p < 4; p++) begin : g_alu
        // RR: the operation, decoded
        logic        wn;
        logic [5:0]  op, nsh;
        logic [63:0] m_n;
        always @(*) begin
            op     = rr_op[p];
            wn     = rr_v[p] && !flush && rr_wr[p] && !(p == 0 && (rr_slow || rr_jalr));
            nsh    = rr_word[p] ? {1'b0, rr_const[p][1][4:0]} : rr_const[p][1][5:0];
            // the bits of the rotation that are the result's
            case (op)
                ALU_SLL:          m_n = (rr_word[p] ? 64'hFFFF_FFFF : ~64'd0) & (~64'd0 << nsh);
                ALU_SRL, ALU_SRA: m_n = (rr_word[p] ? 64'hFFFF_FFFF : ~64'd0) >> nsh;
                ALU_BEXT:         m_n = 64'd1;
                default:          m_n = 64'd0;
            endcase
            if (!wn) m_n = 64'd0;
        end
        logic c_inv, c_uw, c_gadd, c_gaddh, c_glog, c_gcz;
        logic [1:0] c_ash;
        logic [2:0] c_lop;
        logic [5:0] c_amt;
        logic [63:0] c_m;
        logic c_gaddw, c_f63, c_f31, c_gslw, c_gslt, c_gsltu, c_gzh, c_gsb, c_gsxh, c_czn;
        logic ex_v, ex_wr, ex_br;
        logic [TAGW-1:0] ex_dst;
        logic [2:0]      ex_brop;
        always_ff @(posedge clk) begin
            c_inv   <= rr_br[p] || op == ALU_SUB || op == ALU_SLT || op == ALU_SLTU;
            c_uw    <= rr_uw[p];
            c_ash   <= rr_shift[p];
            c_gadd  <= wn && (op == ALU_ADD || op == ALU_SUB);
            c_gaddh <= wn && (op == ALU_ADD || op == ALU_SUB) && !rr_word[p];
            c_gaddw <= wn && (op == ALU_ADD || op == ALU_SUB) && rr_word[p];
            c_glog  <= wn && (op == ALU_XOR || op == ALU_OR || op == ALU_AND || op == ALU_ANDN || op == ALU_ORN || op == ALU_XNOR);
            c_lop   <= op == ALU_XOR ? 3'd0 : op == ALU_OR ? 3'd1 : op == ALU_AND ? 3'd2 :
                       op == ALU_ANDN ? 3'd3 : op == ALU_ORN ? 3'd4 : 3'd5;
            c_m     <= m_n;
            c_f63   <= wn && op == ALU_SRA && !rr_word[p];
            c_f31   <= wn && rr_word[p] && (op == ALU_SRA || (op == ALU_SRL && nsh == 6'd0));
            c_gslw  <= wn && op == ALU_SLL && rr_word[p];
            c_amt   <= op == ALU_SLL ? 6'd0 - nsh : nsh;
            c_gslt  <= wn && op == ALU_SLT;
            c_gsltu <= wn && op == ALU_SLTU;
            c_gzh   <= wn && op == ALU_ZEXTH;
            c_gsb   <= wn && op == ALU_SEXTB;
            c_gsxh  <= wn && op == ALU_SEXTH;
            c_gcz   <= wn && (op == ALU_CZEQZ || op == ALU_CZNEZ);
            c_czn   <= op == ALU_CZNEZ;
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
        logic [63:0] extra;
        /* verilator lint_off UNUSEDSIGNAL */      // (jalr's target only, port 0 only)
        logic [63:0] sum;
        /* verilator lint_on UNUSEDSIGNAL */
        logic        c_eq, c_lt, c_ltu;
        OOO_ALUF u_alu
            (.a(a[p]), .b(b[p]), .inv(c_inv), .a_uw(c_uw), .a_shift(c_ash),
             .g_add(c_gadd), .g_addh(c_gaddh), .g_addw(c_gaddw), .g_log(c_glog), .lop(c_lop),
             .m(c_m), .fill63(c_f63), .fill31(c_f31), .g_slw(c_gslw), .amt(c_amt), .g_slt(c_gslt), .g_sltu(c_gsltu), .g_zh(c_gzh),
             .g_sb(c_gsb), .g_sxh(c_gsxh), .g_cz(c_gcz), .cz_n(c_czn), .extra(extra),
             .result(r_d[p]), .sum(sum), .c_eq(c_eq), .c_lt(c_lt), .c_ltu(c_ltu));

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

        // the result, and what a port shares its write with
        logic own;
        assign own = ex_v && ex_wr;
        if (p == 0) begin : g_p0
            logic            s_go, j_ex;
            logic [63:0]     lk_q, ra_q, rb_q, rare;
            always_ff @(posedge clk) begin
                s_go   <= rr_v[0] && !flush && rr_wr[0] && rr_slow;
                j_ex   <= rr_jalr;
                lk_q   <= (rr_v[0] && !flush && rr_jalr && rr_wr[0]) ? rr_link : 64'd0;
                ra_q   <= a[0];
                rb_q   <= b[0];
            end
            OOO_ALUR #(.STAGE2(1'b0)) u_rare
                (.clk(clk), .op(rr_op[0]), .uw(rr_uw[0]), .word(rr_word[0]), .a(a[0]), .b(b[0]), .result(rare));
            assign extra  = lk_q | x0_d | ({64{s_go}} & rare);
            assign ev[0]  = own || x0_nv;
            assign et[0]  = ({TAGW{own}} & ex_dst) | ({TAGW{x0_nv}} & x0_nt);
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
        end else if (p == 1) begin : g_p1
            assign extra  = x1_d;
            assign ev[1]  = own || x1_nv;
            assign et[1]  = ({TAGW{own}} & ex_dst) | ({TAGW{x1_nv}} & x1_nt);
        end else begin : g_pn
            assign extra  = 64'd0;
            assign ev[p]  = own;
            assign et[p]  = ex_dst;
        end
    end

    // ---- the memory ports
    for (genvar m = 0; m < 2; m++) begin : g_m
        logic [11:0] m_i;
        logic        m_ex;
        always_ff @(posedge clk) m_i <= rr_agi[m];
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) m_ex <= 1'b0;
            else        m_ex <= rr_v[4+m] && !flush;
        end
        assign ag_v[m] = m_ex;
        assign ag[m]   = a[4+m] + {{52{m_i[11]}}, m_i};
    end
    assign sd = b[4];

endmodule : OOO_EXU2
