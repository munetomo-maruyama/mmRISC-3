//---------------------------------------------------------------------------
// OOO_FDEC2.sv
//
// F2 of the 4-wide core at 50 MHz (Doc/STRATEGY.md 4.3, 4.5 loop 4, Plan/OOC.md 29.9): what
// a 32-byte block means for fetch, in one stage: OOO_FDEC's F3 and F4 with no register
// between, so the override is at F2, override_at 2 of the model. A stage more would cost
// -2.0 % (8.46 against 8.63): nearly all from the override's bubble.
//
// What makes one stage possible is that all it starts from is in registers: the I$ and TAGE
// are read at the end of F0, their tags compared and the way chosen in F1, as OOO_TAGE
// and OOO_BTB do already. So F2 has none of the arrays' time.
//
// Every target is compared with where fetch went on, ahead of any choice, and a target's
// form is told from the parcels' bits alone (Plan/OOC.md 28.22), so that those paths run
// beside the boundaries and the choice, not after them.
//
// New against OOO_FDEC: a first half at parcel 15 stays for the next block unless the block
// ends in a taken transfer, also when the block overrides fetch. With the override in the
// block's own stage, the next block is the one that follows it when it says not taken.
//
// What is around it is not here: F0 (OOO_UBTB2 gets ovr, ovr_pc), the arrays. A block that
// fetch dropped does not come: f2_valid is for one still wanted.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_FDEC2
    #(
        parameter int VA = 39
    )
    (
        input  logic                clk,
        input  logic                rst_n,
        input  logic                flush,      // the back end's redirect

        // ---- F2: from F1's registers
        input  logic                f2_valid,
        input  logic [VA-1:5]       f2_line,
        input  logic [3:0]          f2_start,
        input  logic                f2_seq,     // it follows the block before, at parcel 0
        input  logic [255:0]        f2_data,
        input  logic [VA-1:1]       f2_expect,  // where fetch went on after it
        input  logic [2:0]          f2_hv,      // the slot's tagged table has a hit ...
        input  logic [2:0]          f2_pp,      // ... and says this
        input  logic [15:0]         f2_base,    // the base counter's direction, by parcel
        input  logic                f2_bh,      // the BTB has an indirect jump
        input  logic [3:0]          f2_boff,    // at this parcel
        input  logic [VA-1:1]       f2_btgt,

        // ---- F2: the block
        output logic                out_valid,
        output logic [15:0]         out_st,     // an instruction starts here (past the end too)
        output logic [15:0]         out_first,  // the transfer that ends it, by its last parcel
        output logic                out_cross,  // a first half at parcel 15
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

    // ---- F2: the boundaries. A first half at parcel 15 is finished in the next block
    logic [15:0] c_p;                        // that first half
    logic        c_v, c_use;
    logic [15:0] p [16];
    logic [15:0] l32, st, hi;
    assign c_use = c_v && f2_seq;
    always @(*) begin
        for (int k = 0; k < 16; k++) begin
            p[k]   = f2_data[16*k +: 16];
            l32[k] = p[k][1:0] == 2'b11;
        end
        hi[0] = c_use;
        st[0] = f2_start == 4'd0 && !c_use;
        for (int k = 1; k < 16; k++) begin
            hi[k] = st[k-1] && l32[k-1];
            st[k] = 4'(k) >= f2_start && !hi[k];
        end
    end

    // ---- F2: per end parcel, the instruction and its target
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
            tgt[e] = {f2_line, 4'(e)} + {{(VA-22){imm[20]}}, imm} - (VA-1)'(f32);
            s_e[e] = tgt[e] == f2_expect;
        end
    end

    // ---- F2: which branch of the block (3: past the slots), what cannot but be taken
    logic [1:0]  cnt [16];
    logic [15:0] uj;
    logic        b_eq, seq_eq;
    logic [VA-1:5] line_p1;
    always @(*) begin
        automatic logic [1:0] n = 2'd0;
        for (int e = 0; e < 16; e++) begin
            cnt[e] = n;
            if (br[e] && n != 2'd3) n = n + 2'd1;
            uj[e]  = jal[e] || (jalr[e] && (ret[e] || (f2_bh && f2_boff == 4'(e))));
        end
        line_p1 = f2_line + 1'b1;
        b_eq    = f2_btgt == f2_expect;
        seq_eq  = {line_p1, 4'd0} == f2_expect;
    end

    logic [15:0] ok;
    logic        strad;
    always @(*) begin
        for (int e = 0; e < 16; e++) ok[e] = (br[e] || jal[e]) ? s_e[e] : b_eq;
        strad = st[15] && l32[15];
    end

    // ---- F2: the first predicted taken
    logic [VA-1:1] top;
    logic [15:0]   tk, first;
    (* keep = "true" *) logic [15:0] first_s;  // for the compare alone: first has many others
    logic          taken;
    always @(*) begin
        for (int e = 0; e < 16; e++) begin
            automatic logic d;
            case (cnt[e])
                2'd0:    d = f2_hv[0] ? f2_pp[0] : f2_base[e];
                2'd1:    d = f2_hv[1] ? f2_pp[1] : f2_base[e];
                2'd2:    d = f2_hv[2] ? f2_pp[2] : f2_base[e];
                default: d = 1'b0;
            endcase
            tk[e] = uj[e] || (br[e] && d);
        end
        first   = tk & (~tk + 16'd1);
        first_s = tk & (~tk + 16'd1);
        taken = tk != 16'd0;
    end

    // whether fetch was right, and the next address; first picks among what is ready
    logic top_eq, same;
    logic [VA-1:1] nxt;
    assign top_eq  = top == f2_expect;
    assign ras_top = top;
    always @(*) begin
        same = (!taken && seq_eq) || ((first_s & ~ret & ok) != 16'd0) || ((first_s & ret) != 16'd0 && top_eq);
        nxt  = taken ? '0 : {line_p1, 4'd0};
        for (int e = 0; e < 16; e++)
            if (first[e]) nxt = nxt | ((br[e] || jal[e]) ? tgt[e] : ret[e] ? top : f2_btgt);
    end
    assign out_valid = f2_valid;
    assign out_st    = st;
    assign out_first = first;
    assign out_cross = strad;
    assign ovr      = f2_valid && !same && !flush;
    assign ovr_pc   = nxt;

    // what goes into the history, a cycle on: nothing here is in a hurry
    logic [15:0] tk5, first5, br5;
    logic [1:0]  cnt5 [16];
    always_ff @(posedge clk) begin
        tk5    <= tk;
        first5 <= first;
        br5    <= br;
        for (int e = 0; e < 16; e++) cnt5[e] <= cnt[e];
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

    // the first half kept, and the stack, moved by the transfer that ends the block
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)        c_v <= 1'b0;
        else if (flush)    c_v <= 1'b0;
        else if (f2_valid) c_v <= strad && !taken;
    end
    always_ff @(posedge clk) if (f2_valid) c_p <= p[15];

    logic          push, pop;
    logic [VA-1:1] paddr;
    always @(*) begin
        push = f2_valid && !flush && (first & call) != 16'd0;
        pop  = f2_valid && !flush && (first & ret) != 16'd0;
        paddr = '0;
        for (int e = 0; e < 16; e++)
            if (first[e]) paddr = paddr | (e == 15 ? {line_p1, 4'd0} : {f2_line, 4'(e + 1)});
    end
    OOO_RAS #(.VA(VA), .N(16)) u_ras
        (.clk(clk), .rst_n(rst_n), .top(top), .snap_ptr(snap_ptr), .snap_val(snap_val),
         .push(push), .push_addr(paddr), .pop(pop),
         .rs_valid(rs_valid), .rs_ptr(rs_ptr), .rs_val(rs_val),
         .rs_push(rs_push), .rs_addr(rs_addr), .rs_pop(rs_pop));

    // the uBTB learns from what F2 decided when it was wrong
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
        ub_pc    <= {f2_line, eo};
        ub_taken <= taken;
        ub_tgt   <= nxt;
        ub_cond  <= (first & br) != 16'd0;
        ub_ret   <= (first & ret) != 16'd0;
    end

endmodule : OOO_FDEC2
