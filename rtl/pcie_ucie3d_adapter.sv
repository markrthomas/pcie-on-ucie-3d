// ============================================================================
// pcie_ucie3d_adapter.sv — TOP of the PCIe <-> UCIe-3D raw-mode adapter.
//
// STATUS: M1 — the Tx datapath (PCIe -> UCIe-3D) is live:
//   pcie ingress -> tx_cdc (async FIFO) -> tx_framer (256B flit assembly) ->
//   tx_egress (serialise raw beats) -> ucie_tx_*.
// The Rx datapath (M2) and the control plane (sideband master / FSM / register
// file, M3) are still stubbed: the Rx egress is quiet, and the control/status
// outputs hold their reset values.  Because there is no FSM yet, the datapath is
// always enabled (tx_en = 1) and the PCIe ingress is open whenever the Tx CDC
// FIFO is not full; M3 reintroduces link-up gating.  Ports per docs/PLAN.md §2.
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

  // ---- supported lane counts: x1, x2, x4 (D1) -------------------------------
  if (UCIE_BUS_W > PCIE_DATA_W) begin : g_unsupported_lane_count
    $error("UCIE_NLANES=%0d is not supported: UCIE_BUS_W (%0d) exceeds PCIE_DATA_W (%0d); x1, x2, x4 only (D1)",
           UCIE_NLANES, UCIE_BUS_W, PCIE_DATA_W);
  end

  // ==== Tx datapath: PCIe AXI-S -> CDC FIFO -> flit framer -> UCIe Tx =========
  logic                             tx_fifo_full, tx_fifo_empty, tx_fifo_rinc;
  logic [PCIE_DATA_W+PCIE_KEEP_W:0] tx_fifo_rdata;
  logic [$clog2(FIFO_DEPTH):0]      tx_wfree_unused;
  logic                             flit_valid, flit_taken;
  logic [FLIT_BYTES*8-1:0]          flit;
  logic                             framer_idle, egress_busy;
  logic                             tx_st_any, tx_st_data;   // flow-control hooks (M3)

  // M1: no ingress gate yet (control plane is M3) — accept while the FIFO is not full.
  assign pcie_tready = !tx_fifo_full;

  async_fifo #(.W(PCIE_DATA_W+PCIE_KEEP_W+1), .DEPTH(FIFO_DEPTH)) u_tx_cdc (
    .wclk   (pcie_clk), .wrst_n (pcie_rst_n),
    .winc   (pcie_tvalid && pcie_tready),
    .wdata  ({pcie_tlast, pcie_tkeep, pcie_tdata}),
    .wfull  (tx_fifo_full), .wfree (tx_wfree_unused),
    .rclk   (ucie_clk), .rrst_n (ucie_rst_n),
    .rinc   (tx_fifo_rinc), .rdata (tx_fifo_rdata), .rempty (tx_fifo_empty)
  );

  tx_framer u_tx_framer (
    .clk (ucie_clk), .rst_n (ucie_rst_n),
    .fifo_rdata (tx_fifo_rdata), .fifo_empty (tx_fifo_empty), .fifo_rinc (tx_fifo_rinc),
    .flit_valid (flit_valid), .flit (flit), .flit_taken (flit_taken), .idle (framer_idle)
  );

  tx_egress u_tx_egress (
    .clk (ucie_clk), .rst_n (ucie_rst_n), .tx_en (1'b1),
    .flit_valid (flit_valid), .flit (flit), .flit_taken (flit_taken),
    .credit_ok (1'b1), .cr_req (1'b0), .seq_now ('0), .cl_now ('0),
    .st_any (tx_st_any), .st_data (tx_st_data),
    .ucie_tx_data (ucie_tx_data), .ucie_tx_valid (ucie_tx_valid),
    .ucie_tx_start_flit (ucie_tx_start_flit), .busy (egress_busy)
  );

  // ==== Rx datapath (M2) — stubbed quiet ======================================
  assign pcie_rx_tvalid = 1'b0;
  assign pcie_rx_tdata  = '0;
  assign pcie_rx_tkeep  = '0;
  assign pcie_rx_tlast  = 1'b0;
  assign pcie_rx_tuser  = '0;

  // ==== Control plane (M3) — stubbed reset values =============================
  assign ucie_speed     = SPEED_64;    // 64 GT/s baseline (UCIe 3.0)
  assign ucie_width     = 2'b00;       // x1
  assign ucie_powerdown = PWR_L1;      // low power out of reset (no FSM yet)
  assign ucie_sb_m2s    = '0;          // sideband idle

  always_comb begin
    unique case (csr_addr)
      CSR_CTRL:     csr_rdata = {25'b0, 2'b00, 3'(SPEED_64), 2'(PWR_L0)};
      CSR_SPEEDCFG: csr_rdata = {24'b0, SPEEDCFG_RST};
      CSR_STATUS:   csr_rdata = {19'b0, 1'b0, 1'b0, 4'(ST_RESET), 2'b00, 3'(SPEED_64), 2'(PWR_L1)};
      default:      csr_rdata = 32'h0; // ERR / RXCNT0 / RXCNT1 / PMCNT / unmapped
    endcase
  end

  // ---- observation points / still-unused signals (driven in M2+/M3+) --------
  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_obs = (^tx_wfree_unused) ^ framer_idle ^ egress_busy ^ tx_st_any ^ tx_st_data;
  wire unused_in  = ucie_rst_n ^ (^ucie_rx_data) ^ ucie_rx_valid ^ ucie_rx_start_flit
                  ^ ucie_link_status ^ ucie_rx_active ^ ucie_rx_elec_idle ^ (^ucie_sb_s2m)
                  ^ pcie_rx_tready ^ (^pcie_tuser)
                  ^ csr_valid ^ csr_write ^ (^csr_wdata);
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : pcie_ucie3d_adapter
