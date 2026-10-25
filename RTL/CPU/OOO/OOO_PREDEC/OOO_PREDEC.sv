//---------------------------------------------------------------------------
// OOO_PREDEC.sv
//
// Predecode of mmRISC-3 (F2, Doc/UARCH.md 3.1): the control transfers of a
// 16-byte fetch block, found from the instruction bits as they come out of
// the I$, for the predictors' decision in the same cycle.
//
// The block is the line `line` from parcel `start` (fetch starts in the
// middle of a line after a taken transfer). When `carry_v`, parcel 0 is the
// second half of a 32-bit instruction whose first half (`carry`) was parcel
// 7 of the line before; that instruction belongs to this block (it is
// complete only here), so a block that ends with the first half of a
// 32-bit instruction at parcel 7 gives `cross_out` and leaves the instruction
// to the next one.
//
// Everything is given per end parcel e (0 .. 7), the parcel of an
// instruction's last half, which is where a block ends when that
// instruction is a taken transfer:
//   iv      an instruction ends at e
//   br      conditional branch (beq .. bgeu, c.beqz, c.bnez)
//   jal     jal, c.j
//   jalr    jalr, c.jr, c.jalr
//   call    jal / jalr writing x1 or x5 (a return address to push)
//   ret     jalr reading x1 or x5 and not writing them (pop)
//   tgt     the target of br / jal (pc-relative), as a halfword address
// The targets of all 8 parcels are computed in parallel (one adder each),
// so that the choice of the first taken transfer is followed only by a
// select.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_PREDEC
    #(
        parameter int VA = 39
    )
    (
        input  logic [VA-1:4]           line,
        input  logic [2:0]              start,
        input  logic                    carry_v,
        input  logic [15:0]             carry,
        input  logic [127:0]            data,

        output logic [7:0]              iv,
        output logic [7:0]              br,
        output logic [7:0]              jal,
        output logic [7:0]              jalr,
        output logic [7:0]              call,
        output logic [7:0]              ret,
        output logic [7:0][VA-1:1]      tgt,
        output logic                    cross_out
    );

    function automatic logic link(input logic [4:0] r);
        return r == 5'd1 || r == 5'd5;
    endfunction

    logic [15:0] p [8];
    logic [7:0]  l32;                   // parcel p would start a 32-bit instruction
    logic [7:0]  st;                    // an instruction starts at parcel p
    logic [7:0]  hi;                    // parcel p is the second half of a 32-bit instruction
    always @(*) begin
        for (int k = 0; k < 8; k++) begin
            p[k]   = data[16*k +: 16];
            l32[k] = p[k][1:0] == 2'b11;
        end
        // the boundaries, from the start (or from the carried instruction)
        hi[0] = carry_v;
        st[0] = start == 3'd0 && !carry_v;
        for (int k = 1; k < 8; k++) begin
            hi[k] = st[k-1] && l32[k-1];
            st[k] = 3'(k) >= start && !hi[k];
        end
        cross_out = st[7] && l32[7];
    end

    // ---- per end parcel: the instruction, its kind and target
    always @(*) begin
        for (int e = 0; e < 8; e++) begin
            logic [31:0] i;
            logic [15:0] c;
            logic [20:0] imm;           // the offset in halfwords (a signed 21-bit value)
            logic [4:0]  rd, rs1;
            i   = {p[e], (e == 0) ? carry : p[(e + 7) % 8]};
            c   = p[e];
            iv[e]    = hi[e] || (st[e] && !l32[e]);
            br[e] = 1'b0; jal[e] = 1'b0; jalr[e] = 1'b0; call[e] = 1'b0; ret[e] = 1'b0;
            imm = '0;
            if (hi[e]) begin
                rd  = i[11:7];
                rs1 = i[19:15];
                case (i[6:0])
                    7'b1100011: begin                       // BRANCH
                        br[e] = 1'b1;
                        imm   = {{10{i[31]}}, i[7], i[30:25], i[11:8]};
                    end
                    7'b1101111: begin                       // JAL
                        jal[e]  = 1'b1;
                        call[e] = link(rd);
                        imm     = {{2{i[31]}}, i[19:12], i[20], i[30:21]};
                    end
                    7'b1100111: if (i[14:12] == 3'b000) begin   // JALR
                        jalr[e] = 1'b1;
                        call[e] = link(rd);
                        ret[e]  = link(rs1) && !link(rd);
                    end
                    default: ;
                endcase
            end else begin
                rd  = 5'd0;
                rs1 = c[11:7];
                if (c[1:0] == 2'b01 && c[15:13] == 3'b101) begin            // C.J
                    jal[e] = 1'b1;
                    imm    = {{11{c[12]}}, c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3]};
                end else if (c[1:0] == 2'b01 && c[15:14] == 2'b11) begin    // C.BEQZ, C.BNEZ
                    br[e] = 1'b1;
                    imm   = {{14{c[12]}}, c[6:5], c[2], c[11:10], c[4:3]};
                end else if (c[1:0] == 2'b10 && c[15:13] == 3'b100 && c[6:2] == 5'd0 && rs1 != 5'd0) begin
                    jalr[e] = 1'b1;                                         // C.JR, C.JALR
                    call[e] = c[12];
                    ret[e]  = !c[12] && link(rs1);
                end
            end
            if (!iv[e]) begin
                br[e] = 1'b0; jal[e] = 1'b0; jalr[e] = 1'b0; call[e] = 1'b0; ret[e] = 1'b0;
            end
            // the instruction's address is its last parcel, less one for a
            // 32-bit one; the target is that plus the offset
            tgt[e] = {line, 3'(e)} + {{(VA-22){imm[20]}}, imm} - (VA-1)'(hi[e]);
        end
    end

endmodule : OOO_PREDEC
