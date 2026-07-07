# KVE — KV Cache Engine (ChannelQuant)  [dir kept as `kce/` for HLS continuity]

**Spec source:** `../../../arch.yml` block `kv_compression_engine` and definitive `KVE`.

> **Codec of record: ChannelQuant.** The block is the **KVE (KV Cache Engine)**. The directory name `kce/` and any `kce`/`hadamard16` code identifiers are retained for HLS continuity only. The full block RTL is complete through Sky130 sign-off in the `kv-cache-engine` repo. Physical PD numbers at TSMC 16nm (area/power/Fmax) are **TBD — pending re-measurement for ChannelQuant**.

## What this block is

- **Headline research IP:** first-silicon streaming implementation of the **ChannelQuant** KV codec.
- **Keys:** per-channel INT4, grouped **G=128**, with **D per-channel FP16 scales**.
- **Values:** per-token INT4 (INT8 in the CQ-8 tier).
- **Outliers:** a **static top-k (k=2)** FP16 outlier-channel lane, selected by a calibrated **ROM mask**.
- **Tiers:** **CQ-8** (per-token INT8 K+V) · **CQ-4** (per-channel INT4 K / per-token INT4 V, primary) · **CQ-4+** (CQ-4 + k=2 FP16 outlier channels, near-lossless).
- **Compression:** ~3.8× vs FP16 at ~4 bits/value (measured bits/value ≈ 4.13–4.38 depending on head dim D).
- **Accuracy:** near-lossless — HellaSwag acc_norm within ~0.4–0.8 pt of FP16 at CQ-4+ on Qwen2-0.5B/1.5B.
- **Provenance:** recipe follows **KIVI (ICML 2024)** / **KVQuant (2024)**; Longhorn's contribution is the streaming silicon implementation. TurboQuant (arXiv 2504.19874) is cited prior work only; its pure history lives on the `legacy/turboquant` branch.

## Microarchitecture

- **Per-channel scale bank** — holds the D per-channel FP16 scales for the current key group (derived from per-channel amax over the G=128 group, `scale_c = amax_c / 7`).
- **Serialized fp16 divider** — one shared fp16 compute unit (scale / quant / dequant) is time-multiplexed across the D channels: a **single divide cone**, not a wide parallel array. Same cone runs in reverse on the read path for dequant.
- **Outlier ROM mask** — the calibrated static top-k (k=2) selection of the outlier channels; those channels bypass INT4 quantization and are held FP16 in the outlier lane.
- **Unified per-channel SRAM record** — `{tag, D×FP16 scale field, D×INT4 code}` per group. Values are quantized per-token (INT4/INT8) against a per-token scale.
- **Decompress path** — per-channel `INT4_code · FP16_scale` (+ FP16 replay for outlier channels). Keys are dequantized per-channel **before** the Q·K^T score matmul in MatE; there is **no** compressed-domain / raw-index read path.

## Files

- `kce.h`, `kce.cpp` — top-level Stratus entity (identifier kept for HLS continuity).
- `hadamard16.h`, `codebook.h` — **LEGACY TurboQuant HLS implementation** (16-pt Walsh-Hadamard butterfly + Lloyd-Max codebook). These predate the ChannelQuant codec of record and are **pending ChannelQuant reimplementation** — retained (not deleted) for reference; the pure TurboQuant history is on the `legacy/turboquant` branch.
- `tb/` — testbench validating bit-exact against Python golden (peer of `stratus/`).
- `stratus/project.tcl` — Stratus HLS project (canonical syntax in [`../../../docs/tools-overview.md`](../../../docs/tools-overview.md)).
