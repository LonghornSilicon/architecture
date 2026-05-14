# HIF — Host Interface (PCIe Gen3 x1 on M.2 form factor)

**Spec source:** `../../../arch.yml` block `host_interface` + `definitive_features_and_blocks.hardware_blocks` entry `HIF`.
**Revised:** 2026-05-14 (was USB-C 2.0 in earlier drafts; see `../../../STATUS.md` §2 change log + Phase 0.1 in `../../../docs/`).

## What this block is

- **PCIe Gen3 x1 endpoint** at ~1 GB/s sustained (~8 Gbps × 8b/10b = 800 MB/s nominal; realized closer to 1 GB/s including overhead)
- **M.2 2280 form factor** at the PCB level. M.2 connector wires 4 PCIe lanes by spec; on-die PHY drives x1 only (PCIe link training negotiates down cleanly)
- Three jobs: (a) PCIe endpoint enumeration on host, (b) CSR access for chip configuration + microcode load + token I/O, (c) JTAG + scan-chain debug via dedicated pins (separate from PCIe lanes)
- 16-deep doorbell queue (host → chip command notifications)
- 0.55 mm²; 0.30 W

## Why PCIe Gen3 x1 (not USB-C 2.0, not PCIe x4)

- USB-C 2.0 weight-load latency (25 sec for 1.5 GB) is annoying for development iteration. PCIe Gen3 x1 lands at 1.5 sec.
- PCIe Gen3 x4 PHY (~1.0-1.3 mm² at 16nm) doesn't fit at 4 mm² alongside LPDDR5X x16 PHY (1.2 mm²) + SRAM (0.71 mm²) + compute.
- x1 gives ~3× more bandwidth than weight-load actually needs at 0.55 mm² total. Standard M.2 form factor enables plug-and-play on any modern laptop, dev board, or M.2 slot.
- PCIe vendor IP at 16nm has **public datasheets** (Synopsys DesignWare PCIe Gen3 x1, Cadence PCIe Gen3 PHY) — unlike LPDDR5X PHY which is NDA-thin at 16nm.

## Area breakdown

| Component | Area | Source |
|---|---|---|
| PCIe Gen3 x1 PHY (vendor IP) | 0.35 mm² | Synopsys DesignWare or Cadence at 16nm |
| Controller (CSR + doorbell + link state) | 0.20 mm² | our HDL |
| **Total** | **0.55 mm²** | |

JTAG TAP pins separate from PCIe lanes; cost is in the I/O ring (already accounted).

## Files (to be written in Phase E)

- `hif.h`, `hif.cpp` — top-level Stratus entity (wraps vendor PCIe controller + PHY)
- `csr.h` — CSR register file (mapped into BAR0 of PCIe config space)
- `doorbell.h` — 16-deep command queue
- `jtag.h` — JTAG TAP + scan chain
- `tb/` — testbench
- `stratus.tcl`

## Vendor IP integration

The PCIe Gen3 x1 PHY and the PCIe Gen3 root-complex / endpoint controller are vendor IP — likely Synopsys DesignWare PCIe Gen3 x1 family (well-documented public datasheets at 16nm) or Cadence's PCIe Gen3 PHY + controller pair. Our HDL provides the BAR-mapped CSR + doorbell + JTAG side; the PHY + controller are dropped in as IP blocks during integration.

## Risk

- PCIe link training is the main verification surface (state machine + lane width negotiation). Less risky than LPDDR PHY but non-trivial. Verification tests budgeted at 30 (up from USB-C's 25).
- M.2 connector signal integrity at 8 Gbps over PCB traces — standard SI rules apply; not blocking.
