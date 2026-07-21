# Golden Models

Bit-accurate Python reference implementations for every Lambda block. The HLS C++ in `../blocks/` must produce byte-identical output to the corresponding `golden/<block>.py` for every input vector in the block's testbench.

## Files (to be written)

- `mate.py` — MatE PE microarchitecture + 8×8 systolic array + INT8×INT4 + FP16 (P·V) + INT24 K-axis acc. INT8×INT4 for weight/FFN GEMMs, plus a per-tile FP16 P·V mode selected by the ACU precision controller. Both dataflow modes (weight-stationary, output-stationary for Q·K^T).
- `kce.py` — KVE ChannelQuant reference: per-channel INT4 K (grouped G=128, D FP16 scales) + per-token INT4 V + static top-k (k=2) FP16 outlier lane via ROM mask; decompress = per-channel `INT4·FP16`; tiers CQ-8/CQ-4/CQ-4+. *(File name kept for HLS continuity; ChannelQuant is not codebook-based.)*
- `vecu.py` — 8-lane FP/BF SIMD + exp/rsqrt/sigmoid LUTs + online softmax + RoPE.
  - **Decode online-softmax slice: written** — `attention-compute-unit/sw/reference_model/vecu_softmax_ref.py` (64-entry exp LUT + linear interp + online running-max/running-sum recurrence with the `exp(m_old-m_new)` rescale; the golden the `vecu_softmax` RTL is bit-exact to). RoPE / RMSNorm / SiLU / the full 8-lane microcode are still to be written.
- `msc.py` — 128-entry block table + DMA FSM + LPDDR timing model (high-level).
- `lsu.py` — 32-inst decoder + 3-lane dispatch + register file.
- `hif.py` — CSR access + doorbell + JTAG (control-plane only; no USB protocol emulation).

## Cross-block reference

- `full_chip.py` — composes all the above into an end-to-end cycle-approximate model of a decode token through the chip on Qwen2-1.5B (the ≤1.5B validation target) or another target model. Goal: produce token-level outputs that match a CPU run of the same model at W4A8 + ChannelQuant (CQ-4 / CQ-4+) quantization to within rounding tolerance.

## Verification flow

```
1. arch.yml describes the block (numbers + interfaces).
2. golden/<block>.py implements it bit-exactly in Python (~100-300 lines).
3. tests/<block>_tb.py generates input vectors and golden output bit-vectors.
4. blocks/<block>/<block>.cpp implements it in Stratus-synthesizable C++.
5. Stratus testbench runs the same input vectors; comparison must match.
```

Any divergence between Python and HLS is an HLS bug (`arch.yml` is the spec; Python is the executable spec; HLS is the implementation).
