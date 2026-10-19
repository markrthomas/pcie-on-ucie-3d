// ============================================================================
// dv/iverilog/tb_smoke.sv — reset / defaults + link-up smoke test (M3 contract).
//
// Out of reset the adapter reports the UCIe link in L1 at the 64 GT/s (Gen)
// baseline and keeps the PCIe ingress closed.  With the reset CSR values the
// control plane trains the link (SBINIT/MBINIT), sends the Tx preset over the
// sideband, brings power to L0, and then opens the ingress.  This checks both the
// reset values and the settled ACTIVE state (L0 / 64 GT/s / x1, ingress open,
// one preset sideband write, two completed control operations, no error flags).
// ============================================================================
`timescale 1ns/1ps
`include "pcie_ucie3d_pkg.sv"

module tb_smoke;
  import pcie_ucie3d_pkg::*;

  logic pcie_clk = 1'b0;
  logic ucie_clk = 1'b0;
  logic pcie_rst_n;
  logic ucie_rst_n;

  wire                   pcie_tready;
  wire                   ucie_tx_valid, ucie_tx_start_flit;
  wire [UCIE_BUS_W-1:0]  ucie_tx_data;
  ucie_speed_e           ucie_speed;
  ucie_pwr_e             ucie_powerdown;
  wire [1:0]             ucie_width;
  wire [SB_W-1:0]        sb_m2s, sb_s2m;
  wire                   link_status, rx_active, rx_elec_idle;
  logic                  csr_valid = 1'b0, csr_write = 1'b0;
  logic [CSR_ADDR_W-1:0] csr_addr  = 8'h00;
  logic [31:0]           csr_wdata = 32'h0;
  wire  [31:0]           csr_rdata;

  pcie_ucie3d_adapter dut (
    .pcie_clk      (pcie_clk),  .pcie_rst_n (pcie_rst_n),
    .pcie_tvalid   (1'b0),      .pcie_tready (pcie_tready), .pcie_tdata ('0),
    .pcie_tkeep    ('0),        .pcie_tlast (1'b0),         .pcie_tuser ('0),
    .pcie_rx_tvalid(),          .pcie_rx_tready (1'b1),     .pcie_rx_tdata (),
    .pcie_rx_tkeep (),          .pcie_rx_tlast (),          .pcie_rx_tuser (),
    .ucie_clk (ucie_clk), .ucie_rst_n (ucie_rst_n),
    .ucie_tx_data (ucie_tx_data), .ucie_tx_valid (ucie_tx_valid), .ucie_tx_start_flit (ucie_tx_start_flit),
    .ucie_rx_data ('0), .ucie_rx_valid (1'b0), .ucie_rx_start_flit (1'b0),
    .ucie_speed (ucie_speed), .ucie_width (ucie_width), .ucie_powerdown (ucie_powerdown),
    .ucie_link_status (link_status), .ucie_rx_active (rx_active), .ucie_rx_elec_idle (rx_elec_idle),
    .ucie_sb_m2s (sb_m2s), .ucie_sb_s2m (sb_s2m),
    .csr_valid (csr_valid), .csr_write (csr_write), .csr_addr (csr_addr),
    .csr_wdata (csr_wdata), .csr_rdata (csr_rdata)
  );

  ucie_sb_model phyc (
    .ucie_clk(ucie_clk), .ucie_rst_n(ucie_rst_n),
    .powerdown(ucie_powerdown), .speed(ucie_speed), .width(ucie_width),
    .ucie_tx_valid(ucie_tx_valid), .sb_m2s(sb_m2s),
    .ucie_link_status(link_status), .ucie_rx_active(rx_active),
    .ucie_rx_elec_idle(rx_elec_idle), .sb_s2m(sb_s2m)
  );

  always #2.5 pcie_clk = ~pcie_clk;   // 200 MHz
  always #1.0 ucie_clk = ~ucie_clk;   // 500 MHz

  int errors = 0;

  task automatic chk(input logic c, input string msg);
    if (!c) begin $display("FAIL: %s", msg); errors++; end
  endtask

  task automatic csr_rd(input logic [7:0] a, output logic [31:0] d);
    begin @(negedge ucie_clk); csr_addr = a; #0.1; d = csr_rdata; end
  endtask

  logic [31:0] d;

  initial begin
    pcie_rst_n = 1'b0;
    ucie_rst_n = 1'b0;
    repeat (10) @(posedge ucie_clk);
    pcie_rst_n = 1'b1;
    ucie_rst_n = 1'b1;
    repeat (5) @(posedge ucie_clk);

    // ---- reset contract: link still coming up, ingress closed ---------------
    chk(ucie_powerdown === PWR_L1,  "powerdown should be L1 out of reset");
    chk(ucie_speed === SPEED_64,    "speed should be SPEED_64 (UCIe 3.0 baseline)");
    chk(ucie_width === 2'b00,       "width should be x1 out of reset");
    chk(pcie_tready === 1'b0,       "PCIe ingress closed before link-up (M3 gating)");
    chk(ucie_tx_valid === 1'b0,     "no Tx traffic during bring-up");
    chk(dut.ctrl_state !== ST_ACTIVE, "not ACTIVE yet during bring-up");

    csr_rd(CSR_CTRL, d);
    chk(d === {25'b0, 2'b00, 3'(SPEED_64), 2'(PWR_L0)}, "CTRL reset value (requested L0 / 64 GT/s / x1)");
    csr_rd(CSR_SPEEDCFG, d);
    chk(d === {24'b0, SPEEDCFG_RST}, "SPEEDCFG reset value");

    // ---- wait for link-up ---------------------------------------------------
    wait (dut.ctrl_state == ST_ACTIVE);
    repeat (5) @(posedge ucie_clk);

    chk(ucie_powerdown === PWR_L0,  "powerdown L0 once active");
    chk(ucie_speed === SPEED_64,    "speed 64 GT/s once active");
    chk(ucie_width === 2'b00,       "width x1 once active");
    chk(pcie_tready === 1'b1,       "PCIe ingress open once active");
    chk(phyc.sb_writes == 1,        "one preset sideband write at link-up");
    chk(phyc.errors == 0,           "control model saw no illegal Tx");

    csr_rd(CSR_STATUS, d);
    chk(d[1:0] == PWR_L0 && d[4:2] == SPEED_64 && d[6:5] == 2'd0 && d[10:7] == ST_ACTIVE && d[12] == 1'b1,
        "STATUS shows L0 / 64 GT/s / x1 / ACTIVE");
    csr_rd(CSR_PMCNT, d);
    chk(d == 32'd2, "PMCNT == 2 (preset write + power L1->L0)");
    csr_rd(CSR_ERR, d);
    chk(d == 32'h0, "no error flags");

    if (errors == 0)
      $display("SMOKE PASS: reset defaults L1 / 64 GT/s / x1, link up to L0, ingress open, CSRs OK");
    else
      $display("SMOKE FAIL: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #200000;
    $display("SMOKE FAIL: timeout (state %0d)", dut.ctrl_state);
    $finish;
  end
endmodule
