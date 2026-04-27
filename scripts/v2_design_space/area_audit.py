#!/usr/bin/env python3
"""
Area audit for Lambda v2.

Sweeps PHY width × MatE size × SRAM size against a 4 mm² die budget.
Confirms that the v2 baseline (LPDDR5X x16, 8×8 MatE, 1.0 MB SRAM) fits.
Identifies which combinations bust the budget and which leave headroom.

Run: python3 area_audit.py
"""
from constants import (
    LPDDR5X_PHY_AREA_MM2, LPDDR4X_PHY_AREA_MM2,
    matE_area_mm2, sram_area_mm2, io_ring_area_mm2,
    KCE_MINI_AREA_MM2, MSC_TINY_AREA_MM2, LSU_MINIMAL_AREA_MM2,
    SHIF_AREA_MM2, VECU_AREA_PER_LANE_MM2, CLOCK_POWER_ROUTING_FRACTION,
    ROUTING_BUFFER_FRACTION,
)


def total_area(die_side_mm, phy_choice, phy_width, mate_pe, vecu_lanes, sram_mb,
                include_kce=True, include_msc=True, include_lsu=True,
                include_shif=True):
    """Compute total area accounting for a candidate v2 configuration."""
    # PHY
    if phy_choice == "LPDDR5X":
        phy = LPDDR5X_PHY_AREA_MM2[f"x{phy_width}"]
    elif phy_choice == "LPDDR4X":
        phy = LPDDR4X_PHY_AREA_MM2[f"x{phy_width}"]
    else:
        raise ValueError(f"unknown phy: {phy_choice}")

    # I/O ring
    die_area = die_side_mm * die_side_mm
    io_ring = io_ring_area_mm2(die_side_mm)

    # Clock + power + routing as fraction of die
    clock_power = die_area * CLOCK_POWER_ROUTING_FRACTION

    # Routing overhead buffer
    routing_buf = die_area * ROUTING_BUFFER_FRACTION

    # Compute blocks
    mate = matE_area_mm2(mate_pe)
    vecu = vecu_lanes * VECU_AREA_PER_LANE_MM2
    kce = KCE_MINI_AREA_MM2 if include_kce else 0
    msc = MSC_TINY_AREA_MM2 if include_msc else 0
    lsu = LSU_MINIMAL_AREA_MM2 if include_lsu else 0
    shif = SHIF_AREA_MM2 if include_shif else 0

    # SRAM
    sram = sram_area_mm2(sram_mb)

    breakdown = {
        "I/O ring + ESD":           round(io_ring, 3),
        "Clock + power + routing":  round(clock_power, 3),
        "Routing overhead":         round(routing_buf, 3),
        f"PHY ({phy_choice} x{phy_width})": round(phy, 3),
        f"MatE ({mate_pe} PEs)":    round(mate, 3),
        f"VecU ({vecu_lanes} lanes)": round(vecu, 3),
        "KCE (16-pt Hadamard)":     round(kce, 3),
        "MSC":                      round(msc, 3),
        "LSU":                      round(lsu, 3),
        "Serial host iface":        round(shif, 3),
        f"SRAM ({sram_mb} MB)":     round(sram, 3),
    }
    total = sum(breakdown.values())
    return total, breakdown


def print_config(label, total, breakdown, budget_mm2=4.0):
    print(f"=== {label} ===")
    for k, v in breakdown.items():
        print(f"  {k:<35s} {v:>5.3f} mm²")
    headroom = budget_mm2 - total
    status = "WITHIN BUDGET" if headroom >= 0 else "OVER BUDGET"
    print(f"  {'TOTAL':<35s} {total:>5.3f} mm²")
    print(f"  {'Budget':<35s} {budget_mm2:>5.3f} mm²")
    print(f"  {'Headroom':<35s} {headroom:>+5.3f} mm² [{status}]")
    print()


def main():
    print("=" * 72)
    print("Lambda v2 Area Audit (4 mm² die, 2×2 mm)")
    print("=" * 72)
    print()

    DIE_SIDE = 2.0  # 2×2 mm = 4 mm²

    # v2 baseline: LPDDR5X x16, 8×8 MatE, 8-lane VecU, 1.0 MB SRAM
    total, bd = total_area(DIE_SIDE, "LPDDR5X", 16, 64, 8, 1.0)
    print_config("v2 BASELINE (LPDDR5X x16, 8×8 MatE, 1.0 MB SRAM)", total, bd, 4.0)

    # v2 stretch: LPDDR5X x32 with shrinks elsewhere
    total, bd = total_area(DIE_SIDE, "LPDDR5X", 32, 64, 8, 0.4)
    print_config("v2 STRETCH (LPDDR5X x32, 8×8 MatE, 0.4 MB SRAM)", total, bd, 4.0)

    # Failed: LPDDR5X x64 (flagship PHY) at 4 mm² — should bust
    total, bd = total_area(DIE_SIDE, "LPDDR5X", 64, 64, 8, 0.5)
    print_config("v2 IMPOSSIBLE (LPDDR5X x64 — flagship PHY at 4 mm²)", total, bd, 4.0)

    # Original LPDDR4X x16 design (reference for "what we improved on")
    total, bd = total_area(DIE_SIDE, "LPDDR4X", 16, 64, 8, 1.2)
    print_config("v2 PRIOR (LPDDR4X x16, 8×8 MatE, 1.2 MB SRAM)", total, bd, 4.0)

    # Sensitivity: PHY area swings on the v2 baseline
    print("--- Sensitivity: LPDDR5X x16 PHY area uncertainty ---")
    print(f"{'PHY estimate':<20s}{'Total':>10s}{'Headroom':>12s}")
    for phy_est in [1.0, 1.1, 1.2, 1.3, 1.4, 1.5]:
        # Override the constant for this iteration
        from constants import LPDDR5X_PHY_AREA_MM2 as LP
        original = LP["x16"]
        LP["x16"] = phy_est
        total, _ = total_area(DIE_SIDE, "LPDDR5X", 16, 64, 8, 1.0)
        LP["x16"] = original  # restore
        headroom = 4.0 - total
        status = "OK" if headroom >= 0 else "OVER"
        print(f"  {phy_est:>5.2f} mm²    {total:>5.3f} mm² {headroom:>+8.3f} mm²  {status}")
    print()

    # Sensitivity: SRAM density uncertainty
    print("--- Sensitivity: SRAM 1-port HD density uncertainty ---")
    print(f"{'Density':<20s}{'Total':>10s}{'Headroom':>12s}")
    for density in [0.9, 1.0, 1.1, 1.25, 1.4, 1.5]:
        from constants import SRAM_1PORT_HD_DENSITY_MB_PER_MM2 as SD
        # Re-run with override
        import constants
        original = constants.SRAM_1PORT_HD_DENSITY_MB_PER_MM2
        constants.SRAM_1PORT_HD_DENSITY_MB_PER_MM2 = density
        # need to re-import sram_area_mm2 to pick up new constant
        # but constants module level functions capture by reference - safe
        total, _ = total_area(DIE_SIDE, "LPDDR5X", 16, 64, 8, 1.0)
        constants.SRAM_1PORT_HD_DENSITY_MB_PER_MM2 = original
        headroom = 4.0 - total
        status = "OK" if headroom >= 0 else "OVER"
        print(f"  {density:>5.2f} MB/mm² {total:>5.3f} mm² {headroom:>+8.3f} mm²  {status}")
    print()

    # Sweep MatE size at v2 baseline
    print("--- MatE size sweep at v2 baseline (LPDDR5X x16, 1.0 MB SRAM) ---")
    print(f"{'MatE':<10s}{'PEs':>6s}{'TOPS':>8s}{'mm²':>8s}{'Total':>8s}{'Headroom':>10s}")
    for mate_dim in [4, 6, 8, 10, 12, 16]:
        pe_count = mate_dim * mate_dim
        from constants import matE_peak_tops
        tops = matE_peak_tops(pe_count)
        total, bd = total_area(DIE_SIDE, "LPDDR5X", 16, pe_count, 8, 1.0)
        headroom = 4.0 - total
        status = "OK" if headroom >= 0 else "OVER"
        print(f"  {mate_dim}x{mate_dim:<5}{pe_count:>6}{tops:>8.3f}{matE_area_mm2(pe_count):>8.3f}"
              f"{total:>8.3f}{headroom:>+8.3f}  {status}")
    print()


if __name__ == "__main__":
    main()
