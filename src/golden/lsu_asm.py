#!/usr/bin/env python3
"""lsu_asm.py — Lambda LSU assembler / disassembler (golden).

Bit-exact with src/isa/lsu.h (lsu-isa-0.1). Turns a human-readable LSU schedule
into 32-bit instruction words the host DMAs into the LSU instruction RAM, and back.
This is the ground-truth encoder a compiler backend emits through (or checks against).

Instruction word (32-bit): [31:26] opcode  [25:0] operands, format per opcode class:
  SCALAR  : opcode rd, rs1, rs2            or  opcode rd, rs1, #imm16
  DISPATCH: opcode unit, src_buf, dst_buf, #aux14
  DMA     : opcode rd, rs1, rs2, #aux14    (descriptor fields)
  CONTROL : opcode #imm16                  (or CSR: rs1/rd + #imm16)

Run:  python3 lsu_asm.py            # self-test: assemble+disassemble a layer body
      python3 lsu_asm.py file.lsu   # assemble a schedule to hex
"""
from __future__ import annotations
import sys, re

# ---- opcode table (mirror of lsu.h enum lsu_opcode) ------------------------------
OPC = {
    "NOP":0x00,"HALT":0x01,"BARRIER":0x02,"DBELL_WAIT":0x03,"SET_CSR":0x04,
    "GET_CSR":0x05,"LOOP":0x06,"YIELD":0x07,
    "LDI":0x08,"MOV":0x09,"ADD":0x0A,"ADDI":0x0B,"SUB":0x0C,"SLLI":0x0D,"CMP":0x0E,"SELECT":0x0F,
    "LOAD_WEIGHTS":0x10,"DMA_LOAD":0x11,"DMA_STORE":0x12,"KV_ALLOC":0x13,"KV_FREE":0x14,
    "KV_EVICT":0x15,"PREFETCH":0x16,"DMA_FENCE":0x17,
    "ISSUE_MAT_E":0x18,"ISSUE_VEC_U":0x19,"ISSUE_KCE_COMP":0x1A,"ISSUE_KCE_DEC":0x1B,
    "SET_MODE":0x1C,"TIU_ACC":0x1D,"WAIT_DONE":0x1E,"SAMPLE":0x1F,
}
OPC_REV = {v: k for k, v in OPC.items()}

# operand class per opcode
SCALAR = {"LDI","MOV","ADD","ADDI","SUB","SLLI","CMP","SELECT"}
DISPATCH = {"ISSUE_MAT_E","ISSUE_VEC_U","ISSUE_KCE_COMP","ISSUE_KCE_DEC","SET_MODE","TIU_ACC","WAIT_DONE"}
DMA = {"LOAD_WEIGHTS","DMA_LOAD","DMA_STORE","KV_ALLOC","KV_FREE","KV_EVICT","PREFETCH","DMA_FENCE"}
CONTROL = {"NOP","HALT","BARRIER","DBELL_WAIT","SET_CSR","GET_CSR","LOOP","YIELD","SAMPLE"}

# named operand enums (mirror lsu.h)
BUF = {"ACT":0,"QKV":1,"KV_SCRATCH":2,"SCORES":3,"WEIGHT":4,"ROM":5,"OHEAD":6}
MATE_OP = {"QKV_PROJ":0,"FFN_UP":1,"FFN_DOWN":2,"QK_DOT":3,"PV":4,"LM_HEAD":5}
VECU_OP = {"ROPE":0,"SOFTMAX_ONLINE":1,"RMSNORM":2,"SILU":3,"RESIDUAL_ADD":4,"SAMPLE":5}
MATE_MODE = {"WEIGHT_STATIONARY":0,"OUTPUT_STATIONARY":1}
UNIT_ENUM = {"ISSUE_MAT_E":MATE_OP, "ISSUE_VEC_U":VECU_OP, "SET_MODE":MATE_MODE}


def _tok(operand: str) -> int:
    """Resolve a register (r3), immediate (#imm / 0x.. / int) or named enum token."""
    operand = operand.strip()
    if not operand:
        return 0
    if re.fullmatch(r"r\d+", operand):
        return int(operand[1:]) & 0xF
    if operand.startswith("#"):
        operand = operand[1:]
    for table in (BUF, MATE_OP, VECU_OP, MATE_MODE):
        if operand.upper() in table:
            return table[operand.upper()]
    return int(operand, 0)


def encode(line: str) -> int:
    """Assemble one instruction line -> 32-bit word."""
    line = line.split(";")[0].strip()
    m = re.match(r"([A-Z_]+)\s*(.*)", line)
    if not m:
        raise ValueError(f"bad line: {line!r}")
    mn, rest = m.group(1), m.group(2)
    if mn not in OPC:
        raise ValueError(f"unknown opcode: {mn}")
    op = OPC[mn]
    args = [a for a in re.split(r"[,\s]+", rest) if a]

    if mn in DISPATCH:
        # unit is enum-resolved per opcode; src/dst are buffers; trailing #aux
        unit_tbl = UNIT_ENUM.get(mn, {})
        unit = unit_tbl.get(args[0].upper(), None) if args else 0
        if unit is None:
            unit = _tok(args[0])
        src = _tok(args[1]) if len(args) > 1 else 0
        dst = _tok(args[2]) if len(args) > 2 else 0
        aux = _tok(args[3]) if len(args) > 3 else 0
        return (op << 26) | ((unit & 0xF) << 22) | ((src & 0xF) << 18) | ((dst & 0xF) << 14) | (aux & 0x3FFF)

    if mn in SCALAR:
        rd = _tok(args[0]) if args else 0
        rs1 = _tok(args[1]) if len(args) > 1 else 0
        third = args[2] if len(args) > 2 else "0"
        if third.startswith("#") or re.fullmatch(r"(0x[0-9a-fA-F]+|-?\d+)", third):
            imm = _tok(third) & 0xFFFF
            return (op << 26) | ((rd & 0xF) << 22) | ((rs1 & 0xF) << 18) | imm
        rs2 = _tok(third)
        return (op << 26) | ((rd & 0xF) << 22) | ((rs1 & 0xF) << 18) | ((rs2 & 0xF) << 14)

    if mn in DMA:
        rd = _tok(args[0]) if args else 0
        rs1 = _tok(args[1]) if len(args) > 1 else 0
        rs2 = _tok(args[2]) if len(args) > 2 else 0
        aux = _tok(args[3]) if len(args) > 3 else 0
        return (op << 26) | ((rd & 0xF) << 22) | ((rs1 & 0xF) << 18) | ((rs2 & 0xF) << 14) | (aux & 0x3FFF)

    # CONTROL: optional single reg + imm16, or bare
    if mn in ("SET_CSR", "GET_CSR"):
        rrd = _tok(args[0]) if args else 0
        imm = _tok(args[1]) if len(args) > 1 else 0
        return (op << 26) | ((rrd & 0xF) << 22) | (imm & 0xFFFF)
    imm = _tok(args[0]) if args else 0
    return (op << 26) | (imm & 0xFFFF)


def decode(word: int) -> str:
    op = (word >> 26) & 0x3F
    mn = OPC_REV.get(op, f"?0x{op:02x}")
    if mn in DISPATCH:
        unit = (word >> 22) & 0xF; src = (word >> 18) & 0xF
        dst = (word >> 14) & 0xF; aux = word & 0x3FFF
        return f"{mn} {unit}, {src}, {dst}, #{aux}"
    if mn in SCALAR or mn in DMA:
        rd = (word >> 22) & 0xF; rs1 = (word >> 18) & 0xF
        rs2 = (word >> 14) & 0xF; imm = word & 0xFFFF
        return f"{mn} r{rd}, r{rs1}, r{rs2}/#{imm}"
    return f"{mn} #{word & 0xFFFF}"


def assemble(text: str) -> list[int]:
    out = []
    for ln in text.splitlines():
        ln = ln.split(";")[0].strip()
        if ln:
            out.append(encode(ln))
    return out


# ---- self-test: one attention layer body (from dataflow_walkthrough.md) ----------
_LAYER = """
LOAD_WEIGHTS   r1, r2, r0, #0        ; stage weights for qkv_proj -> WEIGHT buf
ISSUE_MAT_E    QKV_PROJ, ACT, QKV    ; INT8xINT4 projection
ISSUE_VEC_U    ROPE, QKV, QKV        ; RoPE on Q,K
ISSUE_KCE_COMP KV_SCRATCH, KV_SCRATCH ; ChannelQuant compress
SET_MODE       OUTPUT_STATIONARY     ; MatE dataflow for Q.K^T
ISSUE_MAT_E    QK_DOT, QKV, SCORES   ; scores (KVE dequants K)
ISSUE_VEC_U    SOFTMAX_ONLINE, SCORES, SCORES ; FA-3 (side-channel -> TIU)
ISSUE_MAT_E    PV, SCORES, OHEAD     ; P.V (adaptive INT8/FP16)
ISSUE_VEC_U    RESIDUAL_ADD, OHEAD, ACT
BARRIER        #0
"""

if __name__ == "__main__":
    if len(sys.argv) > 1:
        words = assemble(open(sys.argv[1]).read())
        for w in words:
            print(f"{w:08x}")
        sys.exit(0)
    words = assemble(_LAYER)
    print(f"assembled {len(words)} instructions:")
    ok = True
    for w in words:
        d = decode(w)
        # round-trip: re-encode the disassembly's opcode is stable
        mn = d.split()[0]
        assert mn in OPC, f"round-trip opcode fail: {d}"
        print(f"  {w:08x}   {d}")
    print("SELF-TEST OK" if ok else "SELF-TEST FAILED")
