//---------------------------------------------------------------------------
// OOO_FUSE.sv
//
// Instruction fusion of mmRISC-3 (STRATEGY.md 4, Plan/MODEL.md 6): out of a
// group of 4 decoded instructions, form the next 2 µops; a µop is one
// instruction or a fused pair of two adjacent ones. Combinational, between
// decode and rename.
//
// Pairs (the rules of fusion_level in Plan/model/ooo.h; LEVEL enables them):
//   level 1  lui + addi        addi reads the lui's rd
//            auipc + x         x reads the auipc's rd
//            slli + srli/srai  the shift right reads the shift left's rd
//            ALU + load        the load's base is the ALU's rd (address)
//            load + load       same base and size, offsets one access apart,
//                              the first does not overwrite the base
//            store + store     same base and size, offsets one access apart
//   level 2  ALU + branch      the branch reads the ALU's rd
// The first's rd is never x0 for the pairs that pass a value on. Level 3
// (ALU + ALU, with a second ALU stage in each port) was given up at G0b
// (D-14, Doc/UARCH.md 6.3 and 6.7): fusion level 2 is the configuration.
//
// SRC2 (Plan/OOC.md 7.4): a pair reads at most 2 registers from outside,
// so that a µop needs no more than 2 register-file reads (6 ports for the
// 2 ALU ports and the LSU instead of 8 to 9). Counted as fuse_2src of
// Plan/model/ooo.h: the distinct registers the two read, without x0 and
// without the second's reads of the first's rd. It applies to every kind
// (a store pair with two data registers and a base is 3).
//
// W1 (Plan/OOC.md 7.4): a pair writes at most one register (both halves
// write none, one, or the same register), so that a µop needs one
// register-file write (3 write ports) and renaming one destination. As
// fuse_1w of Plan/model/ooo.h; a load pair (two destinations) is not fused. The model
// pairs loads and stores by their dynamic addresses (within 8 bytes); here
// it can only be the offsets, which is what Plan/OOC.md measures.
//
// The port of a µop (the issue queue's: 0 any ALU, 1 ALU0 only, 2 LSU, 3
// FPU, from the decoder) is its instruction's; a pair's is the LSU's if a
// half goes there (ALU + load, load and store pairs), else ALU0 only if a
// half is (slli + srli, an ALU + branch whose ALU operation ALU1 does not
// have: G0b L7, Doc/UARCH.md 6.12), else any ALU.
//
// Pairing is greedy from the oldest slot, as in the model: slot 0 pairs
// with slot 1 if it can, and the second µop starts after the first. A pair
// needs both slots valid and the second to follow the first in program
// order without a predicted taken transfer between them (seq). A µop that
// would pair with an instruction beyond slot 3 goes alone. no_fuse (debug
// single step, triggers, a pair being replayed after an exception) turns
// fusion off.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_FUSE
    #(
        parameter int LEVEL = 2,       // 1 or 2 (level 3 was given up, D-14)
        parameter bit SRC2  = 1'b1,
        parameter bit W1    = 1'b1
    )
    (
        input  logic        no_fuse,

        // the 4 decoded instructions, slot 0 the oldest
        input  logic [3:0]       valid,
        input  logic [3:0]       seq,       // slot k follows slot k-1 directly
        input  logic [3:0][2:0]  cls,       // 0 ALU 1 BR 2 JAL 3 JALR 4 LOAD 5 STORE 6 MUL/DIV 7 other
        input  logic [3:0][2:0]  op,        // 0 other 1 lui 2 auipc 3 slli 4 srli/srai 5 add 6 addi
        input  logic [3:0][4:0]  rd,        // 0 when it writes no register
        input  logic [3:0][4:0]  rs1,
        input  logic [3:0][4:0]  rs2,
        input  logic [3:0]       use_rs1,
        input  logic [3:0]       use_rs2,
        input  logic [3:0][11:0] imm,       // offset of a load / store
        input  logic [3:0][1:0]  msize,     // 0 byte .. 3 double
        input  logic [3:0][1:0]  port,      // OOO_DEC: 0 any ALU, 1 ALU0 only, 2 LSU, 3 FPU

        output logic             u0_valid,
        output logic [1:0]       u0_slot,   // first instruction of the µop
        output logic [3:0]       u0_kind,   // 0 alone, else the kind of pair (below)
        output logic [1:0]       u0_port,   // the issue queue's port of the µop (above)
        output logic             u1_valid,
        output logic [1:0]       u1_slot,
        output logic [3:0]       u1_kind,
        output logic [1:0]       u1_port,
        output logic [2:0]       consumed   // instructions taken out of the group
    );

    localparam logic [2:0] C_ALU = 3'd0, C_BR = 3'd1, C_LOAD = 3'd4, C_STORE = 3'd5;
    localparam logic [2:0] O_LUI = 3'd1, O_AUIPC = 3'd2, O_SLLI = 3'd3, O_SRLI = 3'd4, O_ADDI = 3'd6;

    localparam logic [3:0] K_NONE = 4'd0, K_LUI = 4'd1, K_AUIPC = 4'd2, K_SHIFT = 4'd3,
                           K_ALU_LD = 4'd4, K_LD_LD = 4'd5, K_ST_ST = 4'd6,
                           K_ALU_BR = 4'd7;

    // more than 2 registers read from outside by slot k + slot k+1
    function automatic logic over2(input int k);
        logic [4:0] c [4];
        logic [3:0] v;
        logic [2:0] n;
        c[0] = rs1[k];   v[0] = use_rs1[k]   && rs1[k]   != 5'd0;
        c[1] = rs2[k];   v[1] = use_rs2[k]   && rs2[k]   != 5'd0;
        c[2] = rs1[k+1]; v[2] = use_rs1[k+1] && rs1[k+1] != 5'd0 && rs1[k+1] != rd[k];
        c[3] = rs2[k+1]; v[3] = use_rs2[k+1] && rs2[k+1] != 5'd0 && rs2[k+1] != rd[k];
        n = 3'd0;
        for (int i = 0; i < 4; i++) begin
            logic dup;
            dup = 1'b0;
            for (int j = 0; j < i; j++) dup = dup || (v[j] && c[j] == c[i]);
            n = n + 3'(v[i] && !dup);
        end
        return n > 3'd2;
    endfunction

    // the kind of pair slot k + slot k+1 would make (k = 0 .. 2), by the
    // rules alone (the source limit is applied where it is called: Yosys
    // does not take a function called from a function)
    function automatic logic [3:0] pair_kind(input int k);
        logic [4:0]  d;
        logic        rd_b;      // the second reads the first's rd
        logic        adj;       // offsets one access apart
        logic [12:0] diff;
        logic [12:0] step;
        d    = rd[k];
        rd_b = (d != 5'd0) && ((use_rs1[k+1] && rs1[k+1] == d) || (use_rs2[k+1] && rs2[k+1] == d));
        step = 13'd1 << msize[k];
        diff = {imm[k+1][11], imm[k+1]} - {imm[k][11], imm[k]};
        adj  = (msize[k] == msize[k+1]) && (diff == step || diff == -step);
        if (op[k] == O_LUI && op[k+1] == O_ADDI && d != 5'd0 && rs1[k+1] == d)
            return K_LUI;
        if (op[k] == O_AUIPC && rd_b)
            return K_AUIPC;
        if (op[k] == O_SLLI && op[k+1] == O_SRLI && d != 5'd0 && rs1[k+1] == d)
            return K_SHIFT;
        if (cls[k] == C_ALU && cls[k+1] == C_LOAD && d != 5'd0 && rs1[k+1] == d)
            return K_ALU_LD;
        if (cls[k] == C_LOAD && cls[k+1] == C_LOAD && rs1[k] == rs1[k+1] && d != rs1[k] && adj)
            return K_LD_LD;
        if (cls[k] == C_STORE && cls[k+1] == C_STORE && rs1[k] == rs1[k+1] && adj)
            return K_ST_ST;
        if (LEVEL >= 2 && cls[k] == C_ALU && cls[k+1] == C_BR && rd_b)
            return K_ALU_BR;
        return K_NONE;
    endfunction

    logic [2:0][3:0] pk;      // pair kind of k + k+1, when both are there
    always @(*) begin
        for (int k = 0; k < 3; k++)
            pk[k] = (!no_fuse && valid[k] && valid[k+1] && seq[k+1] && !(SRC2 && over2(k)) &&
                     !(W1 && rd[k] != 5'd0 && rd[k+1] != 5'd0 && rd[k] != rd[k+1])) ? pair_kind(k) : K_NONE;
    end

    // the port of a µop starting at slot k, alone or with slot k+1
    function automatic logic [1:0] uport(input logic [1:0] k, input logic paired);
        logic [1:0] a, b;
        a = port[k];
        b = (paired && k != 2'd3) ? port[k + 2'd1] : port[k];
        if (a == 2'd2 || b == 2'd2)      return 2'd2;
        else if (a == 2'd1 || b == 2'd1) return 2'd1;
        else                             return a;
    endfunction

    always @(*) begin
        logic [2:0] s1;       // where the second µop starts
        u0_valid = valid[0];
        u0_slot  = 2'd0;
        u0_kind  = pk[0];
        s1       = (pk[0] != K_NONE) ? 3'd2 : 3'd1;
        u1_valid = valid[0] && (s1 < 3'd4) && valid[s1[1:0]];
        u1_slot  = s1[1:0];
        u1_kind  = (s1 < 3'd3) ? pk[s1[1:0]] : K_NONE;
        u0_port  = uport(2'd0, pk[0] != K_NONE);
        u1_port  = uport(s1[1:0], u1_kind != K_NONE);
        if (!u0_valid)      consumed = 3'd0;
        else if (!u1_valid) consumed = s1;
        else                consumed = s1 + ((u1_kind != K_NONE) ? 3'd2 : 3'd1);
    end

endmodule : OOO_FUSE
