# UCIe-3D baseline notes

Why the design targets **UCIe 3.0 / UCIe-3D raw mode**, and what that means for a
digital adapter model.

## Sources
- UCIe Consortium — **3.0 specification** announced 2025-08-05 (adds 48 & 64 GT/s
  for UCIe-S/-A, runtime recalibration, extended sideband). [businesswire](https://www.businesswire.com/news/home/20250805909613/en/UCIe-Consortium-Introduces-3.0-Specification-With-64-GTs-Performance-and-Enhanced-Manageability)
- UCIe-3D is the **vertical-stacking** variant: hybrid bonding, bump pitch **< 10 µm**
  "optimized" / 10–25 µm "functional"; face-to-face / face-to-back / back-to-back /
  multi-stack; and notably **no D2D adapter** — the protocol layer connects to the
  physical layer directly. [UCIe deck](https://www.uciexpress.org/), [SemiEngineering](https://semiengineering.com/ucies-major-technical-components-are-now-in-place/)
- **Raw mode** (from the UCIe layering): the protocol layer fills **every byte** of
  the flit; the adapter/link inserts **no CRC/Retry**, so the protocol owns error
  handling. PCIe maps onto UCIe via the FLIT-aware interface (e.g. PCIe-6 256B flit
  mode). [Synopsys](https://www.synopsys.com/designware-ip/technical-bulletin/ucie-multi-die-socs.html)

## What this means for the DUT
- The DUT is a **digital raw-mode adapter**, not a PHY: it never sees analog PAM4/NRZ
  levels or hybrid-bond electricals. Those (and UCIe link training) are DV BFMs.
- **No D2D adapter**: there is no CRC/Retry/flit-format negotiation block in the RTL.
  The adapter tunnels PCIe flit bytes opaquely over a wide, low-speed-per-pin parallel
  bump bus (modeled as `UCIE_BUS_W` bits/`ucie_clk`), delimiting PCIe frames with a
  thin internal flit header (D2). A credit scheme is **opt-in** (`FLOW_CTRL`, D16),
  since raw mode has no built-in retry.
- **64 GT/s (Gen) baseline** with the datapath kept speed-parametric (`ucie_speed_e`
  down to 4 GT/s) so lower rates remain a parameter choice.
- Bring-up / speed / width / power (L0/L1/L2) are negotiated over an 8-bit
  **sideband** (D8) — the structural analog of the sibling eth-dj repo's PIPE message
  bus.

These are pre-release / secondary sources; the official specification text is the
authority for exact figures. Refine the sideband register map against the spec in M3.
