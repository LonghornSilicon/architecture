/* csr_map.h — Lambda control/status register (CSR) map.
 *
 * The static configuration surface. Exposed to the host through HIF/PCIe BAR0
 * and read internally by the blocks. The compiler emits a CSR block (address,
 * value pairs) alongside the LSU schedule; the host writes it before ringing the
 * launch doorbell. CSRs are the *static* knobs (per-workload / per-layer);
 * the LSU instruction stream is the *dynamic* program.
 *
 * Status: DRAFT csr-isa-0.1 (2026-07-18). Per-block register windows already
 * exist in the block repos (precision_controller_isa.md, kv_cache_engine_isa.md
 * §2, tiu-isa); this map is the chip-level union the compiler targets. OPEN
 * items marked; see docs/compiler_programming_guide.md §3 and STATUS.md §7.
 *
 * 32-bit word-aligned. Base is chip-integration-time (BAR0). Reserved reads 0.
 */
#ifndef LAMBDA_CSR_MAP_H
#define LAMBDA_CSR_MAP_H

/* ---- 0x000 global ---- */
#define CSR_VERSION      0x000  /* R  : [31:16] major, [15:0] minor (=0x0001_0000) */
#define CSR_CTRL         0x004  /* RW : [0] enable, [1] soft_reset(W1P), [2] launch */
#define CSR_STATUS       0x008  /* R  : [0] idle, [1] running, [2] halted, [3] err  */
#define CSR_SCHED_BASE   0x00C  /* RW : LSU instruction-RAM base for the schedule   */
#define CSR_SCHED_LEN    0x010  /* RW : number of LSU instructions                  */
#define CSR_IRQ_MASK     0x014  /* RW : [0] on-halt, [1] on-token, [2] on-error      */
#define CSR_IRQ_STATUS   0x018  /* R/W1C                                            */

/* ---- 0x040 model / per-layer config (indexed: CSR_LAYER_CFG + l*0x20) ---- */
#define CSR_MODEL_CFG    0x040  /* RW : [15:0] n_layers, [23:16] n_q_heads,
                                        [31:24] n_kv_heads (GQA/MQA)                 */
#define CSR_HEAD_DIM     0x044  /* RW : head dim D (64 / 128 …)                      */
#define CSR_ROPE_BASE    0x048  /* RW : RoPE theta base (fp bits)                    */
#define CSR_SEQ_LEN      0x04C  /* RW : current context length                      */
#define CSR_LAYER_CFG    0x080  /* RW[] : per-layer window, stride 0x20 (dims,
                                          weight DRAM base, active flags)            */

/* ---- 0x200 MatE ---- */
#define CSR_MATE_MODE    0x200  /* RW : [0] dataflow (0=weight-stat,1=output-stat),
                                        [2:1] precision (see mate_precision),
                                        [3] fuse_fa3 (OPEN, STATUS §7)               */
#define CSR_MATE_INFO    0x204  /* R  : [7:0] array_rows, [15:8] array_cols,
                                        [23:16] accum_width (=24)                    */

/* ---- 0x240 KVE (ChannelQuant) — mirrors kv_cache_engine_isa.md §2 ---- */
#define CSR_KVE_TIER     0x240  /* RW : [1:0] tier (0=CQ-8,1=CQ-4,2=CQ-4+)           */
#define CSR_KVE_GROUP    0x244  /* RW : key group size G (default 128)               */
#define CSR_KVE_OUTLIER  0x248  /* RW : top-k FP16 outlier key channels (CQ-4+ -> 2) */
#define CSR_KVE_INFO_CR  0x24C  /* R  : [15:0] CR_K, [31:16] CR_V (8.8 fixed-point)  */
#define CSR_KVE_OCCUP    0x250  /* R  : valid SRAM KV entries                        */
/* OPEN (STATUS §7): tier granularity — per-layer (this CSR) vs per-tile microfield. */

/* ---- 0x280 TIU (Token Importance Unit) ---- */
#define CSR_TIU_MODE     0x280  /* RW : [1:0] mode (see tiu_mode)                    */
#define CSR_TIU_BUDGET   0x284  /* RW : KV cache budget in blocks (≈25% of ctx)      */
#define CSR_TIU_RECENT   0x288  /* RW : recent-window blocks (H2O local; ≈budget/2)  */
#define CSR_TIU_THRESH   0x28C  /* RW : keep/demote importance threshold (tier_keep) */
#define CSR_TIU_INFO     0x290  /* R  : [15:0] n_blocks, [23:16] block_tokens(=16),
                                        [31:24] score_width                          */

/* ---- 0x2C0 sampling ---- */
#define CSR_SAMPLING     0x2C0  /* RW : [0] greedy, [15:1] top_k, [31:16] temp(fp)   */

/* ---- 0x300 host doorbells (16 queues) ---- */
#define CSR_DOORBELL     0x300  /* W[] : 16 * 0x4, host rings to submit a token       */

/* ---- field enums ---- */
enum mate_precision {           /* CSR_MATE_MODE[2:1] — see compiler guide §6      */
    PREC_STATIC_W4A8 = 0,       /* INT8 act × INT4 wt / INT8 Q × dequant-K; silicon */
    PREC_ADAPTIVE    = 1,       /* per-tile INT8/FP16 gate; RESERVED, needs MatE
                                   FP16 escape — OPEN reconciliation (STATUS §7)     */
};
enum tiu_mode {                 /* CSR_TIU_MODE[1:0]                                */
    TIU_OFF = 0,
    TIU_H2O = 1,                /* heavy-hitter retention + eviction (default)      */
    TIU_STREAMING_LLM = 2,      /* attention-sink + recent window                   */
    TIU_ADAPTIVE_PRECISION = 3, /* H2O + drive per-block value tier (keep→CQ8/demote→CQ4) */
};

#endif /* LAMBDA_CSR_MAP_H */
