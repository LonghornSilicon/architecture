# MSC — Memory Subsystem Controller

**Spec source:** `../../../arch.yml` block `memory_subsystem_controller`.

## What this block is

- Single LPDDR5X x16 controller (open-page policy + bank-conflict avoidance + all DRAM timing constraints)
- 4-port SRAM crossbar (MatE, VecU, KCE, HIF)
- **128-entry block table** — vLLM PagedAttention in silicon. 16 tokens/block × 128 entries → 2K-token KV pages addressable
- DMA descriptor FSM
- On-demand KV decompress trigger (cold-page hits route through KCE inverse path)
- Request arbitration priority queue
- 0.18 mm²; 0.15 W

## Explicitly NOT supported

- Continuous batching (single-session chip)
- Tier-3 host-DRAM eviction (no PCIe; weights live in LPDDR forever after boot)
- Prefix sharing across sessions

## LPDDR PHY-side interface

The MSC does NOT include the LPDDR5X PHY itself — that's vendor IP (Synopsys DesignWare or Cadence Denali) at 1.2 mm². MSC implements the controller side (DFI 5.x interface), command queue, refresh management, training sequencer, and bank-state tracking.

## Files

- `msc.h`, `msc.cpp` — top-level Stratus entity
- `block_table.h` — 128-entry CAM-style block table
- `xbar.h` — 4-port SRAM crossbar
- `dfi.h` — DFI 5.x PHY interface (binds to vendor PHY at chip integration)
- `tb/` — testbench
- `stratus.tcl`
