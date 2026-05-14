# LSU — Layer Sequencer

**Spec source:** `../../../arch.yml` block `layer_sequencer`.

## What this block is

- Tiny in-order RISC, 3-stage pipeline
- **32-instruction ISA**, 32-bit fixed-width
- 16 × 32-bit general-purpose registers
- **4 KB microcode RAM** — holds the entire pre-compiled model schedule for one transformer
- Single-issue: 1 scalar + 1 vector + 1 DMA per cycle
- No branch predictor, no OoO, no cache hierarchy — transformer decode is structurally identical layer-to-layer, so a static schedule walked deterministically suffices
- 0.10 mm²; 0.05 W

## ISA stub (to be expanded in `../../isa/lsu.h`)

Three issue lanes per cycle, each dispatching to one downstream block:

- **Scalar lane:** GPR ops + control flow (cmp/branch/jump)
- **Vector lane:** `ISSUE_MAT_E <op>`, `ISSUE_VEC_U <op>`, `ISSUE_KCE_COMP/DECOMP`, `ISSUE_MSC <op>` (3-operand register ops dispatched to the downstream block)
- **DMA lane:** `ISSUE_DMA src, dst, len` to MSC

## Why so minimal

Compiler emits the schedule once per model; chip walks it forever. The host loads ~3K instructions of microcode over USB-C at boot. Layer N+1 reuses layer N's schedule with only the layer-index register bumped. No need for branch prediction or speculative execution at this scale.

## Files

- `lsu.h`, `lsu.cpp` — top-level Stratus entity
- `decoder.h` — 32-inst decoder
- `regfile.h` — 16 × 32b GPR
- `dispatcher.h` — three-lane issue logic
- `tb/` — testbench (runs example schedules)
- `stratus.tcl`
