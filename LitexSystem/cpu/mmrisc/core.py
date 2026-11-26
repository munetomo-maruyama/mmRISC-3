#
# mmRISC-2 core support for the LiteX SoC: mmRISC-3's copy for the Nexys
# Video (step 2.1, Doc/STRATEGY.md), from mmRISC-2/LitexSystem/cpu/mmrisc at
# Rev.02. What differs from mmRISC-2's:
#   - the RTL is mmRISC-2's own, read from its repository (MMRISC2_HOME,
#     by default ../mmRISC-2 beside this one), not copied here;
#   - the debug port defaults to "none": its pins, switches and status LEDs
#     are the Arty's below, the Nexys Video's come at step 2.4
#     (Doc/BOARD.md 7, 8);
#   - step 2.2: the CPU in a clock domain of its own, "mmrisc", at
#     --cpu-clk-freq (50 MHz) from the CRG's MMCM, while LiteX runs at
#     --sys-clk-freq (100 MHz: LiteDRAM's DDR3-800, Doc/BOARD.md 4 option A).
#     Its three buses cross in this wrapper (add_soc_components): the memory
#     bus through AXIClockDomainCrossing, the peripheral and DMA buses through
#     AXILiteClockDomainCrossing, the interrupts through MultiReg. LiteX sees
#     its buses in sys as before; with equal clocks nothing crosses.
#
# mmRISC-2 core support for the LiteX SoC.
#
# The CPU is CPU_TOP of this repository: the pipeline, the L1 caches, the
# MMU, the CLINT, the PLIC and the JTAG debug module in one block. It
# presents two buses, which is what LiteX wants:
#
#   memory bus     AXI4       cache line bursts to LiteDRAM
#   peripheral bus AXI4-Lite  single beats, turned into Wishbone here
#   DMA bus        AXI4-Lite  a slave: the DMA masters of the SoC (the SD
#                             card) reach memory through the data cache,
#                             coherent with the CPU (CPU_DMA/DMA_CACHE)
#
# The JTAG / cJTAG port of the debug module comes out on PMOD JA, with the
# pins of the debug bring-up design FPGA/ARTY_A7_100T (TOP.xdc), so the same
# cable and the same OpenOCD configurations work on both (see add_jtag):
#
#   JA1 TCK/TCKC  JA2 TDI  JA3 TDO  JA4 TMS/TMSC  JA7 nTRST  JA8 nSRST
#   SW3 down JTAG / up cJTAG      SW2 down authentication off / up on
#
# Everything below MEM_BASE leaves the caches on the peripheral bus, so the
# LiteX map falls out of a single boundary: the CSRs at 0x1200_0000 are
# uncached and main memory at 0x8000_0000 is cached.
#
# LiteX finds this file by itself: litex/soc/cores/cpu/__init__.py collects
# every directory holding a core.py, both in its own tree and in the
# working directory. Running the build from LitexSystem/cpu is enough, and
# the LiteX checkout stays untouched.
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

# the root of this repository, from the real path of this file so that a
# symbolic link into the LiteX tree works as well
CPU_DIR  = os.path.dirname(os.path.realpath(__file__))
REPO_DIR = os.path.abspath(os.path.join(CPU_DIR, "..", "..", ".."))
# mmRISC-3: the RTL of mmRISC-2's CPU from mmRISC-2's repository
MMRISC2_DIR = os.path.abspath(os.environ.get("MMRISC2_HOME",
    os.path.join(REPO_DIR, "..", "mmRISC-2")))
RTL_DIR  = os.path.join(MMRISC2_DIR, "RTL")

# The RTL in the order it has to be read. Vivado does not need it, but
# keeping one list means the simulation benches and the FPGA build cannot
# drift apart.
RTL_SOURCES = [
    "CPU/CPU_DBG/DBG_CDC/DBG_CDC.sv",
    "CPU/CPU_DBG/DBG_CJTAG/DBG_CJTAG.sv",
    "CPU/CPU_DBG/DBG_DTM/DBG_DTM.sv",
    "CPU/CPU_DBG/DBG_DM/DBG_DM.sv",
    "CPU/CPU_DBG/DBG_HART_STUB/DBG_HART_STUB.sv",
    "CPU/CPU_DBG/DBG_BUSMST/DBG_BUSMST.sv",
    "CPU/CPU_DBG/CPU_DBG/CPU_DBG.sv",
    "CPU/CPU_DBG/DBG_CACHE/DBG_CACHE.sv",
    "CPU/CPU_CACHE/CACHE_TAG_ARRAY/CACHE_TAG_ARRAY.sv",
    "CPU/CPU_CACHE/CACHE_DATA_ARRAY/CACHE_DATA_ARRAY.sv",
    "CPU/CPU_L2/L2_TAG_ARRAY.sv",
    "CPU/CPU_L2/CPU_L2.sv",
    "CPU/CPU_CACHE/ICACHE/ICACHE.sv",
    "CPU/CPU_CACHE/DCACHE/DCACHE.sv",
    "CPU/CPU_CACHE/CACHE_PORT_ARB/CACHE_PORT_ARB.sv",
    "CPU/CPU_CACHE/CPU_CACHE/CPU_CACHE.sv",
    "CPU/CPU_MMU/MMU_PMP/MMU_PMP.sv",
    "CPU/CPU_MMU/MMU_TLB/MMU_TLB.sv",
    "CPU/CPU_MMU/MMU_PTW/MMU_PTW.sv",
    "CPU/CPU_MMU/CORE_MMU/CORE_MMU.sv",
    "CPU/CPU_CORE/CORE_DEC/CORE_DEC.sv",
    "CPU/CPU_CORE/CORE_DECOMP/CORE_DECOMP.sv",
    "CPU/CPU_CORE/CORE_CSR/CORE_CSR.sv",
    "CPU/CPU_CORE/CORE_MDU/CORE_MDU.sv",
    "CPU/CPU_CORE/CORE_FRF/CORE_FRF.sv",
    "CPU/CPU_FPU/FPU_ROUND/FPU_ROUND.sv",
    "CPU/CPU_FPU/FPU_PIPE/FPU_PIPE.sv",
    "CPU/CPU_CORE/CORE_RF/CORE_RF.sv",
    "CPU/CPU_CORE/CORE_BTB/CORE_BTB.sv",
    "CPU/CPU_CORE/CORE_IFU/CORE_IFU.sv",
    "CPU/CPU_CORE/CORE_EXU/CORE_EXU.sv",
    "CPU/CPU_CORE/CORE_LSU/CORE_LSU.sv",
    "CPU/CPU_CORE/CPU_CORE/CPU_CORE.sv",
    "CPU/CPU_CLINT/CPU_CLINT.sv",
    "CPU/CPU_PLIC/CPU_PLIC.sv",
    "CPU/CPU_MMIO/CPU_MMIO.sv",
    "BUS/BUS_ARB/BUS_ARB.sv",
    "CPU/CPU_DMA/DMA_CACHE.sv",
    "CPU/CPU_BFM/CPU_BFM.sv",
    "CPU/CPU_TOP/CPU_TOP.sv",
]


class MMRISC(CPU):
    category             = "softcore"
    family               = "riscv"
    name                 = "mmrisc"
    human_name           = "mmRISC-2 (RV64GC)"
    variants             = ["standard"]
    data_width           = 64
    endianness           = "little"
    gcc_triple           = CPU_GCC_TRIPLE_RISCV64
    linker_output_format = "elf64-littleriscv"
    nop                  = "nop"

    # External interrupt lines of the PLIC.
    num_irq              = 32

    # --cpu-jtag : where the debug port goes. "pmoda" puts it on PMOD JA
    # (the Arty's or the Nexys Video's, the same positions), "none" ties it
    # off.
    jtag                 = "none"
    # the key of the authentication (SW2 up), as in FPGA/ARTY_A7_100T
    auth_key             = 0xbeefcafe
    # --cpu-l2-size : the L2 cache inside the CPU (RTL/CPU/CPU_L2), bytes;
    # 0 builds without it. Not LiteX's own --l2-size, which sits on the SoC
    # bus where this CPU never looks (build_soc.sh)
    l2_size              = 256 * 1024

    @staticmethod
    def args_fill(parser):
        cpu_group = parser.add_argument_group(title="CPU options")
        cpu_group.add_argument("--cpu-jtag", default="none", choices=["pmoda", "none"],
            help="Debug port of mmRISC-2: PMOD JA (JTAG / cJTAG) or tied off.")
        cpu_group.add_argument("--cpu-l2-size", default=256 * 1024, type=int,
            help="L2 cache of mmRISC-2 in bytes (between its L1 caches and LiteDRAM), 0 for none.")
        cpu_group.add_argument("--cpu-clk-freq", default=None, type=float,
            help="Clock of mmRISC-2 (its own domain, buses crossed to sys); default: sys's.")

    @staticmethod
    def args_read(args):
        MMRISC.jtag    = args.cpu_jtag
        MMRISC.l2_size = args.cpu_l2_size
        if args.cpu_clk_freq:
            MMRISC.cpu_clk_freq = int(args.cpu_clk_freq)
            # the BIOS's banner prints sys's clock: say the CPU's too
            MMRISC.human_name   = "mmRISC-2 (RV64GC, CPU {:g}MHz)".format(args.cpu_clk_freq / 1e6)

    # --cpu-clk-freq : None runs the CPU on sys, as on the Arty
    cpu_clk_freq         = None

    # mtime counts one step every CLINT_TICK_DIV cycles, so at 50 MHz this
    # gives the 500 kHz timebase the working Rocket build uses. The device
    # tree has to repeat the same number in timebase-frequency.
    clint_tick_div       = 100

    # The hardware has one boundary: everything below MEM_BASE is answered
    # on the peripheral bus and is never cached. That is stricter than what
    # is declared here, and deliberately so. LiteX refuses to place the ROM
    # in an IO region, so the ROM and the SRAM are declared cacheable even
    # though this CPU does not cache them; a flush of something that was
    # never cached costs a few cycles and nothing else. The declaration must
    # never go the other way -- calling a region cached that the hardware
    # does cache but LiteX thinks it does not would be a real bug.
    io_regions           = {0x1200_0000: 0x6e00_0000}  # Origin, Length.

    # The CLINT and the PLIC are inside the CPU, at the addresses the
    # privileged software expects; LiteX must not put anything there.
    @property
    def mem_map(self):
        return {
            "clint"    : 0x0200_0000,
            "plic"     : 0x0c00_0000,
            "rom"      : 0x1000_0000,
            "sram"     : 0x1100_0000,
            "csr"      : 0x1200_0000,
            "ethmac"   : 0x3000_0000,     # packet buffers, as in the Rocket build
            "main_ram" : 0x8000_0000,
        }

    @staticmethod
    def get_arch(variant="standard"):
        # the same shape as the Rocket wrapper uses, so the BIOS is built
        # with a -march string this toolchain is known to accept
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
        # PLIC source s is driven by ext_irq[s] and source 0 does not exist,
        # so LiteX interrupt i becomes PLIC source i+1. That is the same
        # numbering the device tree of the Rocket build uses.
        self.interrupt = Signal(self.num_irq - 1)

        # The buses as LiteX sees them, in sys ...
        self.mem_axi    = mem_axi   = axi.AXIInterface(data_width=64, address_width=32, id_width=4)
        self.mmio_axil  = mmio_axil = axi.AXILiteInterface(data_width=64, address_width=32)
        self.mmio_wb    = mmio_wb   = wishbone.Interface(data_width=64,
                                          adr_width=32 - log2_int(64 // 8),
                                          addressing="word")

        self.memory_buses = [mem_axi]  # to LiteDRAM
        self.periph_buses = [mmio_wb]  # to the SoC bus

        # The DMA port. Declaring it makes LiteX put the DMA masters on it
        # instead of on the SoC bus, and define CPU_HAS_DMA_BUS, so the BIOS
        # skips its cache flushes after a transfer; Linux treats DMA as
        # coherent anyway. Without it the SD card wrote to memory behind the
        # data cache, and Linux read stale lines (docs/BRINGUP.md).
        self.dma_bus    = dma_axil  = axi.AXILiteInterface(data_width=64, address_width=32)

        # ... and as CPU_TOP drives them, in the CPU's clock domain (the same
        # as sys unless --cpu-clk-freq says otherwise; joined in
        # add_soc_components, where sys's clock is known).
        self.cpu_mem    = cpu_mem   = axi.AXIInterface(data_width=64, address_width=32, id_width=4)
        self.cpu_mmio   = cpu_mmio  = axi.AXILiteInterface(data_width=64, address_width=32)
        self.cpu_dma    = cpu_dma   = axi.AXILiteInterface(data_width=64, address_width=32)

        # # #

        # CPU_TOP carries 40 bit addresses; LiteX works in 32. Every address
        # this SoC can produce is below 4 GB (the device tree puts memory at
        # 0x8000_0000), so the upper bits are always zero and dropping them
        # is safe. They are dropped here rather than in the RTL so that the
        # parameter keeps its natural value for other systems.
        awaddr_40 = Signal(40)
        araddr_40 = Signal(40)
        mmio_aw_40 = Signal(40)
        mmio_ar_40 = Signal(40)
        self.comb += [
            cpu_mem.aw.addr.eq(awaddr_40),
            cpu_mem.ar.addr.eq(araddr_40),
            cpu_mmio.aw.addr.eq(mmio_aw_40),
            cpu_mmio.ar.addr.eq(mmio_ar_40),
        ]

        self.cpu_params = dict(
            # Parameters.
            p_USE_BFM        = 0,
            p_NUM_IRQ        = self.num_irq,
            p_MEM_BASE       = self.mem_map["main_ram"],
            p_CLINT_BASE     = self.mem_map["clint"],
            p_PLIC_BASE      = self.mem_map["plic"],
            # mtime counts at a fixed rate; the device tree says the same
            # number in timebase-frequency.
            p_CLINT_TICK_DIV = self.clint_tick_div,
            p_L2_SIZE        = self.l2_size,

            # Clk / Rst.
            # rst_n resets the CPU; nSRST of the debugger joins it in
            # add_jtag. rst_dbg_n keeps the debug module out of a reset of
            # the CPU alone, so the debugger stays connected over it.
            # (set in add_soc_components, in the CPU's clock domain)
            o_ndmreset  = Open(),

            # Interrupts: shifted up by one, PLIC source 0 does not exist.
            # (set in add_soc_components, synchronised to the CPU's clock)

            # Memory bus (AXI4).
            o_m_axi4_awid    = cpu_mem.aw.id,
            o_m_axi4_awaddr  = awaddr_40,
            o_m_axi4_awlen   = cpu_mem.aw.len,
            o_m_axi4_awsize  = cpu_mem.aw.size,
            o_m_axi4_awburst = cpu_mem.aw.burst,
            o_m_axi4_awlock  = cpu_mem.aw.lock,
            o_m_axi4_awcache = cpu_mem.aw.cache,
            o_m_axi4_awprot  = cpu_mem.aw.prot,
            o_m_axi4_awqos   = cpu_mem.aw.qos,
            o_m_axi4_awvalid = cpu_mem.aw.valid,
            i_m_axi4_awready = cpu_mem.aw.ready,

            o_m_axi4_wdata   = cpu_mem.w.data,
            o_m_axi4_wstrb   = cpu_mem.w.strb,
            o_m_axi4_wlast   = cpu_mem.w.last,
            o_m_axi4_wvalid  = cpu_mem.w.valid,
            i_m_axi4_wready  = cpu_mem.w.ready,

            i_m_axi4_bid     = cpu_mem.b.id,
            i_m_axi4_bresp   = cpu_mem.b.resp,
            i_m_axi4_bvalid  = cpu_mem.b.valid,
            o_m_axi4_bready  = cpu_mem.b.ready,

            o_m_axi4_arid    = cpu_mem.ar.id,
            o_m_axi4_araddr  = araddr_40,
            o_m_axi4_arlen   = cpu_mem.ar.len,
            o_m_axi4_arsize  = cpu_mem.ar.size,
            o_m_axi4_arburst = cpu_mem.ar.burst,
            o_m_axi4_arlock  = cpu_mem.ar.lock,
            o_m_axi4_arcache = cpu_mem.ar.cache,
            o_m_axi4_arprot  = cpu_mem.ar.prot,
            o_m_axi4_arqos   = cpu_mem.ar.qos,
            o_m_axi4_arvalid = cpu_mem.ar.valid,
            i_m_axi4_arready = cpu_mem.ar.ready,

            i_m_axi4_rid     = cpu_mem.r.id,
            i_m_axi4_rdata   = cpu_mem.r.data,
            i_m_axi4_rresp   = cpu_mem.r.resp,
            i_m_axi4_rlast   = cpu_mem.r.last,
            i_m_axi4_rvalid  = cpu_mem.r.valid,
            o_m_axi4_rready  = cpu_mem.r.ready,

            # Peripheral bus (AXI4-Lite).
            o_m_axil_awaddr  = mmio_aw_40,
            o_m_axil_awprot  = cpu_mmio.aw.prot,
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
            o_m_axil_arprot  = cpu_mmio.ar.prot,
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

            # JTAG : tied off here, wired to PMOD JA by add_jtag.
            i_jtag_tck     = 0,
            i_jtag_tms_i   = 0,
            o_jtag_tms_o   = Open(),
            o_jtag_tms_oe  = Open(),
            i_jtag_tdi     = 0,
            o_jtag_tdo     = Open(),
            o_jtag_tdo_oe  = Open(),
            i_jtag_trst_n  = 1,
            i_cjtag_en     = 0,
            o_cjtag_online = Open(),
            i_dbg_auth_en  = 0,
            i_dbg_auth_key = 0,
            o_dbg_halted   = Open(),
            o_dbg_running  = Open(),
            o_dbg_dmactive = Open(),
        )

        if self.jtag == "pmoda":
            self.add_jtag(platform)

        # The peripheral bus reaches the SoC as Wishbone.
        self.submodules += axi.AXILite2Wishbone(mmio_axil, mmio_wb, base_address=0)

        self.add_sources(platform)

    # JTAG / cJTAG on PMOD JA, the pins, pulls and clock constraints of
    # FPGA/ARTY_A7_100T (TOP.xdc, TOP_impl.xdc). The same Pmod positions on
    # both boards (pmoda:0-5 in LiteX's platforms), so the cable and the
    # OpenOCD configurations are the same (Arty / Nexys Video pins):
    #
    #   JA1 G13 / AB22  TCK/TCKC   pull-up      a clock on a general pin
    #   JA2 B11 / AB21  TDI        pull-up
    #   JA3 A11 / AB20  TDO        pull-up      driven only while shifting
    #   JA4 D12 / AB18  TMS/TMSC   keeper       both sides drive it in cJTAG
    #   JA7 D13 / Y21   nTRST      pull-up      resets the TAP
    #   JA8 B18 / AA21  nSRST      pull-up      resets the CPU (not LiteX)
    #   SW3 A10 / G22   cJTAG enable            SW2 C10 / G21  authentication
    #
    # The status LEDs. On the Arty, LD4-LD7 are LiteX's LED chaser, whose CSR
    # stays where the device tree and fw_jump.bin expect it, so the status
    # goes to the RGB LEDs, dimmed:
    #
    #   LD0 red halted, green running   LD1 blue dmactive   LD2 green cJTAG online
    #
    # On the Nexys Video (no RGB LEDs; mmRISC-3 Doc/BOARD.md 8), LD0-LD3 as
    # they are, LD4-LD7 left to the LED chaser (nexys_video_target.py):
    #
    #   LD0 halted   LD1 running   LD2 dmactive   LD3 cJTAG online
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

        # The buffers are instantiated by name, so that the constraints
        # below find their output nets after synthesis.
        self.specials += [
            Instance("IBUF",  name="mmrisc_jtag_tck_ibuf",
                i_I = pads.tck, o_O = tck),
            Instance("IOBUF", name="mmrisc_jtag_tms_iobuf",
                io_IO = pads.tms, o_O = tms_i, i_I = tms_o, i_T = ~tms_oe),
            Instance("OBUFT", name="mmrisc_jtag_tdo_obuft",
                o_O = pads.tdo, i_I = tdo, i_T = ~tdo_oe),
        ]

        self.cpu_params.update(
            # (rst_n joined with nSRST in add_soc_components)
            i_jtag_tck     = tck,
            i_jtag_tms_i   = tms_i,
            o_jtag_tms_o   = tms_o,
            o_jtag_tms_oe  = tms_oe,
            i_jtag_tdi     = pads.tdi,
            o_jtag_tdo     = tdo,
            o_jtag_tdo_oe  = tdo_oe,
            i_jtag_trst_n  = pads.trst_n,
            i_cjtag_en     = sw_cjtag,
            o_cjtag_online = online,
            i_dbg_auth_en  = sw_auth,
            i_dbg_auth_key = self.auth_key,
            o_dbg_halted   = halted,
            o_dbg_running  = running,
            o_dbg_dmactive = dmactive,
        )

        if rgb:
            # the Arty: the RGB LEDs are blinding at full current, on one
            # cycle in 16
            led0 = platform.request("rgb_led", 0)
            led1 = platform.request("rgb_led", 1)
            led2 = platform.request("rgb_led", 2)
            dim = Signal(4)
            on  = Signal()
            self.sync += dim.eq(dim + 1)
            self.comb += [
                on.eq(dim == 0),
                led0.r.eq(halted   & on),
                led0.g.eq(running  & on),
                led0.b.eq(0),
                led1.r.eq(0),
                led1.g.eq(0),
                led1.b.eq(dmactive & on),
                led2.r.eq(0),
                led2.g.eq(online   & on),
                led2.b.eq(0),
            ]
        else:
            # the Nexys Video: LD0-LD3 (100 ohm, 2.5 V) as they are
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

        # TCK/TCKC and TMSC (the escape detector of cJTAG) are clocks, on
        # pins that are not clock capable; both are asynchronous to sys.
        platform.add_period_constraint(pads.tck, 100.0, name="jtag_tck")
        platform.add_period_constraint(pads.tms, 100.0, name="jtag_tmsc")
        # (their clock groups against sys are set in add_soc_components,
        # where the clock of sys is known)
        self.jtag_clk_pads = [pads.tck, pads.tms]
        # slow debug and board I/O, as in TOP.xdc
        platform.add_platform_command(
            "set_false_path -from [get_ports {{{trst_n} {srst_n} {sw2} {sw3}}}]",
            trst_n=pads.trst_n, srst_n=pads.srst_n, sw2=sw_auth, sw3=sw_cjtag)
        platform.add_platform_command(
            "set_false_path -from [get_ports {{{tdi} {tms}}}]", tdi=pads.tdi, tms=pads.tms)
        platform.add_platform_command(
            "set_false_path -to [get_ports {{{tdo} {tms}}}]", tdo=pads.tdo, tms=pads.tms)
        # after synthesis, when the nets of the buffers exist
        platform.toolchain.pre_placement_commands.append(
            "set_property CLOCK_DEDICATED_ROUTE FALSE "
            "[get_nets -of_objects [get_pins mmrisc_jtag_tck_ibuf/O]]")
        platform.toolchain.pre_placement_commands.append(
            "set_property CLOCK_DEDICATED_ROUTE FALSE "
            "[get_nets -of_objects [get_pins mmrisc_jtag_tms_iobuf/O]]")

    # the reset vector is a parameter, so LiteX may put it where it likes
    def set_reset_address(self, reset_address):
        self.reset_address = reset_address
        self.cpu_params.update(p_RESET_VECTOR=reset_address)

    @staticmethod
    def add_sources(platform):
        for src in RTL_SOURCES:
            platform.add_source(os.path.join(RTL_DIR, src))

    def add_soc_components(self, soc):
        # The CPU's clock domain (step 2.2): sys's, or one of its own from the
        # CRG's MMCM with the three buses crossed. LiteX's crossings are its
        # AsyncFIFOs; the two clocks come from one MMCM (100 and 50 MHz), so
        # Vivado times the crossing paths as related, which they meet easily.
        cd = "sys"
        if self.cpu_clk_freq and self.cpu_clk_freq != soc.sys_clk_freq:
            cd = "mmrisc"
            soc.crg.cd_mmrisc = ClockDomain("mmrisc")
            soc.crg.pll.create_clkout(soc.crg.cd_mmrisc, self.cpu_clk_freq)
            soc.logger.info("mmRISC-2 in its own clock domain at {:g} MHz, sys at {:g} MHz.".format(
                self.cpu_clk_freq / 1e6, soc.sys_clk_freq / 1e6))
        cpu_clk_freq = self.cpu_clk_freq or soc.sys_clk_freq
        self.cpu_cd  = cd
        self.submodules += axi.AXIClockDomainCrossing(self.cpu_mem, self.mem_axi,
            cd_from=cd, cd_to="sys")
        self.submodules += axi.AXILiteClockDomainCrossing(self.cpu_mmio, self.mmio_axil,
            cd_from=cd, cd_to="sys")
        self.submodules += axi.AXILiteClockDomainCrossing(self.dma_bus, self.cpu_dma,
            cd_from="sys", cd_to=cd)

        # Reset: the domain's, and LiteX's CPU reset (ctrl's cpu_rst, a level)
        # taken across; the SoC reset (soc_rst) resets the MMCM, so every
        # domain. Interrupts: LiteX's event managers' levels, taken across in
        # do_finalize, line by line, only the lines LiteX drives.
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
        # mtime at 500 kHz whatever the CPU's clock (the device tree's
        # timebase-frequency)
        tick_div = int(cpu_clk_freq // 500_000)
        assert tick_div * 500_000 == cpu_clk_freq, "the CPU's clock must be a multiple of 500 kHz"
        self.cpu_params.update(
            i_clk            = ClockSignal(cd),
            i_rst_n          = rst_n,
            i_rst_dbg_n      = ~ResetSignal(cd),
            i_ext_irq        = Cat(C(0, 1), ext_irq),
            p_CLINT_TICK_DIV = tick_div,
        )

        # The regions the privileged software needs to see. The CLINT and
        # the PLIC are inside the CPU, so nothing of LiteX answers there;
        # they are declared only so the map and the device tree agree.
        soc.bus.add_region("opensbi", SoCRegion(
            origin=self.mem_map["main_ram"], size=0x20_0000, cached=True, linker=True))
        # cached=True for the same reason as the ROM above: these sit below
        # the IO region LiteX knows about, and the hardware does not cache
        # them whatever this says
        soc.bus.add_region("plic", SoCRegion(
            origin=soc.mem_map.get("plic"),  size=0x40_0000, cached=True, linker=True))
        soc.bus.add_region("clint", SoCRegion(
            origin=soc.mem_map.get("clint"), size=0x1_0000,  cached=True, linker=True))

        # The clocks of the debug port against sys, and each other. LiteX
        # writes these after the create_clock commands, as they have to be.
        if getattr(self, "jtag_clk_pads", None) and hasattr(soc, "crg"):
            soc.platform.add_false_path_constraints(soc.crg.cd_sys.clk, *self.jtag_clk_pads)
            # and against the CPU's own clock (step 2.4), where the debug
            # module meets the core: an MMCM sibling of sys, not a clock
            # generated from sys's net, so not in sys's groups above
            if cd != "sys":
                for pad in self.jtag_clk_pads:
                    soc.platform.add_false_path_constraints(soc.crg.cd_mmrisc.clk, pad)

        soc.add_config("CPU_COUNT", 1)
        soc.add_config("CPU_ISA",   self.get_arch(self.variant))
        soc.add_config("CPU_MMU",   "sv39")

        # What the caches and the TLBs really are (CPU_CACHE_SPEC.md 3,
        # CPU_CORE_SPEC.md 6), so the device tree does not have to guess.
        soc.add_config("CPU_DCACHE_SIZE",       64 * 4 * 64)
        soc.add_config("CPU_DCACHE_WAYS",       4)
        soc.add_config("CPU_DCACHE_BLOCK_SIZE", 64)
        soc.add_config("CPU_ICACHE_SIZE",       64 * 4 * 64)
        soc.add_config("CPU_ICACHE_WAYS",       4)
        soc.add_config("CPU_ICACHE_BLOCK_SIZE", 64)

        # fully associative, so the number of sets is one
        soc.add_config("CPU_DTLB_SIZE", 16)
        soc.add_config("CPU_DTLB_WAYS", 16)
        soc.add_config("CPU_ITLB_SIZE", 16)
        soc.add_config("CPU_ITLB_WAYS", 16)

    def do_finalize(self):
        assert hasattr(self, "reset_address")
        # The interrupts into the CPU's own domain (step 2.2). LiteX connects
        # them (SoC._finalize_irq) before it finalizes its submodules, so the
        # lines it uses are known here. Only those get a MultiReg: its
        # flip-flops are dont_touch, so a MultiReg on an unused line keeps
        # a constant 0 alive, and the PLIC's priority tree for all 31
        # sources with it; the first 100 / 50 MHz build missed 50 MHz by
        # 16.4 ns that way (docs/BRINGUP.md 16). Unused lines stay 0, as in
        # one clock domain, where Vivado removes their sources.
        if self.cpu_cd != "sys":
            used = sorted(set(loc for loc in self.irq_locs.values()
                              if loc < len(self.interrupt)))
            for i in range(len(self.interrupt)):
                if i in used:
                    self.specials += MultiReg(self.interrupt[i], self.ext_irq[i], odomain=self.cpu_cd)
                else:
                    self.comb += self.ext_irq[i].eq(0)
        self.specials += Instance("CPU_TOP", **self.cpu_params)
