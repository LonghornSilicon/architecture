# Lambda ISA

Two ISA layers in this chip:

1. **LSU instruction set** — 32 fixed-width 32-bit instructions, executed by the layer sequencer (see `../blocks/lsu/`). Three-lane issue (scalar + vector dispatch + DMA). This is the *chip-level ISA* — the program that the host loads at boot is a sequence of LSU instructions.

2. **VecU microcode** — programmable SIMD instruction stream stored in VecU's 1K-instruction microcode RAM. The microcoded operations (online softmax, RoPE, RMSNorm, SiLU, residual add, sampling) are themselves *programs* that the LSU calls into via `ISSUE_VEC_U <op_id>`.

This directory holds the headers that define both layers.

## Files

- `lsu.h` — LSU instruction encoding, opcodes, register names
- `vecu_microcode.h` — VecU microcode word format, op handles
- `csr_map.h` — CSR address space (HIF-exposed; layer mode selects, KVE codec/tier selects, etc.)

## Status

- [x] LSU opcode table — **draft `lsu-isa-0.1`** in `lsu.h` (32 opcodes, 4 lanes)
- [x] VecU microcode format — **draft `vecu-isa-0.1`** in `vecu_microcode.h` (uop set, LUTs, op-handle table)
- [x] CSR map — **draft `csr-isa-0.1`** in `csr_map.h` (global / layer / MatE / KVE / TIU / sampling / doorbell)
- [x] Assembler / disassembler — **`../golden/lsu_asm.py`** (assemble + decode, self-tests a layer body)
- [ ] Microcode assembler for VecU in `../golden/vecu_asm.py`

**Compiler-facing overview:** [`../../docs/compiler_programming_guide.md`](../../docs/compiler_programming_guide.md)
ties these headers to the block pipeline and the built KVE/TIU/ACU reference models.

## Design discussions still open

See `STATUS.md` §7 for the planned cross-cutting work that touches the ISA design:

- Whether to fuse `ISSUE_MAT_E` + `ISSUE_VEC_U` into a single FA-3 macro-op
- Whether to add a runtime precision-mode field (cf. Chaithu's adaptive-precision controller) or leave precision selection entirely to the static schedule
- Whether to expose the KVE ChannelQuant tier select (CQ-8 / CQ-4 / CQ-4+) as a per-layer CSR or per-tile micro-field
