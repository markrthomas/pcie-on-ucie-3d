// ============================================================================
// dv/iverilog/loop_harness.svh — shared C1 loopback harness, `include'd inside a
// test module body (tb_loop, tb_pm, tb_rxovf).  Instantiates the adapter with the
// UCIe-3D Tx bus looped back to its Rx bus, the PCIe MAC source, the UCIe flit
// monitor, the UCIe remote-die control model, the PCIe sink, the two clocks, and
// CSR access / reset tasks.
// Requires: `import pcie_ucie3d_pkg::*;` and `include "pcie_pat.svh"` before.
// ============================================================================
  logic pcie_clk = 1'b0, ucie_clk = 1'b0;
  logic pcie_rst_n, ucie_rst_n;

  wire                     pcie_tvalid, pcie_tready, pcie_tlast;
  wire [PCIE_DATA_W-1:0]   pcie_tdata;
  wire [PCIE_KEEP_W-1:0]   pcie_tkeep;
  wire [PCIE_USER_W-1:0]   pcie_tuser;
  wire                     pcie_rx_tvalid, pcie_rx_tready, pcie_rx_tlast;
  wire [PCIE_DATA_W-1:0]   pcie_rx_tdata;
  wire [PCIE_KEEP_W-1:0]   pcie_rx_tkeep;
  wire [PCIE_USER_W-1:0]   pcie_rx_tuser;
  wire [UCIE_BUS_W-1:0]    ucie_tx_data;
  wire                     ucie_tx_valid, ucie_tx_start_flit;
  ucie_pwr_e               ucie_powerdown;
  ucie_speed_e             ucie_speed;
  wire [1:0]               ucie_width;
  wire [SB_W-1:0]          sb_m2s, sb_s2m;
  wire                     link_status, rx_active, rx_elec_idle;
  logic                    csr_valid = 1'b0, csr_write = 1'b0;
  logic [CSR_ADDR_W-1:0]   csr_addr  = 8'h00;
  logic [31:0]             csr_wdata = 32'h0;
  wire  [31:0]             csr_rdata;

  // C1 loopback: the UCIe-3D Tx bus is wired straight back to the Rx bus.
  pcie_ucie3d_adapter dut (
    .pcie_clk(pcie_clk), .pcie_rst_n(pcie_rst_n),
    .pcie_tvalid(pcie_tvalid), .pcie_tready(pcie_tready), .pcie_tdata(pcie_tdata),
    .pcie_tkeep(pcie_tkeep), .pcie_tlast(pcie_tlast), .pcie_tuser(pcie_tuser),
    .pcie_rx_tvalid(pcie_rx_tvalid), .pcie_rx_tready(pcie_rx_tready), .pcie_rx_tdata(pcie_rx_tdata),
    .pcie_rx_tkeep(pcie_rx_tkeep), .pcie_rx_tlast(pcie_rx_tlast), .pcie_rx_tuser(pcie_rx_tuser),
    .ucie_clk(ucie_clk), .ucie_rst_n(ucie_rst_n),
    .ucie_tx_data(ucie_tx_data), .ucie_tx_valid(ucie_tx_valid), .ucie_tx_start_flit(ucie_tx_start_flit),
    .ucie_rx_data(ucie_tx_data), .ucie_rx_valid(ucie_tx_valid), .ucie_rx_start_flit(ucie_tx_start_flit),
    .ucie_speed(ucie_speed), .ucie_width(ucie_width), .ucie_powerdown(ucie_powerdown),
    .ucie_link_status(link_status), .ucie_rx_active(rx_active), .ucie_rx_elec_idle(rx_elec_idle),
    .ucie_sb_m2s(sb_m2s), .ucie_sb_s2m(sb_s2m),
    .csr_valid(csr_valid), .csr_write(csr_write), .csr_addr(csr_addr),
    .csr_wdata(csr_wdata), .csr_rdata(csr_rdata)
  );

  ucie_sb_model phyc (
    .ucie_clk(ucie_clk), .ucie_rst_n(ucie_rst_n),
    .powerdown(ucie_powerdown), .speed(ucie_speed), .width(ucie_width),
    .ucie_tx_valid(ucie_tx_valid), .sb_m2s(sb_m2s),
    .ucie_link_status(link_status), .ucie_rx_active(rx_active),
    .ucie_rx_elec_idle(rx_elec_idle), .sb_s2m(sb_s2m)
  );

  pcie_mac_model mac (
    .pcie_clk(pcie_clk), .pcie_tvalid(pcie_tvalid), .pcie_tready(pcie_tready),
    .pcie_tdata(pcie_tdata), .pcie_tkeep(pcie_tkeep), .pcie_tlast(pcie_tlast),
    .pcie_tuser(pcie_tuser)
  );

  ucie_phy_model phy (
    .ucie_clk(ucie_clk), .ucie_rst_n(ucie_rst_n), .ucie_tx_data(ucie_tx_data),
    .ucie_tx_valid(ucie_tx_valid), .ucie_tx_start_flit(ucie_tx_start_flit)
  );

  pcie_sink_model sink (
    .pcie_clk(pcie_clk), .pcie_rst_n(pcie_rst_n), .pcie_rx_tvalid(pcie_rx_tvalid),
    .pcie_rx_tready(pcie_rx_tready), .pcie_rx_tdata(pcie_rx_tdata),
    .pcie_rx_tkeep(pcie_rx_tkeep), .pcie_rx_tlast(pcie_rx_tlast), .pcie_rx_err(pcie_rx_tuser[0])
  );

  always #2.5 pcie_clk = ~pcie_clk;   // 200 MHz
  always #1.0 ucie_clk = ~ucie_clk;   // 500 MHz

  task automatic csr_wr(input logic [7:0] a, input logic [31:0] d);
    begin
      @(negedge ucie_clk); csr_valid = 1'b1; csr_write = 1'b1; csr_addr = a; csr_wdata = d;
      @(negedge ucie_clk); csr_valid = 1'b0; csr_write = 1'b0;
    end
  endtask

  task automatic csr_rd(input logic [7:0] a, output logic [31:0] d);
    begin
      @(negedge ucie_clk); csr_addr = a; #0.1; d = csr_rdata;
    end
  endtask

  task automatic do_reset();
    begin
      pcie_rst_n = 1'b0; ucie_rst_n = 1'b0;
      repeat (10) @(posedge ucie_clk);
      pcie_rst_n = 1'b1; ucie_rst_n = 1'b1;
    end
  endtask
