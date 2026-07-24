# Lambda — Unit-by-Unit Dataflow Walkthrough

A guided tour of every block in Lambda, walked through in the order data actually flows during a decode token. Each block becomes concrete as it appears in the journey of one token through one layer.

**Setting:** the user has been chatting for a while — 1500 tokens of accumulated context — and the chip is about to generate token #1500. That depth is chosen deliberately: 1500 tokens is 94 blocks of 16, comfortably inside the block table's 128-entry × 16-token = 2048-token coverage, but well past the ~409 tokens/layer the kv_scratchpad can hold — so the walkthrough exercises both the SRAM hit path and the LPDDR spill path. Model: Llama-3.2-3B (3072-dim hidden, 28 layers, 24 query heads / 8 KV heads, head_dim 128, grouped-query attention).

**Companions:**
- [`arch.yml`](arch.yml) — machine-readable spec with all numbers
- [`STATUS.md`](STATUS.md) — iteration history, audit log, open questions, LPDDR PHY tradeoff
- [`floorplan.html`](floorplan.html) — visual floorplan + area accounting
- [`src/`](src/) — HLS C++ implementation (Cadence Stratus)

---

## Stage 0 — Before any decode: the boot

When you slot Lambda's M.2 2280 card into your laptop or dev board's M.2 slot, the very first block to wake up is the **HIF (Host Interface)**. It's a PCIe Gen3 x1 endpoint — the M.2 connector wires 4 PCIe lanes by spec, but Lambda's on-die PHY drives only x1, so PCIe link training negotiates the link down to x1 cleanly. Sustained throughput on the link is ~0.985 GB/s after protocol overhead. Inside the chip, HIF sits at the perimeter of the die (a ~0.55 mm² block) and has three responsibilities at boot: enumerate as a PCIe endpoint on your host, expose a CSR (Configuration / Status Register) interface via PCIe BAR0 so the host driver can poke the chip's control registers, and provide a JTAG + scan-chain debug port on dedicated pins (separate from the PCIe lanes) for if something breaks.

The host driver does two things over HIF: (1) writes ~3K instructions of microcode into the LSU's instruction RAM (this is the pre-compiled schedule for "run Llama-3.2-3B"), and (2) initiates a 1.605 GB DMA transfer of the W4-quantized weights from your laptop's RAM into the chip's external LPDDR5X package. At PCIe Gen3 x1 (~0.985 GB/s sustained), that takes ≈1.6 seconds — a one-time cost per power-on. After that, weights live off-chip in DRAM forever.

Now the chip is armed. You type a prompt. The host writes a doorbell into one of HIF's 16 doorbell-queue entries. HIF asserts an interrupt. The LSU wakes up.

---

## Stage 1 — The LSU fires the layer-0 schedule

The **LSU (Layer Sequencer Unit)** is the chip's brain. It's a tiny 3-stage in-order RISC pipeline (fetch → decode → dispatch) with 16 general-purpose registers and a 16 KB microcode RAM — 4K instructions at 32 bits each — holding the entire pre-compiled program (the 28-layer Llama-3.2-3B schedule uses ~3K of those slots). About 0.10 mm² of silicon — minuscule by CPU standards because it has nothing CPUs need: no branch predictor, no out-of-order execution, no cache hierarchy, no virtual memory. Transformer decode is structurally identical layer-to-layer, so a static schedule walked deterministically is enough.

The LSU's first instruction for this token is `LOAD_WEIGHTS layer=0, slice=qkv_proj`. This isn't a load instruction in the CPU sense — the LSU isn't going to hold the weights. It's a *dispatch* instruction: it tells the MSC "go fetch this slice of weights from DRAM and stage them into the weight_stream_buffer." The LSU writes a descriptor into one of the MSC's DMA request queues and immediately moves to its next instruction.

That next instruction is `ISSUE_MAT_E qkv_proj, in=act_buf, out=qkv_scratch`. The LSU now hands off control to MatE — but MatE will stall waiting for the weights MSC is fetching. The LSU continues, issuing several more instructions speculatively that all queue up behind the weight fetch.

Single-issue scalar + vector + DMA dispatch per cycle. No branches in the hot loop. The LSU is the conductor; from now on, real work happens in the orchestra.

---

## Stage 2 — MSC translates and issues

The **MSC (Memory Subsystem Controller)** receives the LSU's DMA descriptor: "fetch qkv-proj weights, layer 0, into weight_stream_buffer." MSC is the chip's memory traffic cop — about 0.18 mm² that ties together the SRAM crossbar, the LPDDR controller, the block-table TLB, and the DMA engine.

First, MSC consults its **block-table TLB** — a 128-entry associative lookup that maps logical addresses (`session_id, layer_id, block_id`) to physical addresses (either an SRAM bank+offset or a DRAM row+col). For weights, this is straightforward: layer 0's QKV projection is at a known DRAM address that the LSU baked into the schedule. Single-cycle TLB hit.

Now MSC needs to issue an actual DRAM read. It walks down to the LPDDR5X controller, which translates the request into a sequence of low-level DRAM commands honoring the timing rules: ACT (activate the row containing our address) → wait `tRCD` (~18 ns per JEDEC LPDDR5X) → READ → 16-beat data burst (~1.9 ns at 8533 MT/s) → READ → ... and tracks which banks are open so it can re-use them and avoid redundant ACTs. Open-page policy with bank-conflict avoidance. This part of MSC alone is a few thousand gates of state machine — non-trivial verification load.

The 4-port SRAM crossbar inside MSC stays quiet for now (MatE/VecU/KCE/host are all idle waiting). MSC's request goes out to the LPDDR5X PHY.

---

## Stage 3 — The PHY drives the bus

The **LPDDR5X x16 PHY** is the only mixed-signal block on the chip — licensed vendor IP from Synopsys DesignWare or Cadence Denali, ~1.20 mm² of analog circuitry that we treat as a black box. It sits at the die edge with 16 data pads (DQ0–DQ15), 2 strobe pads (DQS), clock pads (CK/CK#), and a handful of command pads (CA0–CA6, CKE, CS).

When MSC's controller sends "ACT row 0x12345 in bank 3," the PHY's command path serializes that into the right pin sequence, drives it across the package onto the LPDDR5X chip's pads, and waits. ~18 ns later the row is open. MSC issues "READ col 0x67," and now the PHY's *data path* gets active — its read leveling logic uses the DQS strobes coming back from the DRAM to time-align the 8533 Mbps DQ signals into the chip's 1 GHz clock domain. There's an actual eye-margin / timing-recovery loop running continuously to keep this aligned across temperature and voltage drift.

8533 Mbps × 16 lanes / 8 = 17 GB/s peak, ~12 GB/s sustained after the bank-conflict and refresh overhead settles. The data lands back in MSC's read buffer ~30 ns after the READ command issued.

This is the entire performance bottleneck of the chip — every gate of compute we built is fed through this 12 GB/s soda straw.

---

## Stage 4 — Weights land in SRAM, MatE wakes up

MSC writes the freshly-fetched weights into the **`weight_stream_buffer` SRAM bank** — a 0.05 MB single-port SRAM macro (~0.05 mm²) at the perimeter of MatE. This bank is *tiny* on purpose: at 12 GB/s with ~100 ns first-byte latency, the minimum-buffer-to-hide-latency is 1.2 KB. We have 50 KB, which is 40× minimum — ample double-buffering headroom. To be clear about what this buffer is *not*: it is latency-hiding only. Against a 197 MB LM head, a 50 KB "warm cache" is a rounding error — every weight byte streams from LPDDR every token.

The other three SRAM banks deserve introduction now too, because MatE is about to read from one and write to another:

- **`activation_buffer` (0.3 MB, 2-port)** — holds the input vector `act_buf` (the previous layer's output, residual-summed and norm'd). 2-port because MatE is going to read it while VecU writes the next iteration's update. ~0.26 mm².
- **`kv_scratchpad` (0.4 MB, 1-port)** — the headline bank. At 4.0 bits/element, one token's K+V for one layer is 1 KB (2 × 1024 elements × 0.5 B), so it holds the ~409 hottest tokens of the current layer; at our 1500-token depth the other ~1,100 tokens' blocks stream in from LPDDR on demand. We'll touch it later in the attention step.
- **`codebook_const_rom` (64 KB, 1-port read-only)** — the RoPE freq table and the Lloyd-Max centroids (the centroid table itself is just 8 × 16-bit = 16 B of it). Read by KCE and VecU; never written. The exp/sigmoid/rsqrt LUTs are *not* here — they live inside VecU (Stage 6).

Total on-chip SRAM: 0.8 MB across these four banks, ~0.71 mm² of die. KV-dominant by 50% intentionally — long-context decode is KV-bandwidth-bound; weight buffer just needs to hide LPDDR latency.

Now MatE has weights in front of it and an activation vector available. Time to compute.

---

## Stage 5 — MatE does the QKV projection

The **MatE (Matrix Engine)** is 0.10 mm² of pure compute: an 8×8 grid of identical PEs (Processing Elements), each containing one INT8×INT4 multiplier and an INT16 partial-product register; INT24 K-axis accumulators sit at the column outputs (INT16 alone would saturate after ~64 accumulations in the worst case — that was a bug in earlier spec drafts; see STATUS.md §4).

```
      (64 INT4 weights pinned, one per PE)

a0 → [PE]–[PE]–[PE]– ··· –[PE]     ← activations enter the left edge (INT8),
       ↓    ↓    ↓          ↓        one row per cycle of stagger,
a1 → [PE]–[PE]–[PE]– ··· –[PE]       and flow rightward
       ↓    ↓    ↓          ↓
      ···  ···  ···        ···
       ↓    ↓    ↓          ↓
a7 → [PE]–[PE]–[PE]– ··· –[PE]
       ↓    ↓    ↓          ↓
      o0   o1   o2   ···   o7      ← partial sums propagate down (INT16 per cycle → INT24 K-axis acc)
```

The schedule for QKV projection of Llama-3.2-3B (3072-dim hidden × 5120-dim QKV output: 3072 for Q's 24 heads, plus 1024 each for K and V's 8 shared GQA heads) is "tile this 3072×5120 GEMM into 8×8 chunks and stream them through the array." Weights pin first: 64 INT4 weight values latch into the 64 PEs (one per PE — this is what "weight-stationary" means). Then activations arrive: 8 INT8 values on the left edge cycle 1, 8 more on the left edge cycle 2 staggered downward, and so on. Every cycle, every PE multiplies its pinned weight by its incoming activation, adds the result to its INT16 partial register, and passes the activation rightward. The bottom row of column outputs feeds into INT24 K-axis accumulators that walk across the K-dimension tile boundary.

Compute throughput: 64 PEs × 2 ops/cycle (mul + add) × 1 GHz = 128 GOPS peak. The QKV projection on a single token is 2 × 3072 × 5120 ≈ 31.5M ops — about 0.25 ms of pure compute at peak. But the stage time isn't set by compute: the 3072 × 5120 INT4 weight slice is 7.9 MB, and 7.9 MB / 12 GB/s ≈ 0.66 ms of DMA. MatE finishes each tile well before the next batch of weights arrives — it idles waiting on the DMA. Bandwidth, not compute, gates throughput.

The output is the new `qkv_scratch` — three vectors sitting in `activation_buffer`: Q is 3072 wide (24 heads × 128), while K and V are 1024 wide each (8 KV heads × 128 — GQA shares each KV head across 3 query heads).

---

## Stage 6 — VecU applies RoPE to Q and K

The **VecU (Vector Unit)** is 0.144 mm² of programmable SIMD — 8 lanes × 16-bit FP/BF, sharing 4 KB of microcode RAM (1K instructions) and 384 B of transcendental LUTs (exp, rsqrt, sigmoid; 64 × 16-bit entries each = 3 × 128 B, plus linear-interpolation logic). It's the chip's Swiss Army knife: every non-GEMM operation runs here as microcoded loops.

Right now LSU dispatches `ISSUE_VEC_U rope, q,k`. RoPE (Rotary Positional Embedding) rotates pairs of consecutive elements in Q and K by a frequency-dependent angle, encoding token position into the dot products. For a 128-dim head, RoPE divides the head into 64 pairs and rotates each pair `(x, y) → (x·cosθ - y·sinθ, x·sinθ + y·cosθ)`. The angles θ come from the RoPE freq table in `codebook_const_rom`.

VecU's microcode for RoPE is ~12 µops per iteration: load pair → load cos/sin from LUT → 4-multiply 2-add per pair → store. Eight lanes process 8 pairs in parallel, cycling through a head's 64 pairs in 8 microcode iterations. Across 24 Q heads + 8 K heads, that's 32 heads × 8 iterations × ~12 µops ≈ 3,100 µops per token's Q+K rotation — at 1 GHz, single-digit microseconds, invisible next to the millisecond-scale weight streams.

Why is VecU programmable instead of fixed-function for RoPE? Because the same SIMD lanes also run softmax, RMSNorm, SiLU, residual adds. One programmable block beats four fixed-function blocks in verification surface — a structural decision that cascaded through the architecture.

---

## Stage 7 — KCE compresses K and V into the scratchpad

LSU fires `ISSUE_KCE_COMP k → kv_scratchpad`. The **KCE (KV Compression Engine)** wakes up — 0.08 mm² of the chip's headline IP, the silicon implementation of TurboQuant.

K is a 1024-element vector (8 KV heads × 128 dim) for this token in this layer. KCE processes it in 16-element chunks. For each chunk:

```
[16-element vector, FP16]
        ↓
[16-point Walsh-Hadamard butterfly]   4 stages × 8 butterflies × 2 = 64 add/sub ops
        ↓                              Mixes outliers across all coordinates
[Nearest-centroid classifier]          7 comparators × 16 lanes = 112 comparators
        ↓                              Picks closest of 8 codebook entries (3 bits each)
[Bit-pack 16 × 3-bit = 48 bits]       Plus a 16-bit magnitude header per group
        ↓
[Write to kv_scratchpad]
```

The Hadamard butterfly is just adds and subtracts arranged in a specific ±1 pattern that's mathematically equivalent to multiplying by an orthogonal rotation matrix. It "mixes" the input — if the original vector had one big outlier coordinate (a real problem in transformer KV), the butterfly spreads that outlier roughly evenly across all 16 coordinates, flattening the distribution. After the butterfly, every coordinate looks roughly Beta-distributed.

The Lloyd-Max codebook is 8 × 16-bit centroids — all of 16 bytes of ROM — optimal for the Beta distribution. Each coordinate independently picks the nearest centroid — that's a 3-bit index. We pack 16 of those plus a 16-bit FP16 group scale into 64 bits per 16 elements, hitting **4.0 bits/element effective → 4.0× compression vs FP16** (the trade-off for using 16-point instead of flagship's 32-point butterfly to save area; flagship gets 3.5 bpe at 32-pt for 4.57× compression).

The killer property: zero multipliers in the dequant direction — reconstructing a value is a 3-bit index into a 16 B LUT, full stop. The forward (compress) path is nearly as lean: the butterfly is pure add/sub and classification is pure comparators, with one honest multiply per element for the FP16 group-scale normalization (or equivalently, scaled comparator thresholds). That near-multiplier-free profile is why the whole block fits in 0.08 mm². The new compressed K (and immediately after, V) lands in `kv_scratchpad` next to all the previous tokens' KV from this same layer.

---

## Stage 8 — MatE switches modes for Q·K^T

Now we score. LSU dispatches `ISSUE_MAT_E qk_dot, q, k_compressed → scores`. MatE flips its dataflow CSR mode from weight-stationary to **output-stationary** — a single mode bit at the array boundary changes which inputs stay pinned and which stream.

For Q·K^T, Q is fixed for this token but K varies across all the past tokens we're attending to. So we pin Q in the array, one query head per row — and since the array has 8 rows, the 24 query heads take 3 passes of 8 head-rows each — and stream past K's through. As K's flow through, MatE reads from `kv_scratchpad`. But wait — `kv_scratchpad` holds *compressed* 3-bit K indices, not 16-bit values. How does that work?

Two pieces make scoring against compressed K honest. First, the Hadamard rotation is orthogonal, so dot products are preserved in the rotated domain — but only if *both* operands live there. Q therefore takes the same 16-point WHT the stored K's took (64 add/sub per 16-element group, reusing KCE's butterfly) before scoring. Second, Lloyd-Max is a *non-uniform* codebook, so there is no shortcut of the form `scale × <Q, K_indices>` — that identity holds only for uniform quantizers. Each 3-bit index instead passes through the 8-entry index→centroid LUT (INT8 centroids; the per-group FP16 scale applies once at the row sum) on its way from the scratchpad read port into the array. The dequant is essentially free — a 16 B LUT, no multipliers — and the real win is bandwidth: the scratchpad and LPDDR serve 4.0 bits per element instead of 16, so attention moves 4× less data for the same scoring math. Partial products live in INT16 inside each PE, and the K-axis accumulator at the column edge is INT24.

The output is the scores tensor — one number per past token in the context, per query head. For our running example at token #1500, that's 1500 × 24 = 36,000 scores for this layer.

---

## Stage 9 — VecU runs online softmax (the heart of FlashAttention-3)

LSU fires `ISSUE_VEC_U softmax_online, scores`. This is the cleverest microcode in the chip.

Naive softmax computes `exp(scores - max(scores)) / sum(exp(...))` — but this requires materializing the *entire* attention score matrix in SRAM before you can compute the max and the sum. At a 3000-token context, that's 3000 × 24 heads × 2 B = 144 KB just for the matrix — roughly half the entire 0.3 MB activation buffer gone before anything else gets a byte.

The **FlashAttention-3 online algorithm** instead processes scores in tiles of 16 at a time (arch.yml allows 8–16). Per attention row, VecU keeps just two running scalars — `m_i` (running max) and `l_i` (running sum-of-exps) — plus the running output accumulator `O_i`. When a new tile arrives:

1. Compute the new tile's max: `m_new = max(m_old, max(tile))`
2. Rescale the existing accumulators: `l_old *= exp(m_old - m_new)`, `O_old *= exp(m_old - m_new)`
3. Compute `exp(tile - m_new)` and accumulate into `l_i` and into `O_i` weighted by V's tile

The math is exactly equivalent to full softmax. The key trick: the rescaling factor `exp(m_old - m_new)` corrects for the fact that we used the wrong "max" earlier. Each row's running state is just `(m_i, l_i)` — tiny. One last step after the final tile: divide through, `O_i /= l_i`, turning the running sum of exp-weighted V's into the true softmax-weighted average.

VecU's 8 lanes each handle one head-row's running state; with 24 query heads that's 3 passes of 8 head-rows, mirroring MatE's Q-pinning passes in Stage 8. The microcode is ~32 µops per tile (load tile → max-reduce → exp via LUT → multiply-accumulate). Over the 1500-token attention, that's ~94 tiles per pass × 3 passes ≈ 9,000 µops per softmax invocation per layer — still single-digit microseconds at 1 GHz.

The exp() lookup is where the LUT pays off: 64 entries of exp(x) for x ∈ [-16, 0] with linear interpolation. Accuracy is ~8e-3 max absolute error — segment width h = 16/64 = 0.25, max linear-interp error ≈ h²·max|exp″|/8 = 0.25²/8 ≈ 7.8e-3 — which is about 8 FP16 ULP at 1.0. Plenty for attention weights that get summed and renormalized anyway. Hardware cost: a 64×16-bit ROM and ~50 gates of interp logic. The whole online-softmax block fits in fewer than 100 cycles per tile.

---

## Stage 9.5 — TIU absorbs the softmax weights as importance signal

Inside the same softmax tile loop, VecU broadcasts a side-channel signal to the **TIU (Token Importance Unit)** — 0.03 mm² of dedicated SRAM + accumulator. For each 16-token KV block that contributed to this attention pass, VecU sends the cumulative softmax weight that fell on that block; TIU adds it to a 16-bit importance register for that block (256 B total SRAM across 128 blocks).

The TIU update is essentially free: it piggybacks on the softmax tile cadence with one extra microcode op per tile (~1 µop per tile across ~94 tiles × 3 head passes ≈ 280 extra µops per layer). The cumulative importance per block is what downstream consumers use:

- **MSC eviction policy** — when the kv_scratchpad fills, MSC asks TIU for the lowest-importance block and evicts that one (H2O-style heavy-hitter retention)
- **KCE-mini per-block precision** — when KCE re-compresses an evicted-and-recalled block, it queries TIU to decide whether to keep it at 4.0 bpe (high importance) or demote to 3.0 bpe (mid) or 2.0 bpe (low importance, attention-sink-like)

TIU is the silicon expression of arXiv 2604.04722's adaptive-precision-KV idea. It was added to Lambda on 2026-05-14 (Phase 0.3, after the Phase 0 audit decisions). Its `csr_modes` field lets the chip switch among `tiu_off` / `tiu_h2o` / `tiu_streaming_llm` / `tiu_adaptive_precision` — useful both as a research ablation knob and as a per-workload tuning lever.

---

## Stage 10 — MatE does softmax · V → attention output

LSU dispatches `ISSUE_MAT_E pv, softmax_scores · v_compressed → attn_out`. MatE goes back to normal weight-stationary dataflow but with V (compressed in scratchpad, dequantized on the fly through KCE inverse path) as the streaming operand.

Wait — in the FlashAttention-3 algorithm, `softmax_scores · V` was actually accumulated *during* the softmax tile loop in stage 9, not as a separate GEMM. So strictly speaking VecU and MatE are interleaving on a per-tile basis: tile-of-K arrives → MatE scores → VecU updates softmax + accumulates `O += weighted V`. When the last tile is consumed, `O` is the final attention output.

This interleaving is what makes FA-3 efficient — there's no intermediate "scores" tensor to materialize, and `O` is accumulated incrementally. The schedule on the LSU explicitly orchestrates the cycle-by-cycle handoff between MatE (compute Q·K^T tile and softmax·V tile) and VecU (update m_i, l_i and rescale O_i). The two blocks run *in parallel* with VecU consuming what MatE just produced.

After the last tile, `attn_out` is in `activation_buffer`. Next: MatE does the attention output projection — the 24 heads' outputs concatenate to 24 × 128 = 3072, so o_proj is a 3072 × 3072 GEMM (9.4M params, 4.7 MB at W4). Same dataflow as Stage 5, different weights.

---

## Stage 11 — The FFN sandwich

Four more dispatches in quick succession — Llama-3's FFN is SwiGLU, which means *three* weight matrices, not two:

1. **`ISSUE_MAT_E ffn_gate`** — MatE computes the gate projection, 3072 × 8192 (~25M MACs, ~2.67× hidden expansion). Weights stream from LPDDR via the weight_stream_buffer.
2. **`ISSUE_MAT_E ffn_up`** — the up projection, another 3072 × 8192. Same shape, different weights — a second 12.6 MB weight stream.
3. **`ISSUE_VEC_U silu_mul`** — VecU computes SiLU(gate) ⊙ up elementwise over the 8192-wide intermediate. SiLU is x · sigmoid(x), so each element is a sigmoid-LUT lookup (the LUT inside VecU), the SiLU multiply, and the gating multiply against up. 8192 elements / 8 lanes ≈ 1,024 iterations × ~3 µops ≈ 3,000+ µops — single-digit microseconds, invisible under the weight DMA.
4. **`ISSUE_MAT_E ffn_down`** — 8192 × 3072 projection back to hidden size. Another big GEMM, another weight stream.

The three FFN matrices total 3 × 3072 × 8192 = 75.5M parameters = 37.7 MB at W4 — about 75% of this layer's weight bytes (the other 25% is QKV's 7.9 MB plus o_proj's 4.7 MB). Forget the gate matrix in your mental model and you undercount the layer by a third; SwiGLU's quality win costs real bandwidth.

---

## Stage 12 — VecU finishes the layer with norm + residual

`ISSUE_VEC_U rmsnorm_residual`. VecU pulls the layer's residual stream from `activation_buffer`, adds the FFN output, computes the RMS over the 3072 elements, looks up `1/sqrt(rms)` from the rsqrt LUT, multiplies through, and writes back. 3072 elements / 8 lanes ≈ 384 iterations puts this at ~1,200+ µops — a microsecond and change at 1 GHz; the rsqrt is the hot transcendental on this path.

This is the layer's output. The activation_buffer now holds the input for layer 1.

LSU's PC increments to the layer-1 schedule. 28 layers total for Llama-3.2-3B; we just finished layer 0. Each layer streams ~50.3 MB of W4 weights (7.9 QKV + 4.7 o_proj + 37.7 FFN) — ~4.2 ms of LPDDR-bound time per layer. Per **token**: 28 × ~4.2 ms ≈ 117 ms, plus 16.4 ms for the 197 MB LM head (Stage 13), plus ~3 ms of off-scratchpad KV streaming at our 1500-token depth (≈1,100 spilled tokens × 1 KB × 28 layers ≈ 31 MB) — **~137 ms per token**. The headline 134 ms / 7.4 tok/s in arch.yml is the weights-only floor: 1.605 GB / 12 GB/s.

We loop back to stage 1 with `layer = 1` until LSU reaches the final `LM_HEAD` instruction.

---

## Stage 13 — Sample, send, repeat

After layer 27, LSU fires `ISSUE_MAT_E lm_head` — a 3072 × 128256 projection from the final hidden state to vocabulary logits; at 197 MB of W4 weights (tied with the embedding), this single matrix is 16.4 ms of streaming, the most expensive dispatch in the schedule. VecU then runs sampling (top-k, top-p, temperature) — a scan over all 128,256 logits, so ≥50,000 µops (128,256 / 8 lanes ≈ 16K iterations × ~3-4 µops each). Sounds big, but at 1 GHz that's ~50-60 µs against the 16.4 ms the weights took. The chosen token ID — a single 17-bit integer — goes into a tiny TX buffer.

HIF picks it up, packetizes it as a PCIe memory write to a host-allocated ring buffer (or signals a doorbell interrupt for a streaming-mode read). Your laptop's driver hands it to whatever runtime is reading from the chip (a llama.cpp backend, a custom Python loop, whatever). Your screen prints "the".

LSU resets its PC to layer 0 with the new token's hidden vector seeded into `activation_buffer`. Next decode pass starts immediately. The token-to-token loop runs ~134-137 ms per token depending on context depth — that's your ~7.4 tok/s.

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
                       MatE (FFN gate, up) ──▶ VecU (SiLU⊙up) ──▶ MatE (FFN down) ──▶ residual
                                                                            │
                                                                            ▼
                       VecU (RMSNorm) ──▶ activation_buffer (next layer's input)
                                                                            │
                                                                            └── (loop)
```

Seven blocks (the PHY is licensed vendor IP, not one of ours). One assembly line. Every cycle, somewhere on the chip, a multiplier is firing or a Hadamard is butterflying or a softmax is updating. The whole thing is choreographed by the LSU's pre-compiled program — no runtime decisions, no branch prediction, no surprises.

That's Lambda v2 from the inside out.
