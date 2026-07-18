/* lsu.h — Lambda LSU (Layer Sequencer Unit) instruction set.
 *
 * The chip-level ISA. The host loads a schedule (a sequence of these 32-bit
 * instructions) into the LSU's 4 KB instruction RAM at boot; the LSU walks it
 * in order (3-stage fetch/decode/dispatch, 16 GPRs, no branch predictor).
 * Instructions either do tiny scalar work (address math) or DISPATCH a job to a
 * compute/memory block and move on — the blocks run asynchronously and
 * self-synchronize on the named SRAM buffers.
 *
 * Status: DRAFT lsu-isa-0.1 (2026-07-18). Encoding is provisional; the golden
 * assembler is src/golden/lsu_asm.py (to draft). Open items are marked OPEN.
 * See docs/compiler_programming_guide.md §4 for how a backend emits these.
 *
 * Instruction word (32-bit, fixed width):
 *   [31:26] opcode (6b)   [25:0] operands (format depends on opcode class)
 * Three issue lanes decode from the opcode class: SCALAR, DISPATCH, DMA.
 */
#ifndef LAMBDA_LSU_H
#define LAMBDA_LSU_H
#include <stdint.h>

/* ---- opcode map (6-bit; <=32 used, one per the "32 fixed-width instrs" spec) ---- */
enum lsu_opcode {
    /* --- control lane (0x00-0x07) --- */
    OP_NOP        = 0x00,  /* do nothing (pipeline bubble / alignment)              */
    OP_HALT       = 0x01,  /* end of schedule; raise completion IRQ to host         */
    OP_BARRIER    = 0x02,  /* wait until all outstanding dispatches for `mask` drain */
    OP_DBELL_WAIT = 0x03,  /* block until a host doorbell (new token) arrives        */
    OP_SET_CSR    = 0x04,  /* CSR[imm16] <- rs1                                      */
    OP_GET_CSR    = 0x05,  /* rd <- CSR[imm16]                                       */
    OP_LOOP       = 0x06,  /* outer-loop only (layers/tokens); NOT used in hot tile  */
    OP_YIELD      = 0x07,  /* release issue slot for a cycle (rarely needed)         */

    /* --- scalar ALU lane (0x08-0x0F): address & count math on 16 GPRs --- */
    OP_LDI        = 0x08,  /* rd <- sign_ext(imm16)                                  */
    OP_MOV        = 0x09,  /* rd <- rs1                                              */
    OP_ADD        = 0x0A,  /* rd <- rs1 + rs2                                        */
    OP_ADDI       = 0x0B,  /* rd <- rs1 + sign_ext(imm16)                            */
    OP_SUB        = 0x0C,  /* rd <- rs1 - rs2                                        */
    OP_SLLI       = 0x0D,  /* rd <- rs1 << imm5 (address scaling)                    */
    OP_CMP        = 0x0E,  /* flags <- (rs1 ? rs2) for the outer LOOP                */
    OP_SELECT     = 0x0F,  /* rd <- flags ? rs1 : rs2                                */

    /* --- DMA / memory lane (0x10-0x17): descriptors to MSC --- */
    OP_LOAD_WEIGHTS = 0x10,/* stage weight slice (layer,slice in fields) -> buffer   */
    OP_DMA_LOAD     = 0x11,/* DRAM -> SRAM descriptor (rs1=src, rs2=dst, imm=len)    */
    OP_DMA_STORE    = 0x12,/* SRAM -> DRAM descriptor                                */
    OP_KV_ALLOC     = 0x13,/* allocate a KV block slot; rd <- slot id                */
    OP_KV_FREE      = 0x14,/* free the KV block slot in rs1                          */
    OP_KV_EVICT     = 0x15,/* ask TIU for the min-importance block, spill via MSC;
                             rd <- evicted slot (see csr TIU_MODE)                   */
    OP_PREFETCH     = 0x16,/* hint: warm a DRAM row into SRAM                        */
    OP_DMA_FENCE    = 0x17,/* order DMAs before/after this point                     */

    /* --- compute dispatch lane (0x18-0x1F) --- */
    OP_ISSUE_MAT_E   = 0x18,/* MatE GEMM: {op_id, src_buf, wt_buf, dst_buf}          */
    OP_ISSUE_VEC_U   = 0x19,/* VecU microcode op: {uop_id, src_buf, dst_buf}         */
    OP_ISSUE_KCE_COMP= 0x1A,/* KVE compress K,V -> kv_scratchpad (grouped keys)      */
    OP_ISSUE_KCE_DEC = 0x1B,/* KVE decompress a KV block/range -> fp16               */
    OP_SET_MODE      = 0x1C,/* per-block mode strobe (e.g. MatE dataflow) = imm      */
    OP_TIU_ACC       = 0x1D,/* explicit TIU importance add (usually implicit via VecU
                             softmax side-channel); {block_id, weight}              */
    OP_WAIT_DONE     = 0x1E,/* stall issue until `unit`'s dispatch queue is empty    */
    OP_SAMPLE        = 0x1F,/* VecU sampling epilogue -> next-token id -> host       */
    /* 0x20-0x3F reserved (OPEN: FA-3 fused ISSUE_MAT_E+ISSUE_VEC_U macro-op,
       STATUS.md §7). */
};

/* ---- field accessors (little-endian bitfields inside the 26 operand bits) ---- */
#define LSU_OPCODE(w)     (((w) >> 26) & 0x3F)
#define LSU_RD(w)         (((w) >> 22) & 0x0F)   /* 16 GPRs                        */
#define LSU_RS1(w)        (((w) >> 18) & 0x0F)
#define LSU_RS2(w)        (((w) >> 14) & 0x0F)
#define LSU_IMM16(w)      ((int16_t)((w) & 0xFFFF))
#define LSU_UNIT(w)       (((w) >> 22) & 0x0F)   /* dispatch: target sub-op/unit   */
#define LSU_SRC(w)        (((w) >> 18) & 0x0F)   /* dispatch: source SRAM buffer   */
#define LSU_DST(w)        (((w) >> 14) & 0x0F)   /* dispatch: dest SRAM buffer     */
#define LSU_AUX(w)        ((w) & 0x3FFF)         /* dispatch: op-specific 14b      */
#define LSU_ENCODE(op,a,b,c,imm) \
    (((uint32_t)(op)<<26)|((uint32_t)((a)&0xF)<<22)|((uint32_t)((b)&0xF)<<18)| \
     ((uint32_t)((c)&0xF)<<14)|((uint32_t)((imm)&0x3FFF)))

/* ---- named SRAM buffers (dispatch src/dst operands) ---- */
enum lsu_buffer {
    BUF_ACT       = 0x0,  /* activation_buffer (0.3 MB, 2-port)          */
    BUF_QKV       = 0x1,  /* qkv scratch                                 */
    BUF_KV_SCRATCH= 0x2,  /* kv_scratchpad (compressed KV)               */
    BUF_SCORES    = 0x3,  /* attention scores / P                        */
    BUF_WEIGHT    = 0x4,  /* weight_stream_buffer (0.05 MB)              */
    BUF_ROM       = 0x5,  /* codebook_const_rom (RoPE/LUT/outlier mask)  */
    BUF_OHEAD     = 0x6,  /* per-head attention output                   */
};

/* ---- MatE op ids (OP_ISSUE_MAT_E unit field) ---- */
enum mate_op   { MATE_QKV_PROJ=0, MATE_FFN_UP=1, MATE_FFN_DOWN=2,
                 MATE_QK_DOT=3, MATE_PV=4, MATE_LM_HEAD=5 };
/* ---- MatE dataflow modes (OP_SET_MODE imm) ---- */
enum mate_mode { MATE_WEIGHT_STATIONARY=0, MATE_OUTPUT_STATIONARY=1 };
/* ---- VecU microcode op ids (OP_ISSUE_VEC_U unit field) ---- */
enum vecu_op   { VECU_ROPE=0, VECU_SOFTMAX_ONLINE=1, VECU_RMSNORM=2,
                 VECU_SILU=3, VECU_RESIDUAL_ADD=4, VECU_SAMPLE=5 };

#endif /* LAMBDA_LSU_H */
