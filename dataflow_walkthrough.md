# Lambda — Unit-by-Unit Dataflow Walkthrough

A guided tour of every block in Lambda, walked through in the order data actually flows during a decode token. Each block becomes concrete as it appears in the journey of one token through one layer.

**Setting:** the user has been chatting for a while, KV cache is partially built up, the chip is about to generate token #42. Model: Llama-3.2-3B (3072-dim hidden, 28 layers, 8 KV heads × 128 dim).

**Companions:**
- [`arch.yml`](arch.yml) — machine-readable spec with all numbers
- [`STATUS.md`](STATUS.md) — iteration history, audit log, open questions, LPDDR PHY tradeoff
- [`floorplan.html`](floorplan.html) — visual floorplan + area accounting
- [`src/`](src/) — HLS C++ implementation (Cadence Stratus)

---

## Stage 0 — Before any decode: the boot

When you slot Lambda's M.2 2280 card into your laptop or dev board's M.2 slot, the very first block to wake up is the **HIF (Host Interface)**. It's a PCIe Gen3 x1 endpoint — the M.2 connector wires 4 PCIe lanes by spec, but Lambda's on-die PHY drives only x1, so PCIe link training negotiates the link down to x1 cleanly. Sustained throughput on the link is ~1 GB/s. Inside the chip, HIF sits at the perimeter of the die (a ~0.55 mm² block) and has three responsibilities at boot: enumerate as a PCIe endpoint on your host, expose a CSR (Configuration / Status Register) interface via PCIe BAR0 so the host driver can poke the chip's control registers, and provide a JTAG + scan-chain debug port on dedicated pins (separate from the PCIe lanes) for if something breaks.

The host driver does two things over HIF: (1) writes ~3K instructions of microcode into the LSU's instruction RAM (this is the pre-compiled schedule for "run Llama-3.2-3B"), and (2) initiates a 1.5 GB DMA transfer of the W4-quantized weights from your laptop's RAM into the chip's external LPDDR5X package. At PCIe Gen3 x1 (~1 GB/s), that takes ~1.5 seconds — a one-time cost per power-on. After that, weights live off-chip in DRAM forever.

Now the chip is armed. You type a prompt. The host writes a doorbell into one of HIF's 16 doorbell-queue entries. HIF asserts an interrupt. The LSU wakes up.

---

## Stage 1 — The LSU fires the layer-0 schedule

The **LSU (Layer Sequencer Unit)** is the chip's brain. It's a tiny 3-stage in-order RISC pipeline (fetch → decode → dispatch) with 16 general-purpose registers and a 4 KB microcode RAM holding the entire pre-compiled program. About 0.10 mm² of silicon — minuscule by CPU standards because it has nothing CPUs need: no branch predictor, no out-of-order execution, no cache hierarchy, no virtual memory. Transformer decode is structurally identical layer-to-layer, so a static schedule walked deterministically is enough.

The LSU's first instruction for this token is `LOAD_WEIGHTS layer=0, slice=qkv_proj`. This isn't a load instruction in the CPU sense — the LSU isn't going to hold the weights. It's a *dispatch* instruction: it tells the MSC "go fetch this slice of weights from DRAM and stage them into the weight_stream_buffer." The LSU writes a descriptor into one of the MSC's DMA request queues and immediately moves to its next instruction.

That next instruction is `ISSUE_MAT_E qkv_proj, in=act_buf, out=qkv_scratch`. The LSU now hands off control to MatE — but MatE will stall waiting for the weights MSC is fetching. The LSU continues, issuing several more instructions speculatively that all queue up behind the weight fetch.

Single-issue scalar + vector + DMA dispatch per cycle. No branches in the hot loop. The LSU is the conductor; from now on, real work happens in the orchestra.

---

## Stage 2 — MSC translates and issues

The **MSC (Memory Subsystem Controller)** receives the LSU's DMA descriptor: "fetch qkv-proj weights, layer 0, into weight_stream_buffer." MSC is the chip's memory traffic cop — about 0.18 mm² that ties together the SRAM crossbar, the LPDDR controller, the block-table TLB, and the DMA engine.

First, MSC consults its **block-table TLB** — a 128-entry associative lookup that maps logical addresses (`session_id, layer_id, block_id`) to physical addresses (either an SRAM bank+offset or a DRAM row+col). For weights, this is straightforward: layer 0's QKV projection is at a known DRAM address that the LSU baked into the schedule. Single-cycle TLB hit.

Now MSC needs to issue an actual DRAM read. It walks down to the LPDDR5X controller, which translates the request into a sequence of low-level DRAM commands honoring the timing rules: ACT (activate the row containing our address) → wait `tRCD` (~14 ns) → READ → wait `tCCD` (~5 ns) → READ → ... and tracks which banks are open so it can re-use them and avoid redundant ACTs. Open-page policy with bank-conflict avoidance. This part of MSC alone is a few thousand gates of state machine — non-trivial verification load.

The 4-port SRAM crossbar inside MSC stays quiet for now (MatE/VecU/KCE/host are all idle waiting). MSC's request goes out to the LPDDR5X PHY.

---

## Stage 3 — The PHY drives the bus

The **LPDDR5X x16 PHY** is the only mixed-signal block on the chip — licensed vendor IP from Synopsys DesignWare or Cadence Denali, ~1.20 mm² of analog circuitry that we treat as a black box. It sits at the die edge with 16 data pads (DQ0–DQ15), 2 strobe pads (DQS), clock pads (CK/CK#), and a handful of command pads (CA0–CA6, CKE, CS).

When MSC's controller sends "ACT row 0x12345 in bank 3," the PHY's command path serializes that into the right pin sequence, drives it across the package onto the LPDDR5X chip's pads, and waits. ~14 ns later the row is open. MSC issues "READ col 0x67," and now the PHY's *data path* gets active — its read leveling logic uses the DQS strobes coming back from the DRAM to time-align the 8533 Mbps DQ signals into the chip's 1 GHz clock domain. There's an actual eye-margin / timing-recovery loop running continuously to keep this aligned across temperature and voltage drift.

8533 Mbps × 16 lanes / 8 = 17 GB/s peak, ~12 GB/s sustained after the bank-conflict and refresh overhead settles. The data lands back in MSC's read buffer ~30 ns after the READ command issued.

This is the entire performance bottleneck of the chip — every gate of compute we built is fed through this 12 GB/s soda straw.

---

## Stage 4 — Weights land in SRAM, MatE wakes up

MSC writes the freshly-fetched weights into the **`weight_stream_buffer` SRAM bank** — a 0.05 MB single-port SRAM macro (~0.05 mm²) at the perimeter of MatE. This bank is *tiny* on purpose: at 12 GB/s with ~100 ns first-byte latency, the minimum-buffer-to-hide-latency is 1.2 KB. We have 50 KB, which is 40× minimum — ample double-buffering plus a small warm-cache for hot weight slices like the LM head.

The other three SRAM banks deserve introduction now too, because MatE is about to read from one and write to another:

- **`activation_buffer` (0.3 MB, 2-port)** — holds the input vector `act_buf` (the previous layer's output, residual-summed and norm'd). 2-port because MatE is going to read it while VecU writes the next iteration's update. ~0.26 mm².
- **`kv_scratchpad` (0.4 MB, 1-port)** — the headline bank. Holds compressed K and V from the last several thousand tokens of this layer. We'll touch it later in this stage's attention step.
- **`codebook_const_rom` (64 KB, 1-port read-only)** — the Lloyd-Max centroids, RoPE freq table, and exp/sigmoid/rsqrt LUTs. Read by KCE and VecU; never written.

Total on-chip SRAM: 0.8 MB across these four banks, ~0.71 mm² of die. KV-dominant by 50% intentionally — long-context decode is KV-bandwidth-bound; weight buffer just needs to hide LPDDR latency.

Now MatE has weights in front of it and an activation vector available. Time to compute.

---

## Stage 5 — MatE does the QKV projection

The **MatE (Matrix Engine)** is 0.10 mm² of pure compute: an 8×8 grid of identical PEs (Processing Elements), each containing one INT8×INT4 multiplier and an INT16 partial-product register; INT24 K-axis accumulators sit at the column outputs (INT16 alone would saturate after ~64 accumulations in the worst case — that was a bug in earlier spec drafts; see STATUS.md §4).

```
       a0   a1   a2  ···  a7      ← activations stream right (INT8)
        ↓    ↓    ↓        ↓
W00 → [PE]–[PE]–[PE]– ··· –[PE]
        ↓    ↓    ↓        ↓
W10 → [PE]–[PE]–[PE]– ··· –[PE]
        ↓    ↓    ↓        ↓
       ···  ···  ···       ···
        ↓    ↓    ↓        ↓
W70 → [PE]–[PE]–[PE]– ··· –[PE]
        ↓    ↓    ↓        ↓
       o0   o1   o2 ···  o7      ← partial sums propagate down (INT16 per cycle → INT24 K-axis acc)
```

The schedule for QKV projection of Llama-3.2-3B (3072-dim hidden × 4096-dim QKV) is "tile this 3072×4096 GEMM into 8×8 chunks and stream them through the array." Weights pin first: 64 INT4 weight values latch into the 64 PEs (one per PE — this is what "weight-stationary" means). Then activations arrive: 8 INT8 values on the left edge cycle 1, 8 more on the left edge cycle 2 staggered downward, and so on. Every cycle, every PE multiplies its pinned weight by its incoming activation, adds the result to its INT16 partial register, and passes the activation rightward. The bottom row of column outputs feeds into INT24 K-axis accumulators that walk across the K-dimension tile boundary.

Compute throughput: 64 PEs × 2 ops/cycle (mul + add) × 1 GHz = 128 GOPS peak. For the 3072-dim QKV projection on a single token, that's ~25M ops, completing in ~0.2 ms. The 1.6× compute headroom over the bandwidth-bound floor means MatE finishes well before the next batch of weights arrives — it idles waiting on memory. Bandwidth, not compute, gates throughput.

The output is the new `qkv_scratch` — three vectors (Q, K, V), 3072 elements wide each, sitting in `activation_buffer`.

---

## Stage 6 — VecU applies RoPE to Q and K

The **VecU (Vector Unit)** is 0.144 mm² of programmable SIMD — 8 lanes × 16-bit FP/BF, sharing 1 KB of microcode RAM and 4 KB of transcendental LUTs (exp, rsqrt, sigmoid; 64 entries each + linear interpolation logic). It's the chip's Swiss Army knife: every non-GEMM operation runs here as microcoded loops.

Right now LSU dispatches `ISSUE_VEC_U rope, q,k`. RoPE (Rotary Positional Embedding) rotates pairs of consecutive elements in Q and K by a frequency-dependent angle, encoding token position into the dot products. For a 64-dim head, RoPE divides the head into 32 pairs and rotates each pair `(x, y) → (x·cosθ - y·sinθ, x·sinθ + y·cosθ)`. The angles θ come from the RoPE freq table in `codebook_const_rom`.

VecU's microcode for RoPE is ~12 µops: load pair → load cos/sin from LUT → 4-multiply 2-add per pair → store. Eight lanes process 8 pairs in parallel, cycling through the 32 pairs in 4 microcode iterations per Q head, then again per K head. Total ~30 µops per token's Q+K rotation.

Why is VecU programmable instead of fixed-function for RoPE? Because the same SIMD lanes also run softmax, RMSNorm, SiLU, residual adds. One programmable block beats four fixed-function blocks in verification surface — a structural decision that cascaded through the architecture.

---

## Stage 7 — KCE compresses K and V into the scratchpad

LSU fires `ISSUE_KCE_COMP k → kv_scratchpad`. The **KCE (KV Compression Engine)** wakes up — 0.08 mm² of the chip's headline IP, the silicon implementation of TurboQuant.

K is a 1024-element vector (8 KV heads × 128 dim) for this token in this layer. KCE processes it in 16-element chunks. For each chunk:

```
[16-element vector, FP16]
        ↓
[16-point Walsh-Hadamard butterfly]   4 stages × 8 add/sub pairs = 32 ops
        ↓                              Mixes outliers across all coordinates
[Nearest-centroid classifier]          7 comparators × 16 lanes = 112 comparators
        ↓                              Picks closest of 8 codebook entries (3 bits each)
[Bit-pack 16 × 3-bit = 48 bits]       Plus a 16-bit magnitude header per group
        ↓
[Write to kv_scratchpad]
```

The Hadamard butterfly is just adds and subtracts arranged in a specific ±1 pattern that's mathematically equivalent to multiplying by an orthogonal rotation matrix. It "mixes" the input — if the original vector had one big outlier coordinate (a real problem in transformer KV), the butterfly spreads that outlier roughly evenly across all 16 coordinates, flattening the distribution. After the butterfly, every coordinate looks roughly Beta-distributed.

The Lloyd-Max codebook is 8 centroids in a 64-byte ROM, optimal for the Beta distribution. Each coordinate independently picks the nearest centroid — that's a 3-bit index. We pack 16 of those plus a 16-bit FP16 group scale into 64 bits per 16 elements, hitting **4.0 bits/element effective → 4.0× compression vs FP16** (the trade-off for using 16-point instead of flagship's 32-point butterfly to save area; flagship gets 3.5 bpe at 32-pt for 4.57× compression).

The killer property: zero multipliers on this entire path. Every operation is an add, comparator, or LUT lookup. That's why the whole block fits in 0.08 mm². The new compressed K (and immediately after, V) lands in `kv_scratchpad` next to all the previous tokens' KV from this same layer.

---

## Stage 8 — MatE switches modes for Q·K^T

Now we score. LSU dispatches `ISSUE_MAT_E qk_dot, q, k_compressed → scores`. MatE flips its dataflow CSR mode from weight-stationary to **output-stationary** — a single mode bit at the array boundary changes which inputs stay pinned and which stream.

For Q·K^T, Q is fixed for this token but K varies across all the past tokens we're attending to. So we pin Q in the array (8 query heads' worth, one per row) and stream past K's through. As K's flow through, MatE reads from `kv_scratchpad`. But wait — `kv_scratchpad` holds *compressed* 3-bit K values, not 16-bit. How does that work?

The trick is **compressed-domain attention scoring**. For a symmetric quantization scheme, the dot product `<Q, dequant(K_compressed)>` is mathematically equivalent to `dequant_scale × <Q, K_compressed>` — you can do the dot product in the *compressed* domain (with INT8 Q × INT3 K) and apply the scale once at the row sum. This means MatE never has to dequant K back to FP16 just to score it; the multipliers run on tiny 3-bit operands, partial products live in INT16 inside each PE, and the K-axis accumulator at the column edge is INT24 (sufficient for head_dim up to ~4K).

The output is the scores tensor — one number per past token in the context, per query head. For our running example with ~3000 tokens of accumulated context, that's ~3000 × 8 query-head scores.

---

## Stage 9 — VecU runs online softmax (the heart of FlashAttention-3)

LSU fires `ISSUE_VEC_U softmax_online, scores`. This is the cleverest microcode in the chip.

Naive softmax computes `exp(scores - max(scores)) / sum(exp(...))` — but this requires materializing the *entire* attention score matrix in SRAM before you can compute the max and the sum. With 3000-token context × 8 heads × 16-bit, that's 50 KB just for the matrix — already pushing the activation buffer.

The **FlashAttention-3 online algorithm** instead processes scores in tiles of (say) 32 at a time. Per attention row, VecU keeps just two running scalars — `m_i` (running max) and `l_i` (running sum-of-exps) — plus the running output accumulator `O_i`. When a new tile arrives:

1. Compute the new tile's max: `m_new = max(m_old, max(tile))`
2. Rescale the existing accumulators: `l_old *= exp(m_old - m_new)`, `O_old *= exp(m_old - m_new)`
3. Compute `exp(tile - m_new)` and accumulate into `l_i` and into `O_i` weighted by V's tile

The math is exactly equivalent to full softmax. The key trick: the rescaling factor `exp(m_old - m_new)` corrects for the fact that we used the wrong "max" earlier. Each row's running state is just `(m_i, l_i)` — tiny.

VecU's 8 lanes each handle one row's running state. The microcode is ~32 µops per tile (load tile → max-reduce → exp via LUT → multiply-accumulate). Over the full 3000-token attention, this runs ~100 tiles. Total ~3200 µops per softmax invocation per layer.

The exp() lookup is where the LUT pays off: 64 entries of exp(x) for x ∈ [-16, 0] with linear interpolation, 0.05 ULP error. Hardware cost: a 64×16-bit ROM and ~50 gates of interp logic. The whole online-softmax block fits in fewer than 100 cycles per tile.

---

## Stage 9.5 — TIU absorbs the softmax weights as importance signal

Inside the same softmax tile loop, VecU broadcasts a side-channel signal to the **TIU (Token Importance Unit)** — 0.03 mm² of dedicated SRAM + accumulator. For each 16-token KV block that contributed to this attention pass, VecU sends the cumulative softmax weight that fell on that block; TIU adds it to a 16-bit importance register for that block (256 B total SRAM across 128 blocks).

The TIU update is essentially free: it piggybacks on the softmax tile cadence with one extra microcode op per tile (~1 µop adds across 100 tiles = ~100 extra µops per layer). The cumulative importance per block is what downstream consumers use:

- **MSC eviction policy** — when the kv_scratchpad fills, MSC asks TIU for the lowest-importance block and evicts that one (H2O-style heavy-hitter retention)
- **KCE-mini per-block precision** — when KCE re-compresses an evicted-and-recalled block, it queries TIU to decide whether to keep it at 4.0 bpe (high importance) or demote to 3.0 bpe (mid) or 2.0 bpe (low importance, attention-sink-like)

TIU is the silicon expression of arXiv 2604.04722's adaptive-precision-KV idea. It's brand new to Lambda v0.4 (added 2026-05-14 after the Phase 0 audit decisions). The CSR mode field `tiu_eviction_policy` lets the chip switch among off / H2O / streaming-LLM / adaptive-precision policies — useful both as a research ablation knob and as a per-workload tuning lever.

---

## Stage 10 — MatE does softmax · V → attention output

LSU dispatches `ISSUE_MAT_E pv, softmax_scores · v_compressed → attn_out`. MatE goes back to normal weight-stationary dataflow but with V (compressed in scratchpad, dequantized on the fly through KCE inverse path) as the streaming operand.

Wait — in the FlashAttention-3 algorithm, `softmax_scores · V` was actually accumulated *during* the softmax tile loop in stage 9, not as a separate GEMM. So strictly speaking VecU and MatE are interleaving on a per-tile basis: tile-of-K arrives → MatE scores → VecU updates softmax + accumulates `O += weighted V`. When the last tile is consumed, `O` is the final attention output.

This interleaving is what makes FA-3 efficient — there's no intermediate "scores" tensor to materialize, and `O` is accumulated incrementally. The schedule on the LSU explicitly orchestrates the cycle-by-cycle handoff between MatE (compute Q·K^T tile and softmax·V tile) and VecU (update m_i, l_i and rescale O_i). The two blocks run *in parallel* with VecU consuming what MatE just produced.

After the last tile, `attn_out` is in `activation_buffer`. Next: MatE does the attention output projection (a 1024 × 3072 GEMM with a different set of weights). Same dataflow as Stage 5, different weights.

---

## Stage 11 — The FFN sandwich

Three more dispatches in quick succession:

1. **`ISSUE_MAT_E ffn_up`** — MatE computes a 3072 × 8192 projection (Llama-3 family uses ~2.67× hidden expansion). Weights stream from LPDDR via the weight_stream_buffer. This is by far the largest GEMM in the layer — ~25M MACs.
2. **`ISSUE_VEC_U silu_mul`** — VecU runs SiLU (x · sigmoid(x)) on the 8192-element FFN intermediate. The sigmoid LUT in `codebook_const_rom` gets queried; 8 lanes process 1024 chunks at a time; ~50 µops total.
3. **`ISSUE_MAT_E ffn_down`** — MatE computes 8192 × 3072 projection back to hidden size. Another LPDDR weight stream; another big GEMM.

These three together are ~70% of the layer's compute and ~70% of the layer's LPDDR traffic. The other 30% is the QKV projection, attention output projection, and the norms.

---

## Stage 12 — VecU finishes the layer with norm + residual

`ISSUE_VEC_U rmsnorm_residual`. VecU pulls the layer's residual stream from `activation_buffer`, adds the FFN output, computes the RMS over the 3072 elements, looks up `1/sqrt(rms)` from the rsqrt LUT, multiplies through, and writes back. ~40 µops; the rsqrt is the hot transcendental on this path.

This is the layer's output. The activation_buffer now holds the input for layer 1.

LSU's PC increments to the layer-1 schedule. 28 layers total for Llama-3.2-3B; we just finished layer 0. Each layer is ~135 ms of LPDDR-bound time on this chip. Total per-token time: 28 × ~5 ms-per-layer LPDDR-bound ≈ 134 ms. Tok/s ≈ 7.4.

We loop back to stage 1 with `layer = 1` until LSU reaches the final `LM_HEAD` instruction.

---

## Stage 13 — Sample, send, repeat

After layer 27, LSU fires `ISSUE_MAT_E lm_head` — a 3072 × 128256 projection from the final hidden state to vocabulary logits. VecU runs sampling (top-k, top-p, temperature; ~30 µops). The chosen token ID — a single 17-bit integer — goes into a tiny TX buffer.

HIF picks it up, packetizes it as a PCIe memory write to a host-allocated ring buffer (or signals a doorbell interrupt for a streaming-mode read). Your laptop's driver hands it to whatever runtime is reading from the chip (a llama.cpp backend, a custom Python loop, whatever). Your screen prints "the".

LSU resets its PC to layer 0 with the new token's hidden vector seeded into `activation_buffer`. Next decode pass starts immediately. The token-2-token loop runs ~125-135 ms per token — that's your 7-8 tok/s.

---

## The data flow as a whole

```
HIF (boot) ──▶ LPDDR (weights at rest)
                                                     ┌── prefetch (concurrent) ──┐
LSU ──▶ MSC ──▶ PHY ──▶ LPDDR ──▶ PHY ──▶ MSC ──▶ weight_stream_buffer ──▶ MatE
       (translate)               (DRAM read)        (SRAM staging)         │
                                                                            ▼
activation_buffer ◀── VecU (RoPE) ◀── MatE (QKV proj output) ──▶ KCE ──▶ kv_scratchpad
                                                                            │
                       MatE (output-stationary) ◀── kv_scratchpad ◀────────┘
                       (Q·K^T compressed-domain)
                                ▼
                       VecU (online softmax) ────▶ MatE (softmax·V) ──▶ attn_out
                                                                            │
                                                                            ▼
                       MatE (FFN up) ──▶ VecU (SiLU) ──▶ MatE (FFN down) ──▶ residual
                                                                            │
                                                                            ▼
                       VecU (RMSNorm) ──▶ activation_buffer (next layer's input)
                                                                            │
                                                                            └── (loop)
```

Eight blocks. One assembly line. Every cycle, somewhere on the chip, a multiplier is firing or a Hadamard is butterflying or a softmax is updating. The whole thing is choreographed by the LSU's pre-compiled program — no runtime decisions, no branch prediction, no surprises.

That's Lambda v2 from the inside out.
