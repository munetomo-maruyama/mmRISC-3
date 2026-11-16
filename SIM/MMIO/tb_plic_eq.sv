// tb_plic_eq.sv : CPU_PLIC (RTL/CPU/MMIO) beside mmRISC-2's (CPU_PLIC_MM2.sv), the same inputs (SIM/MMIO/README.md)
module tb_plic_eq(input logic clk, rst_n, sel, we, input logic [21:0] addr, input logic [63:0] wdata,
           input logic [7:0] wstrb, input logic [31:0] src,
           output logic [63:0] rd_new, rd_old, output logic [1:0] irq_new, irq_old);
    CPU_PLIC     u_n(.clk, .rst_n, .sel, .we, .addr, .wdata, .wstrb, .rdata(rd_new), .src, .irq(irq_new));
    CPU_PLIC_MM2 u_o(.clk, .rst_n, .sel, .we, .addr, .wdata, .wstrb, .rdata(rd_old), .src, .irq(irq_old));
endmodule
