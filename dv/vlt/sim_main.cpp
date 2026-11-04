// dv/vlt/sim_main.cpp — Verilator C++ environment (DV env 2) + coverage vehicle.
//   default / +smoke : build the DUT, pulse reset, check the reset/defaults contract.
//   +scen            : run the shared Config-1 loopback scenarios (dv/common/scenarios.py
//                      via dv/common/cpp/adapter_bfm.h), write logs/results.json.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "Vpcie_ucie3d_adapter.h"
#include "verilated.h"
#if VM_COVERAGE
#include "verilated_cov.h"
#endif
#include "adapter_bfm.h"

using namespace adapter_bfm;

// enum values mirror rtl/pcie_ucie3d_pkg.sv
enum { PWR_L1_ = 2, SPEED_64_ = 7, PWR_L0_ = 0 };

static Vpcie_ucie3d_adapter* dut = nullptr;
static vluint64_t main_time = 0;

static void tick() {
    dut->ucie_clk = 0; dut->pcie_clk = 0; dut->eval(); main_time++;
    dut->ucie_clk = 1; dut->pcie_clk = 1; dut->eval(); main_time++;
}

// ---- drive DUT inputs from the harness In structs --------------------------
static void drive(const PcieIn& pin, const UcieIn& uin) {
    dut->pcie_rst_n = pin.rst_n;
    dut->pcie_tvalid = pin.tvalid; dut->pcie_tlast = pin.tlast;
    dut->pcie_tkeep = pin.keep; dut->pcie_tuser = pin.tuser;
    dut->pcie_rx_tready = pin.rx_tready;
    for (int w = 0; w < 8; w++) {
        uint32_t word = 0;
        for (int b = 0; b < 4; b++) word |= uint32_t(pin.data[w * 4 + b]) << (8 * b);
        dut->pcie_tdata[w] = word;
    }
    dut->ucie_rst_n = uin.rst_n;
    dut->ucie_link_status = uin.link_status; dut->ucie_rx_active = uin.rx_active;
    dut->ucie_rx_elec_idle = uin.rx_elec_idle;
    dut->ucie_rx_data = uin.rx_data; dut->ucie_rx_valid = uin.rx_valid;
    dut->ucie_rx_start_flit = uin.rx_start_flit;
    dut->ucie_sb_s2m = uin.sb_s2m;
    dut->csr_valid = uin.csr_valid; dut->csr_write = uin.csr_write;
    dut->csr_addr = uin.csr_addr; dut->csr_wdata = uin.csr_wdata;
}

// ---- sample DUT outputs into the harness Out structs -----------------------
static void sample(PcieOut& po, UcieOut& uo) {
    po.tready = dut->pcie_tready;
    po.rx_tvalid = dut->pcie_rx_tvalid; po.rx_tlast = dut->pcie_rx_tlast;
    po.rx_keep = dut->pcie_rx_tkeep; po.rx_tuser = dut->pcie_rx_tuser;
    for (int w = 0; w < 8; w++) {
        uint32_t word = dut->pcie_rx_tdata[w];
        for (int b = 0; b < 4; b++) po.rx_data[w * 4 + b] = uint8_t(word >> (8 * b));
    }
    uo.tx_valid = dut->ucie_tx_valid; uo.tx_start_flit = dut->ucie_tx_start_flit;
    uo.tx_data = dut->ucie_tx_data;
    uo.powerdown = dut->ucie_powerdown; uo.speed = dut->ucie_speed; uo.width = dut->ucie_width;
    uo.sb_m2s = dut->ucie_sb_m2s; uo.csr_rdata = dut->csr_rdata;
}

// +rand knobs (random regression): +seed=N +frames=N +maxlen=N +gap=PCT +ready=PCT
static bool rand_mode = false;
static uint32_t k_seed = 1;
static int k_frames = 24, k_maxlen = 2000, k_gap = -1, k_ready = -1;
// B1/B2 (all off by default): +ctl=0..3 +nctl=N +mid=0|1 (control ops) +csr=PCT +ncfg=N (CSR traffic) +nrx=N (Rx injection)
static bool k_probe = false;                                   // +probe: debug prints from the BFM
static int k_ctl = 0, k_nctl = 0, k_mid = 0, k_csr = 0, k_ncfg = 0, k_nrx = 0;

static int run_scen() {
    Harness h(rand_mode ? k_seed * 2654435761u + 1 : 12345);
    if (rand_mode) {
        h.rand_mode = true; h.rand_seed = k_seed; h.rand_frames = k_frames; h.rand_maxlen = k_maxlen;
        h.rand_ctl = k_ctl; h.rand_nctl = k_nctl; h.rand_mid = k_mid;
        h.rand_csr = k_csr; h.rand_ncfg = k_ncfg; h.rand_nrx = k_nrx;
    }
    h.set_probe(k_probe);
    if (k_gap >= 0) h.mac_gap_pct = k_gap;
    if (k_ready >= 0) h.sink_ready_pct = k_ready;
    PcieOut po; UcieOut uo;
    // clocks low, initial (reset) inputs applied, settle
    dut->pcie_clk = 0; dut->ucie_clk = 0;
    drive(h.pcie_in(), h.ucie_in());
    dut->eval();
    long long guard = 0;
    while (!h.done && guard < 20000000) {
        sample(po, uo);                               // outputs held before the rising edge
        dut->pcie_clk = 1; dut->ucie_clk = 1; dut->eval();   // rising edge
        h.step(po, uo);                               // compute next inputs from pre-edge outputs
        drive(h.pcie_in(), h.ucie_in());              // apply after the edge
        dut->eval();                                  // settle combinational (incl. loopback)
        dut->pcie_clk = 0; dut->ucie_clk = 0; dut->eval();   // falling edge
        guard++;
    }
    h.fc_summary();
    h.write_json("logs/results.json", "vlt");
    bool ok = h.done && h.total_errors == 0 && h.results.size() == (rand_mode ? 1u : 5u);
    printf("%s: %zu scenarios, %d error(s), %lld cycles\n", ok ? "VLT PASS" : "VLT FAIL",
           h.results.size(), h.total_errors, guard);
    return ok ? 0 : 1;
}

static int run_smoke() {
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
    chk(dut->ucie_powerdown == PWR_L1_, "powerdown should be L1 out of reset");
    chk(dut->ucie_speed == SPEED_64_,   "speed should be SPEED_64");
    chk(dut->ucie_width == 0,           "width should be x1");
    chk(dut->ucie_tx_valid == 0,        "no Tx traffic out of reset (nothing queued)");
    chk(dut->pcie_tready == 0,          "PCIe ingress closed before link-up (M3 gating)");
    dut->csr_addr = 0x00; dut->eval();
    chk(dut->csr_rdata == (unsigned)((SPEED_64_ << 2) | PWR_L0_), "CTRL reset value");

    if (errors == 0) { printf("VLT SMOKE PASS: reset defaults OK\n"); return 0; }
    printf("VLT SMOKE FAIL: %d error(s)\n", errors); return 1;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vpcie_ucie3d_adapter;
    bool scen = false;
    for (int i = 1; i < argc; i++) {
        const char* a = argv[i];
        if (!strcmp(a, "+scen")) scen = true;
        else if (!strcmp(a, "+rand")) { scen = true; rand_mode = true; }
        else if (!strncmp(a, "+seed=", 6)) k_seed = uint32_t(strtoul(a + 6, 0, 0));
        else if (!strncmp(a, "+frames=", 8)) k_frames = atoi(a + 8);
        else if (!strncmp(a, "+maxlen=", 8)) k_maxlen = atoi(a + 8);
        else if (!strncmp(a, "+gap=", 5)) k_gap = atoi(a + 5);
        else if (!strncmp(a, "+ready=", 7)) k_ready = atoi(a + 7);
        else if (!strcmp(a, "+probe")) k_probe = true;
        else if (!strncmp(a, "+ctl=", 5)) k_ctl = atoi(a + 5);
        else if (!strncmp(a, "+nctl=", 6)) k_nctl = atoi(a + 6);
        else if (!strncmp(a, "+mid=", 5)) k_mid = atoi(a + 5);
        else if (!strncmp(a, "+csr=", 5)) k_csr = atoi(a + 5);
        else if (!strncmp(a, "+ncfg=", 6)) k_ncfg = atoi(a + 6);
        else if (!strncmp(a, "+nrx=", 5)) k_nrx = atoi(a + 5);
    }
    int rc = scen ? run_scen() : run_smoke();
    dut->final();
#if VM_COVERAGE
    Verilated::threadContextp()->coveragep()->write("coverage.dat");
#endif
    delete dut;
    return rc;
}
