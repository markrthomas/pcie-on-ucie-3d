// ============================================================================
// lp/cocotb/pd_top.sv — power-state emulation top.  The adapter on the C1
// loopback (UCIe-3D Tx bus wired straight back to Rx) + the SV remote-die
// control model (ucie_sb_model) + the DV-only power sequencer (adapter_pmu).
//
// Unlike the eth-dj sibling (whose cocotb env drives the PHY from Python), this
// design's control plane / remote die is the SV ucie_sb_model, so it lives here
// inside the top; cocotb only drives the PCIe AXI-S source + sink and the CSR
// port, and watches the PMU controls.  lp/cocotb/pd_emu.py reaches into this
// hierarchy to emulate PD_DP power-off (state corruption), isolation clamps and
// retention save/restore.  No power semantics here: this is the "UPF-like
// without UPF" emulation (docs/power_intent.md, OSS power-state emulation).
// ============================================================================
`timescale 1ns/1ps
`include "pcie_ucie3d_pkg.sv"

module pd_top
  import pcie_ucie3d_pkg::*;
(
  input  logic                     pcie_clk,
  input  logic                     pcie_rst_n,
  input  logic                     pcie_tvalid,
  output logic                     pcie_tready,
  input  logic [PCIE_DATA_W-1:0]   pcie_tdata,
  input  logic [PCIE_KEEP_W-1:0]   pcie_tkeep,
  input  logic                     pcie_tlast,
  input  logic [PCIE_USER_W-1:0]   pcie_tuser,
  output logic                     pcie_rx_tvalid,
  input  logic                     pcie_rx_tready,
  output logic [PCIE_DATA_W-1:0]   pcie_rx_tdata,
  output logic [PCIE_KEEP_W-1:0]   pcie_rx_tkeep,
  output logic                     pcie_rx_tlast,
  output logic [PCIE_USER_W-1:0]   pcie_rx_tuser,
  input  logic                     ucie_clk,
  input  logic                     ucie_rst_n,
  input  logic                     csr_valid,
  input  logic                     csr_write,
  input  logic [CSR_ADDR_W-1:0]    csr_addr,
  input  logic [31:0]              csr_wdata,
  output logic [31:0]              csr_rdata,
  // PMU controls (observed by lp/cocotb/pd_emu.py)
  output logic                     dp_pwr_en,
  output logic                     dp_iso_en,
  output logic                     dp_save,
  output logic                     dp_restore,
  output logic                     dp_off,
  output int                       n_down,
  output int                       n_up
);
  wire [UCIE_BUS_W-1:0] ucie_tx_data;
  wire                  ucie_tx_valid, ucie_tx_start_flit;
  ucie_pwr_e            ucie_powerdown;
  ucie_speed_e          ucie_speed;
  wire [1:0]            ucie_width;
  wire [SB_W-1:0]       sb_m2s, sb_s2m;
  wire                  link_status, rx_active, rx_elec_idle;

  // C1 loopback: UCIe-3D Tx bus wired straight back to the Rx bus.
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

  adapter_pmu #(.DOWN_DELAY(16), .PWR_UP_CYC(2)) u_pmu (
    .clk(ucie_clk), .rst_n(ucie_rst_n), .powerdown(ucie_powerdown),
    .csr_valid(csr_valid), .csr_write(csr_write), .csr_addr(csr_addr), .csr_wdata(csr_wdata),
    .dp_pwr_en(dp_pwr_en), .dp_iso_en(dp_iso_en), .dp_save(dp_save), .dp_restore(dp_restore),
    .dp_off(dp_off), .n_down(n_down), .n_up(n_up)
  );
endmodule
