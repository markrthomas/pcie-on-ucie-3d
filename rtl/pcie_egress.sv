// ============================================================================
// pcie_egress.sv — pcie_clk domain.  Presents the Rx CDC FIFO head (FWFT) as the
// pcie_rx_* AXI4-Stream master.  FIFO word = {err, last, keep, data};
// pcie_rx_tuser[0] = err on the tlast beat of an aborted frame (D9), other bits 0.
// ============================================================================
`include "pcie_ucie3d_pkg.sv"

module pcie_egress
  import pcie_ucie3d_pkg::*;
(
  input  logic [PCIE_DATA_W+PCIE_KEEP_W+1:0] fifo_rdata,
  input  logic                               fifo_empty,
  output logic                               fifo_rinc,

  output logic                               pcie_rx_tvalid,
  input  logic                               pcie_rx_tready,
  output logic [PCIE_DATA_W-1:0]             pcie_rx_tdata,
  output logic [PCIE_KEEP_W-1:0]             pcie_rx_tkeep,
  output logic                               pcie_rx_tlast,
  output logic [PCIE_USER_W-1:0]             pcie_rx_tuser
);
  assign pcie_rx_tvalid = !fifo_empty;
  assign pcie_rx_tdata  = fifo_rdata[PCIE_DATA_W-1:0];
  assign pcie_rx_tkeep  = fifo_rdata[PCIE_DATA_W +: PCIE_KEEP_W];
  assign pcie_rx_tlast  = fifo_rdata[PCIE_DATA_W+PCIE_KEEP_W];
  assign pcie_rx_tuser  = {{(PCIE_USER_W-1){1'b0}}, fifo_rdata[PCIE_DATA_W+PCIE_KEEP_W+1]};
  assign fifo_rinc      = pcie_rx_tvalid && pcie_rx_tready;
endmodule : pcie_egress
