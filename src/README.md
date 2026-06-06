# Lambda — Implementation (HLS C++)

Cadence Stratus HLS path: C++17 → synthesizable RTL. Block-by-block implementation against `../arch.yml`. Bit-accurate Python golden models in `golden/` are the verification reference.

## Top-level grouping (per `../arch.yml` `compute_unit_grouping`)

- **ACU** (Attention Compute Unit) = MatE + VecU + KCE-mini — the compute fabric
- **MSC** — Memory Subsystem Controller (PagedAttention block table, sparse-blocked attention, TIU read interface)
- **LSU** — Layer Sequencer (32-inst in-order RISC)
- **TIU** — Token Importance Unit (adaptive-precision KV, H2O eviction)
- **HIF** — Host Interface (PCIe Gen3 x1 on M.2 2280)

## Build flow

```
src/
├── golden/                   ← Python bit-accurate reference for every block
├── isa/                      ← LSU + VecU microcode + CSR map headers (.h)
├── blocks/                   ← One subdir per RTL block
│   ├── <block>/
│   │   ├── <block>.h         ← Stratus-synthesizable C++ header
│   │   ├── <block>.cpp       ← Implementation
│   │   ├── tb/               ← C++ testbench (peer of stratus/, survives tool changes)
│   │   ├── stratus/          ← Stratus HLS project subdir
│   │   │   └── project.tcl   ← define_hls_module + define_hls_config targets
│   │   └── README.md
└── tests/                    ← Cross-block integration tests
```

## Recommended build order (long poles first)

1. **MatE PE microarchitecture** — INT8×INT4 multiplier + INT16 partial-product register + INT24 K-axis accumulator. The single most-replicated piece (64 PEs). Get this right and the rest of MatE composes trivially. Validate gate count and timing closure at 1 GHz, 16nm, against `arch.yml` MatE block.
2. **KCE-mini Hadamard butterfly + Lloyd-Max classifier + bit-pack** — the headline research IP, 0.08 mm² target. Validate bit-exactly against the Python golden in `golden/kce.py`. Sweep 5 CSR modes (turboquant-3bit, hadamard-int4, asymmetric K3V2, FP4 codebook, FP16 bypass).
3. **VecU lane + online-softmax microcode + TIU update microcode** — 16-bit FP/BF SIMD lane with shared transcendental LUTs. Microcoded; ~1K-inst instruction memory. Online softmax microcode is the first non-trivial program; the TIU importance-broadcast op piggybacks on the same softmax loop.
4. **TIU** — Token Importance Unit, 256 B importance SRAM + accumulator + threshold register. Smallest block; can build in parallel with KCE.
5. **MSC controller + 128-entry block table + sparse-blocked attention CSR + TIU read interface** — vLLM-style PagedAttention in silicon. LPDDR5X protocol-side is vendor IP (DesignWare/Denali); MSC implements the request-arbitration + DMA-descriptor + block-table indexing side.
6. **LSU** — 32-instruction in-order RISC, 4 KB microcode RAM, single-issue. Smallest pole; do this after MatE/KCE/VecU/TIU are stable.
7. **HIF** — PCIe Gen3 x1 endpoint on M.2 2280 form factor. Outsource the PCIe Gen3 x1 PHY + controller IP (Synopsys DesignWare or Cadence); we build the doorbell/CSR/JTAG side around it.

## Golden-model contract

Every block in `blocks/<block>/` has a corresponding Python reference at `golden/<block>.py`. The HLS C++ implementation passes if its bit-vector output equals the Python golden's output for every input vector in `tb/testvectors/`. Discrepancies = HLS bug, not spec bug (the spec is `arch.yml`).

## Status

- [x] Block scaffolding created — MatE, VecU, KCE, MSC, LSU, HIF, TIU (2026-05-14)
- [x] Chamber tooling framework v0.1 — `tools/bin/lambda-stratus` + generic helpers + installer; smoke-tested end-to-end on `ae03ut01` 2026-05-17. See [`../docs/tools-overview.md`](../docs/tools-overview.md).
- [x] Stub `src/blocks/mate/stratus/project.tcl` — IDE opens cleanly; documents canonical Stratus 22.01 Tcl syntax for when source lands (2026-05-17)
- [x] Chamber tooling v0.3 — `tools/bin/lambda-innovus` + `innovus-here` (Innovus Stylus Common UI) + root `Makefile` flow wrapper + stub `src/blocks/mate/innovus/setup.tcl` (2026-06-06). **Chamber-confirmed LIVE same day:** Innovus Stylus GUI brought up on compute node `ip-10-2-6-68`, license `invs` checked out clean.
- [x] Chamber tooling v0.4 (2026-06-06) — full flow stack: `tools/lib/lambda-run.sh` (shared `lambda_require_tool` / `lambda_rundir` / `lambda_publish_release`); new launchers `genus-here`+`lambda-genus`, `xrun-here`+`lambda-xcelium`, `verisium-here`+`lambda-verisium`; Genus synth stub `src/blocks/mate/genus/synth.tcl`. **Run-area relocated to `$LAMBDA_WORK=~/work/lambda`** (outside the git mirror; `LAMBDA_BUILD` aliased for back-compat; `project.tcl:46` reads `$::env(LAMBDA_BUILD)` so Tcl follows the retier). Module pins corrected to confirmed-installed three-level leaves matched to release family: `stratus/2201/22.01.009`, `genus/211/21.18.000`, `innovus/211/21.18.000`, `xcelium/2403/24.03.005`, `verisiumdebug/2403/24.03.001`, `pegasus/232/23.24.000`, `ssv/251/25.12.000`. README/handoff correctness: Calibre→Pegasus, PrimeTime→Tempus/SSV. **Chamber-confirmed:** `make diag` on `ip-10-2-6-68` resolves all 7 tools; Innovus + Genus GUIs launch cleanly. **Compute farm is heterogeneous** — `ip-10-2-6-30` lacks `/apps/INNOVUS*`, so the same `qsh -q normal.q` queue lands on nodes with different tool sets. See [`../docs/tools-overview.md`](../docs/tools-overview.md) "Chamber execution model".
- [ ] MatE PE microarchitecture HLS source — *next* (after Phases A/B/C/D complete per plan)
- [ ] KCE-mini Hadamard + codebook HLS source
- [ ] VecU SIMD lane HLS source
- [ ] TIU importance accumulator HLS source
- [ ] Python golden for MatE, KCE, VecU, TIU, MSC, LSU
- [ ] Block-level testbenches
- [ ] Full-chip integration in Stratus
- [ ] Cadence Genus synthesis pass (tool present `genus/211`; gated on RTL + readable PDK)
- [ ] Cadence Innovus PnR pass (launcher landed v0.3; real flow gated on RTL + PDK — no TSMC N16FFC on chamber yet, `advgpdk` available for bring-up)

Per the approved plan, HLS work begins only after the research dives (Phases A/B/C — Chaithu reconciliation, attention/FFN literature audit, Etched patent analysis) complete. Tracked in detail in `../STATUS.md` §6 and the plan file at `~/.claude/plans/proud-yawning-hopcroft.md`.
