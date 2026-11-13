# RTL/CPU/CACHE

[日本語](README_J.md)

mmRISC-2 Rev.02's L1 data cache, taken for mmRISC-3 (`Doc/UARCH.md` 3.7: the D$ is mmRISC-2's, behind an adapter), and its L2 (step 1.7 H2, `Plan/OOC.md` 29.57; its specification mmRISC-2's `RTL/CPU/CPU_L2/CPU_L2_SPEC.md`).
Its specification is mmRISC-2's `RTL/CPU/CPU_CACHE/CPU_CACHE_SPEC.md`. Each file has a line added to its header to say
where it comes from.

| Block | What it is | Change from mmRISC-2 |
|---|---|---|
| `DCACHE` | Physically indexed and tagged, 4 ways × 64 sets × 64 bytes, write back + write allocate, 2 MSHRs (non-blocking), 2 write-back buffers, answers in request order, AXI4 memory bus and AXI4-Lite peripheral bus | **One output added**: `d_hit_now` / `d_hit_now_data`, a load hit in stage 1 in the cycle it is found (also under a miss), for `OOO_DCAD`, which gives it to the LSU's M (`Plan/OOC.md` 17.2). The answer still goes out in order on `d_resp_*`. **For simulation** (`DCACHE_SIM_UC`): `sim_uc_line`, one line not cached (as below MEM_BASE), the test bench's `tohost` (`Plan/CORE.md` 5.5, B3-6) |
| `CACHE_TAG_ARRAY` | Tags (memory, synchronous read) and valid / dirty bits (flip-flops) | None |
| `CACHE_DATA_ARRAY` | 64-bit words, one block RAM per way, byte write enables | None |
| `CPU_L2` | The L2: 256 KB, 4 ways, 64-byte lines, write back, pseudo LRU, non-inclusive; one transaction at a time; a one-line evict buffer written out beside; AXI4 on both sides | **A part write that hits is written into the line, which becomes dirty, and answered without memory** (it was passed through to memory as well, the line's dirty bit left as it was): mmRISC-3's D$ is written through, so every store comes as a part write. A part write that misses goes to memory, as before |
| `L2_TAG_ARRAY` | The L2's {valid, dirty, tag}, one block RAM a way | None |

- Test: `SIM/OOO_UNIT/tb_dcad` (`OOO_LSU`, `OOO_DCAD` and `DCACHE` with an AXI4 memory model). mmRISC-2's own tests
  of the cache (`SIM/SIM_CACHE`) are not repeated here; the added output is two lines of logic.
- Test of the L2: `SIM/L2` (`run.sh`: mmRISC-2's `tb_L2` with the two ports of `OOO_MARB` in front, 6 configurations; `mutate.py`: 46 mutations of `CPU_L2` and `OOO_MARB`, 46 detected).
- Its lint warnings (unused address bits of the field functions, an unused parameter) are mmRISC-2's.
- `SIM/OOO_UNIT/mutate.py` can break these files (`CACHE:` entries): 1 mutation, detected.
