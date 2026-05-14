# Longhorn Silicon — Lambda

UT Austin AI accelerator project. **Target chip: Lambda — a 4 mm² ASIC on TSMC N16FFC**, taped out via IMEC / Europractice mini@sic 2.0. Standalone end-to-end transformer-decode accelerator running 3–5B-class W4A8 LLMs at 6–8 tok/s in a ~2.6 W envelope. Plugs into any modern laptop or dev board via a **PCIe Gen3 x1 link on M.2 2280 form factor**.

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
        ├── kce/              ← KV Compression Engine (TurboQuant 16-pt)      ┘ umbrella
        ├── msc/              ← Memory Subsystem Controller (PagedAttention + sparse-blocked)
        ├── lsu/              ← Layer Sequencer (32-instruction in-order RISC)
        ├── tiu/              ← Token Importance Unit (adaptive-precision KV)
        └── hif/              ← Host Interface (PCIe Gen3 x1, M.2 form factor)
```

Top-level functional grouping: **ACU** (Attention Compute Unit) = MatE + VecU + KCE-mini · **MSC** memory · **LSU** control · **TIU** adaptive-precision driver · **HIF** PCIe Gen3 x1 host I/O.

The repo was restructured to single-arch focus on 2026-05-14. Earlier history (LASSO on SKY130 → 25 mm² Lambda flagship → three 4 mm² candidates v1/v2/v3 → final v2-only) lives in `STATUS.md` §2. The 2026-05-14 second-pass arch updates (PCIe HIF redesign, ACU naming, TIU block, area-accounting fix) are documented in `STATUS.md` change-log.

---

## Project context

- **Process:** TSMC N16FFC at 28.2 MTr/mm² logic, 1.25 MB/mm² HD SRAM, 0.8 V core, 1 GHz target (800 MHz fallback)
- **Shuttle:** IMEC / Europractice mini@sic 2.0 (primary, ~$60-100K) or Muse Semiconductor (US fallback, ~$75K) — both route to the TSMC University FinFET program
- **Die:** 4 mm² (2 × 2 mm) — the IMEC / Muse mini@sic minimum Full Block at TSMC 16nm
- **EDA:** Cadence flow throughout — Stratus HLS for C++ → RTL, Genus for synthesis, Innovus for PnR, Calibre for DRC/LVS, PrimeTime for STA signoff. Tool access bundled with IMEC mini@sic registration.
- **Off-chip DRAM:** 1× LPDDR5X-8533 x16 (12 GB/s sustained, 4–8 GB capacity) — Synopsys DesignWare or Cadence Denali PHY. **LPDDR4X x16 (Cadence) is the documented fallback** if LPDDR5X PHY quote returns over budget; see `STATUS.md` §5.
- **Host interface:** PCIe Gen3 x1 (~1 GB/s sustained) on **M.2 2280 form factor**. On-die PHY drives x1; M.2 slot wires 4 lanes (negotiated down). Synopsys DesignWare PCIe Gen3 x1 or Cadence PCIe Gen3 PHY — both with public 16nm datasheets.
- **Tape-out target:** Q1 2028; demo Q3 2028; paper submission DAC/ICCAD/MICRO/HotChips 2028-09

---

## What we're building, in one paragraph

A standalone open-source 4 mm² transformer-decoder ASIC that pairs with an off-chip LPDDR5X package and plugs into a host laptop or dev board via **PCIe Gen3 x1 on M.2 2280**. The chip runs the entire transformer decode loop on-die: weight matmuls (MatE 8×8 systolic, INT8 × INT4 → INT24 K-axis accumulator), online softmax + RoPE + RMSNorm + SiLU (VecU 8-lane SIMD), TurboQuant 3-bit KV compression at 4.0 bpe / 4.0× via 16-point Walsh-Hadamard + Lloyd-Max codebook (KCE-mini, 0.08 mm² — the headline research IP), entropy-driven adaptive-precision + H2O-style eviction (TIU, 0.03 mm² — first-silicon implementation of arXiv 2604.04722), LPDDR + SRAM crossbar + vLLM-style 128-entry block table (MSC, with sparse-blocked attention CSR mode), per-layer schedule walker (LSU 32-inst RISC, 4 KB microcode), and PCIe Gen3 x1 endpoint (HIF). 0.8 MB on-die SRAM split across 4 banks (KV-dominant). Targets Llama-3.2-3B / Mistral-NeMo-3B / Qwen2.5-3B at 6–8 tok/s decode in ~2.6 W typical (~3.3 W peak). **First open-source academic standalone transformer accelerator at this scale + workload class.**
