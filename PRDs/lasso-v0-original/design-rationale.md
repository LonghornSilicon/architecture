# LASSO Design Rationale & Strategic Reasoning

**Why this architecture, why these tradeoffs, and what we're actually building**

---

## Why a KV Cache Coprocessor (and Not the Other Ideas)

### The constraint that dictates everything

SKY130 is a 130nm process. The chipIgnite shuttle gives us roughly 10mm² of die area. At this node:

- Logic density: ~150K gates/mm²
- SRAM density: ~0.15 MB/mm²
- Total transistor budget: ~15 million

For comparison, TSMC 5nm (what modern AI chips use) offers ~150M gates/mm² and ~30 MB/mm² SRAM. The gap is 500-1000x in density. A Taalas HC1 at 6nm packs 53 billion transistors into 815mm². We have 15 million transistors in 10mm². No amount of architectural cleverness bridges a 3,500x transistor gap for compute-heavy or storage-heavy workloads.

This is not a criticism of the project. SKY130 is what the open-source shuttle ecosystem offers at student-accessible cost ($10-15K per slot). We build on 130nm because it's what we can fabricate, not because it's optimal for any inference workload. The architecture must be chosen to work *with* this constraint, not fight it.

### Why each alternative idea was eliminated

**Gemma 4 MoE Router + Expert Tiles (from prev-idea.md, idea #3)**

A single MoE expert FFN for an 8B model has ~60M parameters. At 4-bit quantization, one expert's weights alone are ~30MB. Our entire chip holds 0.5MB of SRAM. We cannot store 2% of a single expert, let alone implement routing between 128 of them. The body-biasing power-gating idea (using SkyWater FD-SOI) is creative but SKY130 is bulk CMOS, not FD-SOI. The process doesn't support it.

**Sparsity Master / Zero-Detection Systolic Array (from prev-idea.md, idea #1)**

To demonstrate meaningful sparsity savings, you need a compute array large enough that skipping zeros produces a measurable throughput or power difference. A 16x16 systolic array at 16-bit takes ~0.5mm² for MACs alone, plus weight/activation buffers and control. It would fit, but the resulting array runs workloads so small (256x256 matrix multiplies) that the sparsity benefit is statistically indistinguishable from noise. A SparseCache-inspired dictionary approach (from the updated idea #1) is even worse: it requires an on-chip dictionary of ~4K entries plus matching-pursuit solver logic — substantial area for marginal benefit on tiny matrices.

**Hardwired Model (Taalas-style, from prev-idea.md, idea #3 variant)**

Taalas burns model weights directly into transistor configurations at the physical design level. This requires: (a) enough transistors to encode billions of weights (we have 15M total), or (b) a custom physical design flow that maps weight values to gate-level configurations — a flow that doesn't exist in OpenLane and would be a multi-year research project on its own. The "no instruction set, just dataflow" framing is compelling but physically impossible at our scale.

**Full Attention Engine / Inference Accelerator**

Even a minimal attention engine for a tiny model needs: weight storage (the model itself), activation buffers, a systolic array for Q*K^T and score*V, softmax hardware (exponential + division), layer norm, and an MLP/FFN stage. The smallest useful LLM (Qwen-0.5B) at 4-bit still needs ~250MB of weight storage. We have 0.5MB. An attention engine without weight storage is just a matrix multiplier — it has no story.

### Why the KV cache coprocessor survives this analysis

The KV cache coprocessor is the one architecture where the valuable work lives in the control logic and data transformation pipeline — quantization, scoring, eviction, page management, DMA — not in raw compute or storage.

The area breakdown:
- SRAM (the thing being managed): 6.5 mm² / 65% of die
- All logic (the thing doing the managing): ~0.3 mm² / 3% of die
- I/O + routing overhead: ~3.0 mm² / 30% of die

The logic is tiny because it's purpose-built: multipliers for quantization, comparators for scoring, state machines for page management. These are hundreds-of-gates problems, not millions-of-transistors problems. Meanwhile, 512KB of SRAM is enough to hold a meaningful working set: ~2048 tokens of compressed KV data at 2-bit for a 4-head model. That's a real workload, not a toy.

The scaling property matters: if someone takes LASSO's RTL and re-synthesizes it at 28nm, the same architecture with the same logic suddenly has 10x the SRAM, 10x the clock speed, and occupies 1/25th the area. The design translates across nodes. The architecture is the contribution; the process node is just a multiplier.

---

## Why INT4 and Not FP4

NVIDIA's MXFP4 format (1 sign bit, 2 exponent bits, 1 mantissa bit, shared block exponent) is designed for GPUs at 4-5nm where transistors are nearly free relative to interconnect. The exponent handling logic — addition, bias subtraction, normalization, subnormal/zero special-casing — roughly triples the gate count of each multiplier compared to INT4.

At 5nm, this overhead is negligible: a few hundred extra gates per multiplier when you have billions to spare. At 130nm, those same extra gates are physically ~10x larger each, and we have 15M transistors total. With 32 parallel multipliers in the attention compute unit, the FP4 overhead adds up to measurable area.

More importantly, FP4's advantage over INT4 is marginal for KV cache data. FP4 provides non-uniform quantization levels ({0, 0.5, 1, 1.5, 2, 3, 4, 6} at unit scale) with denser coverage near zero. This helps when data is Gaussian-distributed with many near-zero values. But for KV cache vectors that have already been preconditioned (e.g., Hadamard rotation as in RotateKV), the distribution is flattened and near-uniform. INT4 with a shared scale factor per group of 32 elements gives equivalent effective dynamic range using pure integer arithmetic.

If a future tapeout uses a denser process, FP4/FP8 support becomes a reasonable addition. At 130nm, INT4 is the right format.

---

## Why Not PolarQuant for v1

PolarQuant (from Google's TurboQuant) is an elegant compression scheme: encode a vector as a binary tree of angles plus a single preserved magnitude. For an 8-element vector, 7 angles at 3-bit plus one 16-bit magnitude = 37 bits vs 128 bits at 16-bit. That's ~70% compression with excellent quality because the magnitude (the "strength" of the vector) is never quantized.

The problem is reconstruction. To use a compressed KV vector during attention, you must dequantize it — walk the tree backward, computing `r * cos(angle)` and `r * sin(angle)` at each node. For a realistic 128-dim head (7-level tree), that's 254 trigonometric operations per vector.

Hardware options for sin/cos:

**CORDIC (iterative shift-and-add):** ~16 iterations per operation at 16-bit precision. One CORDIC unit is ~0.01mm². To sustain 1 vector/cycle throughput, you need ~32 parallel CORDICs = 0.32mm². That's 5x the entire KV Cache Engine as currently designed, and more than the Token Importance Unit and Attention Compute Unit combined.

**Lookup table:** 3-bit angles = only 8 possible values, so a tiny ROM for sin/cos values. But you still need 254 multiplications (r * trig_value) per vector, organized in a 7-stage sequential tree (can't parallelize across levels because each level depends on the previous). That's a minimum 7 pipeline stages of varying-width multiply arrays with complex routing between them.

**The comparison that kills it:** Linear 2-bit quantization (RotateKV-style) achieves <0.3 perplexity degradation with 32 parallel multipliers and a shift/round pipeline — the exact hardware we already need for dequantization. PolarQuant at 3-bit achieves better quality (maybe 0.1-0.2 PPL improvement) but costs 3-5x the area. At 130nm, that tradeoff is unambiguously wrong.

PolarQuant is a v2 target for a denser process where CORDIC area is cheap relative to SRAM. The Hadamard preconditioning step (multiply by a matrix of +1/-1 values) IS feasible at 130nm — it's just adds and subtracts — and could be included in v1 as a "should-have" to improve quantization quality without trigonometric cost.

---

## Why Linear Quantization Over Sparse Dictionary Coding

Lexico (ArXiv'24) shows that a universal 4K-entry dictionary can sparse-code any KV vector using ~4-8 dictionary atoms, achieving 90-95% accuracy at ~20% KV size. This is more powerful than linear quantization in theory.

In hardware, sparse dictionary coding requires:
1. An on-chip codebook (4096 entries x 128 dims x 16-bit = 1MB) — this alone would consume 2x our total KV cache SRAM budget
2. A matching-pursuit or OMP solver to find the best atoms — iterative, sequential, hard to pipeline
3. A sparse encoder that stores {atom_index, coefficient} pairs with variable-length encoding

This is fundamentally a software algorithm shoe-horned into hardware. Linear quantization, by contrast, maps perfectly to silicon: one comparator for min/max, one multiplier for scaling, one rounding unit, one bit-packer. Each of these is a single pipeline stage. No iteration, no search, no variable-length anything.

---

## Why Simple Eviction Over Learned Policies

The Token Importance Unit uses a comparator tree to find the lowest-scored tokens and evict them. This is a simple bottom-K selection. Papers like BalanceKV propose theoretically optimal sampling based on geometric discrepancy theory, which requires more sophisticated logic.

For v1, simple bottom-K is correct because:
1. It's the easiest to verify (deterministic output for given input)
2. It matches what every deployed KV cache system actually uses (attention-score-based heuristics)
3. The comparator tree is tiny (~0.01mm²)
4. If the eviction policy is wrong, the Token Importance Unit's CSR interface allows the HOST to override decisions — the host can implement BalanceKV in software and just send eviction commands

The hardware's job is to maintain scores and execute evictions fast. The policy intelligence can live in software until we know it's worth hardening into gates.

---

## Why 50MHz Clock Target (Not Higher)

130nm standard cells can theoretically operate at 200-300MHz in well-optimized designs. We're targeting 50MHz (with 100MHz as stretch) for three reasons:

1. **Timing closure difficulty scales superlinearly with frequency.** At 50MHz (20ns cycle), most paths through our pipeline have 3-4x timing margin. At 100MHz, margin drops to ~2x, and at 200MHz we'd be fighting hold violations and setup violations simultaneously. With a student team doing their first physical design, generous timing margin is the difference between taping out and not taping out.

2. **SRAM access time dominates.** The CF_SRAM_16384x32 macro's read latency determines the critical path. At 130nm, SRAM read typically takes 3-5ns for small macros and 8-12ns for larger ones. Our 64KB macro with 16K words will be on the slow end. A 50MHz clock (20ns) gives comfortable margin; 100MHz (10ns) might require adding a pipeline register between SRAM read and the logic that consumes the data.

3. **Throughput is not the bottleneck.** At 50MHz with 32-wide datapath, we sustain 200MB/s of data through the compression pipeline. The off-chip interface (Wishbone through Caravel) is the actual bandwidth limiter — Caravel's management SoC runs at 10-40MHz on the external interface. Doubling the internal clock doesn't help if data can't get on or off the chip faster.

---

## The Systolic Array Decision

The PRD includes a 1D systolic array as a "should-have" upgrade for the Attention Compute Unit. The reasoning:

The baseline parallel dot-product unit reads 32 Q elements and 32 K elements from SRAM every cycle. For a 1024-token sweep, that's 4096 Q reads + 4096 K reads = 8192 SRAM reads. The Memory Hierarchy Controller is also reading/writing SRAM for page management, DMA staging, and quantization scratch. All of this contends for the same SRAM ports.

A 1D systolic array (8 PEs, each holding 4 Q elements) loads Q once (32 reads) and streams K through the PEs. That cuts SRAM reads to ~4128 — roughly 2x bandwidth reduction. The cost is ~0.06mm² additional area for inter-PE registers and routing.

This is not a must-have because we don't yet know if SRAM bandwidth is actually the bottleneck. It might be that the compression pipeline (KV Cache Engine) or the DMA engine is the limiting stage, not the attention compute. The systolic upgrade is held in reserve as a fix for a specific performance problem, not pre-optimized.

A 2D systolic array (e.g., 8x4) would only help if we were doing matrix-matrix attention (Q_batch * K^T) for multiple queries simultaneously. That's a prefill workload. LASSO targets decode (one query at a time), where 1D is sufficient.

---

## The Compressed-Domain Compute Decision

The Attention Compute Unit supports two modes:
- Mode A: dequantize K to 16-bit, then compute 16x16-bit dot products
- Mode B: compute 16-bit Q x 4-bit K directly, apply scale factor to final sum

Mode B is mathematically equivalent to Mode A for symmetric quantization:

```
Mode A: score = Σ Q[i] * (K_q[i] * scale) = scale * Σ Q[i] * K_q[i]
Mode B: score = scale * Σ Q[i] * K_q[i]
```

For asymmetric quantization (with zero-point), Mode B requires a correction term:
```
score = scale * Σ Q[i] * K_q[i] + zero_point * Σ Q[i]
```

The `Σ Q[i]` term can be precomputed once per query and reused across all tokens.

Mode B's 16x4 multipliers are ~4x smaller than Mode A's 16x16 multipliers. The area savings are modest in absolute terms (~0.03mm²) but the power savings are more significant: smaller multipliers switch fewer transistors per cycle, which matters for a chip that's 65% SRAM (SRAM leakage is already a substantial fraction of total power at 130nm).

The accuracy tradeoff: at 4-bit, the relative error per dot product from skipping dequantization is <1%. At 2-bit, it's higher (~3-5%) because quantization noise on K is larger and the multiplicative error compounds across the 128-element sum. The CSR-selectable mode lets us use Mode A for high-importance tokens (where accuracy matters) and Mode B for bulk scoring sweeps (where speed matters more than precision).

---

## What "Success" Means at 130nm

### What the chip will actually do

LASSO is a coprocessor. A host processor (could be a Caravel RISC-V core, an FPGA, or a desktop CPU) runs the actual model inference. When the model produces KV vectors, the host sends them to LASSO. LASSO compresses them, scores them for importance, stores the important ones on-chip, streams the rest off-chip in compressed form, and on demand dequantizes and returns stored KV data for attention computation. The host does softmax, V-weighting, MLP, and everything else.

In concrete terms:
- Host sends a 128-dim, 16-bit KV vector (256 bytes)
- LASSO quantizes it to 4-bit (64 bytes) or 2-bit (32 bytes) in 4-8 cycles
- LASSO scores the token's importance via a partial Q*K dot product
- LASSO stores it in the appropriate SRAM page, or compresses and DMA's to off-chip
- When the host needs attention scores, it sends a Query and LASSO computes Q*K dot products over stored tokens, returning scores
- When SRAM fills up, LASSO evicts lowest-importance tokens (compress further and stream out)

For a 4-head, 128-dim model at 2-bit, LASSO holds ~2048 tokens on-chip. That's a meaningful context window for a small model (1-3B parameters).

### What it demonstrates

1. **A working KV compression datapath in silicon.** Quantize, pack, store, fetch, unpack, dequantize — verified against a golden model, functional in real silicon.

2. **Hardware token importance scoring.** The first (to our knowledge) open-source silicon implementation of attention-score-based cache eviction.

3. **Paged KV cache management in hardware.** vLLM's PagedAttention concept implemented as a hardware page table with DMA, not a software runtime.

4. **Complete open-source RTL-to-GDSII flow.** Every artifact — Verilog, testbenches, OpenLane configs, GDSII — published and reproducible.

### What it doesn't do

- It doesn't run a model end-to-end
- It doesn't replace a GPU or any commercial accelerator
- It doesn't achieve competitive absolute throughput (a Raspberry Pi's CPU can do more FLOPS)
- It doesn't work standalone — it needs a host

### Why it still matters

The chip is a proof-of-concept for an architecture class that didn't exist in open-source silicon before. The RTL is the real deliverable — it can be re-synthesized at any node. A research lab or startup with 28nm access takes the same Verilog, runs it through a commercial flow, and gets a chip that runs at 500MHz-1GHz with 10-50MB of SRAM. At that point, LASSO becomes a real product-grade KV cache coprocessor. Our job is to prove the architecture works, verify it, and fabricate it. The 130nm tapeout is the proof; the RTL is the asset.

---

## Why Not Pair LASSO With a GPU Over PCIe

A natural question: could LASSO sit in a PCIe slot alongside a consumer GPU (e.g., RTX 3060) and accelerate inference? The short answer is no, and understanding why clarifies where LASSO's real application space lies.

An RTX 3060 already has its own KV cache solution:

| Resource | RTX 3060 | LASSO (130nm) |
|---|---|---|
| Memory | 12 GB GDDR6 | 512 KB SRAM |
| Memory bandwidth | 360 GB/s | ~200 MB/s (Wishbone at 50MHz) |
| KV cache capacity (2-bit, 4-head) | Millions of tokens | ~2048 tokens |
| Clock | 1.78 GHz | 50 MHz |

When a model runs on the 3060, the KV cache lives in 12GB of VRAM, served at 360 GB/s. If the GPU offloaded KV data to LASSO over PCIe, the data would leave the GPU (PCIe 4.0 x16 = ~25 GB/s, latency ~1-2us per transaction), arrive at LASSO's Wishbone bus at ~200 MB/s, get stored in 512KB of SRAM, then travel the reverse path on read. That routes data from a 360 GB/s memory system through a 200 MB/s bottleneck — a 1,800x slowdown. The PCIe round-trip latency alone exceeds the time the 3060 takes to just read the KV cache from its own VRAM.

Any system with a dedicated GPU doesn't need LASSO. The GPU's memory subsystem already handles this workload better than a 130nm coprocessor can.

---

## Where LASSO's Application Space Actually Is

### CPU-only inference (the largest underserved market)

Millions of people run LLMs locally using llama.cpp, ollama, and similar tools on machines with no GPU or an insufficient one. In this setup, model weights and the KV cache both live in system RAM, and the CPU does all compute. System RAM bandwidth is 25-50 GB/s (DDR4/DDR5 dual-channel) — 7-15x worse than a 3060's VRAM.

The memory bottleneck here is severe. A 7B model with 4K context at 16-bit KV cache = ~540MB of cache data. At 40 GB/s DDR4 bandwidth, reading the full cache takes ~13.5ms per token. The actual dot-product compute takes ~3ms. The CPU is idle 80% of the time waiting on memory.

A LASSO-class coprocessor (at a modern process node) holding compressed KV data at 2-bit in on-chip SRAM could serve reads at SRAM speed, bypassing DRAM entirely for the hot working set. Even just compressing to 4-bit and keeping the cache in DRAM cuts the memory read from 13.5ms to ~3.4ms. That's a 2-4x real end-to-end inference speedup from less data movement, not more compute.

This is the market that matters: tens of millions of machines running local inference on CPUs where DRAM bandwidth is the wall.

### Edge devices without GPUs

Phones running on-device LLMs (Google Gemini Nano, Apple's on-device models), IoT/embedded devices, robotics controllers, automotive voice assistants — these have LPDDR4/5 at 15-35 GB/s and power budgets of 1-5W. They cannot afford a GPU. A small, low-power KV compression engine as an IP block inside their SoC reduces memory traffic and thus both latency and power consumption. Every byte not read from DRAM saves ~20 picojoules. Over millions of tokens per day, that's meaningful battery life.

### Cloud inference servers (as an IP block, not a standalone chip)

AWS, Google, and Microsoft run inference on custom silicon (Inferentia, TPU, etc.). These chips already have attention engines, but KV cache management is still handled in software by the serving runtime (vLLM, TensorRT-LLM). A hardened KV compression/eviction block integrated as a functional unit inside the inference ASIC would offload that work from the main compute pipeline. This is essentially the Titanus thesis: a hardware block co-designed with the attention engine that compresses and prunes KV data before it touches off-chip memory.

### FPGA-based inference (most realistic near-term deployment for our RTL)

Before silicon returns from fab, the RTL itself is deployable:

- Take the verified Verilog
- Synthesize onto a Xilinx/Intel FPGA (even a ~$200 dev board like a Zynq or Arty A7)
- Connect to a host CPU via PCIe, AXI, or USB
- Modify llama.cpp's backend to offload KV cache operations to the FPGA

An FPGA running LASSO's RTL at 200-300MHz with 2-4MB of on-chip BRAM is a functional coprocessor that could demonstrably accelerate CPU-only inference. This demo can happen 6-12 months before silicon returns and gives something tangible to show sponsors and faculty.

---

## The Raspberry Pi Comparison (Clarified)

The design-rationale document notes that a Raspberry Pi's CPU can do more raw FLOPS than LASSO. This deserves clarification because it can sound like "the chip is useless," which is not the point.

A Raspberry Pi 5's ARM Cortex-A76 cores produce roughly 30-50 GFLOPS using NEON SIMD. LASSO's 32 multipliers at 50MHz produce about 1.6 GFLOPS. In raw multiply-accumulate throughput, the Pi wins by ~20x.

But LASSO doesn't compete on FLOPS. It competes on a task the Pi is terrible at: reducing memory traffic.

Consider a Pi (or any CPU) running inference on a 1B model with 2048 tokens of context at 16-bit KV:

| Step | Time on CPU | What's happening |
|---|---|---|
| Read KV cache from DRAM | ~17 ms | CPU stalls waiting for 67MB of data over a 4 GB/s bus |
| Compute attention (Q*K dot products) | ~2 ms | Actual math |
| Write new KV entry | ~0.1 ms | Small write |
| **Total per token** | **~19 ms** | **CPU is idle 88% of the time** |

LASSO compresses that 67MB to ~8MB at 2-bit. Now:

| Step | Time with LASSO-compressed KV | What's happening |
|---|---|---|
| Read compressed KV from DRAM | ~2 ms | 8x less data to read |
| Dequantize + compute attention | ~2.5 ms | Slight overhead from dequant |
| Write + compress new KV entry | ~0.2 ms | Compress before write |
| **Total per token** | **~4.7 ms** | **~4x faster** |

The speedup comes from moving fewer bytes, not from faster math. LASSO's FLOPS don't matter. Its compression ratio and memory management do. A purpose-built KV compression engine that reduces memory traffic by 4-8x delivers more real-world inference improvement than a chip with 100x the FLOPS that still has to read the full uncompressed cache from DRAM.

This is the core thesis of the entire project: the memory wall, not the compute wall, is what limits LLM inference.

---

## The Value Chain: From 130nm Proof to Deployable Product

The 130nm ASIC is not the end product. It's the first link in a value chain:

```
130nm ASIC tapeout (Spring 2028)
│   Proves: the architecture is fabricable and functional
│
├── FPGA prototype (can happen 6-12 months before silicon returns)
│   Proves: the RTL accelerates real CPU-only inference workloads
│
├── Open-source RTL publication
│   Enables: anyone to re-synthesize at their target node
│   │
│   ├── Research lab with 28nm access → 500MHz, 40MB SRAM, real coprocessor
│   ├── Startup integrating into edge SoC → IP licensing opportunity
│   └── Cloud provider evaluating KV acceleration → hardware block for next-gen chip
│
├── Academic publication (DAC, ICCAD, ISSCC demo, MICRO workshop)
│   Proves: novel contribution to the field of LLM inference hardware
│
└── Team credibility
    "We taped out a chip" opens doors at every AI silicon company
```

The architecture is the contribution. The process node is a multiplier on performance. Our job is to prove the architecture works, verify it exhaustively, and fabricate it. Everything downstream — FPGA demos, RTL licensing, publications, recruiting leverage — flows from that proof.

---

## Process Node Comparison (For Context)

| Metric | SKY130 (us) | GF 22nm (realistic next step) | TSMC 5nm (industry) |
|---|---|---|---|
| Gate density | 150K/mm² | 10M/mm² | 150M/mm² |
| SRAM density | 0.15 MB/mm² | 4 MB/mm² | 30 MB/mm² |
| 10mm² SRAM budget | 1.5 MB | 40 MB | 300 MB |
| Clock (conservative) | 50 MHz | 500 MHz | 2 GHz |
| Throughput (32-wide) | 200 MB/s | 2 GB/s | 8 GB/s |
| LASSO KV capacity | 2K tokens | 50K tokens | 375K tokens |
| Shuttle cost | ~$10K | ~$50-100K (if available) | Not accessible |

At 22nm (which GF offers and some university programs can access), the same LASSO architecture holds 50K tokens on-chip — enough for production-grade context windows. The architecture scales; the process node determines the operating point.
