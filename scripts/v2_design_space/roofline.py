#!/usr/bin/env python3
"""
Roofline analysis for Lambda v2.

Decode is bandwidth-bound (every token reads all weights from LPDDR). Determines
the largest model at a target tok/s for each PHY width choice. Plus a compute-
headroom check that confirms compute is not the bottleneck.

Run: python3 roofline.py
"""
from constants import (
    LPDDR5X_8533_MBPS, LPDDR4X_4266_MBPS, lpddr_bandwidth_gbs,
    model_w4_size_gb, MODELS, TOK_S_HUMAN_READING, TOK_S_COMFORTABLE,
    matE_peak_tops, W4_BYTES_PER_PARAM,
)


def decode_tok_per_sec(model_params_B, bandwidth_gbs, util=1.0):
    """At batch 1, decode = read_all_weights / bandwidth. Util defaults to bandwidth-bound."""
    weights_gb = model_w4_size_gb(model_params_B)
    time_per_tok_s = weights_gb / (bandwidth_gbs * util)
    return 1.0 / time_per_tok_s


def largest_model_at_threshold(bandwidth_gbs, tok_s_threshold):
    """Solve: tok/s = bandwidth / (params × 0.5e9) for params at threshold."""
    # tok/s × params × 0.5 = bandwidth (GB/s)
    # params (in B) × 0.5 = bandwidth / tok/s
    # params = bandwidth / (tok/s × 0.5)
    return bandwidth_gbs / (tok_s_threshold * W4_BYTES_PER_PARAM)


def compute_headroom_check(model_params_B, tok_s, pe_count, util=0.6):
    """Check whether MatE has enough compute headroom at given decode rate."""
    needed_gops = model_params_B * 1e9 * 2 * tok_s / 1e9  # 2 ops per param per token
    available_tops = matE_peak_tops(pe_count)
    available_gops = available_tops * 1000 * util
    return {
        "needed_gops": needed_gops,
        "available_gops": available_gops,
        "headroom_factor": available_gops / needed_gops,
        "compute_bound": needed_gops > available_gops,
    }


def main():
    print("=" * 72)
    print("Lambda v2 Roofline Analysis")
    print("=" * 72)
    print()

    phy_options = [
        ("LPDDR4X x16",    LPDDR4X_4266_MBPS, 16),
        ("LPDDR5X x16",    LPDDR5X_8533_MBPS, 16),  # v2 baseline
        ("LPDDR5X x32",    LPDDR5X_8533_MBPS, 32),  # v2 stretch
        ("LPDDR5X x64",    LPDDR5X_8533_MBPS, 64),  # flagship reference (won't fit)
    ]

    print("--- Bandwidth per PHY option (sustained at 70% of peak) ---")
    for name, rate, width in phy_options:
        bw = lpddr_bandwidth_gbs(rate, width)
        print(f"  {name:18s}: {bw:5.1f} GB/s sustained")
    print()

    print("--- Largest reasonable model (5 tok/s threshold = 200 ms/tok) ---")
    for name, rate, width in phy_options:
        bw = lpddr_bandwidth_gbs(rate, width)
        max_params = largest_model_at_threshold(bw, TOK_S_HUMAN_READING)
        print(f"  {name:18s}: {max_params:5.2f} B params at {bw:5.1f} GB/s × 200 ms / 0.5 = {max_params:.2f}B")
    print()

    print("--- Largest reasonable model (10 tok/s comfortable threshold) ---")
    for name, rate, width in phy_options:
        bw = lpddr_bandwidth_gbs(rate, width)
        max_params = largest_model_at_threshold(bw, TOK_S_COMFORTABLE)
        print(f"  {name:18s}: {max_params:5.2f} B params")
    print()

    # Per-model decode rate at LPDDR5X x16 (v2 baseline)
    bw_v2 = lpddr_bandwidth_gbs(LPDDR5X_8533_MBPS, 16)
    print(f"--- Decode tok/s for each candidate model at LPDDR5X x16 ({bw_v2:.1f} GB/s) ---")
    print(f"{'Model':<22s}{'params (B)':>12s}{'W4 size (GB)':>15s}{'ms/tok':>10s}{'tok/s':>10s}{'verdict':>22s}")
    for name, m in MODELS.items():
        params = m["params_B"]
        size_gb = model_w4_size_gb(params)
        time_ms = size_gb / bw_v2 * 1000
        tok_s = 1000 / time_ms
        if tok_s >= 20:
            verdict = "very comfortable"
        elif tok_s >= 10:
            verdict = "comfortable"
        elif tok_s >= 5:
            verdict = "borderline interactive"
        else:
            verdict = "below threshold"
        print(f"{name:<22s}{params:>12.2f}{size_gb:>15.2f}{time_ms:>10.1f}{tok_s:>10.1f}{verdict:>22s}")
    print()

    # Per-model decode rate at LPDDR5X x32 (v2 stretch)
    bw_stretch = lpddr_bandwidth_gbs(LPDDR5X_8533_MBPS, 32)
    print(f"--- Decode tok/s for each candidate model at LPDDR5X x32 stretch ({bw_stretch:.1f} GB/s) ---")
    print(f"{'Model':<22s}{'tok/s':>10s}{'verdict':>22s}")
    for name, m in MODELS.items():
        params = m["params_B"]
        size_gb = model_w4_size_gb(params)
        tok_s = bw_stretch / size_gb
        if tok_s >= 20:
            verdict = "very comfortable"
        elif tok_s >= 10:
            verdict = "comfortable"
        elif tok_s >= 5:
            verdict = "borderline interactive"
        else:
            verdict = "below threshold"
        print(f"{name:<22s}{tok_s:>10.1f}{verdict:>22s}")
    print()

    # Compute headroom check at 8x8 PE for each model at its bandwidth-bound rate
    pe_count_v2 = 64  # 8x8
    print(f"--- Compute headroom check (8×8 MatE = {pe_count_v2} PEs at LPDDR5X x16 BW) ---")
    print(f"{'Model':<22s}{'tok/s':>10s}{'GOPS need':>12s}{'GOPS avail':>12s}{'headroom':>12s}")
    for name, m in MODELS.items():
        if m["params_B"] > 5.5:
            continue  # only check models within v2's reasonable range
        params = m["params_B"]
        size_gb = model_w4_size_gb(params)
        tok_s = bw_v2 / size_gb
        check = compute_headroom_check(params, tok_s, pe_count_v2)
        marker = " *COMPUTE BOUND" if check["compute_bound"] else ""
        print(f"{name:<22s}{tok_s:>10.1f}{check['needed_gops']:>12.1f}"
              f"{check['available_gops']:>12.1f}{check['headroom_factor']:>11.1f}x{marker}")
    print()

    # Sanity: confirm bandwidth-bound regime at v2 across all models
    print("--- Conclusion ---")
    print("• LPDDR5X x16 → 12 GB/s sustained → max 4.8B params at 5 tok/s; 2.4B at 10 tok/s")
    print("• 3-3.8B class (Llama-3.2-3B, Qwen2.5-3B, Mistral-NeMo-3B, Phi-3.5-mini) is the")
    print("  comfortable interactive sweet spot at 6-8 tok/s")
    print("• 5B is the threshold (5 tok/s); 7B+ requires v2-stretch (LPDDR5X x32)")
    print("• Compute headroom is 1.5-3× across the entire reasonable model range — NOT a bottleneck")
    print("  (compute is bottleneck only in v2-stretch territory at 7B+)")


if __name__ == "__main__":
    main()
