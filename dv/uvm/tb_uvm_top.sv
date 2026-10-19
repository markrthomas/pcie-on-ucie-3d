// dv/uvm/tb_uvm_top.sv — UVM testbench top (DV env 3).
// M0: clocks + interface + stub DUT + run_test("smoke_test").  M1+ wires the
// Config-1 loopback (UCIe Tx -> Rx) here.
`timescale 1ns/1ps
`include "pcie_ucie3d_pkg.sv"

module tb_uvm_top;
  import uvm_pkg::*;
  import pcie_ucie3d_pkg::*;
  import adapter_uvm_pkg::*;

  logic pcie_clk = 1'b0;
  logic ucie_clk = 1'b0;
  always #2.5 pcie_clk = ~pcie_clk;
  always #1.0 ucie_clk = ~ucie_clk;

  adapter_if vif(.pcie_clk(pcie_clk), .ucie_clk(ucie_clk));

  pcie_ucie3d_adapter dut (
    .pcie_clk (pcie_clk), .pcie_rst_n (vif.pcie_rst_n),
    .pcie_tvalid (vif.pcie_tvalid), .pcie_tready (vif.pcie_tready), .pcie_tdata (vif.pcie_tdata),
    .pcie_tkeep (vif.pcie_tkeep), .pcie_tlast (vif.pcie_tlast), .pcie_tuser (vif.pcie_tuser),
    .pcie_rx_tvalid (vif.pcie_rx_tvalid), .pcie_rx_tready (vif.pcie_rx_tready), .pcie_rx_tdata (vif.pcie_rx_tdata),
    .pcie_rx_tkeep (vif.pcie_rx_tkeep), .pcie_rx_tlast (vif.pcie_rx_tlast), .pcie_rx_tuser (vif.pcie_rx_tuser),
    .ucie_clk (ucie_clk), .ucie_rst_n (vif.ucie_rst_n),
    .ucie_tx_data (vif.ucie_tx_data), .ucie_tx_valid (vif.ucie_tx_valid), .ucie_tx_start_flit (vif.ucie_tx_start_flit),
    .ucie_rx_data (vif.ucie_rx_data), .ucie_rx_valid (vif.ucie_rx_valid), .ucie_rx_start_flit (vif.ucie_rx_start_flit),
    .ucie_speed (vif.ucie_speed), .ucie_width (vif.ucie_width), .ucie_powerdown (vif.ucie_powerdown),
    .ucie_link_status (vif.ucie_link_status), .ucie_rx_active (vif.ucie_rx_active), .ucie_rx_elec_idle (vif.ucie_rx_elec_idle),
    .ucie_sb_m2s (vif.ucie_sb_m2s), .ucie_sb_s2m (vif.ucie_sb_s2m),
    .csr_valid (vif.csr_valid), .csr_write (vif.csr_write), .csr_addr (vif.csr_addr),
    .csr_wdata (vif.csr_wdata), .csr_rdata (vif.csr_rdata)
  );

  // UVM_NO_DPI disables the DPI +UVM_TESTNAME path, so read it explicitly here.
  string tn;
  initial begin
    uvm_config_db#(virtual adapter_if)::set(null, "*", "vif", vif);
    if (!$value$plusargs("UVM_TESTNAME=%s", tn)) tn = "smoke_test";
    run_test(tn);
  end
endmodule
