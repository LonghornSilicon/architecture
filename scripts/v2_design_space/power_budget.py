#!/usr/bin/env python3
"""
Power budget for Lambda v2.

Sums per-block power at the v2 baseline. Total target is 3-5 W (fanless / battery
envelope). Sensitivity to LPDDR5X power, MatE activity, and leakage.

Run: python3 power_budget.py
"""
from constants import (
    LPDDR5X_8533_MBPS, lpddr_bandwidth_gbs,
    LPDDR5X_MW_PER_GBPS, LPDDR4X_MW_PER_GBPS,
    MATE_POWER_W_PER_TOPS, VECU_POWER_W_PER_LANE,
    SRAM_POWER_W_PER_MB, LEAKAGE_W,
    matE_peak_tops,
)


def lpddr_power_w(rate_mbps, width_bits, mw_per_gbps):
    """LPDDR system power (PHY + DRAM combined)."""
    bw_gbps = rate_mbps * width_bits / 1000
    return bw_gbps * mw_per_gbps / 1000


def power_breakdown(phy_choice, phy_width, mate_pe, mate_util, vecu_lanes,
                     sram_mb, sram_util):
    if phy_choice == "LPDDR5X":
        rate = LPDDR5X_8533_MBPS
        mw_per_gbps = LPDDR5X_MW_PER_GBPS
    elif phy_choice == "LPDDR4X":
        from constants import LPDDR4X_4266_MBPS
        rate = LPDDR4X_4266_MBPS
        mw_per_gbps = LPDDR4X_MW_PER_GBPS
    else:
        raise ValueError(phy_choice)

    sustained_bw = lpddr_bandwidth_gbs(rate, phy_width)

    # LPDDR power (sustained throughput; assumes PHY+DRAM on whenever fetching)
    lpddr_power = sustained_bw * 8 * mw_per_gbps / 1000  # GB/s × 8 = Gbps; mW/Gbps → mW; /1000 → W

    # MatE power: peak TOPS × W/TOPS × utilization
    mate_tops = matE_peak_tops(mate_pe)
    mate_power = mate_tops * MATE_POWER_W_PER_TOPS * mate_util

    # VecU power: per-lane × util
    vecu_power = vecu_lanes * VECU_POWER_W_PER_LANE * mate_util  # similar activity to MatE

    # SRAM dynamic + static, ~50% utilization typical
    sram_power = sram_mb * SRAM_POWER_W_PER_MB * sram_util

    # KCE: small fixed-function, ~0.1 W when active
    kce_power = 0.1 * mate_util

    # MSC + LSU + HIF: low-activity control logic
    msc_power = 0.15
    lsu_power = 0.05
    hif_power = 0.10

    breakdown = {
        f"LPDDR PHY+DRAM ({phy_choice} x{phy_width})": lpddr_power,
        f"MatE ({mate_pe} PEs at {mate_util*100:.0f}% util)":   mate_power,
        f"VecU ({vecu_lanes} lanes)":                vecu_power,
        f"SRAM ({sram_mb} MB at {sram_util*100:.0f}% util)":    sram_power,
        "KCE":                                       kce_power,
        "MSC + LSU + HIF":                           msc_power + lsu_power + hif_power,
        "Leakage (whole-chip)":                      LEAKAGE_W,
    }
    total = sum(breakdown.values())
    return total, breakdown


def print_breakdown(label, total, breakdown):
    print(f"=== {label} ===")
    for k, v in breakdown.items():
        print(f"  {k:<50s} {v:>5.3f} W")
    print(f"  {'TOTAL':<50s} {total:>5.3f} W")
    print()


def main():
    print("=" * 78)
    print("Lambda v2 Power Budget")
    print("=" * 78)
    print()

    # v2 baseline at 50% MatE utilization (decode bandwidth-bound, not compute)
    total, bd = power_breakdown("LPDDR5X", 16, 64, 0.50, 8, 1.0, 0.50)
    print_breakdown("v2 BASELINE (LPDDR5X x16, decode at 50% util — bandwidth-bound)", total, bd)

    # Worst case: peak MatE
    total, bd = power_breakdown("LPDDR5X", 16, 64, 1.00, 8, 1.0, 0.80)
    print_breakdown("v2 PEAK (100% MatE util, 80% SRAM — prefill burst)", total, bd)

    # v2 stretch: LPDDR5X x32
    total, bd = power_breakdown("LPDDR5X", 32, 64, 0.50, 8, 0.4, 0.50)
    print_breakdown("v2 STRETCH (LPDDR5X x32, 0.4 MB SRAM)", total, bd)

    # Old: LPDDR4X x16 reference
    total, bd = power_breakdown("LPDDR4X", 16, 64, 0.50, 8, 1.0, 0.50)
    print_breakdown("v2 PRIOR (LPDDR4X x16) — for comparison", total, bd)

    # Sensitivity: leakage worst-case
    print("--- Sensitivity to LPDDR power efficiency ---")
    for mw_per_gbps in [5, 7.5, 10, 12.5]:
        bw_gbps = 12 * 8  # 12 GB/s sustained at x16
        lpddr_w = bw_gbps * mw_per_gbps / 1000
        print(f"  LPDDR5X at {mw_per_gbps:>4.1f} mW/Gbps → {lpddr_w:>5.2f} W"
              f" {'(claimed)' if mw_per_gbps == 7.5 else ''}")
    print()

    print("--- Conclusion ---")
    print("• v2 baseline decode power: ~3-4 W (fits fanless / battery envelope)")
    print("• v2 stretch (LPDDR5X x32) decode power: ~4.5-5.5 W (still fanless-feasible)")
    print("• Leakage is ~20% of total at 16nm 0.8V — significant but not dominant")
    print("• LPDDR power is the second-largest after leakage; PHY efficiency matters")
    print("  most when sponsor cares about battery life (mobile/edge deployment)")


if __name__ == "__main__":
    main()
