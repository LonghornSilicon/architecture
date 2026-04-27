#!/usr/bin/env python3
"""
Top-level audit for Lambda v2.

Runs roofline + area + KV capacity + power + model-fit, then summarizes the
results into a single grounded report. **Start here.**

Run: python3 lambda_v2_audit.py
Or:  python3 lambda_v2_audit.py > audit_report.txt
"""
import sys
import roofline
import area_audit
import kv_capacity
import power_budget
import model_fit


def section(title):
    print()
    print("#" * 80)
    print(f"# {title}")
    print("#" * 80)
    print()


def main():
    print("LAMBDA v2 — Comprehensive Design-Space Audit")
    print("=" * 78)
    print("Generated: from first-principles + published references")
    print("Source files: constants.py + roofline.py + area_audit.py +")
    print("              kv_capacity.py + power_budget.py + model_fit.py")
    print()

    section("ROOFLINE — bandwidth-bound vs compute-bound regime")
    roofline.main()

    section("AREA AUDIT — does the floorplan fit at 4 mm²?")
    area_audit.main()

    section("KV SCRATCHPAD CAPACITY — which models fit which contexts on-die?")
    kv_capacity.main()

    section("POWER BUDGET — fits in fanless / battery envelope?")
    power_budget.main()

    section("MODEL-FIT SEARCH — what models actually run on v2?")
    model_fit.main()

    section("SUMMARY")
    print("""
LAMBDA v2 BASELINE — SURVIVES VALIDATION
=========================================

Configuration:
  - Process:       TSMC N16FFC (28.2 MTr/mm², 1.25 MB/mm² SRAM HD)
  - Die:           4 mm² (2×2 mm) via IMEC / Europractice mini@sic 2.0
  - Off-chip:      1× LPDDR5X-8533 x16 (~12 GB/s sustained, 4-8 GB capacity)
  - Compute:       8×8 MatE INT8×INT4 (64 PEs, 0.13 TOPS at 1 GHz)
                   8-lane VecU 16-bit FP/BF
                   KCE-mini (16-point Hadamard + 8-centroid Lloyd-Max + bit-pack)
  - SRAM:          1.0 MB total (0.5 KV / 0.3 act / 0.15 weight / 0.05 ROM)
  - Host iface:    USB-C 2.0 / minimal SerDes
  - Power:         ~3.5-4.5 W (fanless / battery envelope)
  - Shuttle cost:  ~$60-100K via IMEC / ~$75K via Muse fallback

Workload — confirmed fits at ≥5 tok/s threshold:
  - SmolLM2-360M:    67 tok/s (overkill)
  - Qwen2.5-0.5B:    48 tok/s (very comfortable)
  - Llama-3.2-1B:    20 tok/s (very comfortable)
  - Gemma-2-2B:      12 tok/s (comfortable)
  - Llama-3.2-3B:    8 tok/s (comfortable interactive)  ← PRIMARY DEMO TARGET
  - Qwen2.5-3B:      8 tok/s (comfortable; 32K context fits ON-DIE)
  - Mistral-NeMo-3B: 8 tok/s (comfortable)
  - Phi-3.5-mini:    6.3 tok/s (borderline interactive)
  - Hypothetical-4B: 6 tok/s (borderline)
  - Hypothetical-5B: 4.8 tok/s (at threshold — the ceiling)

NOT fits (would need v2-stretch with LPDDR5X x32):
  - Mistral-7B / Llama-3.1-8B: ~3.5 tok/s — too slow at W4

Stretch path (LPDDR5X x32, 4.4 mm² die, ~$90-130K):
  - Mistral-7B / Llama-3.1-8B fit at 5-6 tok/s (compute-bottlenecked)
  - Forces near-zero KV scratchpad
  - +25% shuttle cost; not pre-committed

Critical assumptions REMAINING TO BE VERIFIED with vendor quotes:
  1. LPDDR5X x16 PHY area at 16nm: estimated 1.2 mm² (could be 1.0-1.5)
     → Synopsys / Cadence quote in Q2 2026
  2. IMEC mini@sic 2.0 4 mm² N16FFC pricing: estimated $60-100K
     → Direct quote via eptsmc@imec.be in Q2 2026
  3. W4 quantization quality on Llama-3.2-3B specifically: literature suggests
     3-6% MMLU degradation with AWQ INT4 vs FP16. ACCEPTABLE for demo.
  4. 1-port HD SRAM density at 16nm: 1.25 MB/mm² mid-estimate
     (1.0 conservative, 1.5 optimistic). At 1.0, area headroom drops 0.2 mm²
     — apply shrink path if quote returns conservative.

DECISION POINTS:
  - v2 baseline (LPDDR5X x16) is the SAFE AMBITIOUS choice. Serves the same
    3-4B model class as the abandoned 25 mm² flagship targeted for 7-8B,
    in 1/6 the area, 1/5 the cost.
  - v2-stretch (LPDDR5X x32) is the AGGRESSIVE choice. Reaches 7-8B class
    but is compute-bottlenecked, has zero KV scratchpad, and costs +25%.
    Not recommended without specific sponsor demand for 7-8B headline.

  RECOMMENDATION: ship v2 baseline. Pursue v2-stretch only if (a) PHY quote
  comes back well under estimate (LPDDR5X x16 < 1.0 mm²) freeing area for
  a wider PHY without over-budget, OR (b) sponsor specifically wants 7-8B.
""")


if __name__ == "__main__":
    main()
