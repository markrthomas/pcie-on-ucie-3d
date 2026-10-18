// ============================================================================
// pcie_ucie3d_adapter.sv — TOP of the PCIe <-> UCIe-3D raw-mode adapter.
//
// STATUS: M0 SCAFFOLD — interface frozen, body is a stub.  Ports per docs/PLAN.md
// §2 plus the CSR port (docs/OPEN_DECISIONS.md D7).  Out of reset the adapter
// holds the UCIe link in L1 at the Gen (64 GT/s) baseline, drives no Tx traffic,
// and keeps the PCIe ingress closed; CSRs read their reset values.  The datapath
// (ingress/CDC/framer/egress, reverse path) and the control plane (sideband
// master, control FSM, register file) land in M1+.
// ============================================================================
`include "pcie_ucie3d_pkg.sv"

module pcie_ucie3d_adapter
  import pcie_ucie3d_pkg::*;
(
  // ---- PCIe / FDI side (PCIe 6 256-byte FLIT mode) --------------------------
  input  logic                     pcie_clk,
  input  logic                     pcie_rst_n,
  // ingress: PCIe controller -> adapter (AXI4-Stream-like flit stream)
  input  logic                     pcie_tvalid,
  output logic                     pcie_tready,
  input  logic [PCIE_DATA_W-1:0]   pcie_tdata,
  input  logic [PCIE_KEEP_W-1:0]   pcie_tkeep,
  input  logic                     pcie_tlast,
  input  logic [PCIE_USER_W-1:0]   pcie_tuser,
  // egress: adapter -> PCIe controller
  output logic                     pcie_rx_tvalid,
  input  logic                     pcie_rx_tready,
  output logic [PCIE_DATA_W-1:0]   pcie_rx_tdata,
  output logic [PCIE_KEEP_W-1:0]   pcie_rx_tkeep,
  output logic                     pcie_rx_tlast,
  output logic [PCIE_USER_W-1:0]   pcie_rx_tuser,

  // ---- UCIe-3D physical side (raw-mode parallel bump bus) -------------------
  input  logic                     ucie_clk,
  input  logic                     ucie_rst_n,
  // Tx datapath: adapter -> remote die
  output logic [UCIE_BUS_W-1:0]    ucie_tx_data,
  output logic                     ucie_tx_valid,
  output logic                     ucie_tx_start_flit,
  // Rx datapath: remote die -> adapter
  input  logic [UCIE_BUS_W-1:0]    ucie_rx_data,
  input  logic                     ucie_rx_valid,
  input  logic                     ucie_rx_start_flit,
  // per-link control/status
  output ucie_speed_e              ucie_speed,
  output logic [1:0]               ucie_width,
  output ucie_pwr_e                ucie_powerdown,
  input  logic                     ucie_link_status,
  input  logic                     ucie_rx_active,
  input  logic                     ucie_rx_elec_idle,
  // 8-bit UCIe sideband (M2S / S2M byte channels)
  output logic [SB_W-1:0]          ucie_sb_m2s,
  input  logic [SB_W-1:0]          ucie_sb_s2m,

  // ---- CSR port (pcie_clk domain, always ready; D7) -------------------------
  input  logic                     csr_valid,
  input  logic                     csr_write,
  input  logic [CSR_ADDR_W-1:0]    csr_addr,
  input  logic [31:0]              csr_wdata,
  output logic [31:0]              csr_rdata
);

  // ---- supported lane counts: x1, x2, x4 ------------------------------------
  // The datapath moves one PCIe beat (PCIE_DATA_W bits) per clock, so a UCIe bus
  // wider than that (x8 and up) cannot be kept fed / drained; refuse to elaborate
  // (OPEN_DECISIONS D1), mirroring the sibling eth-dj bridge.
  if (UCIE_BUS_W > PCIE_DATA_W) begin : g_unsupported_lane_count
    $error("UCIE_NLANES=%0d is not supported: UCIE_BUS_W (%0d) exceeds PCIE_DATA_W (%0d); x1, x2, x4 only (D1)",
           UCIE_NLANES, UCIE_BUS_W, PCIE_DATA_W);
  end

  // ---- M0 stub: static reset-value drives (no datapath / FSM yet) -----------
  assign pcie_tready        = 1'b0;                 // ingress closed until link-up (M3)
  assign pcie_rx_tvalid     = 1'b0;
  assign pcie_rx_tdata      = '0;
  assign pcie_rx_tkeep      = '0;
  assign pcie_rx_tlast      = 1'b0;
  assign pcie_rx_tuser      = '0;

  assign ucie_tx_data       = '0;
  assign ucie_tx_valid      = 1'b0;                 // no Tx traffic out of reset
  assign ucie_tx_start_flit = 1'b0;
  assign ucie_speed         = SPEED_64;             // 64 GT/s baseline (UCIe 3.0)
  assign ucie_width         = 2'b00;                // x1
  assign ucie_powerdown     = PWR_L1;               // low power out of reset
  assign ucie_sb_m2s        = '0;                   // sideband idle

  // ---- CSR read: reset-value constants (stub register file) -----------------
  always_comb begin
    unique case (csr_addr)
      CSR_CTRL:     csr_rdata = {25'b0, 2'b00, 3'(SPEED_64), 2'(PWR_L0)};
      CSR_SPEEDCFG: csr_rdata = {24'b0, SPEEDCFG_RST};
      CSR_STATUS:   csr_rdata = {19'b0, 1'b0, 1'b0, 4'(ST_RESET), 2'b00, 3'(SPEED_64), 2'(PWR_L1)};
      default:      csr_rdata = 32'h0;              // ERR / RXCNT0 / RXCNT1 / PMCNT / unmapped
    endcase
  end

  // ---- unused inputs in the M0 stub (driven in M1+) -------------------------
  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_in = pcie_clk ^ ucie_clk
                 ^ pcie_rst_n ^ pcie_tvalid ^ (^pcie_tdata) ^ (^pcie_tkeep) ^ pcie_tlast
                 ^ (^pcie_tuser) ^ pcie_rx_tready
                 ^ ucie_rst_n ^ (^ucie_rx_data) ^ ucie_rx_valid ^ ucie_rx_start_flit
                 ^ ucie_link_status ^ ucie_rx_active ^ ucie_rx_elec_idle ^ (^ucie_sb_s2m)
                 ^ csr_valid ^ csr_write ^ (^csr_wdata);
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : pcie_ucie3d_adapter
