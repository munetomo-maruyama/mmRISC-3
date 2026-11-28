//---------------------------------------------------------------------------
// probe.sv : a cycle by cycle print of a D$ miss in OOO_CPU, bound into OOO_LSU4
//            and OOO_DMISS2 (no change to the RTL; Plan/OOC.md 29.108)
//
//   PROBE=lat/probe.sv OBJ=<dir> ./build_core.sh cpu
//   <dir>/VOOO_CPU +verilator+rand+reset+2 +plo=<cycle> +phi=<cycle> -mlat 16 -mspread 5 <elf>
//
// From cycle plo to phi (the bench's cycles from reset), a line "P <cycle> LSU ..." in each
// cycle with something on the LSU's side: rr the issues (port 1, port 0), rt a try in port 0's
// RR, miss / its asker's id, fill / dv / done_id the fill's end, cmp a load's completion, rp
// its replay, nv the register written, flush the core's flush (a replay at commit), lqc the
// loads committed; and "P <cycle> DM ..." with the miss handler's AXI4 read (st its state,
// ar valid ready, r valid ready, the last beat). Without +phi nothing is printed.
//---------------------------------------------------------------------------
module probe_lsu (input logic clk,
    input logic [1:0] rr_valid, input logic rt_v, input logic miss_valid, input logic [5:0] miss_id,
    input logic fill_done, input logic done_v, input logic [5:0] done_id,
    input logic [1:0] cmp_ld_valid, input logic [1:0] cmp_ld_rp, input logic flush_all,
    input logic [1:0] ld_nv, input logic [2:0] lq_commit);
    int cyc = 0, lo = 0, hi = 0;
    initial begin
        if (!$value$plusargs("plo=%d", lo)) lo = 0;
        if (!$value$plusargs("phi=%d", hi)) hi = 0;
    end
    always_ff @(posedge clk) begin
        cyc <= cyc + 1;
        if (cyc >= lo && cyc < hi && (rr_valid != 0 || rt_v || miss_valid || fill_done || cmp_ld_valid != 0 || flush_all || lq_commit != 0))
            $display("P %0d LSU rr=%b rt=%b miss=%b/%0d fill=%b dv=%b/%0d cmp=%b rp=%b nv=%b flush=%b lqc=%0d",
                cyc, rr_valid, rt_v, miss_valid, miss_id, fill_done, done_v, done_id, cmp_ld_valid, cmp_ld_rp, ld_nv, flush_all, lq_commit);
    end
endmodule

module probe_dm (input logic clk, input logic arvalid, input logic arready, input logic rvalid, input logic rready,
    input logic rlast, input logic [4:0] st);
    int cyc = 0, lo = 0, hi = 0;
    initial begin
        if (!$value$plusargs("plo=%d", lo)) lo = 0;
        if (!$value$plusargs("phi=%d", hi)) hi = 0;
    end
    always_ff @(posedge clk) begin
        cyc <= cyc + 1;
        if (cyc >= lo && cyc < hi && (arvalid || rvalid))
            $display("P %0d DM  st=%0d ar=%b%b r=%b%b last=%b", cyc, st, arvalid, arready, rvalid, rready, rlast);
    end
endmodule

bind OOO_LSU4 probe_lsu u_probe(.clk(clk), .rr_valid(rr_valid), .rt_v(rt_v),
    .miss_valid(miss_valid), .miss_id(6'(miss_id)), .fill_done(fill_done), .done_v(done_v), .done_id(6'(done_id)),
    .cmp_ld_valid(cmp_ld_valid), .cmp_ld_rp(cmp_ld_rp), .flush_all(flush_all), .ld_nv(ld_nv), .lq_commit(lq_commit));
bind OOO_DMISS2 probe_dm u_probe(.clk(clk), .arvalid(m_axi4_arvalid), .arready(m_axi4_arready), .rvalid(m_axi4_rvalid),
    .rready(m_axi4_rready), .rlast(m_axi4_rlast), .st(5'(st)));
