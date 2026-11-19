//---------------------------------------------------------------------------
// OOO_PMP.sv
//
// Physical memory protection for the OoO core (step 1.8 P1, Plan/OOC.md 29.89):
// mmRISC-2's MMU_PMP (Rev.02, CPU_MMU/MMU_PMP; its notes hold here) for physical
// addresses of PAW bits and blocks of up to 2^(LB+2) bytes.
//
//   Combinational. The naturally aligned block of 2^size bytes that holds paddr
//   is checked at its first and its last 4-byte word: both must fall in the same
//   lowest matching entry, which must allow the access at this privilege (machine
//   mode ignores an entry that is not locked); no entry matching: machine mode
//   only. A load or store is its own block (misaligned ones trap before), the
//   walker's read 8 bytes. The fetch's block of 32 (LB 3) is checked word by word
//   (fail_w: each 4-byte word of the 2^LB-word frame that holds paddr, alone): Spike
//   checks an instruction by its 16-bit pieces, each within one word at the 4-byte
//   grain, and a test may put a region of one word inside a block of code
//   (Plan/OOC.md 29.89).
//
//   The two ends share the word address above its low LB bits, so each entry's
//   magnitude compare is made once for the shared part and the low bits decide per
//   end. pmpaddr holds 54 bits; an entry with bits above the PAW-bit address space
//   is larger than every address (TOR's bound), equal to none (NA4), and a NAPOT
//   region there matches only if its mask covers them.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module OOO_PMP
    #(
        parameter int ENTRIES = 8,
        parameter int PAW     = 40,
        parameter int LB      = 1           // the block's words: 2^LB at most (1: 8 bytes, 3: 32)
    )
    (
        input  logic [8*ENTRIES-1:0]   cfg,
        input  logic [64*ENTRIES-1:0]  addr,
        input  logic [64*ENTRIES-1:0]  mask,    // addr ^ (addr + 1) (CORE_CSR's)
        input  logic [1:0]             priv,    // the access's (MPRV taken into account; S for the walker)
        /* verilator lint_off UNUSEDSIGNAL */   // (its byte in the word: the grain is 4 bytes)
        input  logic [PAW-1:0]         paddr,
        /* verilator lint_on UNUSEDSIGNAL */
        input  logic [2:0]             size,    // 2^size bytes, 0 .. LB + 2
        input  logic                   is_read,
        input  logic                   is_write,
        input  logic                   is_exec,
        output logic                   fail,
        output logic [(1<<LB)-1:0]     fail_w   // each word of the frame alone (the fetch's)
    );

    localparam int WA = PAW - 2;            // a word address's bits
    localparam logic [1:0] A_TOR = 2'd1, A_NA4 = 2'd2, A_NAPOT = 2'd3;

    // the block's two ends, as word addresses: the upper part shared, the low LB bits each
    logic [WA-1:LB] a_up;
    logic [LB-1:0]  lo, hi, lm;             // lm: the block's words below LB, as a mask
    always @(*) begin
        lm   = '0;
        for (int k = 0; k < LB; k++) if (32'(size) > k + 2) lm[k] = 1'b1;
        a_up = paddr[PAW-1:LB+2];
        lo   = paddr[LB+1:2] & ~lm;
        hi   = paddr[LB+1:2] | lm;
    end

    logic [ENTRIES-1:0] lt_lo, lt_hi, eq_lo, eq_hi, nap_lo, nap_hi;
    logic [ENTRIES-1:0] w_lt [1<<LB];       // the same, for each word of the frame (k: a constant)
    logic [ENTRIES-1:0] w_eq [1<<LB];
    logic [ENTRIES-1:0] w_nap [1<<LB];
    always @(*) begin
        for (int i = 0; i < ENTRIES; i++) begin
            logic [53:0] ea, em;
            logic        big, nbig, up_lt, up_eq, nup;
            ea    = addr[64*i +: 54];
            em    = mask[64*i +: 54];
            big   = ea[53:WA] != '0;                              // beyond the address space
            nbig  = (ea[53:WA] & ~em[53:WA]) != '0;               // a NAPOT region there, not covering it
            up_lt = big || a_up < ea[WA-1:LB];
            up_eq = !big && a_up == ea[WA-1:LB];
            nup   = !nbig && ((a_up ^ ea[WA-1:LB]) & ~em[WA-1:LB]) == '0;
            lt_lo[i]  = up_lt || (up_eq && lo < ea[LB-1:0]);
            lt_hi[i]  = up_lt || (up_eq && hi < ea[LB-1:0]);
            eq_lo[i]  = up_eq && lo == ea[LB-1:0];
            eq_hi[i]  = up_eq && hi == ea[LB-1:0];
            nap_lo[i] = nup && ((lo ^ ea[LB-1:0]) & ~em[LB-1:0]) == '0;
            nap_hi[i] = nup && ((hi ^ ea[LB-1:0]) & ~em[LB-1:0]) == '0;
            for (int k = 0; k < (1 << LB); k++) begin
                w_lt[k][i]  = up_lt || (up_eq && LB'(k) < ea[LB-1:0]);
                w_eq[k][i]  = up_eq && LB'(k) == ea[LB-1:0];
                w_nap[k][i] = nup && ((LB'(k) ^ ea[LB-1:0]) & ~em[LB-1:0]) == '0;
            end
        end
    end

    logic [ENTRIES-1:0] m_lo, m_hi;
    always @(*) begin
        for (int i = 0; i < ENTRIES; i++) begin
            logic ge_lo, ge_hi;
            ge_lo = (i == 0) ? 1'b1 : !lt_lo[(i + ENTRIES - 1) % ENTRIES];
            ge_hi = (i == 0) ? 1'b1 : !lt_hi[(i + ENTRIES - 1) % ENTRIES];
            case (cfg[8*i+3 +: 2])
                A_TOR:   begin m_lo[i] = ge_lo && lt_lo[i]; m_hi[i] = ge_hi && lt_hi[i]; end
                A_NA4:   begin m_lo[i] = eq_lo[i];          m_hi[i] = eq_hi[i];          end
                A_NAPOT: begin m_lo[i] = nap_lo[i];         m_hi[i] = nap_hi[i];         end
                default: begin m_lo[i] = 1'b0;              m_hi[i] = 1'b0;              end
            endcase
        end
    end

    // the lowest match at each end; the answer (as MMU_PMP: no selected index, one OR)
    logic [ENTRIES-1:0] first_lo, first_hi, deny;
    always @(*) begin
        for (int i = 0; i < ENTRIES; i++) begin
            first_lo[i] = m_lo[i];
            first_hi[i] = m_hi[i];
            for (int j = 0; j < i; j++) begin
                first_lo[i] = first_lo[i] && !m_lo[j];
                first_hi[i] = first_hi[i] && !m_hi[j];
            end
            deny[i] = !((priv == 2'd3 && !cfg[8*i+7]) ||
                        (!(is_read && !cfg[8*i+0]) && !(is_write && !cfg[8*i+1]) && !(is_exec && !cfg[8*i+2])));
        end
        fail = (m_lo == '0 && (m_hi != '0 || priv != 2'd3)) || (first_lo & (deny | ~first_hi)) != '0;
    end

    // each word alone: the lowest match decides (one word: one end)
    always @(*) begin
        for (int k = 0; k < (1 << LB); k++) begin
            logic [ENTRIES-1:0] m, first;
            for (int i = 0; i < ENTRIES; i++) begin
                case (cfg[8*i+3 +: 2])
                    A_TOR:   m[i] = (i == 0 || !w_lt[k][(i + ENTRIES - 1) % ENTRIES]) && w_lt[k][i];
                    A_NA4:   m[i] = w_eq[k][i];
                    A_NAPOT: m[i] = w_nap[k][i];
                    default: m[i] = 1'b0;
                endcase
            end
            for (int i = 0; i < ENTRIES; i++) begin
                first[i] = m[i];
                for (int j = 0; j < i; j++) first[i] = first[i] && !m[j];
            end
            fail_w[k] = (m == '0 && priv != 2'd3) || (first & deny) != '0;
        end
    end

endmodule : OOO_PMP
