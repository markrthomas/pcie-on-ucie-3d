// dv/uvm/adapter_uvm_pkg.sv — UVM environment (DV env 3).
// M0: a single smoke_test that resets the stub DUT and checks the reset/defaults
// contract.  M1+ grows this into the full env (flit sequencer/driver, UCIe PHY
// driver, CSR agent, scoreboard, scen_test running dv/common/scenarios.py).
package adapter_uvm_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import pcie_ucie3d_pkg::*;

  class smoke_test extends uvm_test;
    `uvm_component_utils(smoke_test)
    virtual adapter_if vif;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual adapter_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "adapter_if not set in config db")
    endfunction

    task run_phase(uvm_phase phase);
      int errors = 0;
      phase.raise_objection(this);

      // tie off DUT inputs
      vif.pcie_tvalid = 1'b0; vif.pcie_tlast = 1'b0; vif.pcie_tdata = '0;
      vif.pcie_tkeep = '0; vif.pcie_tuser = '0; vif.pcie_rx_tready = 1'b1;
      vif.ucie_rx_data = '0; vif.ucie_rx_valid = 1'b0; vif.ucie_rx_start_flit = 1'b0;
      vif.ucie_link_status = 1'b0; vif.ucie_rx_active = 1'b0; vif.ucie_rx_elec_idle = 1'b1;
      vif.ucie_sb_s2m = '0;
      vif.csr_valid = 1'b0; vif.csr_write = 1'b0; vif.csr_addr = '0; vif.csr_wdata = '0;

      vif.pcie_rst_n = 1'b0; vif.ucie_rst_n = 1'b0;
      repeat (10) @(posedge vif.ucie_clk);
      vif.pcie_rst_n = 1'b1; vif.ucie_rst_n = 1'b1;
      repeat (5) @(posedge vif.ucie_clk);

      if (vif.ucie_powerdown !== PWR_L1) begin errors++; `uvm_error("SMOKE", "powerdown != L1") end
      if (vif.ucie_speed !== SPEED_64)   begin errors++; `uvm_error("SMOKE", "speed != SPEED_64") end
      if (vif.ucie_tx_valid !== 1'b0)    begin errors++; `uvm_error("SMOKE", "Tx active out of reset") end
      if (vif.pcie_tready !== 1'b0)      begin errors++; `uvm_error("SMOKE", "ingress open before link-up") end

      if (errors == 0) `uvm_info("SMOKE", "UVM SMOKE PASS: reset defaults OK", UVM_NONE)
      else             `uvm_error("SMOKE", "UVM SMOKE FAIL")
      phase.drop_objection(this);
    endtask
  endclass
endpackage
