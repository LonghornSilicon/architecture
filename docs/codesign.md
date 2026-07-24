# Co-Design Plan: the LSU Schedule Compiler Seam

**Status:** working draft, internal. Not yet ratified by Alan, not referenced from STATUS.md until it is.
**Date:** 2026-07-09
**Spec sources:** `arch.yml` blocks `layer_sequencer`, `matrix_engine`, `vector_unit`, `kv_compression_engine`, `memory_subsystem_controller`; `src/blocks/lsu/README.md`; `dataflow_walkthrough.md`; `docs/attention_frontier.md`.

---

## 1. The one-sentence version

Lambda's LSU walks a pre-compiled static schedule and nothing in our four-team org owns the compiler that emits it, while Saurabh Jha has already built that exact four-phase pipeline for a different NPU. The compiler is the collaboration seam, and session zero is a whiteboard where we hand-compile one decode step together.

## 2. Who we are working with, verified

Internal section. Facts below were checked against the public record on 2026-07-08.

- **Identity.** Sr Distinguished Engineer, CTO Office, Dell Technologies, and Lecturer at UT Austin McCombs in the MSBA program. He is not the IBM Research Saurabh Jha known for GPU reliability work. 
- **The papers.** Forge-UGC, arXiv 2604.16498, a transformer graph compiler for the Intel AI Boost NPU. StreamServe, arXiv 2604.09562, disaggregated prefill and decode serving with adaptive speculative decoding. RAMP, arXiv 2603.17891, RL-driven per-layer weight bit allocation.

## 3. The hole in our org chart

Lambda has no instruction cache, no branch predictor, no program running from DRAM. The LSU is a 3-stage in-order RISC with a 32-instruction fixed-width ISA and 16 x 32-bit GPRs per `arch.yml registers_general_purpose`. It does one thing: walk a static schedule out of its 16 KB microcode RAM, about 3K of the 4K-instruction capacity, issuing up to 1 scalar, 1 vector, and 1 DMA op per cycle to the downstream blocks. The LSU README says it plainly: compiler emits the schedule once per model, chip walks it forever.

That sentence is the hole. The chip is the easy half of it. The compiler does not exist, is not specced, and none of architecture, RTL, DV, or PD owns it. Without it Lambda is a brick, because the host has nothing to load over PCIe at boot.

## 4. Why his work maps one-for-one

The compiler has four jobs. They are, phase for phase, the structure of Forge-UGC.

| Compiler job for Lambda | Forge-UGC phase |
|---|---|
| Flatten one decode step of Llama-3.2-3B into the fixed op sequence from `dataflow_walkthrough.md` | Phase 1, torch.export capture at ATen level |
| Tile every GEMM into jobs the 8x8 MatE array can eat, sized to stream through the 0.05 MB `weight_stream_buffer` | Phase 2, graph optimization and fusion passes |
| Assign every intermediate tensor an address and lifetime in the 0.3 MB `activation_buffer` and 0.4 MB `kv_scratchpad`, with double buffering so DMA of tile N+1 overlaps compute of tile N | Phase 4, liveness analysis and linear-scan buffer allocation |
| Encode it all, plus KCE mode setup and the layer loop, into the 32-bit ISA | Phase 3, typed IR with explicit registers and device placement |

Job three is where the 7.4 tok/s claim lives or dies. Get buffer allocation wrong and the chip idles on memory.

This is co-design rather than outsourced software because the compiler is the first thing that ever executes the spec. The ISA today is a stub with 32 instructions named and encodings undefined. The moment someone compiles a real layer against it, every gap becomes visible: a missing sync primitive, a tile shape the ISA cannot express, an activation that does not fit at some sequence length. Each discovery is an `arch.yml` change found on paper instead of in DV or after tape-out. His compiler pressure-tests our spec. Our spec constrains his compiler. That is the loop.

## 5. How bits become action, the two-minute version

A program is an array of 32-bit numbers in the microcode SRAM. The LSU holds a program counter indexing into it. Every cycle: fetch the word at the PC, carve it into fields by wiring, and let a handful of gates compare the opcode bits against known patterns so that exactly one select line goes high. The bit pattern for ISSUE_MATE physically energizes the wire labeled MatE. That is all an opcode is.

The critical design choice: the LSU does not execute the GEMM. An issue instruction copies GPR contents, previously loaded with tile addresses and a config word, into a small FIFO at the target block's front door. That bundle is a command descriptor. The LSU is done in one cycle and moves on.

MatE cannot be told to do anything but a GEMM, because MatE is a fixed-function block: the 8x8 PE array wrapped in a hardwired FSM. When a descriptor arrives, internal counters generate the thousands of micro-steps, SRAM addresses, PE enables, INT8xINT4 products into INT24 accumulators. The algorithm is wired. The instruction only parameterizes it: where, how big, which mode.

This is where the GPU kernel layer goes on Lambda. On a GPU, a GEMM kernel is thousands of machine instructions fetched one by one. Lambda freezes that inner loop into the block FSMs and lifts the outer loop into the compiled schedule. The kernel layer collapses into two places, the FSM in silicon and the compiler in software, and one LSU instruction stands in for an entire warp's worth of GPU work. That is why 3K instructions can describe a whole transformer.

## 6. Where FlashAttention lives: a sandwich, not a block

FlashAttention is not different math. Attention is still softmax of QK^T times V. FlashAttention is a schedule: process KV in tiles, keep a running max m and running sum l, rescale partials as you go, never materialize the full score matrix in slow memory. On Lambda that schedule splits across three layers, each piece landing where it is cheapest.

1. **Silicon, VecU.** The online-softmax update primitive: compare new scores against the running max, rescale through the 64-entry exp LUT, accumulate the running sum. This must be hardware because it is per-element inner-loop math and MatE deliberately has no FP16 multiplier.
2. **FSM, MatE.** Output-stationary accumulation. Partials stay in the INT24 accumulators across the K axis instead of round-tripping to memory. The never-spill property is enforced by wiring.
3. **Compiled schedule, the ISA.** The tile loop itself, about a dozen instructions in Section 8. There is no ATTENTION opcode and no monolithic attention unit. The primitives are silicon; the algorithm that makes them add up to FlashAttention is a code sequence the compiler emits.

This is exactly why `docs/attention_frontier.md` renames the mechanism to FlashAttention-style online softmax. What Lambda implements is the FA-2 algorithm. FA-3 is a bundle of Hopper-specific software tricks with no referent on an ASIC.

One decode-specific note worth keeping in mind at the whiteboard: at batch 1, Q is a single token, so the score work is matrix-vector and the giant score matrix FA was invented to avoid is mostly a prefill problem. Online softmax still earns its area because it streams 2K tokens of KV through the 0.4 MB scratchpad one 16-token page at a time without ever needing all scores resident.

## 7. Draft ISA v0.1

Everything in this section is a proposal to be attacked in session one, not settled spec. 32-bit fixed width, 5-bit opcode in bits 31:27, which covers the 32-instruction budget exactly. About 20 opcodes are defined below and the rest stay reserved, because we will discover what we forgot the first time we compile a real layer.

**Proposed field layouts.**

```
Scalar:   [31:27 op] [26:23 rd] [22:19 rs1] [18:15 rs2] [14:0 imm15]
Issue:    [31:27 op] [26:23 fn] [22:19 rd ] [18:15 rs1] [14:11 rs2] [10:0 imm11]
```

For issue instructions, fn selects the sub-operation inside the target block, rs1 and rs2 carry source base addresses, rd carries the destination base, and lengths or mode words that do not fit are pre-staged in the target block's CSRs. That convention is itself open question Q4 in Section 9.

**Proposed opcode set.**

| Group | Opcodes | Notes |
|---|---|---|
| Scalar, 9 | NOP, LDI, ADD, ADDI, SUB, CMP, BNE, BEQ, JMP | Loop control and address arithmetic. The layer loop is one ADDI bumping the layer-index register plus one BNE, which is how layer N+1 reuses layer N's schedule per the LSU README. |
| CSR, 2 | CSRW, CSRR | Program block modes: KCE operating mode, TIU policy, MatE config. |
| Issue, 5 | ISSUE_MATE, ISSUE_VECU, ISSUE_KCE, ISSUE_MSC, ISSUE_DMA | One per downstream block. fn field examples: MATE.GEMV, MATE.SCORE, MATE.AV_ACC; VECU.RMSNORM, VECU.ROPE, VECU.SMAX_UPD, VECU.SMAX_FIN, VECU.SILU_MUL, VECU.RESADD, VECU.SAMPLE; KCE.COMP, KCE.DECOMP; MSC.PAGE_LOOKUP, MSC.PAGE_ALLOC. |
| Sync, 3 | WAIT, FENCE, INT_HOST | WAIT takes a block-flag mask and stalls until those done flags are set. FENCE orders DMA against compute. INT_HOST raises the PCIe interrupt with the sampled token. |
| Reserved, 13 | | Headroom for what session one uncovers. |

## 8. Annotated schedule: one decode step, one layer

The centerpiece. This is the mock we hand-compile together in session zero, written against the draft ISA above. Model constants from `dataflow_walkthrough.md`: Llama-3.2-3B, hidden 3072, fused QKV output 5120 under GQA, 28 layers, 16-token KV pages per `arch.yml block_size_tokens`. Register conventions first, because descriptor-building is most of the work.

```asm
; GPR conventions for this schedule
;   r1  layer index            r2  layer weight base in LPDDR
;   r3  activation base, x     r4  scratch dst base
;   r5  KV page counter        r6  current page SRAM addr
;   r7  loop trip counts       r8  block-table walk cursor
;   r15 zero, by convention

; ============ layer body, entered 28 times ============
LAYER_TOP:
  ISSUE_VECU RMSNORM, r4, r3, r15      ; normalize x in the activation buffer,
                                       ; gamma streams from the layer weight base
  WAIT  VECU                           ; VecU done flag before anyone reads r4

; ---- QKV projection, the double-buffer pattern every GEMV uses ----
  ISSUE_DMA  r15, r2, #QKV_TILE0       ; pull the first weight tile, 3072x5120 total
                                       ; at INT4, streamed through the 0.05 MB buffer
QKV_LOOP:
  WAIT  DMA                            ; tile N resident before compute touches it
  ISSUE_DMA  r15, r2, #QKV_TILE_NEXT   ; start pulling tile N+1 immediately, DMA lane
                                       ; is free, this overlap is the whole perf story
  ISSUE_MATE GEMV, r4, r4, r2          ; x times W_qkv tile, INT8 x INT4 into INT24,
                                       ; output-stationary so partials never leave MatE
  ADDI  r7, r7, -1                     ; one scalar op per cycle rides alongside
  BNE   r7, r15, QKV_LOOP              ; next tile until the 5120-wide output is done
  WAIT  MATE                           ; full q,k,v vector now in activation buffer

  ISSUE_VECU ROPE, r4, r4, r1          ; rotate q and k, angle indexed by position CSR

; ---- append this token's k,v to the paged cache ----
  ISSUE_MSC  PAGE_ALLOC, r8, r15, r15  ; block table hands back the current page slot,
                                       ; 128 entries x 16 tokens per arch.yml
  ISSUE_KCE  COMP, r8, r4, r15         ; Hadamard rotate in 16-element blocks, then
                                       ; 3-bit codebook quantize, 4.0 bpe out the back
  WAIT  KCE                            ; compressed k,v committed to kv_scratchpad

; ---- attention: this loop IS FlashAttention on Lambda ----
  LDI   r5, #NUM_PAGES                 ; ceil of context length over 16
ATTN_LOOP:
  ISSUE_MSC  PAGE_LOOKUP, r6, r5, r15  ; block table translates page index to address
  ISSUE_DMA  r6, r6, #PAGE_BYTES       ; spilled pages ride in from LPDDR, resident
                                       ; pages are already in the 0.4 MB scratchpad
  WAIT  DMA
  ISSUE_KCE  DECOMP, r6, r6, r15       ; 3-bit indices through the centroid LUT,
                                       ; scoring operand width is open question Q5
  ISSUE_MATE SCORE, r4, r6, r15        ; q dot k for 16 tokens, one matrix-vector job
  WAIT  MATE
  ISSUE_VECU SMAX_UPD, r4, r4, r15     ; online softmax: update running max m and
                                       ; running sum l, rescale the accumulator, exp
                                       ; comes from the 64-entry LUT, no FP16 multiply
                                       ; anywhere near MatE
  ISSUE_MATE AV_ACC, r4, r6, r15       ; probability-weighted V accumulates on top of
                                       ; the INT24 partials, output-stationary again
  ADDI  r5, r5, -1
  BNE   r5, r15, ATTN_LOOP             ; next 16-token page, scores for the full
                                       ; context never exist all at once anywhere
  ISSUE_VECU SMAX_FIN, r4, r4, r15     ; one divide by l at the very end, the FA-2
                                       ; trick that makes the streaming legal

; ---- o_proj and FFN reuse the QKV double-buffer pattern verbatim ----
  ; o_proj GEMV 3072x3072, then VECU.RESADD onto the residual stream
  ; RMSNORM, gate and up GEMVs, VECU.SILU_MUL, down GEMV, VECU.RESADD
  ; identical structure, different trip counts, elided here, present in Artifact A

  ADDI  r1, r1, 1                      ; bump layer index, weight base derives from it
  CMP   r1, #28
  BNE   LAYER_TOP                      ; same 200-ish static instructions, 28 walks

; ============ epilogue, once per token ============
  ISSUE_VECU RMSNORM, r4, r3, r15      ; final norm
  ; LM head GEMV over 197 MB of streamed weights, same loop pattern
  ISSUE_VECU SAMPLE, r4, r4, r15       ; argmax or top-p per sampling CSR
  INT_HOST                             ; token exits over PCIe, host echoes it back
                                       ; as the next input embedding lookup
```

Static size check: the layer body above is on the order of 200 instructions once o_proj and FFN are written out, so the full schedule lands in the low hundreds. That is an estimate with maybe 2x error either way, and it comfortably clears the 3K-of-4K microcode budget the LSU README claims. If Artifact A blows that budget, we learned something worth knowing in week one.

## 9. The contract questions session one must answer

Every one of these is a question about where the silicon-schedule boundary sits, and every answer becomes a line in `arch.yml`. This list is the real agenda.

- **Q1, blocking semantics.** Does ISSUE block when the target FIFO is full, or fault? Proposed: block, it makes WAIT the only stall primitive.
- **Q2, dependency tracking.** Explicit WAIT everywhere, or a scoreboard that auto-stalls an issue whose operand block is busy? Proposed: explicit WAIT for v1. Dumber, verifiable, and the compiler knows the dependencies anyway.
- **Q3, overlap legality.** Can DMA of page N+1 overlap SMAX_UPD of page N? The schedule above assumes yes for weights and no for KV pages. This single answer moves the attention loop's cycle count materially.
- **Q4, descriptor convention.** Three GPRs plus target-block CSRs, as drafted, or a descriptor RAM the LSU indexes into? CSR pre-staging costs extra instructions per job and the count adds up in the attention loop.
- **Q5, scoring operand width.** The compressed-domain scoring path is currently split-brained across the docs: the corrected `dataflow_walkthrough.md` routes K indices through an INT8 centroid LUT while `arch.yml pe_op_attention_score` still says INT8 x INT3 into a 10-bit product. The descriptor format for MATE.SCORE depends on the answer, so this audit gap has to close before the ISA freezes.
- **Q6, softmax state.** Do running m and l live in VecU-internal registers or in named architectural state the schedule can spill? Internal is cheaper. Architectural is what makes the speculation study in Section 11 possible later.

## 10. Session zero, the concrete plan

**Prep, us, one week before.** Draft the ISA encodings, Section 7 is the starting point. He should be stress-testing a proposal, not a blank page. Hand him `arch.yml`, `dataflow_walkthrough.md`, and the LSU README as the contract.

**The session, 90 minutes at a whiteboard.** Walk the spec for 20 minutes, then together hand-compile just the QKV projection from Section 8. We will hit the first spec gap before the hour is up. Every place either of us gets stuck is an ISA bug, and the running list of stuck-points is the session's primary output. Raise the Dell IP question in this meeting.

**Then split two artifacts, 3 to 4 weeks combined. Estimate, could be 2, could be 6.**

- **Artifact A, ours.** The full hand-compiled decode step, Section 8 completed with real encodings and real trip counts. Forces us to finish the ISA, a deliverable we owe ourselves regardless.
- **Artifact B, his team.** The virtual Lambda: a Python behavioral simulator that executes LSU instructions, models the four SRAM banks with occupancy tracking, counts DRAM bytes and cycles at cycle-approximate fidelity, and checks numerics against a plain PyTorch reference.

**Acceptance test.** Run A on B. Three outputs at once: an executable verdict on the ISA, an independent rederivation of the 134.4 ms per token claim from instruction counts and DMA traffic rather than a bandwidth spreadsheet, and the seed of the golden model DV needs for Phase E anyway. If the simulator says effective bandwidth is 9.8 GB/s instead of the 11.94 in `arch.yml sustained_bandwidth_gb_s`, we want that number today, not at bring-up.

That last output is the fallback baked into step zero itself: if the collaboration ends after a month, the golden-model seed and the finished ISA stay ours and were needed anyway.

## 11. The ladder after step zero

Each rung is independently valuable, so we can stop anywhere.

1. Hand-compiled layer plus simulator. Step zero, above.
2. Auto-generate the schedule from a torch.export trace. The actual compiler, all 28 layers, his Forge-UGC pipeline pointed at our ISA.
3. Perf report: simulator numbers against every `arch.yml` performance claim, which becomes a hardened evaluation section in the paper.
4. Speculation study: sweep verify-depth k on the simulator. Decode is bandwidth-bound with 1.6x compute headroom per `arch.yml`, and verifying k drafted tokens re-streams the weights once, so the ceiling above 7.4 tok/s is real but unquantified until this run. StreamServe's acceptance-rate-driven depth controller is the starting point.

## 12. Adjacent workstreams for a software team he leads

Beyond the compiler, in priority order. The org shape is architecture, RTL, DV, PD, plus this fifth pillar: software and workloads.

- **Benchmarking matrix.** His eval discipline, six model families with logit-fidelity bounds in Forge-UGC, four workload classes in StreamServe, hardens the 6.3 to 7.7 tok/s envelope and the 4.0 bpe accuracy claims. Connects directly to the Quest-style page-selection work item in `docs/attention_frontier.md`, which needs long-context workload evaluation nobody currently owns.
- **Per-layer KV bit allocation.** RAMP's sensitivity machinery, repurposed from weights to KV, turns the TIU's adaptive_precision mode and the K3 V2 asymmetric mode from heuristics into calibrated policy. RAMP's zero-shot transfer result argues profiles derived on open Llama checkpoints hold for Llama-3.2-3B without recalibration.
- **Host runtime.** Driver, boot-time microcode load over PCIe, prefill-on-host with KV handoff. StreamServe's disaggregation framing is our deployment story in miniature.

## 14. Additional notes

### The microcode is model-specific firmware

The right mental model for the compiler's output: it compiles firmware for a specific checkpoint. Input is a named model, Llama-3.2-3B from HuggingFace. Output is three things: the roughly 3K-instruction static schedule, the INT4 quantized weight image laid out for LPDDR streaming, and the KCE codebook plus CSR configuration. The host pushes all of it over PCIe at boot, per the LSU README. One compile per model, never per query. Swap to Qwen2.5-3B or Phi-3.5-mini and you recompile, because layer count, hidden dims, GQA ratio, and FFN width all change the trip counts, tile shapes, and buffer addresses. The chip itself is model-agnostic within its envelope: weights fit LPDDR, activations fit the 0.3 MB buffer, schedule fits 4K instructions. The firmware is what specializes it.

### Where the GPU kernel engineer's job goes

When the industry says model kernels, a Qwen MoE kernel for instance, that is GPU-world terminology: a function launched across thousands of threads, written in CUDA C++, Triton, PTX, or hand-tuned SASS. The craft is resource mapping. Which threads stage which tiles into shared memory, how to keep tensor cores fed without stalling, how to overlap data movement with compute. FlashAttention on GPU is the canonical example: same math everyone had, restructured loop order and memory traffic so the score matrix never touches HBM. Models earn dedicated kernels when their shape demands it. An MoE kernel exists because naive per-expert GEMMs die on launch overhead, so the kernel sorts tokens by expert, batches the work contiguously, and fuses the gather and scatter.

On Lambda that entire job splits in two, per Section 5. The inner loop, the per-tile multiply-accumulate marching and operand staging that most instructions in a GPU GEMM kernel perform, is frozen into MatE's FSM and VecU's primitives. Wired, not written. The outer loop, the tiling strategy, loop order, buffer placement, and DMA-compute overlap where a kernel engineer's judgment actually lives, becomes the compiled schedule. So Lambda has no kernel engineers and no per-model kernels. It has a compiler and per-model firmware, and the compiler is the kernel engineer. This is the cleanest one-sentence pitch for why the seam sits where it does: the layer of the stack Saurabh's team owns on GPUs is the same layer the schedule compiler owns here. One honest boundary worth stating in the same breath: MoE-style dynamic routing is data-dependent control flow, which a static schedule expresses poorly, and whether the LSU's branch instructions could carry a small MoE within the weight-streaming budget is an open architecture question, not a promise.

### Where each attention mechanism in the repo lands

Section 6 established the three layers: silicon primitives, block FSMs, compiled schedule. Every mechanism Lambda plans or considers, per `docs/attention_frontier.md` and `arch.yml`, maps onto them like this.

| Mechanism | Where it lands | What actually changes |
|---|---|---|
| GQA and MQA | Schedule only | No GQA circuit exists, just as no attention circuit exists. Llama-3.2-3B has 24 query heads and 8 KV heads, fused QKV width 5120 per the dataflow walkthrough, so 3 query heads share each KV head. The compiler emits score jobs whose K-operand base addresses point at the same page: GQA is address reuse in the descriptors. Each 16-token page is DMA'd and KCE-decompressed once, then reused by all 3 heads in the group. That 3x cut in KV traffic and storage is load-bearing for a bandwidth-bound design with a 0.4 MB scratchpad. MQA is the same pattern with group size equal to head count. |
| FlashAttention-style online softmax | All three layers | The sandwich of Section 6. Primitive in VecU, never-spill in the MatE FSM, tile loop in the schedule. |
| PagedAttention | MSC silicon plus schedule | The block table, 128 entries by 16 tokens per `arch.yml`, is real address-translation hardware in the MSC. The schedule just calls MSC.PAGE_LOOKUP and stays ignorant of physical layout. |
| Sliding window with pinned sinks | Schedule plus MSC address generation | Changes which pages the attention loop visits: a start offset, a wrap, and a handful of pinned sink pages. Near-free per attention_frontier section 3, and the demo insurance for unbounded sessions. |
| TIU H2O eviction | TIU silicon plus CSR policy | The 256-byte importance accumulators are dedicated hardware, but they only change which pages still exist for the loop to visit. The schedule is untouched. |
| Quest-style page selection | Schedule plus a small KCE assist | Changes which pages the loop visits based on min-max page metadata that KCE can emit in the rotated domain nearly for free. The top recommendation in attention_frontier section 2, and almost entirely a compiler feature once the metadata exists. |
| Per-head KV policy, DuoAttention style | Schedule plus CSR | Different page-visit patterns per head group. Architect now, implement later, per attention_frontier section 5. |
| MLA absorbed decode | Genuinely new math shape | The one exception. Absorbed-decode changes the GEMM structure itself, which is exactly why attention_frontier section 5 says reserve CSR and schedule encoding space now rather than build it. |

The pattern to say out loud in session zero: attention variants overwhelmingly land in the schedule and the MSC's addressing, not in MatE or VecU. The silicon freezes at tape-out. The schedule does not. The compiler is where new attention mechanisms get added post-tapeout, which makes it not just the collaboration seam but the chip's longevity story.
