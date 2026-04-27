"""
Shared constants for Lambda v2 design-space validation.

Every numeric assumption used by the audit scripts. Each value cites its source
or is explicitly tagged as an estimate. If you change a number, update it here
once — never duplicate across scripts.
"""

# ---------------------------------------------------------------------------
# Process — TSMC N16FFC
# ---------------------------------------------------------------------------

# Logic gate density at 16nm. Source: WikiChip, multiple cross-checks.
GATE_DENSITY_MTR_PER_MM2 = 28.2

# 6T HD bitcell area at TSMC 16nm. Source: IEEE/TSMC publications, "0.07 um² per bit"
SRAM_HD_6T_CELL_UM2 = 0.07

# 2-port 256kb SRAM macro density at 16nm. Source: IEEE 2016 paper.
SRAM_2PORT_DENSITY_MB_PER_MM2 = 6.05 / 8  # 6.05 Mb/mm² → 0.756 MB/mm²

# 1-port HD compiler density (estimate; 1.5-2x denser than 2-port).
# Conservative: 1.0 MB/mm². Optimistic: 1.5 MB/mm². Use the middle.
SRAM_1PORT_HD_DENSITY_MB_PER_MM2 = 1.25  # estimate

# Theoretical bitcell-only density (no overhead) for sanity check.
SRAM_THEORETICAL_DENSITY_MB_PER_MM2 = 1.0 / (SRAM_HD_6T_CELL_UM2 * 8) * 1e6 / 1e6
# = 1 / (0.07e-12 m² × 8 bits) × 1e-6 mm²/m² = 1.79 MB/mm²

# Core voltage and clock target
CORE_VOLTAGE_V = 0.8
TARGET_CLOCK_MHZ = 1000  # 1 GHz; 800 MHz fallback documented in YAML

# ---------------------------------------------------------------------------
# LPDDR memory technology
# ---------------------------------------------------------------------------

# LPDDR5X-8533 (the JEDEC peak rate)
LPDDR5X_8533_MBPS = 8533

# LPDDR4X-4266 (typical mobile)
LPDDR4X_4266_MBPS = 4266

# Sustained / peak ratio for LPDDR. ~70% is widely documented planning estimate.
LPDDR_SUSTAINED_RATIO = 0.70

# Power efficiency (PHY + DRAM combined, mW per Gbps).
# Source: Samsung/Micron product briefs — LPDDR5X is "25% better than LPDDR5"
# and LPDDR5 is ~10 mW/Gbps. So LPDDR5X ≈ 7.5 mW/Gbps.
LPDDR5X_MW_PER_GBPS = 7.5
LPDDR4X_MW_PER_GBPS = 12.0  # ~25% worse than LPDDR5X

# PHY area estimates at 16nm, in mm². NDA-gated; these are extrapolations.
# Reference data points: OPENEDGES validated LPDDR5/4 PHY in silicon at 14/16/22 nm.
# Synopsys / Cadence quote NDA-gated; flagship 25 mm² spec used 2.5 mm² for LPDDR5X x64.
# Sub-linear scaling applies (analog calibration is fixed cost).
LPDDR5X_PHY_AREA_MM2 = {
    "x16": 1.20,   # estimated; could be 1.0-1.5
    "x32": 1.80,   # estimated; could be 1.5-2.2
    "x64": 2.50,   # used in flagship spec
}
LPDDR4X_PHY_AREA_MM2 = {
    "x16": 1.00,   # ~17% smaller than LPDDR5X for same width
    "x32": 1.50,
}

# ---------------------------------------------------------------------------
# I/O ring + clock + power at TSMC 16nm
# ---------------------------------------------------------------------------

# I/O pad ring width at 16nm (1.8 V GPIO with 2 kV HBM ESD). Source: Sofics
# I/O library briefs; pad cells ~80-100 µm wide.
IO_RING_WIDTH_UM = 100  # conservative

# Clock tree + power grid + routing as fraction of die at 16nm
CLOCK_POWER_ROUTING_FRACTION = 0.10  # ~10% of die

# Routing-overhead buffer fraction
ROUTING_BUFFER_FRACTION = 0.025  # ~2-3%

# ---------------------------------------------------------------------------
# Compute primitives
# ---------------------------------------------------------------------------

# Per-PE area for INT8 × INT4 systolic at 16nm.
# Conservative bound: ~700 µm² per PE (multiplier + accumulator + register).
# Aggressive bound: ~400 µm² per PE (with autoresearch optimization, e.g.
# T-02 from roadmap.md targeting ~70 gates per multiplier).
# Use middle estimate.
PE_AREA_UM2 = 600  # estimate

# Vector unit per-lane area at 16nm (16-bit FP/BF lane with shared LUT).
VECU_AREA_PER_LANE_MM2 = 0.018  # estimate; flagship 32-lane was 0.5 → 0.0156, use 0.018 for buffer

# KCE-mini (16-point Hadamard + 8-centroid Lloyd-Max + bit-pack).
# Flagship KCE (32-point) was 0.15 mm². 16-point Hadamard halves the butterfly
# (64 add/sub vs 160), saving ~0.07 mm². Lloyd-Max + bit-pack unchanged.
KCE_MINI_AREA_MM2 = 0.08

# MSC tiny (single LPDDR ch, 4-port crossbar, small block table)
MSC_TINY_AREA_MM2 = 0.18

# LSU minimal (32-instruction ISA, 4K microcode)
LSU_MINIMAL_AREA_MM2 = 0.10

# Serial host interface (USB-C 2.0 controller + small SerDes)
SHIF_AREA_MM2 = 0.30

# ---------------------------------------------------------------------------
# Power per block (estimates for sensitivity analysis)
# ---------------------------------------------------------------------------

# Compute power at 0.8V, 1 GHz, ~50% activity factor.
MATE_POWER_W_PER_TOPS = 5.0  # ~5 W/TOPS for INT8x4 at 16nm dense (no sparsity)
VECU_POWER_W_PER_LANE = 0.04  # estimate
SRAM_POWER_W_PER_MB = 0.4  # static + dynamic at 1 GHz access pattern
LEAKAGE_W = 0.7  # whole-chip leakage at 16nm 0.8V for 4 mm² die

# ---------------------------------------------------------------------------
# Quantization
# ---------------------------------------------------------------------------

# INT4 weight bytes per param
W4_BYTES_PER_PARAM = 0.5

# TurboQuant compression at different Hadamard sizes
# Source: ICLR'26 (arXiv 2504.19874) + LASSO design-rationale.md
TURBOQUANT_COMPRESSION = {
    32: 4.57,  # 32-point Hadamard, 3.5 b/elem effective
    16: 3.0,   # 16-point Hadamard, ~5.3 b/elem effective (per-group overhead grows)
}

# ---------------------------------------------------------------------------
# Target model classes
# ---------------------------------------------------------------------------

# Model architectures (params, KV layout) for the 0.25-7B range
# Sources: HuggingFace model cards, official model architecture papers
MODELS = {
    "SmolLM2-360M":     {"params_B": 0.36, "layers": 30, "kv_heads": 5,  "head_dim": 64},
    "Qwen2.5-0.5B":     {"params_B": 0.5,  "layers": 24, "kv_heads": 2,  "head_dim": 64},
    "Llama-3.2-1B":     {"params_B": 1.24, "layers": 16, "kv_heads": 8,  "head_dim": 64},
    "TinyLlama-1.1B":   {"params_B": 1.1,  "layers": 22, "kv_heads": 4,  "head_dim": 64},
    "Gemma-2-2B":       {"params_B": 2.0,  "layers": 26, "kv_heads": 4,  "head_dim": 256},
    "Llama-3.2-3B":     {"params_B": 3.21, "layers": 28, "kv_heads": 8,  "head_dim": 128},
    "Qwen2.5-3B":       {"params_B": 3.09, "layers": 36, "kv_heads": 2,  "head_dim": 128},
    "Mistral-NeMo-3B":  {"params_B": 3.0,  "layers": 28, "kv_heads": 8,  "head_dim": 128},
    "Phi-3.5-mini":     {"params_B": 3.82, "layers": 32, "kv_heads": 32, "head_dim": 96},
    "hypothetical-4B":  {"params_B": 4.0,  "layers": 32, "kv_heads": 8,  "head_dim": 128},
    "hypothetical-5B":  {"params_B": 5.0,  "layers": 32, "kv_heads": 8,  "head_dim": 128},
    "Mistral-7B":       {"params_B": 7.24, "layers": 32, "kv_heads": 8,  "head_dim": 128},
    "Llama-3.1-8B":     {"params_B": 8.03, "layers": 32, "kv_heads": 8,  "head_dim": 128},
}

# ---------------------------------------------------------------------------
# Performance thresholds
# ---------------------------------------------------------------------------

# Tok/s thresholds for "interactive"
TOK_S_HUMAN_READING = 5      # ~5 tok/s = above human reading speed
TOK_S_COMFORTABLE = 10       # comfortable interactive chat
TOK_S_VERY_COMFORTABLE = 20  # very fast interactive

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def lpddr_bandwidth_gbs(rate_mbps, width_bits, sustained=True):
    """LPDDR bandwidth in GB/s for a given rate and bus width."""
    peak = rate_mbps * width_bits / 8 / 1000
    return peak * LPDDR_SUSTAINED_RATIO if sustained else peak

def model_w4_size_gb(params_B):
    """Model weights in GB at INT4 quantization."""
    return params_B * 1e9 * W4_BYTES_PER_PARAM / 1e9

def per_token_kv_bytes(kv_heads, head_dim, layers=1, bits_per_elem=3.5):
    """KV bytes per token: K and V both, at given quantization, for given # layers."""
    return kv_heads * head_dim * 2 * bits_per_elem / 8 * layers

def io_ring_area_mm2(die_side_mm, ring_width_um=IO_RING_WIDTH_UM):
    """I/O ring area for a square die of given side length."""
    perimeter_mm = 4 * die_side_mm
    ring_area_mm2 = perimeter_mm * ring_width_um / 1000
    # Subtract corner double-counting (4 corners × ring_width²)
    corner_overlap_mm2 = 4 * (ring_width_um / 1000) ** 2
    return ring_area_mm2 - corner_overlap_mm2

def matE_area_mm2(pe_count, area_per_pe_um2=PE_AREA_UM2, overhead_factor=1.4):
    """MatE area = PE area + ~40% control/buffer/pipeline overhead."""
    return pe_count * area_per_pe_um2 * overhead_factor / 1e6

def matE_peak_tops(pe_count, clock_mhz=TARGET_CLOCK_MHZ):
    """MatE peak TOPS = 2 ops/cycle/PE × clock × PE_count."""
    return pe_count * 2 * clock_mhz * 1e6 / 1e12

def sram_area_mm2(size_mb, density_mb_per_mm2=SRAM_1PORT_HD_DENSITY_MB_PER_MM2,
                   overhead=0.10):
    """SRAM area + ~10% compiler overhead (BIST, sense amps, periphery)."""
    return size_mb / density_mb_per_mm2 * (1 + overhead)
