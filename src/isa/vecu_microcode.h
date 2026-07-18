/* vecu_microcode.h — Lambda VecU (Vector Unit) microcode format.
 *
 * VecU is 8-lane FP16/BF16 SIMD with a 1K-entry microcode RAM. Every non-GEMM
 * op runs here as a microcoded loop: online softmax (FA-3), RoPE, RMSNorm, SiLU,
 * residual add, sampling — plus the TIU importance side-channel. The LSU calls a
 * microcode routine with `ISSUE_VEC_U <op_handle>` (see lsu.h `enum vecu_op`);
 * this header defines (a) the microcode WORD format the routines are built from
 * and (b) the op-handle → entry-address table the assembler emits.
 *
 * Status: DRAFT vecu-isa-0.1 (2026-07-18). Microcode assembler:
 * src/golden/vecu_asm.py (to draft). See dataflow_walkthrough.md stages 6/9/9.5
 * and compiler_programming_guide.md §4 for the routines' roles.
 *
 * Microcode word (32-bit, fixed width):
 *   [31:26] uop   [25:22] vd   [21:18] vs1   [17:14] vs2   [13:10] lut/aux   [9:0] imm10
 * Lanes execute the same uop in lockstep (SIMD); vd/vs1/vs2 index 16 vector lane
 * registers (each 8×FP16). Scalars (running max/sum in softmax) live in the low
 * lane by convention.
 */
#ifndef LAMBDA_VECU_MICROCODE_H
#define LAMBDA_VECU_MICROCODE_H
#include <stdint.h>

/* ---- microcode uop set (6-bit) ---- */
enum vecu_uop {
    /* data movement */
    UOP_NOP      = 0x00,
    UOP_LD       = 0x01,  /* vd <- SRAM[base+imm] (8 lanes)                       */
    UOP_ST       = 0x02,  /* SRAM[base+imm] <- vs1                                */
    UOP_MOV      = 0x03,  /* vd <- vs1                                            */
    UOP_BCAST    = 0x04,  /* vd <- broadcast(scalar in vs1 low lane)             */
    UOP_LD_LUT   = 0x05,  /* vd <- LUT[lut][vs1] (transcendental table read)     */
    /* FP16 elementwise ALU */
    UOP_VADD     = 0x08,  /* vd <- vs1 + vs2                                      */
    UOP_VSUB     = 0x09,  /* vd <- vs1 - vs2                                      */
    UOP_VMUL     = 0x0A,  /* vd <- vs1 * vs2                                      */
    UOP_VMAC     = 0x0B,  /* vd <- vd + vs1*vs2 (fused)                           */
    UOP_VMAX     = 0x0C,  /* vd <- max(vs1, vs2)                                  */
    UOP_VRECIP   = 0x0D,  /* vd <- 1/vs1 (Newton step; for softmax normalize)    */
    UOP_VSEL     = 0x0E,  /* vd <- mask ? vs1 : vs2                               */
    /* transcendentals via LUT + linear interp (lut field selects table) */
    UOP_VEXP     = 0x10,  /* vd <- exp(vs1)      (softmax)                        */
    UOP_VRSQRT   = 0x11,  /* vd <- rsqrt(vs1)    (RMSNorm)                        */
    UOP_VSIGMOID = 0x12,  /* vd <- sigmoid(vs1)  (SiLU = x*sigmoid(x))            */
    /* cross-lane reductions (tree over the 8 lanes -> low lane) */
    UOP_REDMAX   = 0x18,  /* scalar <- max over lanes of vs1  (online-softmax m) */
    UOP_REDSUM   = 0x19,  /* scalar <- sum over lanes of vs1  (online-softmax l) */
    UOP_REDARGMAX= 0x1A,  /* scalar <- argmax over lanes (sampling)              */
    /* side-channel + control */
    UOP_TIU_EMIT = 0x1C,  /* add vs1 (per-KV-block cumulative softmax weight) to
                            the TIU importance register imm10=block_id (stage 9.5) */
    UOP_LOOP     = 0x1D,  /* decrement loop counter, branch to imm10 if != 0      */
    UOP_RET      = 0x1E,  /* return from the microcode routine to the LSU         */
    UOP_HALT     = 0x1F,
};

/* ---- transcendental LUT ids (uop lut/aux field) ---- */
enum vecu_lut { LUT_EXP = 0, LUT_RSQRT = 1, LUT_SIGMOID = 2, LUT_ROPE_COS = 3, LUT_ROPE_SIN = 4 };
/* Each LUT: 64 entries + linear interpolation (~0.05 ULP), in codebook_const_rom. */

/* ---- field accessors ---- */
#define VECU_UOP(w)  (((w) >> 26) & 0x3F)
#define VECU_VD(w)   (((w) >> 22) & 0x0F)
#define VECU_VS1(w)  (((w) >> 18) & 0x0F)
#define VECU_VS2(w)  (((w) >> 14) & 0x0F)
#define VECU_LUT(w)  (((w) >> 10) & 0x0F)
#define VECU_IMM10(w) ((w) & 0x3FF)
#define VECU_ENCODE(uop,vd,vs1,vs2,lut,imm) \
    (((uint32_t)(uop)<<26)|((uint32_t)((vd)&0xF)<<22)|((uint32_t)((vs1)&0xF)<<18)| \
     ((uint32_t)((vs2)&0xF)<<14)|((uint32_t)((lut)&0xF)<<10)|((uint32_t)((imm)&0x3FF)))

/* ---- op-handle table: ISSUE_VEC_U <vecu_op> -> microcode RAM entry address ----
 * The compiler/loader writes routine bodies into microcode RAM and this table maps
 * the LSU-visible op ids (lsu.h enum vecu_op) to their entry addresses. Addresses
 * here are the default layout emitted by src/golden/vecu_asm.py (to draft);
 * approximate body sizes from dataflow_walkthrough.md are noted. */
struct vecu_handle { int op_id; uint16_t entry_addr; const char *name; };
static const struct vecu_handle VECU_HANDLES[] = {
    { 0, 0x000, "rope"           },  /* ~12 uops/pair, 4 iters/head    (stage 6)   */
    { 1, 0x040, "softmax_online" },  /* ~32 uops/tile, FA-3 running m,l (stage 9)   */
    { 2, 0x0C0, "rmsnorm"        },  /* rsqrt + scale                               */
    { 3, 0x100, "silu"           },  /* x * sigmoid(x)                              */
    { 4, 0x130, "residual_add"   },  /* vd <- vs1 + vs2                             */
    { 5, 0x150, "sample"         },  /* temp/top-k over logits -> next-token id     */
};

#endif /* LAMBDA_VECU_MICROCODE_H */
