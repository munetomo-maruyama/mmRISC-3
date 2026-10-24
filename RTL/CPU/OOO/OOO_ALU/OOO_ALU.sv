//---------------------------------------------------------------------------
// OOO_ALU.sv
//
// One integer ALU of mmRISC-3: RV64I + Zba / Zbb / Zbs / Zicond.
// Combinational; the operands are already selected (register, immediate,
// pc, or the result of the first half of a fused pair, OOO_ALU2).
//
// The operations and their encoding are those of mmRISC-2's CORE_EXU
// (mmRISC-2 RTL/CPU/CPU_CORE/CORE_EXU), so that the decoder and the tests
// of mmRISC-2 carry over:
//   Zba is the adder and the left shift with two changes to the first
//   operand in front of them: its low half zero extended (a_uw, the .uw
//   forms) and a shift left by one to three (a_shift, sh1add .. sh3add).
//   word_op: the 32 bit forms (the result sign extended from bit 31).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_ALU
    (
        input  logic [63:0] op_a,
        input  logic [63:0] op_b,
        input  logic [5:0]  alu_op,
        input  logic        a_uw,         // op_a : the low half, zero extended
        input  logic [1:0]  a_shift,      // op_a : shifted left by this much
        input  logic        word_op,
        output logic [63:0] result
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
    // Zbb
    localparam logic [5:0] ALU_ANDN = 6'd10;
    localparam logic [5:0] ALU_ORN  = 6'd11;
    localparam logic [5:0] ALU_XNOR = 6'd12;
    localparam logic [5:0] ALU_MIN  = 6'd13;
    localparam logic [5:0] ALU_MINU = 6'd14;
    localparam logic [5:0] ALU_MAX  = 6'd15;
    localparam logic [5:0] ALU_MAXU = 6'd16;
    localparam logic [5:0] ALU_ROL  = 6'd17;
    localparam logic [5:0] ALU_ROR  = 6'd18;
    localparam logic [5:0] ALU_CLZ  = 6'd19;
    localparam logic [5:0] ALU_CTZ  = 6'd20;
    localparam logic [5:0] ALU_CPOP = 6'd21;
    localparam logic [5:0] ALU_SEXTB= 6'd22;
    localparam logic [5:0] ALU_SEXTH= 6'd23;
    localparam logic [5:0] ALU_ZEXTH= 6'd24;
    localparam logic [5:0] ALU_ORCB = 6'd25;
    localparam logic [5:0] ALU_REV8 = 6'd26;
    // Zicond
    localparam logic [5:0] ALU_CZEQZ= 6'd27;
    localparam logic [5:0] ALU_CZNEZ= 6'd28;
    // Zbs
    localparam logic [5:0] ALU_BSET = 6'd29;
    localparam logic [5:0] ALU_BCLR = 6'd30;
    localparam logic [5:0] ALU_BINV = 6'd31;
    localparam logic [5:0] ALU_BEXT = 6'd32;

    logic [63:0] res;
    logic [5:0]  shamt;
    logic [63:0] sh_src;
    logic [63:0] a_zx;            // op_a with the .uw change
    logic [63:0] a_add;           // and the sh*add shift : the adder's input
    logic [63:0] a_cnt;           // what clz / ctz / cpop count in
    logic [6:0]  n_clz, n_ctz, n_pop;
    logic [63:0] rot_l, rot_r;
    logic [63:0] srl_v;           // the right shift, also for bext
    logic [63:0] bmask;           // Zbs : the bit op_b names
    logic [31:0] a32;

    // counts over 64 bits; a 32 bit form puts its half where they see it
    function automatic logic [6:0] count_lz(input logic [63:0] v);
        logic [6:0] n;
        n = 7'd64;
        for (int i = 0; i < 64; i++) if (v[i]) n = 7'(63 - i);
        return n;
    endfunction
    function automatic logic [6:0] count_tz(input logic [63:0] v);
        logic [6:0] n;
        n = 7'd64;
        for (int i = 63; i >= 0; i--) if (v[i]) n = 7'(i);
        return n;
    endfunction
    function automatic logic [6:0] count_ones(input logic [63:0] v);
        logic [6:0] n;
        n = 7'd0;
        for (int i = 0; i < 64; i++) n = n + 7'(v[i]);
        return n;
    endfunction

    always @(*) begin
        a_zx  = a_uw ? {32'd0, op_a[31:0]} : op_a;
        a_add = a_zx << a_shift;
        shamt = word_op ? {1'b0, op_b[4:0]} : op_b[5:0];
        // a 32 bit shift works on the zero / sign extended low half
        if (!word_op)               sh_src = a_zx;
        else if (alu_op == ALU_SRA) sh_src = {{32{op_a[31]}}, op_a[31:0]};
        else                        sh_src = {32'd0, op_a[31:0]};

        // Zbb : the 32 bit forms work on the low half
        a32   = op_a[31:0];
        a_cnt = word_op ? {a32, 32'hFFFF_FFFF} : op_a;
        n_clz = count_lz(a_cnt);
        n_ctz = word_op ? count_tz({32'hFFFF_FFFF, a32}) : count_tz(op_a);
        n_pop = word_op ? count_ones({32'd0, a32}) : count_ones(op_a);
        if (word_op) begin
            rot_l = {32'd0, (a32 << shamt[4:0]) | (a32 >> (6'd32 - {1'b0, shamt[4:0]}))};
            rot_r = {32'd0, (a32 >> shamt[4:0]) | (a32 << (6'd32 - {1'b0, shamt[4:0]}))};
        end else begin
            rot_l = (op_a << shamt) | (op_a >> (7'd64 - {1'b0, shamt}));
            rot_r = (op_a >> shamt) | (op_a << (7'd64 - {1'b0, shamt}));
        end

        srl_v = sh_src >> shamt;
        bmask = 64'd1 << op_b[5:0];

        res = 64'd0;
        case (alu_op)
            ALU_SUB:  res = op_a - op_b;
            ALU_SLL:  res = sh_src << shamt;
            ALU_SLT:  res = {63'd0, ($signed(op_a) < $signed(op_b))};
            ALU_SLTU: res = {63'd0, (op_a < op_b)};
            ALU_XOR:  res = op_a ^ op_b;
            ALU_SRL:  res = srl_v;
            ALU_SRA:  res = $signed(sh_src) >>> shamt;
            ALU_OR:   res = op_a | op_b;
            ALU_AND:  res = op_a & op_b;
            ALU_ANDN: res = op_a & ~op_b;
            ALU_ORN:  res = op_a | ~op_b;
            ALU_XNOR: res = ~(op_a ^ op_b);
            ALU_MIN:  res = ($signed(op_a) < $signed(op_b)) ? op_a : op_b;
            ALU_MINU: res = (op_a < op_b) ? op_a : op_b;
            ALU_MAX:  res = ($signed(op_a) < $signed(op_b)) ? op_b : op_a;
            ALU_MAXU: res = (op_a < op_b) ? op_b : op_a;
            ALU_ROL:  res = rot_l;
            ALU_ROR:  res = rot_r;
            ALU_CLZ:  res = {57'd0, n_clz};
            ALU_CTZ:  res = {57'd0, n_ctz};
            ALU_CPOP: res = {57'd0, n_pop};
            ALU_SEXTB:res = {{56{op_a[7]}},  op_a[7:0]};
            ALU_SEXTH:res = {{48{op_a[15]}}, op_a[15:0]};
            ALU_ZEXTH:res = {48'd0, op_a[15:0]};
            ALU_ORCB: for (int i = 0; i < 8; i++) res[8*i +: 8] = {8{|op_a[8*i +: 8]}};
            ALU_REV8: for (int i = 0; i < 8; i++) res[8*i +: 8] = op_a[8*(7-i) +: 8];
            ALU_CZEQZ:res = (op_b == 64'd0) ? 64'd0 : op_a;
            ALU_CZNEZ:res = (op_b != 64'd0) ? 64'd0 : op_a;
            ALU_BSET: res = op_a |  bmask;
            ALU_BCLR: res = op_a & ~bmask;
            ALU_BINV: res = op_a ^  bmask;
            ALU_BEXT: res = {63'd0, srl_v[0]};
            default:  res = a_add + op_b;             // ALU_ADD, add.uw, sh*add
        endcase

        result = word_op ? {{32{res[31]}}, res[31:0]} : res;
    end

endmodule : OOO_ALU
