//---------------------------------------------------------------------------
// OOO_FDEC.sv
//
// F3 and F4 of the 4-issue core at 100 MHz (Doc/STRATEGY.md 4.3, Plan/OOC.md 28.21):
// what a 32-byte block means for fetch. Today's OOO_FETCH does it all in one stage, its
// predecode, slots, choice, compare and RAS in series: −4.79 ns at 10 ns, with fetch
// around it. Here:
//
//   F3  from the block in registers: where instructions start, what ends at each
//       parcel, its target; which conditional branch of the block it is; whether each
//       target is where fetch went on (every one compared, ahead of any choice)
//       (A target's form is told from the parcels' bits alone, not from the boundaries,
//       so the compares do not wait for them: a 16-bit transfer right behind a parcel
//       that only looks like a 32-bit one gets a wrong target, which the back end
//       finds: Plan/OOC.md 28.22)
//   F4  from those in registers: the first transfer predicted taken, whether fetch
//       was right, the next address. A wrong one redirects F0 (ovr), and the block
//       after the taken transfer is cut (first, for OOO_FBUF2)
//
// So 4 stages from F0 to the redirect: the model's override_at 4 (Plan/OOC.md 28.21).
//
// A branch's prediction uses its own parcel's base counter, and the slot's table if it
// has a hit, so no mux of the parcels stands in F4. The stack is read at F4 and moved
// at F4's end, so a block sees all those before it.
//
// What is around it is not here: F0 (OOO_UBTB2 gets ovr, ovr_pc), the arrays of F1, F2.
// A block that fetch dropped does not come: f3_valid is for one still wanted, and ovr
// and flush also drop the one in F3 here.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_FDEC
    #(
        parameter int VA = 39
    )
    (
        input  logic                clk,
        input  logic                rst_n,
        input  logic                flush,      // the back end's redirect

        // ---- F3: from F2's registers
        input  logic                f3_valid,
        input  logic [VA-1:5]       f3_line,
        input  logic [3:0]          f3_start,
        input  logic                f3_seq,     // it follows the block before, at parcel 0
        input  logic [255:0]        f3_data,
        input  logic [VA-1:1]       f3_expect,  // where fetch went on after it
        input  logic [2:0]          f3_hv,      // the slot's tagged table has a hit ...
        input  logic [2:0]          f3_pp,      // ... and says this
        input  logic [15:0]         f3_base,    // the base counter's direction, by parcel
        input  logic                f3_bh,      // the BTB has an indirect jump
        input  logic [3:0]          f3_boff,    // at this parcel
        input  logic [VA-1:1]       f3_btgt,

        // ---- F4: the block
        output logic                f4_valid,
        output logic [15:0]         f4_st,      // an instruction starts here (past the end too)
        output logic [15:0]         f4_first,   // the transfer that ends it, by its last parcel
        output logic                f4_cross,   // a first half at parcel 15
        output logic [255:0]        f4_data,
        output logic                ovr,        // F0 was wrong
        output logic [VA-1:1]       ovr_pc,
        output logic [1:0]          f5_hn,      // a cycle on: the slot predictions it takes
        output logic [2:0]          f5_ht,      // ... and they, slot 0 first

        // ---- the training of the uBTB: registers, a cycle after
        output logic                ub_valid,
        output logic [VA-1:1]       ub_pc,
        output logic                ub_taken,
        output logic [VA-1:1]       ub_tgt,
        output logic                ub_cond,
        output logic                ub_ret,

        // ---- the stack's recovery
        input  logic                rs_valid,
        input  logic [3:0]          rs_ptr,
        input  logic [VA-1:1]       rs_val,
        input  logic                rs_push,
        input  logic [VA-1:1]       rs_addr,
        input  logic                rs_pop,
        output logic [VA-1:1]       ras_top,    // for F0
        output logic [3:0]          snap_ptr,
        output logic [VA-1:1]       snap_val
    );

    function automatic logic link(input logic [4:0] r);
        return r == 5'd1 || r == 5'd5;
    endfunction

    // ---- F3: the boundaries. A first half at parcel 15 is finished in the next block
    logic [15:0] c_p;                        // that first half
    logic        c_v, c_use;
    logic [15:0] p [16];
    logic [15:0] l32, st, hi;
    assign c_use = c_v && f3_seq;
    always @(*) begin
        for (int k = 0; k < 16; k++) begin
            p[k]   = f3_data[16*k +: 16];
            l32[k] = p[k][1:0] == 2'b11;
        end
        hi[0] = c_use;
        st[0] = f3_start == 4'd0 && !c_use;
        for (int k = 1; k < 16; k++) begin
            hi[k] = st[k-1] && l32[k-1];
            st[k] = 4'(k) >= f3_start && !hi[k];
        end
    end

    // ---- F3: per end parcel, the instruction and its target
    logic [15:0]         br, jal, jalr, call, ret;
    logic [15:0][VA-1:1] tgt;
    logic [15:0]         s_e;                // its target is where fetch went on
    always @(*) begin
        for (int e = 0; e < 16; e++) begin
            automatic logic [31:0] i = {p[e], (e == 0) ? c_p : p[e-1]};
            automatic logic [15:0] c = p[e];
            automatic logic [20:0] imm;
            automatic logic        f32 = (e != 0 || c_use) && (i[6:0] == 7'b1100011 || i[6:0] == 7'b1101111);
            automatic logic [4:0]  rd = i[11:7];
            automatic logic [4:0]  rs1 = hi[e] ? i[19:15] : c[11:7];
            br[e] = 1'b0; jal[e] = 1'b0; jalr[e] = 1'b0; call[e] = 1'b0; ret[e] = 1'b0;
            if (hi[e]) begin
                case (i[6:0])
                    7'b1100011: br[e] = 1'b1;
                    7'b1101111: begin jal[e] = 1'b1; call[e] = link(rd); end
                    7'b1100111: if (i[14:12] == 3'b000) begin
                        jalr[e] = 1'b1; call[e] = link(rd); ret[e] = link(rs1) && !link(rd);
                    end
                    default: ;
                endcase
            end else if (st[e] && !l32[e]) begin
                if (c[1:0] == 2'b01 && c[15:13] == 3'b101) jal[e] = 1'b1;
                else if (c[1:0] == 2'b01 && c[15:14] == 2'b11) br[e] = 1'b1;
                else if (c[1:0] == 2'b10 && c[15:13] == 3'b100 && c[6:2] == 5'd0 && rs1 != 5'd0) begin
                    jalr[e] = 1'b1; call[e] = c[12]; ret[e] = !c[12] && link(rs1);
                end
            end
            if (f32)            imm = i[3] ? {{2{i[31]}}, i[19:12], i[20], i[30:21]} : {{10{i[31]}}, i[7], i[30:25], i[11:8]};
            else if (c[14])     imm = {{14{c[12]}}, c[6:5], c[2], c[11:10], c[4:3]};
            else                imm = {{11{c[12]}}, c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3]};
            tgt[e] = {f3_line, 4'(e)} + {{(VA-22){imm[20]}}, imm} - (VA-1)'(f32);
            s_e[e] = tgt[e] == f3_expect;
        end
    end

    // ---- F3: which branch of the block (3: past the slots), what cannot but be taken
    logic [1:0]  cnt [16];
    logic [15:0] uj;
    logic        b_eq, seq_eq;
    logic [VA-1:5] line_p1;
    always @(*) begin
        automatic logic [1:0] n = 2'd0;
        for (int e = 0; e < 16; e++) begin
            cnt[e] = n;
            if (br[e] && n != 2'd3) n = n + 2'd1;
            uj[e]  = jal[e] || (jalr[e] && (ret[e] || (f3_bh && f3_boff == 4'(e))));
        end
        line_p1 = f3_line + 1'b1;
        b_eq    = f3_btgt == f3_expect;
        seq_eq  = {line_p1, 4'd0} == f3_expect;
    end

    // ---- F4's registers
    logic                v4;
    logic [15:0]         st4, br4, jal4, ret4, call4, uj4, ok4, base4;
    logic [15:0][VA-1:1] tgt4;
    logic [1:0]          cnt4 [16];
    logic [2:0]          hv4, pp4;
    logic [VA-1:5]       line4, lp14;
    logic [VA-1:1]       btgt4, exp4;
    logic                seq4;
    logic                cross4;
    logic                drop;
    assign drop = flush || ovr;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v4  <= 1'b0;
            c_v <= 1'b0;
        end else begin
            v4 <= f3_valid && !drop;
            if (drop)          c_v <= 1'b0;
            else if (f3_valid) c_v <= st[15] && l32[15];
        end
    end
    always_ff @(posedge clk) begin
        st4    <= st;
        br4    <= br;
        jal4   <= jal;
        ret4   <= ret;
        call4  <= call;
        uj4    <= uj;
        for (int e = 0; e < 16; e++) ok4[e] <= (br[e] || jal[e]) ? s_e[e] : b_eq;
        base4  <= f3_base;
        tgt4   <= tgt;
        hv4    <= f3_hv;
        pp4    <= f3_pp;
        line4  <= f3_line;
        lp14   <= line_p1;
        btgt4  <= f3_btgt;
        exp4   <= f3_expect;
        seq4   <= seq_eq;
        cross4 <= st[15] && l32[15];
        f4_data <= f3_data;
        for (int e = 0; e < 16; e++) cnt4[e] <= cnt[e];
        if (f3_valid) c_p <= p[15];
    end

    // ---- F4: the first predicted taken
    logic [VA-1:1] top;
    logic [15:0]   tk, first;
    (* keep = "true" *) logic [15:0] first_s;  // for the compare alone: first has many others
    logic          taken;
    always @(*) begin
        for (int e = 0; e < 16; e++) begin
            automatic logic d;
            case (cnt4[e])
                2'd0:    d = hv4[0] ? pp4[0] : base4[e];
                2'd1:    d = hv4[1] ? pp4[1] : base4[e];
                2'd2:    d = hv4[2] ? pp4[2] : base4[e];
                default: d = 1'b0;
            endcase
            tk[e] = uj4[e] || (br4[e] && d);
        end
        first   = tk & (~tk + 16'd1);
        first_s = tk & (~tk + 16'd1);
        taken = tk != 16'd0;
    end

    // whether fetch was right, and the next address; first picks among what is ready
    logic top_eq, same;
    logic [VA-1:1] nxt;
    assign top_eq  = top == exp4;
    assign ras_top = top;
    always @(*) begin
        same = (!taken && seq4) || ((first_s & ~ret4 & ok4) != 16'd0) || ((first_s & ret4) != 16'd0 && top_eq);
        nxt  = taken ? '0 : {lp14, 4'd0};
        for (int e = 0; e < 16; e++)
            if (first[e]) nxt = nxt | ((br4[e] || jal4[e]) ? tgt4[e] : ret4[e] ? top : btgt4);
    end
    assign f4_valid = v4;
    assign f4_st    = st4;
    assign f4_first = first;
    assign f4_cross = cross4;
    assign ovr      = v4 && !same && !flush;
    assign ovr_pc   = nxt;

    // what goes into the history, a cycle on: nothing here is in a hurry
    logic [15:0] tk5, first5, br5;
    logic [1:0]  cnt5 [16];
    always_ff @(posedge clk) begin
        tk5    <= tk;
        first5 <= first;
        br5    <= br4;
        for (int e = 0; e < 16; e++) cnt5[e] <= cnt4[e];
    end
    always @(*) begin
        automatic logic [15:0] upto = first5 - 16'(first5 != 16'd0);     // the parcels before the end
        automatic logic [1:0]  n = 2'd0;
        f5_ht = 3'd0;
        for (int e = 0; e < 16; e++) begin
            if (br5[e] && cnt5[e] != 2'd3 && (first5 == 16'd0 || upto[e] || first5[e])) begin
                f5_ht[n] = tk5[e];
                n = n + 2'd1;
            end
        end
        f5_hn = n;
    end

    // the stack: moved by the transfer that ends the block
    logic          push, pop;
    logic [VA-1:1] paddr;
    always @(*) begin
        push = v4 && !flush && (first & call4) != 16'd0;
        pop  = v4 && !flush && (first & ret4) != 16'd0;
        paddr = '0;
        for (int e = 0; e < 16; e++)
            if (first[e]) paddr = paddr | (e == 15 ? {lp14, 4'd0} : {line4, 4'(e + 1)});
    end
    OOO_RAS #(.VA(VA), .N(16)) u_ras
        (.clk(clk), .rst_n(rst_n), .top(top), .snap_ptr(snap_ptr), .snap_val(snap_val),
         .push(push), .push_addr(paddr), .pop(pop),
         .rs_valid(rs_valid), .rs_ptr(rs_ptr), .rs_val(rs_val),
         .rs_push(rs_push), .rs_addr(rs_addr), .rs_pop(rs_pop));

    // the uBTB learns from what F4 decided when it was wrong
    logic [3:0] eo;
    always @(*) begin
        eo = 4'd15;
        for (int e = 15; e >= 0; e--) if (first[e]) eo = 4'(e);
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ub_valid <= 1'b0;
        else        ub_valid <= ovr && taken;
    end
    always_ff @(posedge clk) begin
        ub_pc    <= {line4, eo};
        ub_taken <= taken;
        ub_tgt   <= nxt;
        ub_cond  <= (first & br4) != 16'd0;
        ub_ret   <= (first & ret4) != 16'd0;
    end

endmodule : OOO_FDEC
