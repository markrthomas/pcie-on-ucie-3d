# Open decisions — pcie-on-ucie-3d

Numbered design decisions; the sink for "behaviour to review" items from the
swarms. Status: **OPEN** / **RESOLVED** (date). Mirrors the sibling eth-dj repo's
D-list convention; the RTL banners cite these D-numbers as they land (M1+).

| D | Topic | Status | Note |
|---|---|---|---|
| D1 | UCIe lane count | RESOLVED 2026-10-17 | `UCIE_NLANES` default 1; x2/x4 a parameter bump; **x8+ refused at elaboration** (`UCIE_BUS_W > PCIE_DATA_W` — the datapath moves one PCIe beat/clock). |
| D2 | Flit tunnel format | RESOLVED 2026-10-17 | PCIe frame bytes carried opaquely in the 256B flit payload (hdr byte0 valid/sof/eof, byte1 count, bytes 2..241 payload, 242..255 DLP/FEC placeholders). Raw mode: the link adds no CRC/retry. |
| D3 | Interface widths | **OPEN** | `PCIE_DATA_W=256`, `UCIE_DATA_W=64` first-cut; confirm against a realistic PCIe-rate ÷ UCIe-3D-rate ratio (sizes the gearbox + CDC depth). |
| D4 | `pcie_tuser` semantics | **OPEN** | SOF/err/tc tag carried or dropped across the link — decide in M1. |
| D7 | CSR map | RESOLVED 2026-10-17 | `CSR_CTRL/SPEEDCFG/STATUS/ERR/RXCNT0/RXCNT1/PMCNT` (see `rtl/pcie_ucie3d_pkg.sv`). |
| D8 | Sideband encoding | RESOLVED 2026-10-17 | 8-bit M2S/S2M byte channels, idle 0; opcodes NOP/WR/RD/WR_ACK/RD_CPL; preset written to `SB_ADDR_TX_PRESET` at bring-up. Analog of eth-dj's PIPE message bus. **OPEN**: exact UCIe-3.0 sideband register map (refine against the spec in M3). |
| D10 | Sideband / link timeout | RESOLVED 2026-10-17 | `SB_TIMEOUT=1024` cycles before flagging a timeout. |
| D16 | Link flow control | RESOLVED 2026-10-17 | Opt-in, compile-time (`-DFLOW_CTRL_OVERRIDE`); credit carried in the flit DLP area. Raw mode has no built-in retry, so this is the backpressure scheme when enabled. |
| D18 | Datapath-local reset | RESOLVED 2026-10-17 | Default ON (`DP_RESET`); PD_DP held in reset L1→DRAIN so no retention needed. Off via `-DDP_RESET_DISABLE`, and automatically with flow control. |
| D-baseline | UCIe generation / mode | RESOLVED 2026-10-17 | **UCIe 3.0 UCIe-3D, raw mode, NO D2D adapter, 64 GT/s (Gen) baseline.** Keep the datapath speed-parametric. |
| D-configs | The three TB configs | RESOLVED 2026-10-17 | Integrated DUT (C1) + PCIe-only back-to-back (C2) + UCIe-3D-only back-to-back (C3). User decision. |

Add new decisions here (never silently in code). RTL/DUT behaviour changes proposed
by a swarm land here for human sign-off, not in a merged PR.
