//---------------------------------------------------------------------------
// OOO_RARE.sv
//
// Whether an instruction is of a rare class (Doc/UARCH.md 6.3 G2: decoded
// in slot 0 only), from its first parcel alone: a predecode of a few gates,
// so that the fetch buffer's count taken can stop a group before one
// without waiting for decode (Plan/OOC.md 26: CORE_DEC's illegal in that
// loop missed 50 MHz by 2.2 ns).
//
//   32-bit  by the major opcode: AMO (AMO / LR / SC), MISC-MEM (FENCE,
//           FENCE.I, cbo.zero), SYSTEM (CSR, ECALL, EBREAK, MRET, SRET, WFI,
//           SFENCE.VMA)
//   RVC     c.ebreak
// FP (LOAD-FP, STORE-FP, the FMAs, OP-FP; c.fld, c.fsd, c.fldsp, c.fsdsp) was
// rare until step 1.8 U2b (Plan/OOC.md 29.83): decoded in every slot since.
//
// It covers every legal instruction of those classes, and also the illegal
// encodings in those opcodes (they are decoded in slot 0 then). The other
// illegal instructions are not rare: decode reports them in every slot.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_RARE
    (
        input  logic [15:0] p,          // the first parcel
        output logic        rare
    );

    logic r32, rc;
    always @(*) begin
        case (p[6:2])
            5'b01011,                   // AMO
            5'b00011,                   // MISC-MEM
            5'b11100:                   // SYSTEM
                     r32 = 1'b1;
            default: r32 = 1'b0;
        endcase
        rc = p == 16'h9002;            // c.ebreak
    end
    assign rare = (p[1:0] == 2'b11) ? r32 : rc;

endmodule : OOO_RARE
