#!/usr/bin/env python3
"""
Model-fit search for Lambda v2.

Given (PHY width, target tok/s threshold, compute headroom multiplier),
enumerates which models in `MODELS` actually fit. A model 'fits' when:
  (a) bandwidth_bound_decode_tok_s ≥ threshold
  (b) compute_bound_decode_tok_s ≥ threshold (under given utilization)

Run: python3 model_fit.py
"""
from constants import (
    MODELS, lpddr_bandwidth_gbs, LPDDR5X_8533_MBPS, LPDDR4X_4266_MBPS,
    matE_peak_tops, model_w4_size_gb,
)


def fits_check(model_params_B, bandwidth_gbs, pe_count, tok_s_threshold, util=0.6):
    """Returns (fits, bw_tok_s, compute_tok_s, bottleneck)."""
    weights_gb = model_w4_size_gb(model_params_B)
    bw_tok_s = bandwidth_gbs / weights_gb

    # Compute side: ops needed = params × 2; available = TOPS × util × 1e3 (in GOPS)
    needed_ops_per_token = model_params_B * 1e9 * 2
    available_ops_per_sec = matE_peak_tops(pe_count) * 1e12 * util
    compute_tok_s = available_ops_per_sec / needed_ops_per_token

    actual_tok_s = min(bw_tok_s, compute_tok_s)
    fits = actual_tok_s >= tok_s_threshold

    if compute_tok_s < bw_tok_s:
        bottleneck = "compute"
    else:
        bottleneck = "bandwidth"

    return fits, bw_tok_s, compute_tok_s, bottleneck


def search(phy_label, bandwidth_gbs, pe_count, threshold):
    print(f"--- {phy_label}, {pe_count} PEs, ≥{threshold} tok/s threshold ---")
    print(f"{'Model':<22s}{'params (B)':>12s}{'BW tok/s':>10s}{'Comp tok/s':>12s}"
          f"{'Actual':>10s}{'Bottleneck':>13s}{'Fits?':>8s}")
    for name, m in MODELS.items():
        fits, bw_ts, comp_ts, bottleneck = fits_check(
            m["params_B"], bandwidth_gbs, pe_count, threshold)
        actual = min(bw_ts, comp_ts)
        marker = "YES" if fits else "no"
        print(f"{name:<22s}{m['params_B']:>12.2f}{bw_ts:>10.1f}{comp_ts:>12.1f}"
              f"{actual:>10.1f}{bottleneck:>13s}{marker:>8s}")
    print()


def main():
    print("=" * 100)
    print("Lambda v2 Model-Fit Search")
    print("=" * 100)
    print()

    # v2 baseline: LPDDR5X x16, 8x8 MatE
    bw = lpddr_bandwidth_gbs(LPDDR5X_8533_MBPS, 16)
    search(f"LPDDR5X x16 ({bw:.1f} GB/s sustained)", bw, 64, threshold=5)
    search(f"LPDDR5X x16 ({bw:.1f} GB/s sustained)", bw, 64, threshold=10)

    # v2 stretch: LPDDR5X x32
    bw = lpddr_bandwidth_gbs(LPDDR5X_8533_MBPS, 32)
    search(f"LPDDR5X x32 STRETCH ({bw:.1f} GB/s sustained)", bw, 64, threshold=5)

    # Old design: LPDDR4X x16
    bw = lpddr_bandwidth_gbs(LPDDR4X_4266_MBPS, 16)
    search(f"LPDDR4X x16 PRIOR ({bw:.1f} GB/s)", bw, 64, threshold=5)

    print("--- Conclusion ---")
    print("• At LPDDR5X x16 with 8×8 MatE: every model 0.36-3.8B fits at 5+ tok/s.")
    print("  4-5B class is at threshold (5 tok/s). 7-8B does not fit (would need x32).")
    print("• At LPDDR5X x32 stretch: 7-8B fits at 5-6 tok/s. Compute is the bottleneck")
    print("  for 5B+ models — but only 20% short, still above 5 tok/s threshold.")
    print("• 8×8 MatE has ample compute headroom for the v2 baseline target. NO need")
    print("  to grow MatE; bandwidth is the entire story.")


if __name__ == "__main__":
    main()
