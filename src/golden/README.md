# Golden Models

Bit-accurate Python reference implementations for every Lambda block. The HLS C++ in `../blocks/` must produce byte-identical output to the corresponding `golden/<block>.py` for every input vector in the block's testbench.

## Files (to be written)

- `mate.py` — MatE PE microarchitecture + 8×8 systolic array + INT8×INT4 + INT24 K-axis acc. Both dataflow modes (weight-stationary, output-stationary for Q·K^T).
- `kce.py` — 16-pt Walsh-Hadamard butterfly + Lloyd-Max 8-centroid classifier + bit-pack. All 5 CSR modes.
- `vecu.py` — 8-lane FP/BF SIMD + exp/rsqrt/sigmoid LUTs + online softmax + RoPE.
- `msc.py` — 128-entry block table + DMA FSM + LPDDR timing model (high-level).
- `lsu.py` — 32-inst decoder + 3-lane dispatch + register file.
- `hif.py` — CSR access + doorbell + JTAG (control-plane only; no USB protocol emulation).

## Cross-block reference

- `full_chip.py` — composes all the above into an end-to-end cycle-approximate model of a decode token through the chip on Llama-3.2-3B or another target model. Goal: produce token-level outputs that match a CPU run of the same model at W4A8 + TurboQuant 4.0 bpe quantization to within rounding tolerance.

## Verification flow

```
1. arch.yml describes the block (numbers + interfaces).
2. golden/<block>.py implements it bit-exactly in Python (~100-300 lines).
3. tests/<block>_tb.py generates input vectors and golden output bit-vectors.
4. blocks/<block>/<block>.cpp implements it in Stratus-synthesizable C++.
5. Stratus testbench runs the same input vectors; comparison must match.
```

Any divergence between Python and HLS is an HLS bug (`arch.yml` is the spec; Python is the executable spec; HLS is the implementation).
