#
# mmRISC-3 core support for the LiteX SoC (step 2.6, Doc/STRATEGY.md): the
# out-of-order RV64GC core of this repository in place of mmRISC-2, on the
# Nexys Video, with what steps 2.1 to 2.5 set up around mmRISC-2 (cpu/mmrisc):
# LiteX at 100 MHz and the CPU at 50 MHz in a clock domain of its own, the
# buses crossed here, the debug port on Pmod JA.
#
# The CPU is RTL/CPU/TOP/CPU_TOP: OOO_CPU (the core, a 128 KB I$, a 128 KB D$
# written back, a 512 KB L2, the CLINT and the PLIC) with DBG_TOP (the debug
# module, JTAG / cJTAG) and a DMA port. Its buses:
#
#   memory bus     AXI4       the L2's line bursts. OOO_ICACHE caches every
#                             fetch, so the BIOS's ROM is fetched here too: the
#                             bus is split by address, main RAM (from
#                             0x8000_0000) to LiteDRAM, the ROM's region onto
#                             the SoC bus (a Wishbone master: the ROM's lines),
#                             anything else answered at once with DECERR
#                             (AXIErrorSlave): the core fetches speculatively
#                             from wherever a prediction points, and the SoC
#                             bus would hold an address no slave decodes until
#                             its timeout (1M cycles; the first simulation hung
#                             so on a fetch of address 0), and would read
#                             devices
#   peripheral bus AXI4-Lite  the D$'s accesses outside [0x8000_0000,
#                             0x1_0000_0000), single beats, as Wishbone here
#                             (the BIOS's data and stack in the SRAM, the CSRs,
#                             the Ethernet buffers, the ROM's read-only data)
#   DMA bus        AXI4-Lite  a slave: the SoC's DMA masters (the SD card)
#                             reach memory through the D$, coherent with the
#                             CPU (CPU_TOP's DMA port on OOO_CPU's bus master
#                             port, shared with the debug module)
#
# What differs from cpu/mmrisc (mmRISC-2):
#   - the reset vector, the CLINT's divider, the L2's size are CPU_TOP's
#     parameters; the start after a reset is CPU_TOP's own;
#   - the fetch from the ROM goes over the memory bus (above), cached in the
#     I$ and the L2 (mmRISC-2 fetched it uncached, a word at a time over the
#     peripheral bus: about 14 CPU cycles a word, BRINGUP 22);
#   - the cacheable memory is OOO_CPU's [CBASE, CTOP) = [0x8000_0000,
#     0x1_0000_0000) for the D$ (mmRISC-2's: everything from MEM_BASE);
#   - the debug module's IDCODE 0x36d6d001 (mmRISC-2 0x26d6d001), misa with B
#     (0x800000000014112f).
#
# LiteX finds this file by itself (litex/soc/cores/cpu/__init__.py collects
# every directory holding a core.py in the working directory): build_soc.sh
# runs from LitexSystem/cpu with --cpu-type mmrisc3.
#

import os

from migen import *

from litex.gen import *

from migen.genlib.cdc import MultiReg

from litex.soc.interconnect import axi
from litex.soc.interconnect import wishbone

from litex.soc.integration.soc import SoCRegion

from litex.build.generic_platform import Subsignal, Pins, IOStandard, Misc

from litex.soc.cores.cpu import CPU, CPU_GCC_TRIPLE_RISCV64

CPU_DIR  = os.path.dirname(os.path.realpath(__file__))
REPO_DIR = os.path.abspath(os.path.join(CPU_DIR, "..", "..", ".."))
RTL_DIR  = os.path.join(REPO_DIR, "RTL", "CPU")

# OOO_CPU's sources as SIM/CORE/build_core.sh and SIM/OCD/run_ocd.sh read
# them, then the debug logic and CPU_TOP.
RTL_SOURCES = [
    "OOO/OOO_UBTB2/OOO_UBTB2.sv", "OOO/OOO_FDEC2/OOO_FDEC2.sv", "OOO/OOO_TAGE2/OOO_TAGE2.sv",
    "OOO/OOO_BTB/OOO_BTB.sv", "OOO/OOO_RAS/OOO_RAS.sv", "OOO/OOO_FETCH2/OOO_FETCH2.sv",
    "OOO/OOO_FTQ/OOO_FTQ.sv", "OOO/OOO_FERS/OOO_FERS.sv", "OOO/OOO_FBUF3/OOO_FBUF3.sv",
    "CORE/CORE_DECOMP/CORE_DECOMP.sv", "CORE/CORE_DEC/CORE_DEC.sv", "OOO/OOO_RARE/OOO_RARE.sv",
    "OOO/OOO_DEC/OOO_DEC.sv", "OOO/OOO_FRONT/OOO_FRONT.sv", "OOO/OOO_RENAME2/OOO_RENAME2.sv",
    "OOO/OOO_BUSY/OOO_BUSY.sv", "OOO/OOO_CTRL/OOO_CTRL.sv", "OOO/OOO_DSREG/OOO_DSREG.sv",
    "OOO/OOO_ROB/OOO_ROB.sv", "OOO/OOO_IQ3/OOO_IQ3.sv", "OOO/OOO_IQPL2/OOO_IQPL2.sv",
    "OOO/OOO_STAGE/OOO_STAGE.sv", "OOO/OOO_ALU/OOO_ALU.sv", "OOO/OOO_ALU2/OOO_ALU2.sv",
    "OOO/OOO_PRF/OOO_PRF.sv", "OOO/OOO_DTLB3/OOO_DTLB3.sv", "OOO/OOO_PMP/OOO_PMP.sv",
    "OOO/OOO_PTW/OOO_PTW.sv", "OOO/OOO_DCH2/OOO_DCH2.sv", "OOO/OOO_LSU4/OOO_LSU4.sv",
    "CORE/CORE_CSR/CORE_CSR.sv", "OOO/OOO_CSRU/OOO_CSRU.sv", "OOO/OOO_TRAP/OOO_TRAP.sv",
    "OOO/OOO_DBG/OOO_DBG.sv", "OOO/OOO_SYS/OOO_SYS.sv", "OOO/OOO_PMUL/OOO_PMUL.sv",
    "CORE/CORE_MDU/CORE_MDU.sv", "OOO/OOO_MDUP/OOO_MDUP.sv",
    "FPU/FPU_ROUND/FPU_ROUND.sv", "FPU/FPU_PIPE/FPU_PIPE.sv", "OOO/OOO_FREN/OOO_FREN.sv",
    "OOO/OOO_FIQ/OOO_FIQ.sv", "OOO/OOO_FPUW/OOO_FPUW.sv", "OOO/OOO_CORE/OOO_CORE.sv",
    "OOO/OOO_DMISS2/OOO_DMISS2.sv", "OOO/OOO_ICACHE/OOO_ICACHE.sv", "OOO/OOO_MARB/OOO_MARB.sv",
    "CACHE/CACHE_DATA_ARRAY/CACHE_DATA_ARRAY.sv", "CACHE/CPU_L2/L2_TAG_ARRAY.sv", "CACHE/CPU_L2/CPU_L2.sv",
    "MMIO/CPU_CLINT/CPU_CLINT.sv", "MMIO/CPU_PLIC/CPU_PLIC.sv", "MMIO/CPU_MMIO/CPU_MMIO.sv",
    "OOO/OOO_CPU/OOO_CPU.sv",
    "DBG/DBG_CDC/DBG_CDC.sv", "DBG/DBG_CJTAG/DBG_CJTAG.sv", "DBG/DBG_DTM/DBG_DTM.sv",
    "DBG/DBG_DM/DBG_DM.sv", "DBG/DBG_TOP/DBG_TOP.sv",
    "TOP/CPU_TOP.sv",
]


# An AXI4 slave that answers everything with DECERR: a read with its beats (data
# 0, the last marked), a write after its last beat. One of each at a time.
class AXIErrorSlave(LiteXModule):
    def __init__(self, bus):
        r_busy = Signal()
        r_id   = Signal(len(bus.ar.id))
        r_left = Signal(8)
        self.comb += [
            bus.ar.ready.eq(~r_busy),
            bus.r.valid.eq(r_busy),
            bus.r.id.eq(r_id),
            bus.r.data.eq(0),
            bus.r.resp.eq(0b11),
            bus.r.last.eq(r_left == 0),
        ]
        self.sync += [
            If(bus.ar.valid & bus.ar.ready,
                r_busy.eq(1), r_id.eq(bus.ar.id), r_left.eq(bus.ar.len),
            ).Elif(bus.r.valid & bus.r.ready,
                If(r_left == 0, r_busy.eq(0)).Else(r_left.eq(r_left - 1)),
            )
        ]
        w_busy = Signal()
        b_out  = Signal()
        w_id   = Signal(len(bus.aw.id))
        self.comb += [
            bus.aw.ready.eq(~w_busy & ~b_out),
            bus.w.ready.eq(w_busy),
            bus.b.valid.eq(b_out),
            bus.b.id.eq(w_id),
            bus.b.resp.eq(0b11),
        ]
        self.sync += [
            If(bus.aw.valid & bus.aw.ready, w_busy.eq(1), w_id.eq(bus.aw.id)),
            If(bus.w.valid & bus.w.ready & bus.w.last, w_busy.eq(0), b_out.eq(1)),
            If(bus.b.valid & bus.b.ready, b_out.eq(0)),
        ]


class MMRISC3(CPU):
    category             = "softcore"
    family               = "riscv"
    name                 = "mmrisc3"
    human_name           = "mmRISC-3 (RV64GC)"
    variants             = ["standard"]
    data_width           = 64
    endianness           = "little"
    gcc_triple           = CPU_GCC_TRIPLE_RISCV64
    linker_output_format = "elf64-littleriscv"
    nop                  = "nop"

    # the PLIC's sources 1 to 31: LiteX's interrupt i is source i + 1
    num_irq              = 32

    # --cpu-jtag : "pmoda" puts the debug port on Pmod JA, "none" ties it off
    jtag                 = "none"
    # the key of the authentication (SW2 up), as mmRISC-2's
    auth_key             = 0xbeefcafe
    # --cpu-l2-size : OOO_CPU's L2 (RTL/CPU/CACHE/CPU_L2), bytes; 512 KB is
    # what mmRISC-3 was designed and timed with (Plan/OOC.md 29.70)
    l2_size              = 512 * 1024
    # --cpu-clk-freq : None runs the CPU on sys
    cpu_clk_freq         = None

    @staticmethod
    def args_fill(parser):
        cpu_group = parser.add_argument_group(title="CPU options")
        cpu_group.add_argument("--cpu-jtag", default="none", choices=["pmoda", "none"],
            help="Debug port of mmRISC-3: PMOD JA (JTAG / cJTAG) or tied off.")
        cpu_group.add_argument("--cpu-l2-size", default=512 * 1024, type=int,
            help="L2 cache of mmRISC-3 in bytes.")
        cpu_group.add_argument("--cpu-clk-freq", default=None, type=float,
            help="Clock of mmRISC-3 (its own domain, buses crossed to sys); default: sys's.")

    @staticmethod
    def args_read(args):
        MMRISC3.jtag    = args.cpu_jtag
        MMRISC3.l2_size = args.cpu_l2_size
        if args.cpu_clk_freq:
            MMRISC3.cpu_clk_freq = int(args.cpu_clk_freq)
            MMRISC3.human_name   = "mmRISC-3 (RV64GC, CPU {:g}MHz)".format(args.cpu_clk_freq / 1e6)

    # As cpu/mmrisc: LiteX refuses the ROM in an IO region, so the ROM and the
    # SRAM are declared cacheable. The D$ never caches them (outside CBASE);
    # the I$ and the L2 cache the ROM's lines (read only, so nothing goes
    # stale), and nothing is fetched from the SRAM.
    io_regions           = {0x1200_0000: 0x6e00_0000}  # Origin, Length.

    @property
    def mem_map(self):
        return {
            "clint"    : 0x0200_0000,
            "plic"     : 0x0c00_0000,
            "rom"      : 0x1000_0000,
            "sram"     : 0x1100_0000,
            "csr"      : 0x1200_0000,
            "ethmac"   : 0x3000_0000,
            "main_ram" : 0x8000_0000,
        }

    @staticmethod
    def get_arch(variant="standard"):
        return "rv64i2p0_mafdc"

    @property
    def gcc_flags(self):
        flags =  "-mno-save-restore "
        flags += f"-march={self.get_arch(self.variant)} -mabi=lp64 "
        flags += "-D__mmrisc__ "
        flags += "-D__riscv_plic__ "
        flags += "-mcmodel=medany"
        return flags

    def __init__(self, platform, variant="standard"):
        self.platform  = platform
        self.variant   = variant

        self.reset     = Signal()
        self.interrupt = Signal(self.num_irq - 1)

        # The buses as LiteX sees them, in sys: the memory bus to LiteDRAM
        # (main RAM only, the address decoded in add_soc_components), the
        # peripheral bus to the SoC bus, the DMA bus from it.
        self.mem_axi    = axi.AXIInterface(data_width=64, address_width=32, id_width=4)
        self.mmio_axil  = mmio_axil = axi.AXILiteInterface(data_width=64, address_width=32)
        self.mmio_wb    = mmio_wb   = wishbone.Interface(data_width=64,
                                          adr_width=32 - log2_int(64 // 8),
                                          addressing="word")
        self.dram_axi   = axi.AXIInterface(data_width=64, address_width=32, id_width=4)
        # the memory bus's other part, the ROM's lines: a master on the SoC bus
        self.fetch_wb   = wishbone.Interface(data_width=64,
                                          adr_width=32 - log2_int(64 // 8),
                                          addressing="word")

        self.memory_buses = [self.dram_axi]
        self.periph_buses = [mmio_wb]
        # Declared, so LiteX puts its DMA masters here and defines
        # CPU_HAS_DMA_BUS (the BIOS skips its flushes after a transfer).
        self.dma_bus    = axi.AXILiteInterface(data_width=64, address_width=32)

        # ... and as CPU_TOP drives them, in the CPU's clock domain.
        self.cpu_mem    = cpu_mem   = axi.AXIInterface(data_width=64, address_width=32, id_width=4)
        self.cpu_mmio   = cpu_mmio  = axi.AXILiteInterface(data_width=64, address_width=32)
        self.cpu_dma    = cpu_dma   = axi.AXILiteInterface(data_width=64, address_width=32)

        # # #

        # CPU_TOP's addresses are 40 bits; everything here is below 4 GB.
        awaddr_40  = Signal(40)
        araddr_40  = Signal(40)
        mmio_aw_40 = Signal(40)
        mmio_ar_40 = Signal(40)
        self.comb += [
            cpu_mem.aw.addr.eq(awaddr_40),
            cpu_mem.ar.addr.eq(araddr_40),
            cpu_mmio.aw.addr.eq(mmio_aw_40),
            cpu_mmio.ar.addr.eq(mmio_ar_40),
            # what OOO_CPU does not drive: normal, non-secure data accesses
            cpu_mem.aw.lock.eq(0), cpu_mem.aw.cache.eq(0b0011), cpu_mem.aw.prot.eq(0), cpu_mem.aw.qos.eq(0),
            cpu_mem.ar.lock.eq(0), cpu_mem.ar.cache.eq(0b0011), cpu_mem.ar.prot.eq(0), cpu_mem.ar.qos.eq(0),
            cpu_mmio.aw.prot.eq(0), cpu_mmio.ar.prot.eq(0),
        ]

        self.cpu_params = dict(
            p_L2_SIZE        = self.l2_size,

            o_ndmreset       = Open(),

            # Memory bus (AXI4).
            o_m_axi4_awid    = cpu_mem.aw.id,
            o_m_axi4_awaddr  = awaddr_40,
            o_m_axi4_awlen   = cpu_mem.aw.len,
            o_m_axi4_awsize  = cpu_mem.aw.size,
            o_m_axi4_awburst = cpu_mem.aw.burst,
            o_m_axi4_awvalid = cpu_mem.aw.valid,
            i_m_axi4_awready = cpu_mem.aw.ready,
            o_m_axi4_wdata   = cpu_mem.w.data,
            o_m_axi4_wstrb   = cpu_mem.w.strb,
            o_m_axi4_wlast   = cpu_mem.w.last,
            o_m_axi4_wvalid  = cpu_mem.w.valid,
            i_m_axi4_wready  = cpu_mem.w.ready,
            i_m_axi4_bresp   = cpu_mem.b.resp,
            i_m_axi4_bvalid  = cpu_mem.b.valid,
            o_m_axi4_bready  = cpu_mem.b.ready,
            o_m_axi4_arid    = cpu_mem.ar.id,
            o_m_axi4_araddr  = araddr_40,
            o_m_axi4_arlen   = cpu_mem.ar.len,
            o_m_axi4_arsize  = cpu_mem.ar.size,
            o_m_axi4_arburst = cpu_mem.ar.burst,
            o_m_axi4_arvalid = cpu_mem.ar.valid,
            i_m_axi4_arready = cpu_mem.ar.ready,
            i_m_axi4_rdata   = cpu_mem.r.data,
            i_m_axi4_rresp   = cpu_mem.r.resp,
            i_m_axi4_rlast   = cpu_mem.r.last,
            i_m_axi4_rvalid  = cpu_mem.r.valid,
            o_m_axi4_rready  = cpu_mem.r.ready,

            # Peripheral bus (AXI4-Lite).
            o_m_axil_awaddr  = mmio_aw_40,
            o_m_axil_awvalid = cpu_mmio.aw.valid,
            i_m_axil_awready = cpu_mmio.aw.ready,
            o_m_axil_wdata   = cpu_mmio.w.data,
            o_m_axil_wstrb   = cpu_mmio.w.strb,
            o_m_axil_wvalid  = cpu_mmio.w.valid,
            i_m_axil_wready  = cpu_mmio.w.ready,
            i_m_axil_bresp   = cpu_mmio.b.resp,
            i_m_axil_bvalid  = cpu_mmio.b.valid,
            o_m_axil_bready  = cpu_mmio.b.ready,
            o_m_axil_araddr  = mmio_ar_40,
            o_m_axil_arvalid = cpu_mmio.ar.valid,
            i_m_axil_arready = cpu_mmio.ar.ready,
            i_m_axil_rdata   = cpu_mmio.r.data,
            i_m_axil_rresp   = cpu_mmio.r.resp,
            i_m_axil_rvalid  = cpu_mmio.r.valid,
            o_m_axil_rready  = cpu_mmio.r.ready,

            # DMA bus (AXI4-Lite slave), 32 bit addresses made 40 bit.
            i_s_dma_awaddr   = Cat(cpu_dma.aw.addr, C(0, 8)),
            i_s_dma_awvalid  = cpu_dma.aw.valid,
            o_s_dma_awready  = cpu_dma.aw.ready,
            i_s_dma_wdata    = cpu_dma.w.data,
            i_s_dma_wstrb    = cpu_dma.w.strb,
            i_s_dma_wvalid   = cpu_dma.w.valid,
            o_s_dma_wready   = cpu_dma.w.ready,
            o_s_dma_bresp    = cpu_dma.b.resp,
            o_s_dma_bvalid   = cpu_dma.b.valid,
            i_s_dma_bready   = cpu_dma.b.ready,
            i_s_dma_araddr   = Cat(cpu_dma.ar.addr, C(0, 8)),
            i_s_dma_arvalid  = cpu_dma.ar.valid,
            o_s_dma_arready  = cpu_dma.ar.ready,
            o_s_dma_rdata    = cpu_dma.r.data,
            o_s_dma_rresp    = cpu_dma.r.resp,
            o_s_dma_rvalid   = cpu_dma.r.valid,
            i_s_dma_rready   = cpu_dma.r.ready,

            # JTAG: tied off here, wired to PMOD JA by add_jtag.
            i_jtag_tck       = 0,
            i_jtag_tms_i     = 0,
            o_jtag_tms_o     = Open(),
            o_jtag_tms_oe    = Open(),
            i_jtag_tdi       = 0,
            o_jtag_tdo       = Open(),
            o_jtag_tdo_oe    = Open(),
            i_jtag_trst_n    = 1,
            i_cjtag_en       = 0,
            o_cjtag_online   = Open(),
            i_dbg_auth_en    = 0,
            i_dbg_auth_key   = 0,
            o_dbg_halted     = Open(),
            o_dbg_running    = Open(),
            o_dbg_dmactive   = Open(),
        )

        if self.jtag == "pmoda":
            self.add_jtag(platform)

        self.submodules += axi.AXILite2Wishbone(mmio_axil, mmio_wb, base_address=0)

        self.add_sources(platform)

    # JTAG / cJTAG on PMOD JA: cpu/mmrisc's add_jtag (the same pins, pulls,
    # constraints and status LEDs; docs/BRINGUP.md 23), on CPU_TOP's ports.
    def add_jtag(self, platform):
        platform.add_extension([
            ("mmrisc_jtag", 0,
                Subsignal("tck",    Pins("pmoda:0"), Misc("PULLUP TRUE")),
                Subsignal("tdi",    Pins("pmoda:1"), Misc("PULLUP TRUE")),
                Subsignal("tdo",    Pins("pmoda:2"), Misc("PULLUP TRUE")),
                Subsignal("tms",    Pins("pmoda:3"), Misc("KEEPER TRUE")),
                Subsignal("trst_n", Pins("pmoda:4"), Misc("PULLUP TRUE")),
                Subsignal("srst_n", Pins("pmoda:5"), Misc("PULLUP TRUE")),
                IOStandard("LVCMOS33"),
            ),
        ])
        pads     = platform.request("mmrisc_jtag")
        self.jtag_srst_n = pads.srst_n
        sw_auth  = platform.request("user_sw", 2)
        sw_cjtag = platform.request("user_sw", 3)
        rgb      = any(r[0] == "rgb_led" for r in platform.constraint_manager.available)

        tck    = Signal()
        tms_i  = Signal()
        tms_o  = Signal()
        tms_oe = Signal()
        tdo    = Signal()
        tdo_oe = Signal()
        halted, running, dmactive, online = Signal(), Signal(), Signal(), Signal()

        self.specials += [
            Instance("IBUF",  name="mmrisc_jtag_tck_ibuf",
                i_I = pads.tck, o_O = tck),
            Instance("IOBUF", name="mmrisc_jtag_tms_iobuf",
                io_IO = pads.tms, o_O = tms_i, i_I = tms_o, i_T = ~tms_oe),
            Instance("OBUFT", name="mmrisc_jtag_tdo_obuft",
                o_O = pads.tdo, i_I = tdo, i_T = ~tdo_oe),
        ]

        self.cpu_params.update(
            i_jtag_tck       = tck,
            i_jtag_tms_i     = tms_i,
            o_jtag_tms_o     = tms_o,
            o_jtag_tms_oe    = tms_oe,
            i_jtag_tdi       = pads.tdi,
            o_jtag_tdo       = tdo,
            o_jtag_tdo_oe    = tdo_oe,
            i_jtag_trst_n    = pads.trst_n,
            i_cjtag_en       = sw_cjtag,
            o_cjtag_online   = online,
            i_dbg_auth_en    = sw_auth,
            i_dbg_auth_key   = self.auth_key,
            o_dbg_halted     = halted,
            o_dbg_running    = running,
            o_dbg_dmactive   = dmactive,
        )

        if rgb:
            led0 = platform.request("rgb_led", 0)
            led1 = platform.request("rgb_led", 1)
            led2 = platform.request("rgb_led", 2)
            dim = Signal(4)
            on  = Signal()
            self.sync += dim.eq(dim + 1)
            self.comb += [
                on.eq(dim == 0),
                led0.r.eq(halted   & on), led0.g.eq(running & on), led0.b.eq(0),
                led1.r.eq(0), led1.g.eq(0), led1.b.eq(dmactive & on),
                led2.r.eq(0), led2.g.eq(online & on), led2.b.eq(0),
            ]
        else:
            # the Nexys Video: LD0 halted, LD1 running, LD2 dmactive, LD3 cJTAG online
            leds = [platform.request("user_led", i) for i in range(4)]
            self.comb += [
                leds[0].eq(halted),
                leds[1].eq(running),
                leds[2].eq(dmactive),
                leds[3].eq(online),
            ]
            platform.add_platform_command(
                "set_false_path -to [get_ports {{{l0} {l1} {l2} {l3}}}]",
                l0=leds[0], l1=leds[1], l2=leds[2], l3=leds[3])

        platform.add_period_constraint(pads.tck, 100.0, name="jtag_tck")
        platform.add_period_constraint(pads.tms, 100.0, name="jtag_tmsc")
        self.jtag_clk_pads = [pads.tck, pads.tms]
        platform.add_platform_command(
            "set_false_path -from [get_ports {{{trst_n} {srst_n} {sw2} {sw3}}}]",
            trst_n=pads.trst_n, srst_n=pads.srst_n, sw2=sw_auth, sw3=sw_cjtag)
        platform.add_platform_command(
            "set_false_path -from [get_ports {{{tdi} {tms}}}]", tdi=pads.tdi, tms=pads.tms)
        platform.add_platform_command(
            "set_false_path -to [get_ports {{{tdo} {tms}}}]", tdo=pads.tdo, tms=pads.tms)
        platform.toolchain.pre_placement_commands.append(
            "set_property CLOCK_DEDICATED_ROUTE FALSE "
            "[get_nets -of_objects [get_pins mmrisc_jtag_tck_ibuf/O]]")
        platform.toolchain.pre_placement_commands.append(
            "set_property CLOCK_DEDICATED_ROUTE FALSE "
            "[get_nets -of_objects [get_pins mmrisc_jtag_tms_iobuf/O]]")

    def set_reset_address(self, reset_address):
        self.reset_address = reset_address
        self.cpu_params.update(p_RESET_VECTOR=reset_address)

    @staticmethod
    def add_sources(platform):
        for src in RTL_SOURCES:
            platform.add_source(os.path.join(RTL_DIR, src))

    def add_soc_components(self, soc):
        # The CPU's clock domain, as cpu/mmrisc (step 2.2).
        cd = "sys"
        if self.cpu_clk_freq and self.cpu_clk_freq != soc.sys_clk_freq:
            cd = "mmrisc"
            soc.crg.cd_mmrisc = ClockDomain("mmrisc")
            soc.crg.pll.create_clkout(soc.crg.cd_mmrisc, self.cpu_clk_freq)
            soc.logger.info("mmRISC-3 in its own clock domain at {:g} MHz, sys at {:g} MHz.".format(
                self.cpu_clk_freq / 1e6, soc.sys_clk_freq / 1e6))
        cpu_clk_freq = self.cpu_clk_freq or soc.sys_clk_freq
        self.cpu_cd  = cd
        self.submodules += axi.AXIClockDomainCrossing(self.cpu_mem, self.mem_axi,
            cd_from=cd, cd_to="sys")
        self.submodules += axi.AXILiteClockDomainCrossing(self.cpu_mmio, self.mmio_axil,
            cd_from=cd, cd_to="sys")
        self.submodules += axi.AXILiteClockDomainCrossing(self.dma_bus, self.cpu_dma,
            cd_from="sys", cd_to=cd)

        # The memory bus split (in sys, do_finalize: the ROM's region is
        # known then): main RAM to LiteDRAM (memory_buses, which LiteX
        # connects with main RAM's base taken off), the ROM's region (the
        # ROM's lines, as OOO_ICACHE fetches them) onto the SoC bus, the rest
        # to AXIErrorSlave.
        assert self.mem_map["main_ram"] == 0x8000_0000
        self.soc_bus = soc.bus
        soc.bus.add_master(name="mmrisc3_fetch", master=self.fetch_wb)

        # Resets: CPU_TOP's rst_dbg_n the debug logic's (the domain's), rst_n
        # the CPU's (the domain's, LiteX's CPU reset, the board's nSRST).
        cpu_reset = Signal()
        ext_irq   = Signal(self.num_irq - 1)
        self.ext_irq  = ext_irq
        self.irq_locs = soc.irq.locs
        if cd == "sys":
            self.comb += [cpu_reset.eq(self.reset), ext_irq.eq(self.interrupt)]
        else:
            self.specials += MultiReg(self.reset, cpu_reset, odomain=cd)
        rst_n = ~(ResetSignal(cd) | cpu_reset)
        if getattr(self, "jtag_srst_n", None) is not None:
            rst_n = rst_n & self.jtag_srst_n
        # mtime at 500 kHz whatever the CPU's clock
        tick_div = int(cpu_clk_freq // 500_000)
        assert tick_div * 500_000 == cpu_clk_freq, "the CPU's clock must be a multiple of 500 kHz"
        self.cpu_params.update(
            i_clk            = ClockSignal(cd),
            i_rst_n          = rst_n,
            i_rst_dbg_n      = ~ResetSignal(cd),
            i_irq_src        = ext_irq,
            p_CLINT_TICK_DIV = tick_div,
        )

        soc.bus.add_region("opensbi", SoCRegion(
            origin=self.mem_map["main_ram"], size=0x20_0000, cached=True, linker=True))
        soc.bus.add_region("plic", SoCRegion(
            origin=soc.mem_map.get("plic"),  size=0x40_0000, cached=True, linker=True))
        soc.bus.add_region("clint", SoCRegion(
            origin=soc.mem_map.get("clint"), size=0x1_0000,  cached=True, linker=True))

        if getattr(self, "jtag_clk_pads", None) and hasattr(soc, "crg"):
            soc.platform.add_false_path_constraints(soc.crg.cd_sys.clk, *self.jtag_clk_pads)
            if cd != "sys":
                for pad in self.jtag_clk_pads:
                    soc.platform.add_false_path_constraints(soc.crg.cd_mmrisc.clk, pad)

        soc.add_config("CPU_COUNT", 1)
        soc.add_config("CPU_ISA",   self.get_arch(self.variant))
        soc.add_config("CPU_MMU",   "sv39")

        # OOO_CPU's caches (256 sets x 8 ways of 64 bytes each) and TLBs
        # (OOO_DTLB3: 32 sets of 2 ways, one for each load / store port, one
        # for the fetch)
        soc.add_config("CPU_DCACHE_SIZE",       256 * 8 * 64)
        soc.add_config("CPU_DCACHE_WAYS",       8)
        soc.add_config("CPU_DCACHE_BLOCK_SIZE", 64)
        soc.add_config("CPU_ICACHE_SIZE",       256 * 8 * 64)
        soc.add_config("CPU_ICACHE_WAYS",       8)
        soc.add_config("CPU_ICACHE_BLOCK_SIZE", 64)
        soc.add_config("CPU_DTLB_SIZE", 64)
        soc.add_config("CPU_DTLB_WAYS", 2)
        soc.add_config("CPU_ITLB_SIZE", 64)
        soc.add_config("CPU_ITLB_WAYS", 2)

    def do_finalize(self):
        assert hasattr(self, "reset_address")
        # the memory bus split (add_soc_components): decoders on a 64-bit
        # word's address (the byte's >> 3)
        rom   = self.soc_bus.regions["rom"]
        r_lo  = rom.origin >> 3
        r_hi  = (rom.origin + rom.size) >> 3
        fetch_axi = axi.AXIInterface(data_width=64, address_width=32, id_width=4)
        err_axi   = axi.AXIInterface(data_width=64, address_width=32, id_width=4)
        self.submodules += axi.AXIDecoder(self.mem_axi, [
            (lambda a: a[28], self.dram_axi),                               # from 0x8000_0000
            (lambda a: ~a[28] & (a >= r_lo) & (a < r_hi), fetch_axi),       # the ROM
            (lambda a: ~a[28] & ((a < r_lo) | (a >= r_hi)), err_axi),       # nothing
        ])
        self.submodules += axi.AXI2Wishbone(fetch_axi, self.fetch_wb, base_address=0)
        self.submodules += AXIErrorSlave(err_axi)
        # The interrupts into the CPU's domain, only the lines LiteX uses (as
        # cpu/mmrisc: docs/BRINGUP.md 16).
        if self.cpu_cd != "sys":
            used = sorted(set(loc for loc in self.irq_locs.values()
                              if loc < len(self.interrupt)))
            for i in range(len(self.interrupt)):
                if i in used:
                    self.specials += MultiReg(self.interrupt[i], self.ext_irq[i], odomain=self.cpu_cd)
                else:
                    self.comb += self.ext_irq[i].eq(0)
        self.specials += Instance("CPU_TOP", **self.cpu_params)
