//---------------------------------------------------------------------------
// OOO_RAS.sv
//
// The return address stack of mmRISC-3 (Doc/UARCH.md 3.2): N entries in
// LUTRAM, circular (an overflow overwrites the oldest), pushed and popped
// speculatively at F2 by the transfer that ends a block (a call pushes the
// address after it, a return pops and is predicted to the top).
//
// Recovery as usual for a stack in a speculative front end: each block
// keeps (in the FTQ) the pointer and the entry a push would overwrite,
// `snap_ptr` / `snap_val` before its own push or pop. A misprediction puts
// them back and then does the push or pop of the mispredicted block if its
// own transfer is one (rs_push / rs_pop), in one cycle. A wrong-path push
// deeper than one entry can still be lost; that costs a misprediction of a
// return later, never a wrong instruction.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_RAS
    #(
        parameter int VA = 39,
        parameter int N  = 16           // a power of two
    )
    (
        input  logic                clk,
        input  logic                rst_n,

        output logic [VA-1:1]       top,
        output logic [$clog2(N)-1:0] snap_ptr,
        output logic [VA-1:1]       snap_val,

        input  logic                push,       // F2 (not with pop)
        input  logic [VA-1:1]       push_addr,
        input  logic                pop,

        input  logic                rs_valid,   // recovery (wins over push / pop)
        input  logic [$clog2(N)-1:0] rs_ptr,
        input  logic [VA-1:1]       rs_val,
        input  logic                rs_push,
        input  logic [VA-1:1]       rs_addr,
        input  logic                rs_pop
    );

    localparam int PW = $clog2(N);

    (* ram_style = "distributed" *) logic [VA-1:1] mem [N];
    logic [PW-1:0] ptr;

    assign top      = mem[ptr - PW'(1)];
    assign snap_ptr = ptr;
    assign snap_val = mem[ptr];

    // one write a cycle: the push, or the entry put back by a recovery
    logic          we;
    logic [PW-1:0] wa;
    logic [VA-1:1] wd;
    always @(*) begin
        we = rs_valid || push;
        wa = rs_valid ? rs_ptr : ptr;
        wd = rs_valid ? (rs_push ? rs_addr : rs_val) : push_addr;
    end
    always_ff @(posedge clk) if (we) mem[wa] <= wd;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)        ptr <= '0;
        else if (rs_valid) ptr <= rs_ptr + PW'(rs_push) - PW'(rs_pop);
        else if (push)     ptr <= ptr + PW'(1);
        else if (pop)      ptr <= ptr - PW'(1);
    end

endmodule : OOO_RAS
