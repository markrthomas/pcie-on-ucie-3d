// dv/uvm/adapter_if.sv — DUT pin interface for the UVM env (DV env 3).
// M0: carries the full port set; the M1+ agents/sequencers drive/monitor it.
interface adapter_if import pcie_ucie3d_pkg::*; (input logic pcie_clk, input logic ucie_clk);
  logic                   pcie_rst_n, ucie_rst_n;
  // PCIe / FDI side
  logic                   pcie_tvalid, pcie_tready, pcie_tlast;
  logic [PCIE_DATA_W-1:0] pcie_tdata;
  logic [PCIE_KEEP_W-1:0] pcie_tkeep;
  logic [PCIE_USER_W-1:0] pcie_tuser;
  logic                   pcie_rx_tvalid, pcie_rx_tready, pcie_rx_tlast;
  logic [PCIE_DATA_W-1:0] pcie_rx_tdata;
  logic [PCIE_KEEP_W-1:0] pcie_rx_tkeep;
  logic [PCIE_USER_W-1:0] pcie_rx_tuser;
  // UCIe-3D side
  logic [UCIE_BUS_W-1:0]  ucie_tx_data, ucie_rx_data;
  logic                   ucie_tx_valid, ucie_tx_start_flit, ucie_rx_valid, ucie_rx_start_flit;
  ucie_speed_e            ucie_speed;
  logic [1:0]             ucie_width;
  ucie_pwr_e              ucie_powerdown;
  logic                   ucie_link_status, ucie_rx_active, ucie_rx_elec_idle;
  logic [SB_W-1:0]        ucie_sb_m2s, ucie_sb_s2m;
  // CSR
  logic                   csr_valid, csr_write;
  logic [CSR_ADDR_W-1:0]  csr_addr;
  logic [31:0]            csr_wdata, csr_rdata;
endinterface
