# RTL/CPU/CACHE

[日本語](README_J.md)

mmRISC-2 Rev.02's L1 data cache, taken for mmRISC-3 (`Doc/UARCH.md` 3.7: the D$ is mmRISC-2's, behind an adapter).
Its specification is mmRISC-2's `RTL/CPU/CPU_CACHE/CPU_CACHE_SPEC.md`. Each file has a line added to its header to say
where it comes from.

| Block | What it is | Change from mmRISC-2 |
|---|---|---|
| `DCACHE` | Physically indexed and tagged, 4 ways × 64 sets × 64 bytes, write back + write allocate, 2 MSHRs (non-blocking), 2 write-back buffers, answers in request order, AXI4 memory bus and AXI4-Lite peripheral bus | **One output added**: `d_hit_now` / `d_hit_now_data`, a load hit in stage 1 in the cycle it is found (also under a miss), for `OOO_DCAD`, which gives it to the LSU's M (`Plan/OOC.md` 17.2). The answer still goes out in order on `d_resp_*` |
| `CACHE_TAG_ARRAY` | Tags (memory, synchronous read) and valid / dirty bits (flip-flops) | None |
| `CACHE_DATA_ARRAY` | 64-bit words, one block RAM per way, byte write enables | None |

- Test: `SIM/OOO_UNIT/tb_dcad` (`OOO_LSU`, `OOO_DCAD` and `DCACHE` with an AXI4 memory model). mmRISC-2's own tests
  of the cache (`SIM/SIM_CACHE`) are not repeated here; the added output is two lines of logic.
- Its lint warnings (unused address bits of the field functions, an unused parameter) are mmRISC-2's.
- `SIM/OOO_UNIT/mutate.py` can break these files (`CACHE:` entries): 1 mutation, detected.
