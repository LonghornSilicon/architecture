# Longhorn Silicon — Lambda

> **Codec-of-record note (2026-06-22 pivot):** Lambda's KV-cache compression codec of record is now **ChannelQuant** — per-channel INT4 keys (grouped, G=128) + per-token INT4 values + a static top-k FP16 outlier-channel lane, packaged as the **KV Cache Engine (KVE)**. The full block lives in the `kv-cache-engine` repo. The **TurboQuant / Walsh–Hadamard KCE microarchitecture** and its derived PPA numbers described elsewhere in this repo predate the ChannelQuant pivot and are **pending re-derivation** for ChannelQuant. TurboQuant remains a cited prior work, not the chip's current codec.

UT Austin AI accelerator project. **Target chip: Lambda — a 4 mm² ASIC on TSMC 16nm FinFET (N16FFC)**, targeting tape-out via IMEC / Europractice mini@sic 2.0. Standalone end-to-end transformer-decode accelerator running up to 1.5B-parameter W4A8 LLMs (validated on Qwen2-1.5B) at 6–8 tok/s in a ~2.6 W envelope. Plugs into any modern laptop or dev board via a **PCIe Gen3 x1 link on M.2 2280 form factor**.

*Lambda* is the codename: **L**onghorn **A**ccelerator for **M**atrix-**B**ased **D**ataflow & **A**ttention.

---

## Where to start

| If you want… | Read |
|---|---|
| **Current state, audit log, open questions, LPDDR PHY tradeoff** | [`STATUS.md`](STATUS.md) |
| **Visual floorplan + area accounting + workload coverage tables** | [`floorplan.html`](floorplan.html) (open in browser) |
| **Unit-by-unit dataflow walkthrough (teaching doc)** | [`dataflow_walkthrough.md`](dataflow_walkthrough.md) |
| **Machine-readable spec with every number** | [`arch.yml`](arch.yml) |
| **HLS C++ implementation (Cadence Stratus path)** | [`src/`](src/) |

Start with `STATUS.md`; then `floorplan.html` for the visual; then `dataflow_walkthrough.md` if you want to follow a single decode token through every block; then `arch.yml` for the authoritative numbers.

---

## Repo structure

```
architecture/
├── README.md                 ← this file
├── STATUS.md                 ← live status, iteration history, open questions
├── arch.yml                  ← canonical machine-readable spec
├── floorplan.html            ← visual floorplan + area + workload coverage
├── dataflow_walkthrough.md   ← unit-by-unit teaching doc
└── src/                      ← HLS C++ implementation (Cadence Stratus)
    ├── README.md
    ├── isa/                  ← LSU and chip-level ISA definitions
    ├── golden/               ← Python bit-accurate reference models
    └── blocks/               ← per-block HLS C++ (one subdir per block)
        ├── mate/             ← Matrix Engine (8×8 INT8×INT4 systolic)        ┐
        ├── vecu/             ← Vector Unit (8-lane FP16/BF16 SIMD)           │ ACU
        ├── kce/              ← KV Cache Engine (KVE, ChannelQuant)           ┘ umbrella  (dir kept for HLS continuity)
        ├── msc/              ← Memory Subsystem Controller (PagedAttention + sparse-blocked)
        ├── lsu/              ← Layer Sequencer (32-instruction in-order RISC)
        ├── tiu/              ← Token Importance Unit (adaptive-precision KV)
        └── hif/              ← Host Interface (PCIe Gen3 x1, M.2 form factor)
```

Top-level functional grouping follows the canonical four-block taxonomy: **Block 1 — Attention Compute Unit (ACU)** = MatE + VecU · **Block 2 — KV Cache Engine (KVE)** = ChannelQuant KV codec (formerly the KCE block) · **Block 3 — Token Importance Unit (TIU)** adaptive-precision driver · **Block 4 — Memory Hierarchy Controller (MHC)**, which this repo's finer taxonomy calls the MSC (Memory Subsystem Controller). Control (**LSU**) and host I/O (**HIF** PCIe Gen3 x1) sit alongside.

The repo was restructured to single-arch focus on 2026-05-14. Earlier history (130nm Sky130 track → 25 mm² Lambda flagship → three 4 mm² candidates v1/v2/v3 → final v2-only) lives in `STATUS.md` §2. The 130nm Sky130 work now lives in a separate repo, [Chipathon](https://github.com/LonghornSilicon/Chipathon) (SkyWater Sky130 PDK). The 2026-05-14 second-pass arch updates (PCIe HIF redesign, ACU naming, TIU block, area-accounting fix) are documented in `STATUS.md` change-log.

---

## Project context

- **Process:** TSMC 16nm FinFET (N16FFC), via imec / TSMC University Program — 28.2 MTr/mm² logic, 1.25 MB/mm² HD SRAM, 0.8 V core, 1 GHz target (800 MHz fallback)
- **Shuttle:** IMEC / Europractice mini@sic 2.0 (primary, ~$60-100K) or Muse Semiconductor (US fallback, ~$75K) — both route to the TSMC University FinFET program
- **Die:** 4 mm² (2 × 2 mm) — the IMEC / Muse mini@sic minimum Full Block at TSMC 16nm
- **EDA:** Cadence flow throughout — Stratus HLS for C++ → RTL, Genus for synthesis, Innovus (Stylus Common UI) for PnR, **Pegasus for DRC/LVS, Tempus/SSV for STA signoff** (Quantus for extraction, Voltus for power) — all Cadence, matching the shared hosted chamber's tool set; **Verisium Debug** with SimVision as fallback for waveform debug. Tool access bundled with the chamber engagement (see `docs/tools-overview.md` "Chamber execution model").
- **Off-chip DRAM:** 1× LPDDR5X-8533 x16 (12 GB/s sustained, 4–8 GB capacity) — Synopsys DesignWare or Cadence Denali PHY. **LPDDR4X x16 (Cadence) is the documented fallback** if LPDDR5X PHY quote returns over budget; see `STATUS.md` §5.
- **Host interface:** PCIe Gen3 x1 (~1 GB/s sustained) on **M.2 2280 form factor**. On-die PHY drives x1; M.2 slot wires 4 lanes (negotiated down). Synopsys DesignWare PCIe Gen3 x1 or Cadence PCIe Gen3 PHY — both with public 16nm datasheets.
- **Schedule (canonical Lambda milestones):** Spring 2026 Charter & tooling (in progress) → Fall 2026 Architecture finalization → Spring 2027 RTL design freeze → **Summer 2027 Tapeout** (TSMC 16nm FinFET via imec / TSMC University Program) → Post-silicon bring-up & validation

---

## What we're building, in one paragraph

A standalone open-source 4 mm² transformer-decoder ASIC that pairs with an off-chip LPDDR5X package and plugs into a host laptop or dev board via **PCIe Gen3 x1 on M.2 2280**. The chip runs the entire transformer decode loop on-die: weight matmuls (MatE 8×8 systolic, INT8 × INT4 → INT24 K-axis accumulator), online softmax + RoPE + RMSNorm + SiLU (VecU 8-lane SIMD), ChannelQuant KV compression — per-channel INT4 keys (grouped, G=128) + per-token INT4 values + a static top-k FP16 outlier-channel lane, at ~3.8× KV compression at ~4 bits/value, near-lossless (KV Cache Engine / KVE; recipe follows KIVI (ICML 2024) / KVQuant (2024), Longhorn's contribution is the streaming silicon implementation — full block in the `kv-cache-engine` repo), entropy-driven adaptive-precision + H2O-style eviction (TIU, 0.03 mm² — first-silicon implementation of arXiv 2604.04722), LPDDR + SRAM crossbar + vLLM-style 128-entry block table (MSC / canonical MHC, with sparse-blocked attention CSR mode), per-layer schedule walker (LSU 32-inst RISC, 4 KB microcode), and PCIe Gen3 x1 endpoint (HIF). 0.8 MB on-die SRAM split across 4 banks (KV-dominant). Targets up to 1.5B-parameter models, validated on Qwen2-1.5B, at 6–8 tok/s decode in ~2.6 W typical (~3.3 W peak). **First open-source academic standalone transformer accelerator at this scale + workload class.** *(The KVE area figure and its per-bit/per-value hardware detail are pending re-derivation for ChannelQuant; the TurboQuant/Hadamard 0.08 mm² number predates the pivot.)*
