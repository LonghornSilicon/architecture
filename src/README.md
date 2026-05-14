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
│   │   ├── tb/               ← C++ testbench (cycle-accurate)
│   │   ├── stratus.tcl       ← Stratus HLS script
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
- [ ] MatE PE microarchitecture HLS source — *next* (after Phases A/B/C/D complete per plan)
- [ ] KCE-mini Hadamard + codebook HLS source
- [ ] VecU SIMD lane HLS source
- [ ] TIU importance accumulator HLS source
- [ ] Python golden for MatE, KCE, VecU, TIU, MSC, LSU
- [ ] Block-level testbenches
- [ ] Full-chip integration in Stratus
- [ ] Cadence Genus synthesis pass
- [ ] Cadence Innovus PnR pass

Per the approved plan, HLS work begins only after the research dives (Phases A/B/C — Chaithu reconciliation, attention/FFN literature audit, Etched patent analysis) complete. Tracked in detail in `../STATUS.md` §6 and the plan file at `~/.claude/plans/proud-yawning-hopcroft.md`.
