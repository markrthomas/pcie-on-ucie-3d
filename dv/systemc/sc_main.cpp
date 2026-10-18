// dv/systemc/sc_main.cpp — Verilator->SystemC smoke (DV env 4).
// M0: build the stub DUT as a verilated SystemC model, pulse reset, check the
// reset/defaults contract.  M1+ binds the Config-1 loopback (UCIe Tx -> Rx) and
// runs the shared scenarios via dv/common/cpp/adapter_bfm.h -> logs/results.json.
#include <systemc.h>
#include "Vpcie_ucie3d_adapter.h"

enum { PWR_L1 = 2, SPEED_64 = 7 };

int sc_main(int argc, char* argv[]) {
    Verilated::commandArgs(argc, argv);

    sc_clock pclk("pclk", 5, SC_NS);
    sc_clock uclk("uclk", 2, SC_NS);

    sc_signal<bool> pcie_rst_n, ucie_rst_n;
    sc_signal<bool> pcie_tvalid, pcie_tready, pcie_tlast;
    sc_signal<uint32_t> pcie_tkeep, pcie_tuser;
    sc_signal<sc_bv<256>> pcie_tdata, pcie_rx_tdata;
    sc_signal<bool> pcie_rx_tvalid, pcie_rx_tready, pcie_rx_tlast;
    sc_signal<uint32_t> pcie_rx_tkeep, pcie_rx_tuser;
    sc_signal<uint64_t> ucie_tx_data, ucie_rx_data;
    sc_signal<bool> ucie_tx_valid, ucie_tx_start_flit, ucie_rx_valid, ucie_rx_start_flit;
    sc_signal<uint32_t> ucie_speed, ucie_width, ucie_powerdown, ucie_sb_m2s, ucie_sb_s2m;
    sc_signal<bool> ucie_link_status, ucie_rx_active, ucie_rx_elec_idle;
    sc_signal<bool> csr_valid, csr_write;
    sc_signal<uint32_t> csr_addr, csr_wdata, csr_rdata;

    Vpcie_ucie3d_adapter dut("dut");
    dut.pcie_clk(pclk); dut.pcie_rst_n(pcie_rst_n);
    dut.pcie_tvalid(pcie_tvalid); dut.pcie_tready(pcie_tready); dut.pcie_tdata(pcie_tdata);
    dut.pcie_tkeep(pcie_tkeep); dut.pcie_tlast(pcie_tlast); dut.pcie_tuser(pcie_tuser);
    dut.pcie_rx_tvalid(pcie_rx_tvalid); dut.pcie_rx_tready(pcie_rx_tready); dut.pcie_rx_tdata(pcie_rx_tdata);
    dut.pcie_rx_tkeep(pcie_rx_tkeep); dut.pcie_rx_tlast(pcie_rx_tlast); dut.pcie_rx_tuser(pcie_rx_tuser);
    dut.ucie_clk(uclk); dut.ucie_rst_n(ucie_rst_n);
    dut.ucie_tx_data(ucie_tx_data); dut.ucie_tx_valid(ucie_tx_valid); dut.ucie_tx_start_flit(ucie_tx_start_flit);
    dut.ucie_rx_data(ucie_rx_data); dut.ucie_rx_valid(ucie_rx_valid); dut.ucie_rx_start_flit(ucie_rx_start_flit);
    dut.ucie_speed(ucie_speed); dut.ucie_width(ucie_width); dut.ucie_powerdown(ucie_powerdown);
    dut.ucie_link_status(ucie_link_status); dut.ucie_rx_active(ucie_rx_active); dut.ucie_rx_elec_idle(ucie_rx_elec_idle);
    dut.ucie_sb_m2s(ucie_sb_m2s); dut.ucie_sb_s2m(ucie_sb_s2m);
    dut.csr_valid(csr_valid); dut.csr_write(csr_write); dut.csr_addr(csr_addr);
    dut.csr_wdata(csr_wdata); dut.csr_rdata(csr_rdata);

    pcie_rx_tready.write(true); ucie_rx_elec_idle.write(true);
    pcie_rst_n.write(false); ucie_rst_n.write(false);
    sc_start(40, SC_NS);
    pcie_rst_n.write(true); ucie_rst_n.write(true);
    sc_start(20, SC_NS);

    int errors = 0;
    auto chk = [&](bool c, const char* m) { if (!c) { printf("FAIL: %s\n", m); errors++; } };
    chk(ucie_powerdown.read() == PWR_L1, "powerdown should be L1 out of reset");
    chk(ucie_speed.read() == SPEED_64,   "speed should be SPEED_64");
    chk(ucie_tx_valid.read() == false,   "no Tx traffic out of reset (nothing queued)");
    chk(pcie_tready.read() == true,      "PCIe ingress open at idle (M1: FIFO not full)");

    if (errors == 0) { printf("SYSTEMC SMOKE PASS: reset defaults OK\n"); return 0; }
    printf("SYSTEMC SMOKE FAIL: %d error(s)\n", errors); return 1;
}
