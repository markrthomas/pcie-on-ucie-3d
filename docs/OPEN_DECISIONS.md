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
| D7 | CSR map + domain | RESOLVED 2026-10-17 (domain 2026-10-18) | `CSR_CTRL/SPEEDCFG/STATUS/ERR/RXCNT0/RXCNT1/PMCNT` (see `rtl/pcie_ucie3d_pkg.sv`). **M3: the control plane and CSR port run on `ucie_clk`** (the link clock, co-located with the sideband and link pins), not `pcie_clk` — the single-control-clock reference architecture; `csr_rdata` is a combinational read so a `pcie_clk`-side quasi-static read still works. |
| D8 | Sideband encoding | RESOLVED 2026-10-17 (frame 2026-10-18) | 8-bit M2S/S2M byte channels, idle 0; opcodes NOP/WR/RD/WR_ACK/RD_CPL. **M3 committed-write frame**: cycle0 `{SB_WR,4'h0}`, cycle1 `addr[15:8]`, cycle2 `addr[7:0]`, cycle3 `data`; remote die replies with one `{SB_WR_ACK,x}` byte or `SB_TIMEOUT`. Raw mode = the adapter is the only sideband master (no inbound arbitration). Preset written to `SB_ADDR_TX_PRESET` at bring-up and on each speed change / SPEEDCFG write. **OPEN**: exact UCIe-3.0 sideband register map (refine against the spec later). |
| D10 | Sideband / link timeout | RESOLVED 2026-10-17 | `SB_TIMEOUT=1024` cycles before flagging a timeout. |
| D16 | Link flow control | RESOLVED 2026-10-17 | Opt-in, compile-time (`-DFLOW_CTRL_OVERRIDE`); credit carried in the flit DLP area. Raw mode has no built-in retry, so this is the backpressure scheme when enabled. |
| D18 | Datapath-local reset | RESOLVED 2026-10-17 | Default ON (`DP_RESET`); PD_DP held in reset L1→DRAIN so no retention needed. Off via `-DDP_RESET_DISABLE`, and automatically with flow control. |
| D-baseline | UCIe generation / mode | RESOLVED 2026-10-17 | **UCIe 3.0 UCIe-3D, raw mode, NO D2D adapter, 64 GT/s (Gen) baseline.** Keep the datapath speed-parametric. |
| D-configs | The three TB configs | RESOLVED 2026-10-17 | Integrated DUT (C1) + PCIe-only back-to-back (C2) + UCIe-3D-only back-to-back (C3). User decision. |
| D20 | Link bring-up sequence | RESOLVED 2026-10-18 | FSM `ST_RESET` (wait `ucie_link_status` fall = reset handshake done) → `ST_SBINIT` (wait `ucie_rx_elec_idle` fall) → `ST_MBINIT` (wait `ucie_rx_active`) → power to L0 + preset write → `ST_ACTIVE`. `ucie_link_status` doubles as the op-complete handshake (held high through reset, pulses on each power/speed/width change), analog of eth-dj's PhyStatus. Modeled by `dv/common/ucie_sb_model.sv`. |
| D21 | L0s unsupported | RESOLVED 2026-10-18 | An `L0S` (`PWR_L0S`) power request is treated as `L0` by the FSM and flagged in `CSR_ERR[2]` once per CTRL write; the link stays up. |
| D22 | Preset re-send policy | RESOLVED 2026-10-18 | In raw mode the Tx preset (`SPEEDCFG`→`SB_ADDR_TX_PRESET`) is re-sent over the sideband at bring-up, on **every** speed change, and on a `SPEEDCFG` write — not gated on a modulation mode (unlike eth-dj's PAM4/Gen6 gate). |
| D23 | Golden `pmcnt` for `speed_change` | RESOLVED 2026-10-18 (M4) | The M0-scaffold golden assumed one preset re-send for the 64→32→64 round trip (`ops=3`, pmcnt 5). The real control plane completes, per D22, a SPEED_CHG op **and** a PARAM (preset re-send) op on **each** speed change: 2 link-up + 2×2 = **6**. `scenarios.py` `speed_change` ops reconciled 3→4; all five envs measure 6 and agree. Refining the golden to documented-correct behaviour, not weakening a checker. |
| D24 | C2 / C3 back-to-back scope | RESOLVED 2026-10-18 (M4) | **C2** (`tb_pcie_b2b`) wires a PCIe MAC source straight to a PCIe sink (no adapter) — the PCIe AXI-S FLIT interface / BFM contract baseline. **C3** (`tb_ucie_b2b`) joins two adapters at the UCIe-3D mainband (A.tx↔B.rx both ways); each adapter still brings up against its own local `ucie_sb_model` because the sideband is point-to-point to the local PHY, not carried across the 3D link. |

Add new decisions here (never silently in code). RTL/DUT behaviour changes proposed
by a swarm land here for human sign-off, not in a merged PR.
