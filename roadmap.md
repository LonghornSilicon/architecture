# Lambda — Circuit-Level Optimization Roadmap

**Codename:** Lambda (Longhorn Accelerator for Matrix-Based Dataflow & Attention) — Flagship
**Project:** Longhorn Silicon, UT Austin — "Chips, designed at Texas"
**Process:** TSMC N16FFC, ~25 mm² die target (PCIe Gen3 x4 form factor, 7-8B model class)
**Companions:** `PRDs/lambda-v2/PRD.md`, `archs/Lambda_25mm2.yaml`, `PRDs/lambda-v2/design-rationale.md`
**Created:** 2026-04-25

---

## What this document is

The PRD says *what* Lambda contains. The YAML says *how big and how fast*. The design rationale says *why*. **This document says where the FP4-multiplier-style research runs live** — the discrete circuit-optimization problems that benefit from the same Karpathy-autoresearch / SAT-exact / AlphaEvolve loop you're already running on the Etched FP4 multiplier (85 → 74 gates and counting).

Each entry below is a self-contained "research run" target: a defined unit problem, a frozen verifier, a baseline gate count, an expected ceiling, a search method, and a compute ask. Items are scored on **payoff × tractability × dependency-criticality** so you know which to launch next when the FP4 work converges.

The unifying frame: **Lambda's silicon will contain ~30 distinct combinational circuits whose gate counts compound multiplicatively over hundreds-to-thousands of instances.** A 15% gate reduction on the INT8×INT4 PE (1024 instances in MatE alone) saves more area than the entire VecU. A 30% gate reduction on the Hadamard butterfly saves nothing measurable because it appears once. Pick targets accordingly.

---

## How to read each entry

```
T-NN  | Name                              | Tier
        ──────────────────────────────────────────────────────────
        Unit problem:    one paragraph, what the circuit must compute
        Instances:       how many copies appear on the die
        Baseline:        naive synthesis gate count (cite if known)
        Floor estimate:  best plausible result (cite or back-of-envelope)
        Verifier:        how to check correctness (frozen harness)
        Search method:   ABC / SAT-exact / AlphaEvolve-LLM / hand
        Compute ask:     CPU-hours, API $, GPU-hours
        Dependency:      what must land first
        Payoff signal:   what a 20% reduction unlocks (area/power/timing)
        Status:          NOT-STARTED / IN-PROGRESS / CONVERGED / DEFERRED
```

---

## Executive ranking — what to launch next

| Priority | Item | Why |
|---|---|---|
| 1 | **T-02 INT8×INT4 PE multiplier** | 1024 instances. Same methodology as your FP4 work. Largest gate-count compound. |
| 2 | **T-04 INT8×INT4 fused MAC** | 1024 instances. PE = MAC; pulling multiply+add together saves more than separate optimization |
| 3 | **T-12 exp() approximation circuit** | Single instance but on the softmax critical path. Energy + latency. Has a published rich design space (LUT vs Schraudolph vs minimax poly). |
| 4 | **T-16 32-point Walsh-Hadamard butterfly** | 1 instance but defines the KCE area. LASSO IP carries forward; tightening it makes the research story crisper. |
| 5 | **T-08 32-input INT24 accumulator (CSA tree)** | 1 instance per PE column = 32 instances. Wallace vs Dadda vs counter-tree is a classic search problem. |
| 6 | **T-20 6-port SRAM crossbar** | 1 instance, but it's the hottest wire in the chip. Critical path candidate. |
| 7 | **T-24 LPDDR5X command scheduler** | Bandwidth-bound chip → BW efficiency is throughput. |
| 8 | **T-13 rsqrt approximation** | RMSNorm hot path. Newton-Raphson vs Quake fast-inverse-sqrt vs LUT — a real search space. |
| 9 | **T-23 block-table TLB (PagedAttention)** | Hardware-novel; failing this kills MSC. |
| 10 | **T-30 LSU microcode ROM compression** | Boot-time and area; lower urgency. |

The **first six** of these together account for an estimated ~60% of the chip's combinational gate count.

---

## A. Compute primitives (MatE PE-internal)

### T-01 | FP4 × FP4 → INT9 multiplier | Tier 0 (in flight)

```
Unit problem:   E2M1-FP4 × E2M1-FP4, output 9-bit signed integer = 4·val_a·val_b
Instances:      0 in Lambda v1 (NVFP4 is v2). But the methodology and the
                infrastructure you've built for Etched are the template for
                everything below.
Baseline:       390 gates (PLA → ABC FAST)
Current best:   74 gates (your in-flight autoresearch, down from 85)
Floor:          unknown; SAT-exact below 80 is infeasible on a workstation
Verifier:       256-pair truth table, BLIF simulator (frozen)
Search method:  ABC + remap search + AlphaEvolve LLM mutation loop
Compute ask:    Already scoped — Anthropic API budget for AlphaEvolve loop
Status:         IN-PROGRESS
```

**Why it's listed here even though it's for Etched:** Lambda's NVFP4 mode (v2 stretch) reuses *exactly* this circuit as the multiply primitive in the FP4-microscale mode of MatE. Whatever you converge to for Etched ports directly into Lambda v2. The 74-gate (or lower) FP4 multiplier × 1024 PEs × 2× cross-mode duplication = ~150K gates of v2 silicon savings. Real money.

---

### T-02 | INT8 × INT4 PE multiplier | Tier 1 (highest priority for v1)

```
Unit problem:   8-bit signed × 4-bit signed → 12-bit signed product
Instances:      1024 (every cell of the 32×32 systolic array)
Baseline:       Naive Booth-2 + CPA: ~120 gates (estimate; verify with yosys + ABC FAST)
Floor:          ~60-70 gates (Wallace tree + radix-4 Booth, hand-tuned)
Verifier:       2^12 = 4096 input pairs, exhaustive truth table
Search method:  Identical to your FP4 work — structural Verilog +
                ABC &deepsyn + remap search (signed-magnitude, ones-complement,
                two's-complement, signed-2x). AlphaEvolve LLM loop on top.
Compute ask:    1 CPU-day for the deterministic search; $200-500 API for
                AlphaEvolve overnight run if you want to push past ABC's
                local optimum
Dependency:     None. Can start today.
Payoff signal:  20% gate reduction = ~25K gates saved in MatE alone =
                ~0.15 mm² die area at 16nm = enough to either keep 16 MB
                SRAM target or upgrade VecU to 64 lanes.
Status:         NOT-STARTED — hot
```

**Sub-experiment families to enumerate** (each becomes a remap-search axis):

1. Operand encoding (sign-magnitude / one's-complement / two's-complement / biased)
2. Booth radix (no Booth / radix-2 / radix-4 / radix-8)
3. Partial-product compression (Wallace / Dadda / counter-tree / no compression)
4. Final adder (ripple-carry / Kogge-Stone / Brent-Kung / Han-Carlson)
5. Sign-extension scheme (extended PP / sign-bit folding / Baugh-Wooley)

The cross-product is ~4×4×4×4×3 = 768 variants. Same methodology as your FP4 5040-perm sweep.

---

### T-03 | INT8 × INT8 multiplier (W8A8 fallback mode) | Tier 2

```
Unit problem:   8-bit × 8-bit signed → 16-bit signed
Instances:      1024 (same PE, alternative mode)
Baseline:       ~200 gates
Floor:          ~100 gates (well-studied; published designs exist)
Verifier:       2^16 = 65K input pairs (still exhaustive)
Search method:  Same as T-02; rich literature on 8×8 mults
Compute ask:    1 CPU-day, $100 API
Dependency:     T-02 — share datapath where possible
Payoff signal:  Smaller; only fires in W8 fallback mode. But the PE area
                is dominated by the larger of the two multipliers, so
                T-03 also caps T-02 unless you separate the datapaths.
Status:         NOT-STARTED — fold into T-02 sweep
```

---

### T-04 | INT8 × INT4 fused MAC (PE-complete) | Tier 1

```
Unit problem:   (8b × 4b) + 24b accumulator → 24b accumulator
Instances:      1024 (the actual PE primitive)
Baseline:       T-02 multiplier + ripple-carry adder, no fusion: ~150 gates
Floor:          Fused MAC with carry-save accumulator: ~110 gates
                (saves the multiplier's final CPA by deferring carry resolution
                until the column-end reduction tree)
Verifier:       Multi-cycle accumulator behavior — needs sequential testbench,
                not pure combinational truth table. Verilator + cocotb.
Search method:  Hand-design the carry-save accumulation; ABC for the per-cycle
                logic; AlphaEvolve for end-of-column CPA optimization
Compute ask:    1 CPU-week + $500 API
Dependency:     T-02 (the multiplier inside the MAC)
Payoff signal:  20% reduction = entire MatE shrinks ~10%, freeing ~0.1 mm²
                or trading for higher clock margin
Status:         NOT-STARTED — second-priority after T-02 is in flight
```

**The fusion question is structural.** It's not "do we use a multiplier with an external accumulator." It's "do we let partial products from the multiplier feed directly into a carry-save tree that also includes the prior accumulator value." The literature calls this a "fused multiply-add" but at the gate level there's a real gate-count search to do — the same kind of search you ran on FP4.

---

### T-05 | NVFP4 microscale exponent path | Tier 3 (v2 only)

```
Unit problem:   Block exponent in E4M3, mantissa in E2M1, 16-element block
                scale; outputs aligned for the multiplier path
Instances:      32 per row of MatE = 1024 total in v2
Baseline:       Synopsys reference FP unit + microscale wrapper: ~180 gates
Floor:          ~100 gates with shared exponent-bias and folded shift logic
Verifier:       Compare against PyTorch microscale reference (TorchAO library)
Search method:  Hand + ABC; SAT-exact infeasible (operand bits push beyond
                workstation budget)
Compute ask:    1 CPU-week, $500 API
Dependency:     T-02 (multiplier path), T-01 (FP4 multiplier from Etched work)
Payoff signal:  Defines whether NVFP4 is buildable in v2 area budget. If
                this can't go below 120 gates, v2 stays INT-only.
Status:         DEFERRED to v2 unless team grows
```

---

### T-06 | Wallace/Dadda partial-product compression tree | Tier 2

```
Unit problem:   Compress N rows of partial products to 2 rows of (sum, carry)
                using 3:2 (full adder) and 2:2 (half adder) compressors
Instances:      Inside every MAC; 1024 instances
Baseline:       Naive ripple compression: 2× the gate count of optimal Wallace
Floor:          [Wallace 1964; Dadda 1965] both proven near-optimal asymptotically;
                small-N (4-8 PPs) has 5-10% search room
Verifier:       Symbolic; output (sum,carry) must equal sum of inputs mod 2^N
Search method:  Greedy Wallace assignment + simulated annealing + ABC
                clean-up. Cirbo SAT-exact is feasible at N=4.
Compute ask:    1 CPU-day for sweep; $200 for SA tuning
Dependency:     T-02 (which tree fits inside the multiplier)
Payoff signal:  Folded into T-02 reduction; not a standalone area win
Status:         NOT-STARTED — bundle with T-02
```

---

## B. Reduction trees (MatE column outputs + VecU)

### T-07 | 32-input INT24 accumulator | Tier 2

```
Unit problem:   Sum 32 INT24 values → INT29 result (one per MatE column per cycle)
Instances:      32 (one per array column)
Baseline:       Linear adder chain: ~750 gates × 32 cols = 24K gates
Floor:          Carry-save tree + final CPA: ~350 gates × 32 = 11K gates
                (potentially lower with shared carry-save trees across columns)
Verifier:       Random 32-tuple inputs vs Python sum
Search method:  Wallace/CSA tree topology search via SA + ABC final-stage opt
Compute ask:    2 CPU-days
Dependency:     T-02, T-04 (defines accumulator width)
Payoff signal:  ~10K-15K gates savings = ~0.05 mm² across MatE
Status:         NOT-STARTED
```

---

### T-08 | 32-input max comparator tree (online softmax m_i) | Tier 2

```
Unit problem:   Find max of 32 INT16 values
Instances:      Per-row softmax, ~8-32 across attention heads
Baseline:       Linear comparator chain: ~200 gates per max
Floor:          Tournament tree: ~120 gates; with shared-comparison
                optimization: ~90 gates
Verifier:       Random inputs vs Python max
Search method:  Tournament-tree topology search (5 levels for 32 inputs);
                ABC for per-comparator logic. Knuth-style merge-network
                literature has the optimality bounds.
Compute ask:    1 CPU-day
Dependency:     None
Payoff signal:  Modest; max trees are area-efficient already
Status:         NOT-STARTED
```

---

### T-09 | 32-input sum reducer with online-stable update | Tier 2

```
Unit problem:   l_new = exp(m_old - m_new) * l_old + sum(exp(s_i - m_new) for i in 32)
                — the FlashAttention-3 online-softmax row-wise update
Instances:      Per-row softmax; multiple per head
Baseline:       Naive: 32 exps + 32 adds + 1 mul = ~3000 gates per row
Floor:          Schraudolph approx exp + log-domain trick: ~600 gates
Verifier:       Compare against PyTorch FlashAttention-3 reference under
                FP16 numerics tolerance
Search method:  Algorithm-level search (Schraudolph variants, log-sum-exp
                shortcuts) + ABC on the chosen variant
Compute ask:    1 CPU-week + $500 API for variant exploration
Dependency:     T-12 (exp circuit)
Payoff signal:  Defines softmax energy; softmax is ~5% of inference energy
                across 32 layers
Status:         NOT-STARTED
```

---

### T-10 | Top-k selector (sampling) | Tier 3

```
Unit problem:   From a 32K-element vocabulary distribution, select top-k
                (k=1 for greedy, k=50 for nucleus sampling)
Instances:      1 per generated token; not on the hot path
Baseline:       Sort + take-k, ~10K gates for k=1
Floor:          Heap-based top-k: ~3K gates
Verifier:       Compare against Python heapq.nlargest
Search method:  Architectural choice (sort vs heap vs threshold) + ABC
Compute ask:    1 CPU-day
Dependency:     None
Payoff signal:  Small. Sampling runs once per token, not per layer.
Status:         DEFERRED — host can do this
```

---

## C. Vector unit transcendentals

### T-11 | exp(x) approximation circuit | Tier 1

```
Unit problem:   Compute exp(x) for x ∈ [-16, 0] (softmax shifted-input range),
                output FP16 with ≤ 0.5 ULP error
Instances:      1 (32-lane SIMD shares one functional unit)
Baseline:       128-entry FP16 LUT + linear interp: ~500 gates, 0.1 ULP
Floor:          Schraudolph "fast exp" (bit manipulation of FP repr): ~80 gates,
                3% error; HARDER but rich: minimax polynomial degree-3 with
                Horner: ~300 gates, 0.05 ULP
Verifier:       1024 random inputs vs Python math.exp under tolerance
Search method:  This is THE perfect AlphaEvolve target. Algorithmic search
                across (Schraudolph / Cody-Waite / minimax / range-reduction
                schemes). Each variant is ~50 lines of Verilog.
Compute ask:    $500-1000 API for an overnight AlphaEvolve sweep across
                ~50 algorithmic variants
Dependency:     None
Payoff signal:  Softmax is ~5% of total energy; halving exp() halves softmax.
                Also: exp() is on the latency-critical path inside online
                softmax loop; smaller circuit = lower latency = higher clock
                ceiling for VecU.
Status:         NOT-STARTED — second highest priority after T-02
```

---

### T-12 | rsqrt(x) approximation (RMSNorm) | Tier 1

```
Unit problem:   Compute 1/sqrt(x) for x ∈ [2^-32, 2^32], FP16 output, ≤ 1 ULP
Instances:      1 per layer = called 32× per token; significant energy
Baseline:       Newton-Raphson 2 iterations from FP16 LUT seed: ~600 gates
Floor:          Quake fast-inverse-sqrt + 1 NR iteration: ~250 gates
                (the famous 0x5F3759DF trick; well-studied at FP32, less so
                at FP16/BF16)
Verifier:       1024 random inputs vs Python 1/math.sqrt under tolerance
Search method:  Algorithmic variants (LUT size × NR iterations × initial
                approximation). AlphaEvolve LLM is well-suited.
Compute ask:    $500 API
Dependency:     None
Payoff signal:  RMSNorm is ~3% of inference energy; halving rsqrt halves it
Status:         NOT-STARTED — high-priority
```

---

### T-13 | sigmoid(x) and tanh(x) approximations | Tier 2

```
Unit problem:   sigmoid for SiLU = x*sigmoid(x); tanh for GELU approximation
Instances:      1 each (SIMD-shared)
Baseline:       128-entry LUT each: ~500 gates
Floor:          Piecewise-linear approximation, 4 segments: ~150 gates;
                or rational approximation (Padé): ~200 gates
Verifier:       1024 random inputs under tolerance
Search method:  Same as T-11; rich algorithmic literature
Compute ask:    $300 API
Dependency:     None
Status:         NOT-STARTED
```

---

### T-14 | Fused SiLU(x) = x * sigmoid(x) | Tier 3

```
Unit problem:   Avoid materializing sigmoid(x) as intermediate — fold the
                multiplication into the sigmoid approximation
Instances:      1 (FFN activation)
Baseline:       T-13 sigmoid + 16-bit multiplier: ~700 gates
Floor:          Fused piecewise-quadratic: ~300 gates
Verifier:       Compare against PyTorch silu()
Search method:  Algorithmic + ABC
Compute ask:    $300 API
Dependency:     T-13
Status:         NOT-STARTED — fold with T-13
```

---

### T-15 | RoPE pair-rotation circuit | Tier 2

```
Unit problem:   For 64 frequency bands × 32 lanes, compute (x,y) → (x cos θ - y sin θ,
                x sin θ + y cos θ) where θ comes from a 2KB sin/cos LUT
Instances:      32 in VecU per Q,K head pair
Baseline:       4 multipliers + 2 adders per pair: ~1000 gates
Floor:          Shared sin/cos LUT + folded multiplier: ~600 gates
                (or CORDIC if frequency table is small enough — but CORDIC
                area scales worse at 16-bit)
Verifier:       Compare against PyTorch rotary_emb under FP16 tolerance
Search method:  LUT vs CORDIC vs hybrid; ABC on chosen path
Compute ask:    1 CPU-week, $300 API
Dependency:     None
Payoff signal:  RoPE is ~2% of inference energy; ~5% of VecU area
Status:         NOT-STARTED
```

---

## D. Hadamard / KCE (LASSO IP carryforward)

### T-16 | 32-point Walsh-Hadamard butterfly | Tier 1

```
Unit problem:   5-stage WHT, 160 add/sub operations, 32 INT16 inputs → 32 INT16 outputs
Instances:      2 (forward + inverse, possibly shared with mux)
Baseline:       Direct 160 16-bit adders: ~3200 gates
Floor:          Shared partial-sum structure + carry-save: ~1800 gates;
                with bit-serial folding: ~600 gates (multi-cycle)
Verifier:       Random INT16 vector + verify H·H^T = 32I (orthogonality)
                + bit-exact match against numpy WHT reference
Search method:  Architectural (combinational vs pipelined vs serial) + ABC
                on chosen architecture. SAT-exact infeasible (160 ops too big).
Compute ask:    2 CPU-days; $500 API for variant search
Dependency:     None — pure carryforward from LASSO A3 design
Payoff signal:  KCE area dominated by butterfly; halving = halve KCE
                = ~0.07 mm². Small absolute, but the publication story is
                "TurboQuant in <0.1 mm²" which is more striking
Status:         NOT-STARTED — high-priority
```

---

### T-17 | Carry-save adder for Hadamard butterfly stages | Tier 3

```
Unit problem:   16-bit signed CSA optimized for {+1, -1, 0} multiplications
                (the WHT pattern); each stage compresses signed pairs
Instances:      ~32 per butterfly stage, 5 stages = 160 instances
Baseline:       Generic 16-bit CSA: ~50 gates each
Floor:          Specialized for ±1 multiplier (the WHT case): ~30 gates each
Verifier:       Symbolic
Search method:  Hand-design + ABC; small enough for SAT-exact
Compute ask:    1 CPU-day
Dependency:     T-16 (informs the CSA structure)
Status:         NOT-STARTED — bundle with T-16
```

---

### T-18 | Lloyd-Max nearest-centroid classifier | Tier 2

```
Unit problem:   Given 32 INT16 inputs and 8 centroid thresholds (3-bit codebook),
                output 3-bit nearest-centroid index for each input
Instances:      32 lanes × 1 classifier per lane = 32 instances, OR
                shared classifier over time-multiplexed lanes
Baseline:       7 comparators per lane × 32 lanes = 224 comparators ≈ 4500 gates
Floor:          Shared comparators + priority encoder: ~2000 gates
                (the 7 thresholds are static; can absorb into truth table)
Verifier:       Compare against Python codebook lookup
Search method:  ABC on the truth-table-encoded version + remap search
Compute ask:    2 CPU-days
Dependency:     T-16 (KCE owns this)
Status:         NOT-STARTED
```

---

### T-19 | Bit-pack/unpack for 3b/4b/8b → 32b SRAM word | Tier 2

```
Unit problem:   Pack {3, 4, 8} bit values into 32-bit SRAM words and inverse;
                handle the 3-bit case (10 values + 2 slack bits per word)
Instances:      KCE input/output, MatE accumulator output, multiple SRAM ports
Baseline:       Switch-case per mode: ~500 gates (high redundancy)
Floor:          Shifted-mux with shared barrel-shifter: ~200 gates
Verifier:       Round-trip pack/unpack identity test
Search method:  Hand-architected mux structure + ABC
Compute ask:    1 CPU-day
Dependency:     None
Status:         NOT-STARTED
```

---

## E. Memory & SRAM

### T-20 | 6-port SRAM crossbar | Tier 1

```
Unit problem:   Route requests from {MatE×2, VecU×2, KCE×1, host/DMA×1} to
                {weight buf, activation buf, KV scratch, codebook ROM} with
                arbitration, single-cycle latency at 1 GHz
Instances:      1 (the chip's central nervous system)
Baseline:       Full 6×4 crossbar with priority mux: ~5K gates
Floor:          Banked crossbar with conflict detection: ~3K gates
                (there's no point routing every input to every output —
                some pairs are statically impossible)
Verifier:       Stress test with random request patterns vs reference
                arbitration policy
Search method:  Architectural (full xbar / banked / time-multiplexed) +
                ABC on the chosen topology
Compute ask:    1 CPU-week, $500 API
Dependency:     None — but defines the chip's max sustained bandwidth
Payoff signal:  This is on the critical path. Halving its depth lets us
                hit 1 GHz; failing to optimize forces 800 MHz fallback.
Status:         NOT-STARTED — Tier 1 because it's load-bearing for clock
```

---

### T-21 | SRAM bitcell + sense amp (foundry vs custom) | Tier 3

```
Unit problem:   Choose between TSMC's HD vs HC vs UHD SRAM compilers, or
                hand-design a custom bitcell. Sense amp design is foundry-
                provided typically.
Instances:      Per SRAM bank (×4 banks)
Baseline:       Foundry HD compiler — out of the box
Floor:          Hand-tuned UHD with bit-line precharge optimization: ~10%
                area win, weeks of analog-design effort
Verifier:       Memory BIST + foundry sign-off
Search method:  Foundry tool sweeps (compiler options); custom is out of
                scope without a senior analog designer
Compute ask:    Foundry compiler runs; days of CPU time
Dependency:     LPDDR5X PHY area quote (defines remaining SRAM budget)
Status:         DEFERRED — use foundry HD compiler; revisit only if area
                budget is desperately tight
```

---

### T-22 | ECC (SECDED) for SRAM banks | Tier 3

```
Unit problem:   Single-error-correct, double-error-detect Hamming code for
                SRAM banks; encode on write, decode on read
Instances:      Per SRAM bank (×4)
Baseline:       SECDED Hamming for 64-bit data + 8-bit ECC: ~600 gates
Floor:          Shared decoder across banks: ~300 gates
Verifier:       Inject errors, verify correction
Search method:  Hand-design (well-known); ABC for area
Compute ask:    1 CPU-day
Dependency:     None
Payoff signal:  Resilience to 16nm soft errors. Required for correctness
                if SRAM exceeds ~8 MB.
Status:         REQUIRED for tape-out — verify but don't over-optimize
```

---

### T-23 | Block table TLB (PagedAttention) | Tier 2

```
Unit problem:   1024-entry associative lookup: logical block ID → physical
                SRAM/DRAM page. Single-cycle hit at 1 GHz.
Instances:      1
Baseline:       Naive content-addressable memory: ~15K gates
Floor:          Banked CAM + hash index: ~6K gates
                (vLLM block-table is the abstraction; there's no published
                hardware implementation to compare against — research
                novelty is here)
Verifier:       Random lookup workload; compare against Python dict
Search method:  Architectural (CAM vs hash vs hybrid) + ABC
Compute ask:    1 CPU-week, $500 API
Dependency:     None
Payoff signal:  This is one of the chip's research firsts. Failing to
                make it small enough kills MSC's area budget.
Status:         NOT-STARTED — Tier 2; could be Tier 1 if it ends up
                dominating MSC area
```

---

## F. Memory controller / DMA

### T-24 | LPDDR5X command scheduler (request reorder) | Tier 1

```
Unit problem:   Reorder pending DRAM requests to maximize bandwidth
                under timing constraints (tRC, tRCD, tRP, tFAW, ...).
                Open-page policy with bank-conflict avoidance.
Instances:      1 per LPDDR5X channel (×2)
Baseline:       FIFO request queue: ~50% of peak BW achievable
Floor:          FR-FCFS with bank-aware reordering: ~85% of peak;
                with prefetch coalescing: ~92%
Verifier:       Trace-based simulation against DRAMSim3 reference
Search method:  Architectural; not a gate-count optimization but a
                throughput optimization. Different methodology — search
                policy parameters via simulated annealing on traces.
Compute ask:    2 CPU-weeks for trace-based tuning
Dependency:     T-26 (defines what arrives at the scheduler)
Payoff signal:  DIRECTLY moves the chip's headline tok/s number. From
                100 GB/s sustained to 120 GB/s = 25% more decode throughput.
Status:         NOT-STARTED — highest non-gate-count payoff
```

**This is methodologically different from FP4-style autoresearch.** Verifier is a workload trace, not a truth table. Optimization variable is policy parameters, not gates. But the loop structure (modify→verify→keep) is identical.

---

### T-25 | Open-page bank conflict avoidance | Tier 2

```
Unit problem:   Decide when to keep a bank's row open vs precharge,
                under the actual access pattern of transformer decode
Instances:      1 (in scheduler)
Baseline:       Always-precharge or always-open: 70% peak BW
Floor:          Adaptive policy with row-locality predictor: 88% peak
Verifier:       Trace simulation
Search method:  Same as T-24
Compute ask:    1 CPU-week
Dependency:     T-24
Status:         NOT-STARTED — bundle with T-24
```

---

### T-26 | DMA descriptor parser FSM | Tier 3

```
Unit problem:   Walk a chained linked list of DMA descriptors in DRAM,
                issue read/write requests to the LPDDR scheduler
Instances:      2 (one per LPDDR channel)
Baseline:       Generic descriptor FSM: ~2K gates
Floor:          Specialized for transformer access patterns: ~1K gates
Verifier:       Random descriptor chain walk vs reference
Search method:  Hand-design + ABC
Compute ask:    1 CPU-day
Dependency:     None
Status:         NOT-STARTED — straightforward
```

---

### T-27 | Prefetcher confidence threshold | Tier 3

```
Unit problem:   Decide when prefetched-but-unused data has wasted enough
                bandwidth that the prefetcher should back off
Instances:      1
Baseline:       Always prefetch next N blocks
Floor:          Confidence-based gate (PC-indexed predictor)
Verifier:       Trace simulation
Search method:  Policy parameter sweep
Compute ask:    1 CPU-week
Dependency:     T-24
Payoff signal:  ~5% bandwidth savings on adversarial workloads
Status:         DEFERRED — software (LSU schedule) can hint instead
```

---

## G. Control & sequencer

### T-28 | LSU instruction decoder | Tier 3

```
Unit problem:   Decode 32-bit fixed-width instructions into MatE / VecU /
                DMA dispatch signals. ~64 instructions.
Instances:      1
Baseline:       Direct switch decoder: ~1500 gates
Floor:          Encoded opcode + field-extraction shared logic: ~600 gates
Verifier:       Walk all 64 opcodes, compare against assembler reference
Search method:  ABC on the encoded design; opcode-encoding optimization
                is a small SAT problem (Cirbo-feasible)
Compute ask:    2 CPU-days
Dependency:     ISA freeze (Q4 2026)
Status:         NOT-STARTED
```

---

### T-29 | LSU register file | Tier 3

```
Unit problem:   32×32-bit GPR with 2 read + 1 write port
Instances:      1
Baseline:       Foundry SRAM compiler: ~0.03 mm²
Floor:          Custom flip-flop array with mux read: ~0.02 mm²
Verifier:       Random read/write traffic
Search method:  Architectural choice
Compute ask:    Trivial
Dependency:     ISA freeze
Status:         NOT-STARTED — use foundry compiler
```

---

### T-30 | Microcode ROM compression | Tier 3

```
Unit problem:   16K instructions × 32 bits = 64 KB ROM. Compress via
                instruction frequency analysis or sub-program factoring.
Instances:      1
Baseline:       Direct 64 KB ROM: ~0.05 mm²
Floor:          Run-length / dictionary compression: 30-50% smaller
Verifier:       Bit-exact decompression of test programs
Search method:  Architectural; not gate-count search
Compute ask:    1 CPU-day
Dependency:     LSU ISA + Llama-3-8B / Qwen3-7B schedules compiled
Status:         NOT-STARTED — defer until schedules exist
```

---

## H. Glue / cross-cutting

### T-31 | Bit-packer / unpacker (parallel & area-balanced) | Tier 2

```
Unit problem:   Generalized N-bit-to-32-bit pack across {2, 3, 4, 8, 16} bit
                widths, with single barrel-shifter datapath
Instances:      Multiple — KCE, MatE accumulator output, MSC interface
Baseline:       Per-width specialized circuits: ~3K gates total
Floor:          Shared barrel-shifter + width mux: ~1.2K gates
Verifier:       Round-trip identity per width
Search method:  Hand-design + ABC
Compute ask:    1 CPU-day
Dependency:     None
Status:         NOT-STARTED
```

---

### T-32 | PRNG for stochastic rounding & sampling | Tier 3

```
Unit problem:   xoroshiro128+ or LFSR-based PRNG, 64-bit per cycle
Instances:      1 (shared); plus per-PE RNG for stochastic rounding (×1024)
Baseline:       LFSR per PE: ~30 gates × 1024 = 30K gates
Floor:          Shared PRNG with deterministic stride per PE: ~1K total
Verifier:       Statistical (TestU01 small crush)
Search method:  Architectural
Compute ask:    1 CPU-day
Dependency:     None
Status:         DEFERRED — only needed if MatE adds stochastic rounding
                for FP4 path (v2)
```

---

### T-33 | Causal mask generator | Tier 3

```
Unit problem:   For attention scoring, mask future tokens — set scores
                for j > i to -inf (or large-negative)
Instances:      1
Baseline:       Comparator + mux per attention element: ~100 gates × 32 lanes
Floor:          Position-index comparator + bulk mask vector: ~600 gates total
Verifier:       Random Q/K positions, verify masking
Search method:  Hand-design
Compute ask:    Trivial
Dependency:     None
Status:         NOT-STARTED — straightforward
```

---

### T-34 | Tensor-walk address generation FSM | Tier 3

```
Unit problem:   Generate SRAM/DRAM addresses for striding through tensors
                in (batch, head, seq, dim) order under various tile patterns
Instances:      Multiple (per DMA, per MatE input)
Baseline:       4-loop nested counter: ~500 gates
Floor:          Shared base-address generator with per-axis increments: ~300 gates
Verifier:       Compare against Python tensor-walk reference
Search method:  Hand-design + ABC
Compute ask:    1 CPU-day
Dependency:     None
Status:         NOT-STARTED
```

---

## I. Methodology — what tool fits what target

| Methodology | Best for | Time per result | Cost per result |
|---|---|---|---|
| **ABC `&deepsyn` + remap search** | Combinational circuits ≤ 200 gates with rich operand-encoding choices | Hours | CPU only |
| **Cirbo / SAT-exact** | Proving optimality on small (≤ 5-input) circuits, or per-output bit minimums | Hours to days | CPU only |
| **AlphaEvolve LLM mutation loop** | Mid-sized circuits (50-500 gates) where ABC has hit a local optimum | Hours per iteration; thousands of iterations overnight | $300-1500 API per overnight run |
| **Architectural simulated annealing** | Trees, networks, schedulers — where structure choice dominates | Days | CPU only |
| **Trace-based policy tuning** | Memory schedulers, prefetchers, cache policies | Weeks | CPU only |
| **Hand-design from literature** | Well-studied patterns (Wallace tree, Newton-Raphson, Hamming ECC) | Days | Time only |

---

## J. Compute resource ask (total project, not per-item)

If you want to launch the full roadmap, here's what the resources buy:

### Tier 1 (do first, in parallel with FP4 convergence) — ~$3K API + 1 CPU-month

- **T-02 INT8×INT4 mul:** $300 API for ABC saturation + AlphaEvolve overnight; 2 CPU-days
- **T-04 INT8×INT4 fused MAC:** $500 API; 1 CPU-week
- **T-11 exp() approximation:** $1000 API for variant sweep
- **T-12 rsqrt:** $500 API
- **T-16 Walsh-Hadamard butterfly:** $500 API; 2 CPU-days
- **T-20 6-port crossbar:** $500 API; 1 CPU-week (critical path!)
- **T-24 LPDDR5X scheduler:** trace simulation, no API; 2 CPU-weeks

Total: ~$3,300 API budget + 1 CPU-month. **Could be done in 6-8 weeks with the FP4-mul autoresearch infrastructure repurposed.**

### Tier 2 (after Tier 1 converges) — ~$2K API + 2 CPU-weeks

T-07, T-08, T-13, T-15, T-18, T-19, T-25, T-31 — straightforward extensions.

### Tier 3 (defer or fold into block PD) — ~$500 API + 1 CPU-week

Glue, ECC, ROM compression, decoder. Not optimization-critical.

### Sustained ask

- **Anthropic API budget**: ~$5K total across the roadmap. Equivalent to 2-3 weeks of one engineer's salary; massively positive ROI on circuit area.
- **CPU compute**: ~3 CPU-months distributed across the project. 1 modest workstation for the duration.
- **GPU compute**: not needed unless you self-host an open coder model for AlphaEvolve — only relevant if API access is constrained.

### Defensive ask (only if you want rigorous lower bounds for a paper)

- **32-core CPU box for 2 weeks**: Cirbo SAT-exact lower-bound runs on T-02, T-04, T-11. Likely outcome: confirms the autoresearch results are at-or-near optimal. Strong publication ammunition.

---

## K. Dependency graph

```
                 T-02 INT8×INT4 mul ───┬──> T-04 fused MAC ──> T-07 INT24 acc
                                       └──> T-03 INT8×INT8 mul (same sweep)
                                       └──> T-06 PP compression (sub-task)

                 T-11 exp() ───────────┬──> T-09 online softmax
                                       └──> stays standalone (multiple uses)

                 T-12 rsqrt ───────────────> RMSNorm path
                 T-13 sigmoid ─────────────> T-14 SiLU fused
                 T-15 RoPE ──────────────── standalone
                 T-16 WHT butterfly ───────> T-17 specialized CSA (sub-task)
                                             T-18 Lloyd-Max (peer)

                 T-20 6-port crossbar ─────> defines 1 GHz clock fate
                 T-23 block-table TLB ─────> defines MSC area fate

                 T-24 LPDDR scheduler ─────> T-25 bank policy (sub-task)
                                             T-27 prefetch confidence

                 T-28 LSU decoder ─────────> T-30 microcode ROM (depends on
                                             ISA freeze + compiled schedules)

                 T-22 ECC ──────────────── independent; required for tape-out
                 T-31 bit-pack ─────────── independent; cross-block reuse
```

Most items are **independent** and can be parallelized across the team. Critical-path: **T-02 → T-04 → MatE PD freeze.** Everything else can fan out.

---

## L. Cross-cutting wins

Some optimizations have leverage across blocks. Prioritize these when looking for "free" gains:

1. **Operand encoding (sign-magnitude vs two's-complement)** — a single decision in T-02 propagates through T-03, T-04, T-07, T-08. Get it right once.

2. **Shared SIMD lane width** — VecU is 32-lane. Every transcendental (T-11, T-12, T-13, T-15) uses the same lane. Optimizing the lane multiplier once helps all of them.

3. **Carry-save accumulators** — the fusion in T-04 also benefits T-07 (accumulator tree) and T-16 (Hadamard butterfly). If you commit to CSA throughout MatE, ~30% adders disappear.

4. **Barrel-shifter sharing** — T-19 (bit-pack) and T-31 (general pack) and the K-shifter in your FP4 multiplier all use the same primitive. One good barrel-shifter design unlocks all of them.

5. **LUT consolidation** — exp/sigmoid/tanh (T-11, T-13) all benefit from a shared 128-entry FP16 LUT primitive. Same SRAM macro, three different mode bits.

---

## M. When to STOP optimizing each item

The FP4-mul work shows the discipline: **diminishing returns are real and measurable.** For each item, the stopping rule should be:

- **ABC `&deepsyn` returns the same result on three independent restarts** with different random seeds → search has saturated for that methodology
- **AlphaEvolve LLM loop hasn't found an improvement in 100+ iterations** → local optimum reached
- **The remaining gate count is < 5% of the block's total** → no further effort is justified
- **The optimization no longer changes the chip's worst-case timing or area on the critical path** → diminishing returns

For Tier 1 items: invest until the stopping rule fires, then move on.
For Tier 2/3: invest until ABC defaults are hit; only escalate if a measurable area or timing budget violation requires it.

---

## N. What's specifically NOT on this roadmap (and why)

These are NOT good targets for autoresearch loops:

- **PCIe Gen3 PHY** — licensed black-box IP; we don't optimize vendor IP
- **LPDDR5X PHY** — same
- **Foundry SRAM macros** — vendor-tuned analog; we choose compiler options, not gate counts
- **Clock tree synthesis** — owned by PD tooling (Innovus / IC Compiler II); architectural choices made elsewhere
- **Power gating and DVFS** — v2 effort; not in scope for first tape-out
- **Process / device-level optimization** — TSMC owns it
- **Behavioral RTL of high-level blocks (entire MatE, entire VecU)** — too large for autoresearch; decompose into the unit problems above

---

## O. Documentation discipline (mirror the FP4-mul work)

Per item, expect to maintain:

```
research_runs/
├── T-02_int8_int4_mul/
│   ├── PRD.md                # design space + decomposition + optimality argument
│   ├── MEMORY.md             # chronological journal
│   ├── SUMMARY.md            # executive summary
│   ├── results.tsv           # experiment ledger
│   ├── current_best/         # canonical answer (Verilog + BLIF + reproduce script)
│   └── code/
│       ├── spec.py           # truth-table source of truth
│       ├── verify.py         # frozen evaluation harness (BLIF simulator)
│       ├── synth.py          # synthesis pipeline
│       ├── search.py         # autoresearch driver
│       └── strategy.py       # AlphaEvolve / mutation skeleton
└── T-04_fused_mac/
    └── ... (same shape)
```

This is exactly what you've built for FP4. Replicate the structure for each Tier 1 item.

---

## P. Tracking & cadence

Recommended cadence for the team:

- **Weekly**: review which research-run is in-progress per owner. Mark items CONVERGED when stopping rule fires.
- **Monthly**: cross-block review — has any optimization unlocked new options elsewhere (e.g., did T-20 crossbar shrink enough that we can fit more SRAM)?
- **Quarterly**: re-rank the Tier 1 list. Move CONVERGED items to "done", promote Tier 2 items.

Use a simple status column in this document or a shared tracker. The FP4-mul `MEMORY.md` + `SUMMARY.md` pattern is the right granularity per item.

---

## Q. Why this roadmap matters for Lambda

A 20% gate-count reduction across the Tier 1 items (T-02, T-04, T-11, T-12, T-16, T-20) would save roughly:

- T-02: 25K gates × 1024 PEs = 25M gate-equivalents — but most are shared in the carry-save tree, so realistically ~5M effective
- T-04: ~5M gate-equivalents (fused MAC vs separate)
- T-11: ~1K gates (single instance, but lower exp latency raises VecU clock ceiling)
- T-12: ~1K gates (same)
- T-16: ~3K gates (KCE)
- T-20: ~1K gates + critical-path improvement worth a 10-20% clock margin

**In aggregate: ~10M gate-equivalents = ~0.6 mm² recovered**, plus the timing margin to confidently hit 1 GHz instead of falling back to 800 MHz.

That recovered area can either:
- Push SRAM from 12 MB target back to 16 MB (KV scratch grows from 2 MB to 6 MB)
- Add a second LPDDR5X channel's worth of NoC fabric headroom
- Add an NVFP4 microscale path to MatE (move that v2 stretch into v1)

Each of these meaningfully improves the chip. **The autoresearch work is not a luxury — it is how Lambda fits in 25 mm² instead of 30.**

---

*Generated 2026-04-25. Companion to PRDs/lambda-v2/PRD.md and archs/Lambda_25mm2.yaml. Note: the Lambda/Lambda renaming is in flight; treat all "Lambda" references in companion docs as referring to "Lambda".*
