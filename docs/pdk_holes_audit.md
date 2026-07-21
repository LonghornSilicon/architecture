# PDK Holes Audit — Sky130 (flagship) & GF180 (shuttle)

**Living document (started 2026-07-21).** Honest, exhaustive gap register for the decode
attention datapath across PDKs. Update it as holes close — do not let it go stale.

**PDK roles:**
- **Sky130 (130nm)** = the **flagship** — a real, manufacturable PDK; our closest-to-actual-chip
  proof. Priority for completeness.
- **GF180MCU** = the **chipathon shuttle** target (SSCS Chipathon 2026).
- **ASAP7 (7nm)** = predictive **research bracket** only (16nm-FinFET proxy), not a tapeout.

## Master matrix (decode attention datapath)

| Block | RTL | Sky130 signoff | GF180 signoff | ASAP7 | cosim / GLS |
|---|---|---|---|---|---|
| `precision_controller` | ✅ | ✅ 80 MHz | ✅ | ✅ | ✅ RTL + GF180 GLS |
| `mate_pv` (INT8 P·V) | ✅ | ✅ 71 MHz | ✅ | ✅ | ✅ RTL + GF180 GLS |
| `mate_pv_fp16` (FP16 P·V) | ✅ | ✅ 12 MHz | ✅ | ✅ | ✅ RTL + GF180 GLS |
| `token_importance_unit` | ✅ | ✅ (multi-corner) | ✅ | — | ✅ RTL + GF180 GLS |
| `mate_qkt` (Q·Kᵀ) | ✅ | ❌ **none** (Yosys smoke only) | ✅ | — | ✅ RTL + GF180 GLS |
| `vecu_softmax` | ✅ | ❌ **none** | ✅ (ss fixed) | — | ✅ RTL + GF180 GLS |
| `kv_cache_engine` (KVE) | ✅ | ⚠️ **config only, no committed signoff**; `SRAM_DEPTH=2` flop proxy | ⚠️ hardens but flop-array proxy (real SRAM macro in progress) | — | ✅ RTL; GLS via combinational reconstruct |
| RoPE | ❌ **no RTL** | — | — | — | reference stand-in (pre-RoPE'd tiles) |
| RMSNorm | ❌ **no RTL** | — | — | — | reference stand-in |
| `lambda_acu` top + decode FSM | ❌ **stub only** | — | — | — | testbench-stitched; no integrated top |
| MatE 8×8 GEMM/FFN systolic · full VecU · MSC · LSU · HIF | ❌ no RTL (off-shuttle scope) | — | — | — | off-chip / spec-only |

## 🔴 130nm (Sky130) flagship holes — PRIORITY

The flagship is currently **less complete than GF180** for the datapath, because `mate_qkt` and
`vecu_softmax` were advanced on GF180 with Sky130 sign-off skipped. To keep 130nm as the flagship:

1. **`mate_qkt` — no Sky130 sign-off.** Only a Yosys smoke + GF180 hardening exist. The flagship
   cannot do Q·Kᵀ scoring in 130nm silicon terms. → *Backfill a Sky130 OpenLane sign-off.*
2. **`vecu_softmax` — no Sky130 sign-off.** Only GF180. Flagship missing softmax. → *Backfill
   Sky130 (use the pipelined + area-reclaimed version once it lands).*
3. **KVE — no committed Sky130 sign-off.** Only a `config.json` (`SRAM_DEPTH=2`, 100 ns); no GDS /
   metrics in the tree. The "through Sky130 sign-off" claim isn't backed by committed artifacts.
   → *Commit a real Sky130 KVE run; decide real SRAM vs documented flop proxy.*
4. **KVE storage is a `SRAM_DEPTH=2` flop proxy on Sky130 too** — no real KV capacity at 130nm
   (same hole as GF180). → *Sky130 SRAM macro (sky130 OpenRAM/DFFRAM) or documented proxy.*
5. **No Sky130 integrated top.** Blocks are signed off individually; there is no Sky130 GDSII of
   the integrated ACU datapath, and the cosim is RTL-only. → *Phase-3 `lambda_acu` top → Sky130.*

## 🟠 GF180 (shuttle) holes

1. **KVE `gf180mcu_fd_ip_sram` macro** — KV storage hardens as flop register arrays at the depth-2
   proxy (not real capacity). → **in progress** (SRAM-macro agent).
2. **`vecu_softmax` area** — the ss-close resize ~2×'d cells (→1.49 mm²); may not fit the padring
   slot. → **in progress** (pipeline-rebalance agent).
3. **ss-corner max-transition (slew)** on the large fp16 / register-array blocks (`mate_pv_fp16`,
   `vecu_softmax`, `kve`). Setup/hold/DRC/LVS unaffected. → physical-opt (driver upsizing / slew
   repair).
4. **No integrated `lambda_acu` top hardened on GF180.** Blocks are standalone macros; the
   padring stitching (`chip_core.sv` override + SPI loader → `chipathon-2026-gf180mcu-padring`)
   is not done. → Phase 5.
5. **Full-chip cocotb GL** (chip_core through the padring) not run — only per-block + the
   datapath GLS.

## ⚪ Cross-cutting (both PDKs)

- **RoPE + RMSNorm** have no RTL — the cosim uses pre-RoPE'd Qwen tiles, so the on-die raw-Q/K
  path doesn't exist yet. Needed for a self-contained chip-top.
- **`lambda_acu` integration top + decode-step FSM** is a stub — the datapath is stitched by the
  testbench, not a single RTL module.
- **Projections (QKV/output), FFN GEMMs, logits** — off-chip by design for this shuttle (the
  general 8×8 systolic GEMM engine was never RTL).

## Priority ranking (as of 2026-07-21)

1. **Flagship parity (Sky130):** backfill Sky130 sign-off for `mate_qkt` + `vecu_softmax` (+ commit
   a real KVE Sky130 run). *The flagship should not trail the shuttle.*
2. GF180 KVE real SRAM macro + `vecu_softmax` area — *in progress.*
3. `lambda_acu` integration top + decode FSM (both PDKs) → Phase 3.
4. RoPE / RMSNorm RTL for the chip-top.
5. ss-corner slew physical-opt; full-chip padring GL.
