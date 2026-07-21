# VecU — Vector Unit (8-lane FP16/BF16 SIMD)

**Spec source:** `../../../arch.yml` block `vector_unit`.

## What this block is

- 8 lanes × 16-bit FP/BF (selectable per-mode)
- Microcoded: 1K-instruction microcode RAM; ~32 µops typical per op
- Three transcendental LUTs: exp (64-entry), rsqrt (64-entry), sigmoid (64-entry) + linear interp logic
- Operations: vector add/sub/mul, compare/max/min, exp_lut, rsqrt_lut, sigmoid_lut, RoPE pair-rotation
- 0.144 mm²; 0.16 W — **16nm ESTIMATE** (arch.yml `vector_unit`: 8 lanes × 16-bit, quarter-scale of the 32-lane flagship; power = 0.04 W/lane × 8 × 0.5 util). Analytical planning figure, not silicon.

## Why programmable instead of fixed-function

Every non-GEMM operation in a transformer (RoPE, RMSNorm, online softmax, SiLU/GELU, residual add, sampling) runs here. One programmable block has smaller verification surface than four fixed-function blocks — that's the structural decision. The microcode programs are the "ISA" of this block.

## Online-softmax microcode (Milakov & Gimelshein 2018 recurrence; FlashAttention-style tiling)

Heart of the chip. Per attention row, each lane keeps (m_i, l_i, O_i) running state. New tile arrives → rescale + accumulate. ~32 µops per tile. See `dataflow_walkthrough.md` Stage 9 for the algorithm.

## Files

- `vecu.h`, `vecu.cpp` — top-level Stratus entity
- `lane.h` — single FP/BF lane (gets replicated 8×)
- `lut.h` — transcendental LUT primitive (exp/rsqrt/sigmoid share the structure)
- `microcode/` — assembler-ready microcode source for the standard ops
- `tb/` — testbench (peer of `stratus/`)
- `stratus/project.tcl` — Stratus HLS project (canonical syntax in [`../../../docs/tools-overview.md`](../../../docs/tools-overview.md))
