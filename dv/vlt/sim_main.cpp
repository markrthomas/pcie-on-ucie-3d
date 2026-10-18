// dv/vlt/sim_main.cpp — Verilator C++ smoke (DV env 2).
// M0: build the stub DUT, pulse reset, check the reset/defaults contract.
// M1+ wires the Config-1 loopback (UCIe Tx -> Rx) and runs the shared scenarios
// via dv/common/cpp/adapter_bfm.h, writing logs/results.json.
#include <cstdio>
#include <cstdlib>
#include "Vpcie_ucie3d_adapter.h"
#include "verilated.h"

// enum values mirror rtl/pcie_ucie3d_pkg.sv
enum { PWR_L0 = 0, PWR_L1 = 2 };
enum { SPEED_64 = 7 };

static Vpcie_ucie3d_adapter* dut = nullptr;
static vluint64_t main_time = 0;

static void tick() {
    dut->ucie_clk = 0; dut->pcie_clk = 0; dut->eval(); main_time++;
    dut->ucie_clk = 1; dut->pcie_clk = 1; dut->eval(); main_time++;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vpcie_ucie3d_adapter;

    // tie off inputs (wide signals such as pcie_tdata are zero at construction)
    dut->pcie_tvalid = 0; dut->pcie_tkeep = 0;
    dut->pcie_tlast = 0; dut->pcie_tuser = 0; dut->pcie_rx_tready = 1;
    dut->ucie_rx_data = 0; dut->ucie_rx_valid = 0; dut->ucie_rx_start_flit = 0;
    dut->ucie_link_status = 0; dut->ucie_rx_active = 0; dut->ucie_rx_elec_idle = 1;
    dut->ucie_sb_s2m = 0;
    dut->csr_valid = 0; dut->csr_write = 0; dut->csr_addr = 0; dut->csr_wdata = 0;

    dut->pcie_rst_n = 0; dut->ucie_rst_n = 0;
    for (int i = 0; i < 10; i++) tick();
    dut->pcie_rst_n = 1; dut->ucie_rst_n = 1;
    for (int i = 0; i < 5; i++) tick();

    int errors = 0;
    auto chk = [&](bool c, const char* m) { if (!c) { printf("FAIL: %s\n", m); errors++; } };

    chk(dut->ucie_powerdown == PWR_L1, "powerdown should be L1 out of reset");
    chk(dut->ucie_speed == SPEED_64,   "speed should be SPEED_64");
    chk(dut->ucie_width == 0,          "width should be x1");
    chk(dut->ucie_tx_valid == 0,       "no Tx traffic out of reset");
    chk(dut->pcie_tready == 0,         "PCIe ingress closed before link-up");

    // CSR_CTRL (addr 0x00) reset value
    dut->csr_addr = 0x00; dut->eval();
    chk(dut->csr_rdata == (unsigned)((SPEED_64 << 2) | PWR_L0), "CTRL reset value");

    dut->final();
    delete dut;
    if (errors == 0) { printf("VLT SMOKE PASS: reset defaults OK\n"); return 0; }
    printf("VLT SMOKE FAIL: %d error(s)\n", errors); return 1;
}
