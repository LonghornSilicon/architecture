#!/usr/bin/env python3
"""Generate a real Qwen2 attention slice for the KVCE+APA+TIU end-to-end RTL cosim.

Captures one (layer, head) of Qwen2-0.5B causal attention and emits a trace the
SystemVerilog testbench drives through all three built blocks in one simulation:

  Q vector (fp16→real) , and for T cached tokens the K and V vectors (fp16 bit
  patterns). The TB compresses+decompresses K,V through the KVCE value codec
  (cq_value_path, CQ-8), computes scores S=Q·K̂ in-sim, routes them through the
  APA precision_controller, softmaxes them into the TIU, and evicts — self-checking
  each block's rule on the coherent, RTL-derived data.

Output: trace.hex  (line 1: "D T C" ; line 2: Q reals ; then T×{K hex line, V hex line}).
"""
import argparse, math, os
import numpy as np
import torch, torch.nn.functional as F
from transformers import AutoModelForCausalLM, AutoTokenizer, AttentionInterface

CAP = {}
def hook(module, query, key, value, attention_mask, scaling=None, dropout=0.0, **kw):
    nrep = query.shape[1] // key.shape[1]
    k = key.repeat_interleave(nrep, 1) if nrep > 1 else key
    v = value.repeat_interleave(nrep, 1) if nrep > 1 else value
    if scaling is None: scaling = 1.0 / math.sqrt(query.shape[-1])
    Tq, Tk = query.shape[-2], k.shape[-2]
    s = torch.matmul(query.float(), k.float().transpose(-1, -2)) * scaling
    i = torch.arange(Tq, device=s.device).unsqueeze(-1)
    j = torch.arange(Tk, device=s.device).unsqueeze(0)
    s = s.masked_fill(j > i, float("-inf"))
    A = F.softmax(s, dim=-1, dtype=torch.float32)
    CAP[module.layer_idx] = (query.detach().cpu(), k.detach().cpu(), v.detach().cpu())
    return torch.matmul(A.to(query.dtype), v).transpose(1, 2).contiguous(), A

def f16hex(x):
    return format(int(np.float16(x).view(np.uint16)), "04x")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="Qwen/Qwen2-0.5B")
    ap.add_argument("--layer", type=int, default=6)
    ap.add_argument("--head", type=int, default=0)
    ap.add_argument("--T", type=int, default=16)   # cached tokens (= precision tile N via 4x4)
    ap.add_argument("--C", type=int, default=8)    # TIU cache budget (slots)
    ap.add_argument("--out", default="trace.hex")
    ap.add_argument("--prompt", default=(
        "The token importance unit and the KV cache engine and the precision "
        "controller all work together inside the attention block of the accelerator."))
    a = ap.parse_args()
    AttentionInterface.register("cap", hook)
    tok = AutoTokenizer.from_pretrained(a.model)
    model = AutoModelForCausalLM.from_pretrained(a.model, dtype=torch.float16,
                                                 attn_implementation="cap").cuda().eval()
    ids = tok(a.prompt, return_tensors="pt").input_ids.cuda()
    with torch.no_grad():
        model(ids)
    q_all, k_all, v_all = CAP[a.layer]                    # [1,H,T,D]
    D = q_all.shape[-1]
    T = min(a.T, k_all.shape[-2])
    # query = the last position's Q for the chosen head; K,V = first T cached tokens
    Q = q_all[0, a.head, -1, :].float().numpy()           # [D]
    K = k_all[0, a.head, :T, :].float().numpy()           # [T,D]
    V = v_all[0, a.head, :T, :].float().numpy()           # [T,D]

    outp = os.path.join(os.path.dirname(os.path.abspath(__file__)), a.out)
    with open(outp, "w") as f:
        f.write(f"{D} {T} {a.C}\n")
        f.write(" ".join(f"{float(x):.6f}" for x in Q) + "\n")
        for t in range(T):
            f.write(" ".join(f16hex(K[t, d]) for d in range(D)) + "\n")
            f.write(" ".join(f16hex(V[t, d]) for d in range(D)) + "\n")
    print(f"wrote {outp}: D={D} T={T} C={a.C}  (layer {a.layer} head {a.head})")

if __name__ == "__main__":
    main()
